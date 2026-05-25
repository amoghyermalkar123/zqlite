const std = @import("std");
const Allocator = std.mem.Allocator;

const Db = @import("db.zig");
const ep = @import("encode_page.zig");
const planner = @import("planner.zig");

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

    _ = try rebuild_and_write_leaf(db, oper.table, leaf);

    return 1;
}

fn allocate_rowid(db: *Db, table: *const Db.TableMetadata) !u64 {
    _ = db;
    _ = table;
    return error.UnsupportedInsert; // Phase 5.1: max scan + 1
}

fn rebuild_and_write_leaf(db: *Db, table: *const Db.TableMetadata, new_cell: []const u8) !void {
    _ = db;
    _ = table;
    _ = new_cell;
    return error.UnsupportedInsert; // Phase 5.2–5.3 + 6.3
}
