const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const ast = @import("ast/ast.zig");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEndOfInput,
};

const ParserState = struct {
    tokens: []const Token,
    pos: usize,

    const Self = @This();

    fn init(tokens: []const Token) Self {
        return .{
            .tokens = tokens,
            .pos = 0,
        };
    }

    // parse_statement parses a sql statement
    // cotrm
    fn parse_statement(self: *Self, alloc: Allocator) !ast.Statement {
        switch (self.peek() orelse return error.UnexpectedEndOfInput) {
            .Select => return .{ .Select = try self.parse_select(alloc) },
            .Create => return .{ .CreateTable = try self.parse_create_table(alloc) },
            .Insert => return .{ .Insert = try self.parse_insert(alloc) },
            else => return error.UnexpectedToken,
        }
        unreachable;
    }

    fn parse_insert(self: *Self, alloc: Allocator) !ast.Insert.InsertStatement {
        _ = try self.expectNextTokenEq(Token.Insert);
        _ = try self.expectNextTokenEq(Token.Into);

        const table_name = try self.expectIdentifier();

        const columns: ?[]const []const u8 = if (self.nextTokenIs(Token.Lpar))
            try self.parse_column_list(alloc)
        else
            null;

        _ = try self.expectNextTokenEq(Token.Values);
        _ = try self.expectNextTokenEq(Token.Lpar);
        const values = try self.parse_literal_list(alloc);
        _ = try self.expectNextTokenEq(Token.Rpar);

        return .{
            .table = table_name,
            .columns = columns,
            .values = values,
        };
    }

    fn parse_column_list(self: *Self, alloc: Allocator) ![]const []const u8 {
        _ = try self.expectNextTokenEq(Token.Lpar);

        var names = try std.ArrayList([]const u8).initCapacity(alloc, 1);
        errdefer names.deinit(alloc);

        try names.append(alloc, try self.expectIdentifier());

        while (self.nextTokenIs(Token.Comma)) {
            self.advance();
            try names.append(alloc, try self.expectIdentifier());
        }

        _ = try self.expectNextTokenEq(Token.Rpar);
        return try names.toOwnedSlice(alloc);
    }

    fn parse_literal_list(self: *Self, alloc: Allocator) ![]ast.Insert.Literal {
        var literals = try std.ArrayList(ast.Insert.Literal).initCapacity(alloc, 1);
        errdefer literals.deinit(alloc);

        try literals.append(alloc, try self.parse_literal(alloc));

        while (self.nextTokenIs(Token.Comma)) {
            self.advance();
            try literals.append(alloc, try self.parse_literal(alloc));
        }

        return try literals.toOwnedSlice(alloc);
    }

    fn parse_literal(self: *Self, alloc: Allocator) !ast.Insert.Literal {
        const tkn = self.nextToken() orelse return error.UnexpectedEndOfInput;
        return switch (tkn) {
            .Null => .Null,
            .Integer => |n| .{ .Integer = n },
            .StringLiteral => |s| .{ .String = try alloc.dupe(u8, s) },
            else => error.UnexpectedToken,
        };
    }

    // parses a create table statement
    // cotrm
    fn parse_create_table(self: *Self, alloc: Allocator) !ast.Create.CreateTableStatement {
        _ = try self.expectNextTokenEq(Token.Create);
        _ = try self.expectNextTokenEq(Token.Table);

        const table_name = try self.expectIdentifier();
        _ = try self.expectNextTokenEq(Token.Lpar);

        var column_defs = try std.ArrayList(ast.Create.ColumnDef).initCapacity(alloc, 1);
        errdefer column_defs.deinit(alloc);

        const first_def = try self.parse_column_def();
        try column_defs.append(alloc, first_def);

        while (self.nextTokenIs(Token.Comma)) {
            self.advance();
            try column_defs.append(alloc, try self.parse_column_def());
        }

        _ = try self.expectNextTokenEq(Token.Rpar);

        return .{
            .name = table_name,
            .cols = try column_defs.toOwnedSlice(alloc),
        };
    }

    // parse_select parses a select statement
    fn parse_select(self: *Self, alloc: Allocator) !ast.SelectStatement {
        // the first token should be select
        _ = try self.expectNextTokenEq(Token.Select);
        // TODO: do we have to free this list or no? since we are creating
        // a new one from this at the return site.
        const cols = try self.parse_result_columns(alloc);
        _ = try self.expectNextTokenEq(Token.From);
        const from = try self.parse_select_from();
        return .{
            .from = from,
            .core = .{
                .result_columns = .fromOwnedSlice(cols),
            },
        };
    }

    /// parse_select_from parses a selectFrom statement
    /// Used to populate the table name
    fn parse_select_from(self: *Self) !ast.SelectFrom {
        const table = try self.expectIdentifier();
        return ast.SelectFrom{ .Table = table };
    }

    // parse_expr parses a column expression for now
    fn parse_expr(self: *Self) !ast.Expr {
        return ast.Expr{
            .Column = .{
                .name = try self.expectIdentifier(),
            },
        };
    }

    // parse_expr_result_column parses an expression result column
    // where optional aliases for a column name are specified.
    fn parse_expr_result_column(self: *Self) !ast.ExprResultColumn {
        const expr = try self.parse_expr();
        const alias: ?[]const u8 = blk: {
            if (self.nextTokenIs(Token.As)) {
                self.advance();
                // TODO: won't this throw an error when the alias isnt
                // provided, the SQl should still be valid I guess..
                const v = try self.expectIdentifier();
                break :blk v;
            } else break :blk null;
        };

        return .{ .expr = expr, .alias = alias };
    }

    // parse_result_column parses a single result column
    fn parse_result_column(self: *Self) !ast.ResultColumn {
        const next = self.peek();
        if (next != null and next.? == Token.Star) {
            self.advance();
            return .Star;
        }

        return ast.ResultColumn{
            .Expr = try self.parse_expr_result_column(),
        };
    }

    // parse_result_columns parses all the result columns in a query
    // and gives back an owned list of ResultColumn
    // caller owns the returned memory
    fn parse_result_columns(self: *Self, alloc: Allocator) ![]ast.ResultColumn {
        var l: std.ArrayList(ast.ResultColumn) = try .initCapacity(alloc, 1);

        const first = try self.parse_result_column();
        try l.append(alloc, first);

        // The Comma token seperates the list of column names
        while (self.nextTokenIs(Token.Comma)) {
            // We need to advance here because the subsequent parsers
            // check whether the next token is Star or a Result Column Expression
            self.advance();
            try l.append(alloc, try self.parse_result_column());
        }

        return l.toOwnedSlice(alloc);
    }

    fn nextTokenIs(self: Self, expected: Token) bool {
        if (self.pos >= self.tokens.len) return false;
        return std.meta.eql(self.tokens[self.pos], expected);
    }

    /// Returns the next token if it is an identifier or throws an error
    fn expectIdentifier(self: *Self) ParseError![]const u8 {
        const tkn = self.nextToken() orelse return ParseError.UnexpectedEndOfInput;
        return switch (tkn) {
            .Identifier => |ident| ident,
            else => ParseError.UnexpectedToken,
        };
    }

    /// expectNextTokenEq asserts the whether the next token is the `expected`
    /// this consume the next token
    fn expectNextTokenEq(self: *Self, expected: Token) ParseError!Token {
        const tkn = self.nextToken() orelse return ParseError.UnexpectedEndOfInput;
        if (std.meta.eql(tkn, expected)) {
            return tkn;
        }
        return ParseError.UnexpectedToken;
    }

    /// Returns the Token at the current position, does not advance the `pos` cursor
    fn peek(self: Self) ?Token {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    /// Gives the token in current position and advances the `pos` cursor
    fn nextToken(self: *Self) ?Token {
        if (self.pos >= self.tokens.len) return null;
        const tkn = self.tokens[self.pos];
        self.advance();
        return tkn;
    }

    fn advance(self: *Self) void {
        self.pos += 1;
    }

    fn parse_col_type(self: *Self) !ast.Create.Type {
        const type_name = try self.expectIdentifier();
        if (std.mem.eql(u8, type_name, "integer")) {
            return ast.Create.Type.Integer;
        } else if (std.mem.eql(u8, type_name, "text")) {
            return ast.Create.Type.Text;
        } else if (std.mem.eql(u8, type_name, "blob")) {
            return ast.Create.Type.Blob;
        } else if (std.mem.eql(u8, type_name, "string") or std.mem.eql(u8, type_name, "text")) {
            return ast.Create.Type.Text;
        } else {
            return error.UnexpectedColumnType;
        }
    }

    // parse a column definition statement which has a column name and it's
    // respective column type, generally used as part of a CREATE TABLE
    // statement
    fn parse_column_def(self: *Self) !ast.Create.ColumnDef {
        return .{
            // order of fields matters here because first we want to parse the column name
            // and then the column type
            .name = try self.expectIdentifier(),
            .col_type = try self.parse_col_type(),
        };
    }
};

pub const ParseResult = struct {
    statement: ast.Statement,
    tokens: []const Token,
    alloc: Allocator,

    pub fn deinit(self: *ParseResult) void {
        deinitStatement(self.alloc, self.statement);
        for (self.tokens) |tok| {
            switch (tok) {
                .Identifier, .StringLiteral => |s| self.alloc.free(s),
                else => {},
            }
        }
        self.alloc.free(self.tokens);
    }
};

fn deinitStatement(alloc: Allocator, statement: ast.Statement) void {
    var stmt = statement;
    switch (stmt) {
        .Select => |*sel| sel.core.result_columns.deinit(alloc),
        .CreateTable => |crt| {
            // Column names borrow identifier storage freed with `tokens` in ParseResult.deinit.
            alloc.free(crt.cols);
        },
        .Insert => |ins| {
            if (ins.columns) |cols| alloc.free(cols);
            for (ins.values) |lit| {
                switch (lit) {
                    .String => |s| alloc.free(s),
                    else => {},
                }
            }
            alloc.free(ins.values);
        },
    }
}

pub fn parse_statement(input: []const u8, alloc: Allocator, trailing_semicolon: bool) !ParseResult {
    const tokens = try token.tokenize(alloc, input);
    errdefer {
        for (tokens) |tk| {
            switch (tk) {
                .Identifier, .StringLiteral => |s| alloc.free(s),
                else => {},
            }
        }
        alloc.free(tokens);
    }
    var parser = ParserState.init(tokens);
    const statement = try parser.parse_statement(alloc);
    errdefer deinitStatement(alloc, statement);

    if (trailing_semicolon) {
        _ = try parser.expectNextTokenEq(Token.Semicolon);
    } else if (parser.peek() != null) {
        return error.UnexpectedToken;
    }

    return .{
        .statement = statement,
        .tokens = tokens,
        .alloc = alloc,
    };
}

/// cotrm
pub fn parse_create_statement(input: []const u8, alloc: Allocator) !ParseResult {
    const tokens = try token.tokenize(alloc, input);
    errdefer {
        for (tokens) |tk| {
            switch (tk) {
                .Identifier, .StringLiteral => |s| alloc.free(s),
                else => {},
            }
        }
        alloc.free(tokens);
    }
    var parser = ParserState.init(tokens);
    const statement = try parser.parse_create_table(alloc);

    return .{
        .statement = .{ .CreateTable = statement },
        .tokens = tokens,
        .alloc = alloc,
    };
}

const t = std.testing;

test "parse insert without column list" {
    var parsed = try parse_statement("insert into users values (1, 'alice')", t.allocator, false);
    defer parsed.deinit();

    const ins = parsed.statement.Insert;
    try t.expectEqualStrings("users", ins.table);
    try t.expect(ins.columns == null);
    try t.expectEqual(@as(usize, 2), ins.values.len);
    try t.expect(ins.values[0] == .Integer);
    try t.expectEqual(@as(i64, 1), ins.values[0].Integer);
    try t.expect(ins.values[1] == .String);
    try t.expectEqualStrings("alice", ins.values[1].String);
}

test "parse insert with column list" {
    var parsed = try parse_statement("insert into users (name, id) values ('bob', 2)", t.allocator, false);
    defer parsed.deinit();

    const ins = parsed.statement.Insert;
    try t.expectEqualStrings("users", ins.table);
    try t.expect(ins.columns != null);
    try t.expectEqual(@as(usize, 2), ins.columns.?.len);
    try t.expectEqualStrings("name", ins.columns.?[0]);
    try t.expectEqualStrings("id", ins.columns.?[1]);
    try t.expectEqualStrings("bob", ins.values[0].String);
    try t.expectEqual(@as(i64, 2), ins.values[1].Integer);
}

test "parse insert with null literal" {
    var parsed = try parse_statement("insert into t values (null)", t.allocator, false);
    defer parsed.deinit();

    try t.expect(parsed.statement.Insert.values[0] == .Null);
}

test "parse insert with trailing semicolon" {
    var parsed = try parse_statement("insert into t values (1);", t.allocator, true);
    defer parsed.deinit();

    try t.expect(parsed.statement.Insert.values[0] == .Integer);
}

test "parse insert rejects extra tokens" {
    try t.expectError(error.UnexpectedToken, parse_statement("insert into t values (1) from x", t.allocator, false));
}

test "parse create table with multiple columns" {
    var parsed = try parse_create_statement("CREATE TABLE users (id INTEGER, name TEXT)", t.allocator);
    defer parsed.deinit();

    const crt = parsed.statement.CreateTable;
    try t.expectEqualStrings("users", crt.name);
    try t.expectEqual(@as(usize, 2), crt.cols.len);
    try t.expectEqualStrings("id", crt.cols[0].name);
    try t.expect(crt.cols[0].col_type == .Integer);
    try t.expectEqualStrings("name", crt.cols[1].name);
    try t.expect(crt.cols[1].col_type == .Text);
}
