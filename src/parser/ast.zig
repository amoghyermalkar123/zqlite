const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Statement = union(enum) {
    Select: SelectStatement,
};

pub const SelectStatement = struct {
    core: SelectCore,
    from: SelectFrom,
};

pub const SelectCore = struct {
    result_columns: std.ArrayList(ResultColumn),
};

pub const SelectFrom = union(enum) {
    Table: []const u8,
};

pub const ResultColumn = union(enum) {
    Star,
    Expr: ExprResultColumn,
};

pub const ExprResultColumn = struct {
    expr: Expr,
    alias: ?[]const u8,
};

pub const Expr = union(enum) {
    Column: Column,
};

pub const Column = struct {
    name: []const u8,
};
