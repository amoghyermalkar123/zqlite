const std = @import("std");
const Allocator = std.mem.Allocator;

const Db = @import("db.zig");
const ep = @import("encode_page.zig");
const planner = @import("planner.zig");
const pg = @import("page.zig");

pub const InsertError = error{
    UnsupportedInsert,
    PageFull,
};

pub fn execute_insert(alloc: Allocator, db: *Db, oper: planner.InsertOp) !usize {
    const rowid = try allocate_rowid(db, oper.table);
    const record = try ep.encode_record(alloc, oper.fields);
    defer alloc.free(record);

    const leaf = try ep.encode_table_leaf_cell(alloc, db.header, rowid, record, null);
    defer alloc.free(leaf);

    try rebuild_and_write_leaf(alloc, db, oper.table, leaf);

    return 1;
}

fn allocate_rowid(db: *Db, table: *const Db.TableMetadata) !u64 {
    var scanner = try db.scanner(db.alloc, table.first_page);
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
    const page = try db.pager.read_page(table.first_page);

    switch (page.*) {
        .Interior => return error.UnsupportedInsert,
        .Leaf => |*leaf| {
            if (leaf.header.rightmost_pointer != null) return error.UnsupportedInsert;
            return .{ .leaf = leaf, .page_num = table.first_page };
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

    // TODO: phase 6
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
