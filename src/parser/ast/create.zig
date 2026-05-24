const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents the declaration of a type. Hence, as such it does not carry any value
/// Used wherever the type of a column is supposed to be described.
pub const Type = enum {
    Integer,
    Real,
    Text,
    Blob,
};

pub const ColumnDef = struct {
    name: []const u8,
    col_type: Type,
};

pub const CreateTableStatement = struct {
    name: []const u8,
    cols: []ColumnDef,
};
