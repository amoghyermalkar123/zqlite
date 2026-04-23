const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Create = @import("create.zig");

pub const Statement = union(enum) {
    Select: SelectStatement,
    CreateTable: Create.CreateTableStatement,
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

// ResultColumn represents a column expression, so it could be * which means
// all columns ot it could be an ExprResultColumn which means explicit columns
// with optional aliases defined
pub const ResultColumn = union(enum) {
    Star,
    Expr: ExprResultColumn,
};

// ExprResultColumn represents an expression of the form columnName as col
pub const ExprResultColumn = struct {
    expr: Expr,
    alias: ?[]const u8,
};

// An expression is a column
pub const Expr = union(enum) {
    Column: Column,
};

// A column
pub const Column = struct {
    name: []const u8,
};
