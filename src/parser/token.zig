const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Token = union(enum) {
    Select,
    As,
    From,
    Star,
    Comma,
    Semicolon,
    Insert,
    Into,
    Values,
    Null,
    Integer: i64,
    StringLiteral: []u8,
    // caller owns the identifier, they must free this after using
    Identifier: []u8,
    Create,
    Table,
    Lpar,
    Rpar,
};

pub const TokenizeError = error{
    UnexpectedCharacter,
    UnterminatedString,
    InvalidNumber,
    IntegerOverflow,
};

// caller owns the returned Token list
// tokenizes a given SQL statement
// NOTE: identifier tokens are normalized to lower case ASCII; string literal contents are not
pub fn tokenize(alloc: Allocator, input: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer {
        for (tokens.items) |tok| freeToken(alloc, tok);
        tokens.deinit(alloc);
    }

    var i: usize = 0;

    while (i < input.len) {
        switch (input[i]) {
            '(' => {
                try tokens.append(alloc, Token.Lpar);
                i += 1;
            },
            ')' => {
                try tokens.append(alloc, Token.Rpar);
                i += 1;
            },
            '*' => {
                try tokens.append(alloc, Token.Star);
                i += 1;
            },
            ',' => {
                try tokens.append(alloc, Token.Comma);
                i += 1;
            },
            ';' => {
                try tokens.append(alloc, Token.Semicolon);
                i += 1;
            },
            '\'' => {
                const scanned = try scanStringLiteral(alloc, input, i);
                try tokens.append(alloc, .{ .StringLiteral = scanned.lit });
                i = scanned.end;
            },
            ' ', '\n', '\r', '\t' => i += 1,
            else => {
                if (input[i] == '-' and i + 1 < input.len and std.ascii.isDigit(input[i + 1])) {
                    const scanned = try scanInteger(input, i);
                    try tokens.append(alloc, .{ .Integer = scanned.value });
                    i = scanned.end;
                } else if (std.ascii.isDigit(input[i])) {
                    const scanned = try scanInteger(input, i);
                    try tokens.append(alloc, .{ .Integer = scanned.value });
                    i = scanned.end;
                } else if (std.ascii.isAlphabetic(input[i])) {
                    const start = i;
                    i += 1;

                    while (i < input.len and isIdentChar(input[i])) i += 1;

                    const identifier = try alloc.dupe(u8, input[start..i]);

                    for (identifier) |*ch| {
                        ch.* = std.ascii.toLower(ch.*);
                    }

                    if (keywordToken(identifier)) |kw| {
                        alloc.free(identifier);
                        try tokens.append(alloc, kw);
                    } else {
                        try tokens.append(alloc, .{ .Identifier = identifier });
                    }
                } else {
                    return TokenizeError.UnexpectedCharacter;
                }
            },
        }
    }

    return tokens.toOwnedSlice(alloc);
}

fn keywordToken(identifier: []const u8) ?Token {
    if (std.mem.eql(u8, identifier, "select")) return Token.Select;
    if (std.mem.eql(u8, identifier, "as")) return Token.As;
    if (std.mem.eql(u8, identifier, "from")) return Token.From;
    if (std.mem.eql(u8, identifier, "create")) return Token.Create;
    if (std.mem.eql(u8, identifier, "table")) return Token.Table;
    if (std.mem.eql(u8, identifier, "insert")) return Token.Insert;
    if (std.mem.eql(u8, identifier, "into")) return Token.Into;
    if (std.mem.eql(u8, identifier, "values")) return Token.Values;
    if (std.mem.eql(u8, identifier, "null")) return Token.Null;
    return null;
}

// TODO: library?
fn scanInteger(input: []const u8, start: usize) TokenizeError!struct { value: i64, end: usize } {
    var end = start;
    if (input[end] == '-') end += 1;
    while (end < input.len and std.ascii.isDigit(input[end])) : (end += 1) {}

    const value = std.fmt.parseInt(i64, input[start..end], 10) catch |err| switch (err) {
        error.Overflow => return TokenizeError.IntegerOverflow,
        else => return TokenizeError.InvalidNumber,
    };
    return .{ .value = value, .end = end };
}

fn scanStringLiteral(alloc: Allocator, input: []const u8, start: usize) !struct { lit: []u8, end: usize } {
    var end = start + 1; // opening quote
    var chars: std.ArrayList(u8) = .empty;
    errdefer chars.deinit(alloc);

    while (end < input.len) : (end += 1) {
        if (input[end] == '\'') {
            end += 1; // closing quote
            return .{ .lit = try chars.toOwnedSlice(alloc), .end = end };
        }
        try chars.append(alloc, input[end]);
    }

    return TokenizeError.UnterminatedString;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const t = std.testing;

test "tokenize select" {
    const result = try tokenize(t.allocator, "SELECT * FROM columns");
    defer freeTokens(t.allocator, result);

    try t.expect(result[0] == .Select);
    try t.expect(result[1] == .Star);
    try t.expect(result[2] == .From);
    try t.expect(result[3] == .Identifier);
}

test "tokenize insert keywords" {
    const result = try tokenize(t.allocator, "insert into t values (null)");
    defer freeTokens(t.allocator, result);

    try t.expect(result[0] == .Insert);
    try t.expect(result[1] == .Into);
    try t.expect(result[2] == .Identifier);
    try t.expect(result[3] == .Values);
    try t.expect(result[4] == .Lpar);
    try t.expect(result[5] == .Null);
    try t.expect(result[6] == .Rpar);
}

test "tokenize INSERT is case insensitive" {
    const result = try tokenize(t.allocator, "INSERT INTO t VALUES (NULL)");
    defer freeTokens(t.allocator, result);

    try t.expect(result[0] == .Insert);
    try t.expect(result[1] == .Into);
    try t.expect(result[5] == .Null);
}

test "tokenize integers" {
    const result = try tokenize(t.allocator, "values (42, -1)");
    defer freeTokens(t.allocator, result);

    try t.expect(result[2] == .Integer);
    try t.expectEqual(@as(i64, 42), result[2].Integer);
    try t.expect(result[4] == .Integer);
    try t.expectEqual(@as(i64, -1), result[4].Integer);
}

test "tokenize rejects integer overflow" {
    try t.expectError(error.IntegerOverflow, tokenize(t.allocator, "9223372036854775808"));
}

test "tokenize string literals" {
    const result = try tokenize(t.allocator, "values ('', 'alice')");
    defer freeTokens(t.allocator, result);

    try t.expect(result[2] == .StringLiteral);
    try t.expectEqualStrings("", result[2].StringLiteral);
    try t.expect(result[4] == .StringLiteral);
    try t.expectEqualStrings("alice", result[4].StringLiteral);
}

test "tokenize unterminated string" {
    try t.expectError(error.UnterminatedString, tokenize(t.allocator, "values ('oops)"));
}

fn freeToken(alloc: Allocator, tok: Token) void {
    switch (tok) {
        .Identifier, .StringLiteral => |s| alloc.free(s),
        else => {},
    }
}

fn freeTokens(alloc: Allocator, tokens: []Token) void {
    for (tokens) |tok| freeToken(alloc, tok);
    alloc.free(tokens);
}
