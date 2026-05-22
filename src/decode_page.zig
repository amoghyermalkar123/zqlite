pub const Decoder = struct {
    buffer: []const u8,
    cursor: usize,

    pub fn init(buffer: []const u8) Decoder {
        return .{ .buffer = buffer, .cursor = 0 };
    }

    pub fn initAt(buffer: []const u8, offset: usize) Decoder {
        return .{ .buffer = buffer, .cursor = offset };
    }

    pub fn remaining(self: *Decoder) []const u8 {
        return self.buffer[self.cursor..];
    }

    pub fn pos(self: *const Decoder) usize {
        return self.cursor;
    }

    pub fn seekTo(self: *Decoder, offset: usize) void {
        self.cursor = offset;
    }

    pub fn readInt(self: *Decoder, comptime T: type) !T {
        const bits = @divExact(@typeInfo(T).int.bits, 8);
        if (self.cursor + bits > self.buffer.len) return error.BufferExhausted;
        const value = std.mem.readInt(T, self.buffer[self.cursor .. self.cursor + bits][0..bits], .big);
        self.cursor += bits;
        return value;
    }

    pub fn readEnum(self: *Decoder, comptime T: type) !T {
        const raw = try self.readInt(std.meta.Tag(T));
        return std.enums.fromInt(T, raw) orelse error.InvalidEnumTag;
    }

    pub fn readSlice(self: *Decoder, len: usize) ![]const u8 {
        if (self.cursor + len > self.buffer.len) return error.BufferExhausted;
        const slice = self.buffer[self.cursor .. self.cursor + len];
        self.cursor += len;
        return slice;
    }

    pub fn skip(self: *Decoder, len: usize) !void {
        if (self.cursor + len > self.buffer.len) return error.BufferExhausted;
        self.cursor += len;
    }

    pub fn readVarint(self: *Decoder) !varint.Varint {
        const v = try varint.decode(self.buffer, self.cursor);
        self.cursor += v.len;
        return v;
    }
};

const std = @import("std");
const varint = @import("varint.zig");
const t = std.testing;

test "Decoder readEnum validates tag" {
    var decoder = Decoder.init(&[_]u8{0xFF});
    const PageType = enum(u8) {
        a = 0x01,
        b = 0x02,
    };

    try t.expectError(error.InvalidEnumTag, decoder.readEnum(PageType));
}

test "Decoder skip advances cursor" {
    var decoder = Decoder.init("hello");
    try decoder.skip(2);
    try t.expectEqual(@as(usize, 2), decoder.pos());
    try t.expectEqualSlices(u8, "llo", decoder.remaining());
}

test "Decoder skip bounds checks" {
    var decoder = Decoder.init("hi");
    try t.expectError(error.BufferExhausted, decoder.skip(3));
}
