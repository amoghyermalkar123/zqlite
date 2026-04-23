const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Type = enum {
    Integer,
    Real,
    Text,
    Blob,
};

pub const ColumnDef = union(enum) {
    name: []const u8,
    col_type: Type,
};

pub const CreateTableStatement = struct {
    name: []const u8,
    cols: []ColumnDef,
};
