const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const ast = @import("ast.zig");
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
    fn parse_statement(self: *Self, alloc: Allocator) !ast.Statement {
        return .{
            .Select = try self.parse_select(alloc),
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

    // expectNextTokenEq asserts the whether the next token is the `expected`
    // this consume the next token
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
};

pub fn parse_statement(input: []const u8, alloc: Allocator) !ast.Statement {
    const tokens = try token.tokenize(alloc, input);
    var parser = ParserState.init(tokens);
    const statement = try parser.parse_statement(alloc);
    _ = try parser.expectNextTokenEq(Token.Semicolon);
    return statement;
}
