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
        const next = self.peek() orelse return error.UnexpectedEndOfInput;

        if (next == Token.Select) {
            return .{
                .Select = try self.parse_select(alloc),
            };
        }

        if (next == Token.Create) {
            return .{
                .CreateTable = try self.parse_create_table(alloc),
            };
        }

        return error.UnexpectedToken;
    }

    // parses a create table statement
    // cotrm
    fn parse_create_table(self: *Self, alloc: Allocator) !ast.Create.CreateTableStatement {
        _ = try self.expectNextTokenEq(Token.Create);
        _ = try self.expectNextTokenEq(Token.Table);

        const table_name = try self.expectIdentifier();
        _ = try self.expectNextTokenEq(Token.Lpar);

        var column_defs = try std.ArrayList(ast.Create.ColumnDef).initCapacity(alloc, 1);

        const first_def = try self.parse_column_def();
        try column_defs.append(alloc, first_def);

        while (self.nextTokenIs(Token.Semicolon)) {
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
        _ = try self.expectNextTokenEq(Token.Select);
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

    // parse_select_from parses a selectFrom statement
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

        while (self.nextTokenIs(Token.Comma)) {
            self.advance();
            try l.append(alloc, try self.parse_result_column());
        }

        return l.toOwnedSlice(alloc);
    }

    fn nextTokenIs(self: Self, expected: Token) bool {
        if (self.pos >= self.tokens.len) return false;
        return std.meta.eql(self.tokens[self.pos], expected);
    }

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

    fn peek(self: Self) ?Token {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

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
        // Free identifier strings inside tokens
        for (self.tokens) |tok| {
            switch (tok) {
                .Identifier => |ident| self.alloc.free(ident),
                else => {},
            }
        }
        // Free the token slice itself
        self.alloc.free(self.tokens);
        // Free the result_columns ArrayList
        switch (self.statement) {
            .Select => |*sel| sel.core.result_columns.deinit(self.alloc),
            .CreateTable => |*crt| {
                self.alloc.free(crt.cols);
                self.alloc.free(crt.name);
            },
        }
    }
};

pub fn parse_statement(input: []const u8, alloc: Allocator, trailing_semicolon: bool) !ParseResult {
    const tokens = try token.tokenize(alloc, input);
    var parser = ParserState.init(tokens);
    const statement = try parser.parse_statement(alloc);
    if (trailing_semicolon) {
        _ = try parser.expectNextTokenEq(Token.Semicolon);
    }
    return .{
        .statement = statement,
        .tokens = tokens,
        .alloc = alloc,
    };
}

pub fn parse_create_statement(input: []const u8, alloc: Allocator) !ParseResult {
    const tokens = try token.tokenize(alloc, input);
    var parser = ParserState.init(tokens);
    const statement = try parser.parse_create_table(alloc);

    return .{
        .statement = .{ .CreateTable = statement },
        .tokens = tokens,
        .alloc = alloc,
    };
}
