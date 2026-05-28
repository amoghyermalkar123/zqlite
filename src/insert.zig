const std = @import("std");
const Allocator = std.mem.Allocator;

const Db = @import("db.zig");
const ep = @import("encode_page.zig");
const planner = @import("planner.zig");
const pg = @import("page.zig");
const ast = @import("parser/ast/ast.zig");
const OverflowScanner = @import("overflow_scanner.zig");

pub const InsertError = error{
    UnsupportedInsert,
    PageFull,
    EmptyDB,
    OverflowChunkTooLarge,
};

pub fn execute_insert(alloc: Allocator, db: *Db, oper: planner.InsertOp) !usize {
    const rowid = try allocate_rowid(db, oper.table);
    const record = try ep.encode_record(alloc, oper.fields);
    defer alloc.free(record);

    const layout = try ep.table_leaf_payload_layout(db.header, record.len);
    const first_ov: ?u32 = if (layout.overflow_bytes != null) blk: {
        const tail = record[layout.local..];
        break :blk try write_overflow_chain(alloc, &db.pager, db.header, tail);
    } else null;

    const leaf = try ep.encode_table_leaf_cell(alloc, db.header, rowid, record, first_ov);
    defer alloc.free(leaf);

    try rebuild_and_write_leaf(alloc, db, oper.table, rowid, leaf);

    return 1;
}

fn write_overflow_chain(alloc: Allocator, pager: *pgm, db_header: pg.DbHeader, tail: []const u8) !u32 {
    // deduct the 4 bytes which store the pointer to the next overflow page
    const chunk_cap = db_header.usable_page_size() - 4;
    // how many overflow pages do we need to fit tail.len?
    // chunk_cap - 1 for correction of page counts otherwise it'd count 1 extra
    const page_count = (tail.len + chunk_cap - 1) / chunk_cap;
    const next_page_number = try pager.alloc_next_page_number();
    var offset: usize = 0;

    for (0..page_count) |i| {
        const page_num = next_page_number + i;
        const writable_chunk_len = @min(chunk_cap, tail.len - offset);
        const next: ?u32 = if (i + 1 < page_count) @intCast(page_num + 1) else null;
        const buf = try ep.encode_overflow_page(alloc, db_header, next, tail[offset..][0..writable_chunk_len]);
        defer alloc.free(buf);
        try pager.write_raw_page(page_num, buf);
        offset += writable_chunk_len;
    }

    try pager.bump_database_page_count(page_count);
    return @intCast(next_page_number);
}

fn allocate_rowid(db: *Db, table: *const Db.TableMetadata) !u64 {
    var scanner = try db.scanner(db.alloc, table.table_root_page);
    defer scanner.page_stack.deinit(db.alloc);
    return try scanner.max_rowid();
}

const TargetLeaf = struct {
    page_num: usize,
    leaf: *const pg.TableLeafPage,
};

/// returns the leaf where the data for the row can be found
/// loops interior pages until the target leaf is found
fn load_target_leaf(db: *Db, table: *const Db.TableMetadata, rowid: u64) !TargetLeaf {
    var page_num = table.table_root_page;

    while (true) {
        const page = try db.pager.read_page(page_num);
        switch (page.*) {
            .Interior => |*interior| {
                page_num = try child_page_for_rowid(interior, rowid);
            },
            .Leaf => |*leaf| return .{ .leaf = leaf, .page_num = page_num },
        }
    }
}

fn child_page_for_rowid(interior: *const pg.TableInteriorPage, rowid: u64) !usize {
    for (interior.cells.items) |cell| {
        if (rowid <= @as(u64, @intCast(cell.key))) {
            return cell.left_child_page;
        }
    }

    const rm = interior.header.rightmost_pointer orelse unreachable;
    return rm;
}

fn collect_existing_cells(alloc: Allocator, db: *Db, target: TargetLeaf) ![][]const u8 {
    var cells = try std.ArrayList([]const u8).initCapacity(alloc, target.leaf.cells.items.len);
    errdefer {
        for (cells.items) |ce| {
            alloc.free(ce);
        }
        cells.deinit(alloc);
    }

    for (target.leaf.cells.items) |cell| {
        const ov: ?u32 = if (cell.first_overflow) |p| @intCast(p) else null;
        const enc_cell = try ep.encode_table_leaf_cell(alloc, db.header, @intCast(cell.row_id), cell.payload, ov);
        try cells.append(alloc, enc_cell);
    }

    return cells.toOwnedSlice(alloc);
}

fn rebuild_and_write_leaf(alloc: Allocator, db: *Db, table: *const Db.TableMetadata, rowid: u64, new_cell: []const u8) !void {
    const tl = try load_target_leaf(db, table, rowid);
    const exi = try collect_existing_cells(alloc, db, tl);

    var all = try std.ArrayList([]const u8).initCapacity(alloc, exi.len + 1);
    errdefer {
        for (all.items) |c| alloc.free(c);
        all.deinit(alloc);
    }

    defer alloc.free(exi);

    for (exi) |e| try all.append(alloc, e);
    try all.append(alloc, try alloc.dupe(u8, new_cell));

    defer {
        for (all.items) |c| alloc.free(c);
        all.deinit(alloc);
    }

    std.sort.pdq([]const u8, all.items, {}, struct {
        pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const ra = rowid_from_cell(a) catch unreachable;
            const rb = rowid_from_cell(b) catch unreachable;
            return ra < rb;
        }
    }.lessThan);

    const new_page_buf = ep.encode_leaf_page(alloc, db.header, all.items) catch |e| switch (e) {
        error.PageTooSmall => {
            try split_and_insert_leaf(alloc, db, table, rowid, all.items);
            return;
        },
        else => |x| return x,
    };

    defer alloc.free(new_page_buf);

    try db.pager.write_raw_page(tl.page_num, new_page_buf);
    try db.pager.flush();
}

const InsertContext = struct {
    target_leaf_page: usize,
    target_interior_page_parent: ?usize, // null => target was root (leaf or interior)
};

/// loads the context required for conducting a potential split insert
/// traverses the tree until it finds the matched leaf page
/// keeps track of the traversal stack. When it finds the matched leaf page based on the
/// provided `rowid`, returns it as part of the insert context along with it's immediate
/// Interior page parent
fn load_insert_context(db: *Db, table: *const Db.TableMetadata, rowid: u64) !InsertContext {
    var page_num = table.table_root_page;
    var parent: ?usize = null;

    while (true) {
        const page = try db.pager.read_page(page_num);
        switch (page.*) {
            .Interior => |*interior| {
                parent = page_num;
                page_num = try child_page_for_rowid(interior, rowid);
            },
            .Leaf => return .{
                .target_leaf_page = page_num,
                .target_interior_page_parent = parent,
            },
        }
    }
}

fn set_table_root_page(db: *Db, table: *const Db.TableMetadata, new_root: usize) void {
    for (db.tables_metadata) |*tm| {
        if (tm.name.ptr == table.name.ptr) {
            tm.table_root_page = new_root;
            return;
        }
    }
}

fn split_and_insert_leaf(alloc: Allocator, db: *Db, table: *const Db.TableMetadata, rowid: u64, cells: []const []const u8) !void {
    const ctx = try load_insert_context(db, table, rowid);
    const split = try split_cells(alloc, db.header, cells);

    const left_buf = try ep.encode_leaf_page(alloc, db.header, split.left);
    defer alloc.free(left_buf);

    const new_right_page_num = try db.pager.alloc_next_page_number();

    const right_buf = try ep.encode_leaf_page(alloc, db.header, split.right);
    defer alloc.free(right_buf);

    try db.pager.write_raw_page(ctx.target_leaf_page, left_buf);
    try db.pager.write_raw_page(new_right_page_num, right_buf);

    const new_left_child_page = try ep.encode_table_interior_cell(alloc, @intCast(ctx.target_leaf_page), split.divider_key);
    errdefer alloc.free(new_left_child_page);

    if (ctx.target_interior_page_parent) |pi| {
        const par = try db.pager.read_page(pi);
        // allocate new interior cells
        var new_interior_cells = try std.ArrayList([]const u8).initCapacity(alloc, par.Interior.cells.items.len + 1);
        errdefer {
            for (new_interior_cells.items) |ce| alloc.free(ce);
            new_interior_cells.deinit(alloc);
        }
        // encode each cell
        for (par.Interior.cells.items) |cell| {
            const enc = try ep.encode_table_interior_cell(alloc, cell.left_child_page, @intCast(cell.key));
            try new_interior_cells.append(alloc, enc);
        }
        // now add the new cell which points to the split page
        try new_interior_cells.append(alloc, new_left_child_page);
        // encode a new interior page with new interior cells
        const parent_buf = ep.encode_interior_page(alloc, db.header, new_interior_cells.items, @intCast(new_right_page_num)) catch |e| switch (e) {
            error.PageTooSmall => return error.PageFull,
            else => |x| return x,
        };
        defer alloc.free(parent_buf);

        defer {
            for (new_interior_cells.items) |ce| alloc.free(ce);
            new_interior_cells.deinit(alloc);
        }
        // write to file
        try db.pager.write_raw_page(pi, parent_buf);
        try db.pager.bump_database_page_count(1);
    } else {
        defer alloc.free(new_left_child_page);

        const new_root = new_right_page_num + 1;
        const new_root_page = ep.encode_interior_page(alloc, db.header, &.{new_left_child_page}, @intCast(new_right_page_num)) catch |e| switch (e) {
            error.PageTooSmall => return error.PageFull,
            else => |x| return x,
        };
        defer alloc.free(new_root_page);

        try db.pager.write_raw_page(new_root, new_root_page);
        set_table_root_page(db, table, new_root);
        try db.pager.bump_database_page_count(2);
    }

    try db.pager.flush();
}

fn split_cells(
    alloc: Allocator,
    db_header: pg.DbHeader,
    cells: []const []const u8,
) !struct { left: []const []const u8, right: []const []const u8, divider_key: u64 } {
    if (cells.len < 2) return error.PageFull;

    for (1..cells.len) |split_index| {
        const left = cells[0..split_index];
        const right = cells[split_index..];

        const left_buf = ep.encode_leaf_page(alloc, db_header, left) catch continue;
        defer alloc.free(left_buf);
        const right_buf = ep.encode_leaf_page(alloc, db_header, right) catch continue;
        defer alloc.free(right_buf);

        const divkey = try rowid_from_cell(left[left.len - 1]);
        return .{ .divider_key = divkey, .left = left, .right = right };
    }

    return error.PageFull;
}

// TODO: this should be part of varint
fn rowid_from_cell(cell: []const u8) !u64 {
    const varint = @import("varint.zig");
    const ps = try varint.decode(cell, 0);
    const rid = try varint.decode(cell, ps.len);
    return rid.value;
}

pub fn update_table_rootpage_in_master(db: *Db, table_name: []const u8, new_root: usize) !void {
    _ = db;
    _ = table_name;
    _ = new_root;
    return error.NotImplemented;
}

const t = std.testing;
const pgm = @import("pager_manager.zig");
const Scanner = @import("scanner.zig");
const PageBuilder = @import("testing/page_builder.zig").PageBuilder;

fn write_interior_tree_fixture(alloc: Allocator, pm: *pgm, db_header: pg.DbHeader) !void {
    var leaf3 = try PageBuilder.init(alloc, .Leaf, db_header);
    defer leaf3.deinit();
    try leaf3.addLeafCell(1, &.{.{ .I32 = 10 }});
    try leaf3.addLeafCell(5, &.{.{ .I32 = 50 }});
    const page3 = try leaf3.build();
    defer alloc.free(page3);
    try pm.write_raw_page(3, page3);

    var leaf4 = try PageBuilder.init(alloc, .Leaf, db_header);
    defer leaf4.deinit();
    try leaf4.addLeafCell(10, &.{.{ .I32 = 100 }});
    try leaf4.addLeafCell(20, &.{.{ .I32 = 200 }});
    const page4 = try leaf4.build();
    defer alloc.free(page4);
    try pm.write_raw_page(4, page4);

    const interior_cell = try ep.encode_table_interior_cell(alloc, 3, 5);
    defer alloc.free(interior_cell);
    const page2 = try ep.encode_interior_page(alloc, db_header, &.{interior_cell}, 4);
    defer alloc.free(page2);
    try pm.write_raw_page(2, page2);
}

test "child_page_for_rowid picks subtree by rowid" {
    const db_header = pg.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    const interior_cell = try ep.encode_table_interior_cell(t.allocator, 3, 5);
    defer t.allocator.free(interior_cell);

    const page_buf = try ep.encode_interior_page(t.allocator, db_header, &.{interior_cell}, 4);
    defer t.allocator.free(page_buf);

    var parsed = try pg.parse_page(t.allocator, page_buf, 2, &db_header);
    defer pg.deinitPage(t.allocator, &parsed);

    const interior = &parsed.Interior;
    try t.expectEqual(@as(usize, 3), try child_page_for_rowid(interior, 1));
    try t.expectEqual(@as(usize, 3), try child_page_for_rowid(interior, 5));
    try t.expectEqual(@as(usize, 4), try child_page_for_rowid(interior, 6));
    try t.expectEqual(@as(usize, 4), try child_page_for_rowid(interior, 21));
}

test "load_target_leaf descends interior root to correct leaf" {
    var scratch: [65536]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const alloc = fba.allocator();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const db_header = pg.DbHeader{
        .page_size = 4096,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(alloc, .Leaf, db_header);
    defer builder.deinit();
    const file_image = try builder.buildPageFile(4);
    defer alloc.free(file_image);

    var file = try tmp.dir.createFile(t.io, "interior-root.db", .{ .read = true });
    defer file.close(t.io);

    var writer_buf: [256]u8 = undefined;
    var file_writer = file.writer(t.io, &writer_buf);
    try file_writer.interface.writeAll(file_image);

    var pm = try pgm.new(alloc, t.io, file);
    defer pm.deinit();

    try write_interior_tree_fixture(alloc, &pm, db_header);

    const table_meta = Db.TableMetadata{
        .name = "t",
        .cols = &.{},
        .table_root_page = 2,
    };
    var tables = [_]Db.TableMetadata{table_meta};
    var db = Db{
        .header = db_header,
        .pager = pm,
        .tables_metadata = tables[0..],
        .alloc = alloc,
    };

    const left = try load_target_leaf(&db, &tables[0], 3);
    try t.expectEqual(@as(usize, 3), left.page_num);
    try t.expectEqual(@as(i64, 5), left.leaf.cells.items[left.leaf.cells.items.len - 1].row_id);

    const right = try load_target_leaf(&db, &tables[0], 21);
    try t.expectEqual(@as(usize, 4), right.page_num);
    try t.expectEqual(@as(i64, 20), right.leaf.cells.items[right.leaf.cells.items.len - 1].row_id);
}

test "load_target_leaf returns single-leaf root unchanged" {
    var scratch: [49152]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const alloc = fba.allocator();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const db_header = pg.DbHeader{
        .page_size = 4096,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(alloc, .Leaf, db_header);
    defer builder.deinit();
    try builder.addLeafCell(1, &.{.{ .I32 = 10 }});
    const file_image = try builder.buildPageFile(2);
    defer alloc.free(file_image);

    var file = try tmp.dir.createFile(t.io, "single-leaf.db", .{ .read = true });
    defer file.close(t.io);

    var writer_buf: [256]u8 = undefined;
    var file_writer = file.writer(t.io, &writer_buf);
    try file_writer.interface.writeAll(file_image);

    var pm = try pgm.new(alloc, t.io, file);
    defer pm.deinit();

    const table_meta = Db.TableMetadata{
        .name = "t",
        .cols = &.{},
        .table_root_page = 2,
    };
    var tables = [_]Db.TableMetadata{table_meta};
    var db = Db{
        .header = db_header,
        .pager = pm,
        .tables_metadata = tables[0..],
        .alloc = alloc,
    };

    const tl = try load_target_leaf(&db, &tables[0], 2);
    try t.expectEqual(@as(usize, 2), tl.page_num);
    try t.expectEqual(@as(usize, 1), tl.leaf.cells.items.len);
}

test "max_rowid increments" {
    var scratch: [49152]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const alloc = fba.allocator();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const db_header = pg.DbHeader{
        .page_size = 4096,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(alloc, .Leaf, db_header);
    defer builder.deinit();
    try builder.addLeafCell(1, &.{.{ .I32 = 10 }});
    try builder.addLeafCell(5, &.{.{ .I32 = 50 }});

    const file_image = try builder.buildPageFile(2);
    defer alloc.free(file_image);

    var file = try tmp.dir.createFile(t.io, "two-rows.db", .{ .read = true });
    defer file.close(t.io);

    var writer_buf: [256]u8 = undefined;
    var file_writer = file.writer(t.io, &writer_buf);
    try file_writer.interface.writeAll(file_image);

    var pm = try pgm.new(alloc, t.io, file);
    defer pm.deinit();

    var scanner = try Scanner.new(&pm, alloc, 2);
    defer scanner.page_stack.deinit(alloc);

    try t.expectEqual(@as(u64, 6), try scanner.max_rowid());
}

test "insert large text writes overflow chain" {
    var scratch: [131072]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const alloc = fba.allocator();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const db_header = pg.DbHeader{
        .page_size = 4096,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(alloc, .Leaf, db_header);
    defer builder.deinit();
    const file_image = try builder.buildPageFile(2);
    defer alloc.free(file_image);

    var file = try tmp.dir.createFile(t.io, "overflow-insert.db", .{ .read = true });
    defer file.close(t.io);

    var writer_buf: [256]u8 = undefined;
    var file_writer = file.writer(t.io, &writer_buf);
    try file_writer.interface.writeAll(file_image);

    var pm = try pgm.new(alloc, t.io, file);
    defer pm.deinit();

    const big = try alloc.alloc(u8, 12_000);
    defer alloc.free(big);
    @memset(big, 'z');

    var data_cols = [_]ast.Create.ColumnDef{
        .{ .name = "data", .col_type = .Text },
    };
    var table_meta = Db.TableMetadata{
        .name = "items",
        .cols = data_cols[0..],
        .table_root_page = 2,
    };
    var tables = [_]Db.TableMetadata{table_meta};

    var db = Db{
        .header = db_header,
        .pager = pm,
        .tables_metadata = tables[0..],
        .alloc = alloc,
    };

    var fields = [_]ep.RecordFieldEntry{.{ .String = big }};
    const op = planner.InsertOp{
        .table = &table_meta,
        .fields = fields[0..],
    };

    try t.expectEqual(@as(usize, 1), try execute_insert(alloc, &db, op));

    var pm2 = try pgm.new(alloc, t.io, file);
    defer pm2.deinit();

    const leaf_page = try pm2.read_page(2);
    try t.expectEqual(@as(usize, 1), leaf_page.Leaf.cells.items.len);

    const cell = leaf_page.Leaf.cells.items[0];
    const first_overflow = cell.first_overflow orelse return error.TestExpectedOverflow;
    try t.expectEqual(@as(i64, 1), cell.row_id);

    const layout = try ep.table_leaf_payload_layout(db_header, @intCast(cell.size));
    const tail_len = layout.overflow_bytes orelse return error.TestExpectedOverflow;

    var ov_scanner = OverflowScanner.new(alloc, &pm2);
    const tail = try ov_scanner.read(first_overflow, tail_len);
    defer alloc.free(tail.data);

    try t.expectEqual(tail_len, tail.data.len);
    for (tail.data) |b| try t.expectEqual('z', b);

    // 12k-byte tail needs multiple overflow pages; last page must have no next pointer.
    const chunk_cap = db_header.usable_page_size() - 4;
    const overflow_page_count = (tail_len + chunk_cap - 1) / chunk_cap;
    try t.expect(overflow_page_count >= 2);

    const last_page = first_overflow + overflow_page_count - 1;
    const last_ov = try pm2.read_overflow(last_page);
    try t.expect(last_ov.next == null);
}

test "insert splits full leaf root into interior btree" {
    var scratch: [262144]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const alloc = fba.allocator();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const db_header = pg.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(alloc, .Leaf, db_header);
    defer builder.deinit();

    var packed_rowid: u64 = 1;
    while (true) {
        try builder.addLeafCell(packed_rowid, &.{.{ .I32 = @intCast(packed_rowid) }});
        const trial = builder.build() catch {
            builder.deinit();
            builder = try PageBuilder.init(alloc, .Leaf, db_header);
            const full_count = packed_rowid - 1;
            for (1..full_count + 1) |rid| {
                try builder.addLeafCell(rid, &.{.{ .I32 = @intCast(rid) }});
            }
            break;
        };
        alloc.free(trial);
        packed_rowid += 1;
    }
    try t.expect(packed_rowid > 1);

    const file_image = try builder.buildPageFile(2);
    defer alloc.free(file_image);

    var file = try tmp.dir.createFile(t.io, "split-leaf.db", .{ .read = true });
    defer file.close(t.io);

    var writer_buf: [256]u8 = undefined;
    var file_writer = file.writer(t.io, &writer_buf);
    try file_writer.interface.writeAll(file_image);

    var pm = try pgm.new(alloc, t.io, file);
    defer pm.deinit();

    var tables = [_]Db.TableMetadata{.{
        .name = "t",
        .cols = &.{},
        .table_root_page = 2,
    }};
    var db = Db{
        .header = db_header,
        .pager = pm,
        .tables_metadata = tables[0..],
        .alloc = alloc,
    };

    const insert_rowid = packed_rowid;
    var fields = [_]ep.RecordFieldEntry{.{ .I32 = @intCast(insert_rowid) }};
    const op = planner.InsertOp{
        .table = &tables[0],
        .fields = fields[0..],
    };

    try t.expectEqual(@as(usize, 1), try execute_insert(alloc, &db, op));

    const root_page = try pm.read_page(tables[0].table_root_page);
    try t.expect(root_page.* == .Interior);
    try t.expectEqual(@as(usize, 1), root_page.Interior.cells.items.len);

    const left_page = try pm.read_page(root_page.Interior.cells.items[0].left_child_page);
    try t.expect(left_page.* == .Leaf);

    const right_page_num = root_page.Interior.header.rightmost_pointer orelse return error.TestExpectedRightmost;
    const right_page = try pm.read_page(right_page_num);
    try t.expect(right_page.* == .Leaf);

    const total_cells = left_page.Leaf.cells.items.len + right_page.Leaf.cells.items.len;
    try t.expectEqual(@as(usize, @intCast(insert_rowid)), total_cells);

    var scanner = try Scanner.new(&pm, alloc, tables[0].table_root_page);
    defer scanner.page_stack.deinit(alloc);
    try t.expectEqual(@as(u64, insert_rowid + 1), try scanner.max_rowid());
}

test "insert splits rightmost leaf under interior root" {
    var scratch: [65536]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const alloc = fba.allocator();

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    const db_header = pg.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(alloc, .Leaf, db_header);
    defer builder.deinit();
    const file_image = try builder.buildPageFile(4);
    defer alloc.free(file_image);

    var file = try tmp.dir.createFile(t.io, "split-interior.db", .{ .read = true });
    defer file.close(t.io);

    var writer_buf: [256]u8 = undefined;
    var file_writer = file.writer(t.io, &writer_buf);
    try file_writer.interface.writeAll(file_image);

    var pm = try pgm.new(alloc, t.io, file);
    defer pm.deinit();

    var leaf4 = try PageBuilder.init(alloc, .Leaf, db_header);
    defer leaf4.deinit();

    var packed_rowid: u64 = 10;
    while (true) {
        try leaf4.addLeafCell(packed_rowid, &.{.{ .I32 = @intCast(packed_rowid) }});
        const trial = leaf4.build() catch {
            leaf4.deinit();
            leaf4 = try PageBuilder.init(alloc, .Leaf, db_header);
            const full_count = packed_rowid - 1;
            for (10..full_count + 1) |rid| {
                try leaf4.addLeafCell(rid, &.{.{ .I32 = @intCast(rid) }});
            }
            break;
        };
        alloc.free(trial);
        packed_rowid += 1;
    }
    try t.expect(packed_rowid > 11);

    const page4 = try leaf4.build();
    defer alloc.free(page4);
    try pm.write_raw_page(4, page4);

    var leaf3 = try PageBuilder.init(alloc, .Leaf, db_header);
    defer leaf3.deinit();
    try leaf3.addLeafCell(1, &.{.{ .I32 = 1 }});
    try leaf3.addLeafCell(5, &.{.{ .I32 = 5 }});
    const page3 = try leaf3.build();
    defer alloc.free(page3);
    try pm.write_raw_page(3, page3);

    const interior_cell = try ep.encode_table_interior_cell(alloc, 3, 5);
    defer alloc.free(interior_cell);
    const page2 = try ep.encode_interior_page(alloc, db_header, &.{interior_cell}, 4);
    defer alloc.free(page2);
    try pm.write_raw_page(2, page2);

    var tables = [_]Db.TableMetadata{.{
        .name = "t",
        .cols = &.{},
        .table_root_page = 2,
    }};
    var db = Db{
        .header = db_header,
        .pager = pm,
        .tables_metadata = tables[0..],
        .alloc = alloc,
    };

    const insert_rowid = packed_rowid;
    var fields = [_]ep.RecordFieldEntry{.{ .I32 = @intCast(insert_rowid) }};
    const op = planner.InsertOp{
        .table = &tables[0],
        .fields = fields[0..],
    };

    try t.expectEqual(@as(usize, 1), try execute_insert(alloc, &db, op));

    const interior = try pm.read_page(2);
    try t.expectEqual(@as(usize, 2), interior.Interior.cells.items.len);
    try t.expect(interior.Interior.header.rightmost_pointer != 4);

    var scanner = try Scanner.new(&pm, alloc, 2);
    defer scanner.page_stack.deinit(alloc);

    var count: usize = 0;
    var rec = try scanner.next_record();
    while (rec != null) : (rec = try scanner.next_record()) {
        defer rec.?.deinit();
        count += 1;
    }
    // left leaf (2 rows) + packed right rows + inserted row
    try t.expectEqual(@as(usize, 2 + (packed_rowid - 10) + 1), count);
}
