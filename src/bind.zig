const db = @import("db.zig");
const ep = @import("encode_page.zig");
const ast = @import("parser/ast/ast.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const BindError = error{
    ColTypeLiteralValMismatch,
    UnsupportedColType,
    ColumnNotFound,
    MismatchedColsAndLiteralLength,
};

pub fn bindLiteral(col_type: ast.Create.Type, lit: ast.Insert.Literal) BindError!ep.RecordFieldEntry {
    return switch (col_type) {
        .Integer => switch (lit) {
            .Null => .Null,
            .Integer => |n| integerEntry(n),
            .String => error.ColTypeLiteralValMismatch,
        },
        .Text => switch (lit) {
            .Null => .Null,
            .String => |s| .{ .String = s },
            .Integer => error.ColTypeLiteralValMismatch,
        },
        .Blob => switch (lit) {
            .Null => .Null,
            .String => |s| .{ .Blob = s },
            .Integer => error.ColTypeLiteralValMismatch,
        },
        .Real => error.UnsupportedColType,
    };
}

fn integerEntry(n: i64) ep.RecordFieldEntry {
    if (n >= std.math.minInt(i8) and n <= std.math.maxInt(i8)) return .{ .I8 = @intCast(n) };
    if (n >= std.math.minInt(i16) and n <= std.math.maxInt(i16)) return .{ .I16 = @intCast(n) };
    if (n >= std.math.minInt(i24) and n <= std.math.maxInt(i24)) return .{ .I24 = @intCast(n) };
    if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) return .{ .I32 = @intCast(n) };
    if (n >= std.math.minInt(i48) and n <= std.math.maxInt(i48)) return .{ .I48 = @intCast(n) };
    return .{ .I64 = n };
}

/// columns is the list of columns, when provided,
/// binds only those columns to record fields, using order defined in metadata
/// if columns is null, binds all columns from table_metadata
///
/// if you provide `columns` the length of `values` should also be the same
/// cotrm
pub fn bindInsertValues(
    alloc: Allocator,
    table: db.TableMetadata,
    columns: ?[]const []const u8,
    values: []const ast.Insert.Literal,
) ![]ep.RecordFieldEntry {
    var out = try alloc.alloc(ep.RecordFieldEntry, table.cols.len);
    errdefer {
        freeOwnedFields(alloc, out);
        alloc.free(out);
    }

    @memset(out, ep.RecordFieldEntry.Null);

    if (columns) |cols| {
        if (cols.len != values.len) return error.MismatchedColsAndLiteralLength;

        for (cols, values) |col, literal| {
            const ix = findColumnIndex(table, col) orelse return error.ColumnNotFound;
            const bound = try bindLiteral(table.cols[ix].col_type, literal);
            out[ix] = try ownField(alloc, bound);
        }

        return out;
    }

    if (values.len != table.cols.len) return error.MismatchedColsAndLiteralLength;

    for (values, 0..) |lit, ix| {
        const bound = try bindLiteral(table.cols[ix].col_type, lit);
        out[ix] = try ownField(alloc, bound);
    }

    return out;
}

fn findColumnIndex(table: db.TableMetadata, name: []const u8) ?usize {
    for (table.cols, 0..) |col, i| {
        if (std.mem.eql(u8, col.name, name)) return i;
    }
    return null;
}

fn freeOwnedFields(alloc: Allocator, fields: []ep.RecordFieldEntry) void {
    for (fields) |f| switch (f) {
        .String, .Blob => |s| alloc.free(s),
        else => {},
    };
}

pub fn deinitFields(alloc: Allocator, fields: []ep.RecordFieldEntry) void {
    freeOwnedFields(alloc, fields);
    alloc.free(fields);
}

/// given the field converts the borrwed strings/ blobs into owned slices
/// cotrm
fn ownField(alloc: Allocator, field: ep.RecordFieldEntry) !ep.RecordFieldEntry {
    return switch (field) {
        .String => |s| .{ .String = try alloc.dupe(u8, s) },
        .Blob => |b| .{ .Blob = try alloc.dupe(u8, b) },
        else => field,
    };
}

const t = std.testing;

var test_user_cols = [_]ast.Create.ColumnDef{
    .{ .name = "id", .col_type = .Integer },
    .{ .name = "name", .col_type = .Text },
};

fn testUsersTable() db.TableMetadata {
    return .{
        .name = "users",
        .cols = test_user_cols[0..],
        .first_page = 2,
    };
}

test "bind insert without column list" {
    const table = testUsersTable();
    const fields = try bindInsertValues(t.allocator, table, null, &.{
        .{ .Integer = 3 },
        .{ .String = "bob" },
    });
    defer deinitFields(t.allocator, fields);

    try t.expectEqual(ep.RecordFieldEntry{ .I8 = 3 }, fields[0]);
    try t.expect(fields[1] == .String);
    try t.expectEqualStrings("bob", fields[1].String);
}

test "bind insert with column list reorder" {
    const table = testUsersTable();
    const fields = try bindInsertValues(t.allocator, table, &.{ "name", "id" }, &.{
        .{ .String = "bob" },
        .{ .Integer = 3 },
    });
    defer deinitFields(t.allocator, fields);

    try t.expectEqual(ep.RecordFieldEntry{ .I8 = 3 }, fields[0]);
    try t.expect(fields[1] == .String);
    try t.expectEqualStrings("bob", fields[1].String);
}

test "bind insert partial column list leaves others null" {
    const table = testUsersTable();
    const fields = try bindInsertValues(t.allocator, table, &.{"name"}, &.{.{ .String = "bob" }});
    defer deinitFields(t.allocator, fields);

    try t.expect(fields[0] == .Null);
    try t.expect(fields[1] == .String);
    try t.expectEqualStrings("bob", fields[1].String);
}

test "bind insert type mismatch" {
    const table = testUsersTable();
    try t.expectError(
        error.ColTypeLiteralValMismatch,
        bindInsertValues(t.allocator, table, &[_][]const u8{"id"}, &[_]ast.Insert.Literal{.{ .String = "not-a-number" }}),
    );
}

test "bind insert column not found" {
    const table = testUsersTable();
    try t.expectError(
        error.ColumnNotFound,
        bindInsertValues(t.allocator, table, &[_][]const u8{"missing"}, &[_]ast.Insert.Literal{.{ .Integer = 1 }}),
    );
}

test "bind insert without column list rejects wrong value count" {
    const table = testUsersTable(); // id + name => 2 cols
    try t.expectError(
        error.MismatchedColsAndLiteralLength,
        bindInsertValues(t.allocator, table, null, &.{.{ .Integer = 1 }}),
    );
}
