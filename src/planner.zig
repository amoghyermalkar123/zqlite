const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig");
const ast = @import("parser/ast/ast.zig");
const Operator = @import("operator.zig");

pub const Planner = struct {
    db: *Db,
    alloc: Allocator,

    const Self = @This();

    pub fn new(db: *Db, alloc: Allocator) Self {
        return .{
            .db = db,
            .alloc = alloc,
        };
    }

    pub fn compile(self: *Self, statement: ast.Statement) !Operator.SeqScan {
        return switch (statement) {
            .Select => |s| try self.compile_select(s),
            .CreateTable => error.UnsupportedStatement,
            .Insert => error.UnsupportedStatement,
        };
    }

    fn compile_select(self: *Self, stmt: ast.SelectStatement) !Operator.SeqScan {
        const sf = stmt.from.Table;
        const table: Db.TableMetadata = blk: for (self.db.tables_metadata) |tm| {
            if (std.mem.eql(u8, tm.name, sf)) {
                break :blk tm;
            }
        } else return error.TableNotFound;

        // TODO: since we have metadata at comptime, we can statically allocate the
        // required memory here.
        var cols = try std.ArrayList(usize).initCapacity(self.alloc, 1);
        errdefer cols.deinit(self.alloc);

        for (stmt.core.result_columns.items) |res_col| {
            switch (res_col) {
                .Star => {
                    for (table.cols, 0..) |_, ix| try cols.append(self.alloc, ix);
                },
                .Expr => |e| {
                    const cl = e.expr.Column.name;

                    const idx: ?usize = blk: for (table.cols, 0..) |cd, ix| {
                        if (std.mem.eql(u8, cd.name, cl)) break :blk ix;
                    } else null;

                    if (idx) |i| try cols.append(self.alloc, i) else return error.InvalidColumnName;
                },
            }
        }

        return Operator.SeqScan.new(
            self.alloc,
            try cols.toOwnedSlice(self.alloc),
            try self.db.scanner(self.alloc, table.first_page),
        );
    }
};
