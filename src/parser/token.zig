const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Token = union(enum) {
    Select,
    As,
    From,
    Star,
    Comma,
    Semicolon,
    // caller owns the identifier, they must free this after using
    Identifier: []u8,
    Create,
    Table,
    Lpar,
    Rpar,
};

pub const TokenizeError = error{
    UnexpectedCharacter,
};

// caller owns the returned Token list
// tokenizes a given SQL statement
// NOTE: every identifier token is normalized to lower case ASCII
pub fn tokenize(alloc: Allocator, input: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;

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
            ' ', '\n', '\r', '\t' => i += 1,
            else => {
                if (std.ascii.isAlphabetic(input[i])) {
                    const start = i;
                    i += 1;

                    while (i < input.len and isIdentChar(input[i])) i += 1;

                    const identifier = try alloc.dupe(u8, input[start..i]);

                    for (identifier) |*ch| {
                        ch.* = std.ascii.toLower(ch.*);
                    }

                    if (std.mem.eql(u8, identifier, "select")) {
                        alloc.free(identifier);
                        try tokens.append(alloc, Token.Select);
                    } else if (std.mem.eql(u8, identifier, "as")) {
                        alloc.free(identifier);
                        try tokens.append(alloc, Token.As);
                    } else if (std.mem.eql(u8, identifier, "from")) {
                        alloc.free(identifier);
                        try tokens.append(alloc, Token.From);
                    } else if (std.mem.eql(u8, identifier, "create")) {
                        alloc.free(identifier);
                        try tokens.append(alloc, Token.Create);
                    } else if (std.mem.eql(u8, identifier, "table")) {
                        alloc.free(identifier);
                        try tokens.append(alloc, Token.Table);
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

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const t = std.testing;

test "tokenize" {
    const result = try tokenize(t.allocator, "SELECT * FROM columns");
    defer t.allocator.free(result);
    defer t.allocator.free(result[3].Identifier);

    try t.expect(result[0] == Token.Select);
    try t.expect(result[1] == Token.Star);
    try t.expect(result[2] == Token.From);
    try t.expect(result[3] == Token.Identifier);
}
