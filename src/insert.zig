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

    try rebuild_and_write_leaf(alloc, db, oper.table, leaf);

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

/// for now, loads the first page. Also the first page is always a leaf page
/// until node splitting support is implemented.
fn load_target_leaf(db: *Db, table: *const Db.TableMetadata) !TargetLeaf {
    const page = try db.pager.read_page(table.table_root_page);

    switch (page.*) {
        .Interior => return error.UnsupportedInsert,
        .Leaf => |*leaf| {
            if (leaf.header.rightmost_pointer != null) return error.UnsupportedInsert;
            return .{ .leaf = leaf, .page_num = table.table_root_page };
        },
    }
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

fn rebuild_and_write_leaf(alloc: Allocator, db: *Db, table: *const Db.TableMetadata, new_cell: []const u8) !void {
    const tl = try load_target_leaf(db, table);
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
        error.PageTooSmall => return error.PageFull,
        else => |x| return x,
    };

    defer alloc.free(new_page_buf);

    try db.pager.write_raw_page(tl.page_num, new_page_buf);
    try db.pager.flush();
}

fn rowid_from_cell(cell: []const u8) !u64 {
    const varint = @import("varint.zig");
    const ps = try varint.decode(cell, 0);
    const rid = try varint.decode(cell, ps.len);
    return rid.value;
}

const t = std.testing;
const pgm = @import("pager_manager.zig");
const Scanner = @import("scanner.zig");
const PageBuilder = @import("testing/page_builder.zig").PageBuilder;

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
