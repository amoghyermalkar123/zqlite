const std = @import("std");
const Allocator = std.mem.Allocator;
const Token = @import("token.zig").Token;

pub const ParserState = struct {
    tokens: std.ArrayList(Token),
    pos: usize,
};
