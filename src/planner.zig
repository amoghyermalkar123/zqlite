const std = @import("std");
const Allocator = std.mem.Allocator;

const Db = @import("db.zig");
const ast = @import("parser/ast/ast.zig");
const Operator = @import("operator.zig");
const ep = @import("encode_page.zig");
const bind = @import("bind.zig");

pub const InsertOp = struct {
    table: *const Db.TableMetadata,
    fields: []ep.RecordFieldEntry,

    pub fn deinit(self: *InsertOp, alloc: Allocator) void {
        bind.deinitFields(alloc, self.fields);
    }
};

pub const Plan = union(enum) {
    Select: Operator.SeqScan,
    Insert: InsertOp,

    pub fn deinit(self: *Plan, alloc: Allocator) void {
        switch (self.*) {
            .Select => |*scan| scan.deinit(),
            .Insert => |*op| op.deinit(alloc),
        }
    }
};

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

    pub fn compile(self: *Self, statement: ast.Statement) !Plan {
        return switch (statement) {
            .Select => |s| .{ .Select = try self.compile_select(s) },
            .Insert => |s| .{ .Insert = try self.compile_insert(s) },
            .CreateTable => error.UnsupportedStatement,
        };
    }

    fn compile_insert(self: *Self, stmt: ast.Insert.InsertStatement) !InsertOp {
        const table: *const Db.TableMetadata = blk: for (self.db.tables_metadata) |*tm| {
            if (std.mem.eql(u8, tm.name, stmt.table)) {
                break :blk tm;
            }
        } else return error.TableNotFound;

        const fields = try bind.bindInsertValues(self.alloc, table.*, stmt.columns, stmt.values);

        return .{ .fields = fields, .table = table };
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
            try self.db.scanner(self.alloc, table.table_root_page),
        );
    }
};

const t = std.testing;
const sql = @import("parser/parser.zig");

var test_user_cols = [_]ast.Create.ColumnDef{
    .{ .name = "id", .col_type = .Integer },
    .{ .name = "name", .col_type = .Text },
};

var test_users_meta = Db.TableMetadata{
    .name = "users",
    .cols = test_user_cols[0..],
    .table_root_page = 2,
};

var test_tables = [_]Db.TableMetadata{test_users_meta};

fn testDb() Db {
    return .{
        .header = .{ .page_size = 4096, .page_reserved_size = 0 },
        .pager = undefined,
        .tables_metadata = test_tables[0..],
        .alloc = t.allocator,
    };
}

test "compile insert without column list" {
    var fake_db = testDb();
    var planner = Planner.new(&fake_db, t.allocator);

    var parsed = try sql.parse_statement("INSERT INTO users VALUES (3, 'bob')", t.allocator, false);
    defer parsed.deinit();

    var plan = try planner.compile(parsed.statement);
    defer plan.deinit(t.allocator);

    try t.expect(plan == .Insert);
    const op = plan.Insert;
    try t.expect(op.table == &test_users_meta);
    try t.expectEqual(ep.RecordFieldEntry{ .I8 = 3 }, op.fields[0]);
    try t.expect(op.fields[1] == .String);
    try t.expectEqualStrings("bob", op.fields[1].String);
}

test "compile insert with column list binds storage order" {
    var fake_db = testDb();
    var planner = Planner.new(&fake_db, t.allocator);

    var parsed = try sql.parse_statement(
        "INSERT INTO users (name, id) VALUES ('alice', 7)",
        t.allocator,
        false,
    );
    defer parsed.deinit();

    var plan = try planner.compile(parsed.statement);
    defer plan.deinit(t.allocator);

    try t.expect(plan == .Insert);
    const op = plan.Insert;
    try t.expectEqual(ep.RecordFieldEntry{ .I8 = 7 }, op.fields[0]);
    try t.expect(op.fields[1] == .String);
    try t.expectEqualStrings("alice", op.fields[1].String);
}

test "compile insert unknown table" {
    var fake_db = testDb();
    var planner = Planner.new(&fake_db, t.allocator);

    var parsed = try sql.parse_statement("INSERT INTO missing VALUES (1, 'x')", t.allocator, false);
    defer parsed.deinit();

    try t.expectError(error.TableNotFound, planner.compile(parsed.statement));
}

test "compile rejects unsupported statements" {
    var fake_db = testDb();
    var planner = Planner.new(&fake_db, t.allocator);

    var parsed = try sql.parse_statement("CREATE TABLE t (id INTEGER)", t.allocator, false);
    defer parsed.deinit();

    try t.expectError(error.UnsupportedStatement, planner.compile(parsed.statement));
}
