pub const Varint = struct {
    len: u8,
    value: u64,
};

pub fn lenFor(value: u64) u8 {
    const bits_needed_to_repr = 64 - @clz(value);
    if (bits_needed_to_repr <= 7) return 1;
    if (bits_needed_to_repr <= 14) return 2;
    if (bits_needed_to_repr <= 21) return 3;
    if (bits_needed_to_repr <= 28) return 4;
    if (bits_needed_to_repr <= 35) return 5;
    if (bits_needed_to_repr <= 42) return 6;
    if (bits_needed_to_repr <= 49) return 7;
    if (bits_needed_to_repr <= 56) return 8;
    return 9;
}

pub fn encodeAppend(value: u64, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    const bytes_needed = lenFor(value);
    const newsl = try out.addManyAsSlice(alloc, bytes_needed);
    _ = encode(value, newsl);
}

pub fn encode(value: u64, out: []u8) Varint {
    if (value == 0) {
        out[0] = 0;
        return .{ .len = 1, .value = 0 };
    }

    const bytes_needed = lenFor(value);
    assert(out.len >= bytes_needed);

    if (bytes_needed <= 8) {
        var remn = value;
        var idx: usize = bytes_needed;

        while (idx > 0) {
            idx -= 1;

            // get the 7 bits of the first byte which represent the value
            const seven_bit_chunk = remn & 0x7f;
            var value_containing_byte = @as(u8, @truncate(seven_bit_chunk));
            // now we had maskde remn to get the 7 bits that contain a value excluding cont bit
            // which leaves the remaining bits in incorrect positions, so we shift by 7
            remn >>= 7;
            if (idx < bytes_needed - 1) {
                value_containing_byte |= 0x80;
            }

            out[idx] = value_containing_byte;
        }

        return .{ .len = bytes_needed, .value = value };
    }

    if (bytes_needed == 9) {
        // Lowest 8 bits go into the last byte, no continuation bit
        out[8] = @as(u8, @truncate(value));

        // Remaining 56 bits spread across first 8 bytes, all with continuation bit
        var remaining = value >> 8;
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            out[i] = @as(u8, @truncate(remaining & 0x7F)) | 0x80;
            remaining >>= 7;
        }

        return .{ .len = 9, .value = value };
    }

    return .{ .len = bytes_needed, .value = value };
}

pub fn decode(buf: []const u8, offset: usize) !Varint {
    var bytes_read: u8 = 0;
    var result: u64 = 0;
    var ofs = offset;
    while (bytes_read < 9) {
        if (ofs >= buf.len) return error.BufferExhausted;
        const current_byte: u64 = buf[ofs];
        if (bytes_read == 8) {
            result = (result << 8) | current_byte;
        } else {
            result = (result << 7) | (current_byte & 0x7F);
        }
        ofs += 1;
        bytes_read += 1;
        if (current_byte & 0x80 == 0) break;
    }
    return .{ .len = bytes_read, .value = result };
}

pub fn decodeSlice(buf: []const u8) !struct { varint: Varint, remaining: []const u8 } {
    const varint = try decode(buf, 0);
    return .{
        .varint = varint,
        .remaining = buf[varint.len..],
    };
}

const std = @import("std");
const assert = std.debug.assert;
const t = std.testing;

test "decode zero" {
    const result = try decode(&[_]u8{0x00}, 0);
    try t.expectEqual(1, result.len);
    try t.expectEqual(0, result.value);
}

test "decode 300" {
    const result = try decode(&[_]u8{ 0x82, 0x2C }, 0);
    try t.expectEqual(2, result.len);
    try t.expectEqual(300, result.value);
}

test "encode decode roundtrip" {
    var buf: [9]u8 = undefined;
    const values = [_]u64{ 0, 300, 127, 128, 0x00ff_ffff_ffff_ffff, 0xffff_ffff_ffff_ffff };
    for (values) |v| {
        const enc = encode(v, &buf);
        const dec = try decode(buf[0..enc.len], 0);
        try t.expectEqual(v, dec.value);
        try t.expectEqual(enc.len, dec.len);
    }
}

test "decodeSlice returns remaining" {
    const result = try decodeSlice(&[_]u8{ 0x82, 0x2C, 0xFF });
    try t.expectEqual(300, result.varint.value);
    try t.expectEqualSlices(u8, &[_]u8{0xFF}, result.remaining);
}

test "decode bounds check" {
    try t.expectError(error.BufferExhausted, decode(&[_]u8{0x82}, 0));
}

test "encode zero" {
    var buf: [9]u8 = undefined;
    const result = encode(0, &buf);
    try t.expectEqual(1, result.len);
    try t.expectEqual(0, result.value);
    try t.expectEqual(@as(u8, 0x00), buf[0]);
}

test "encode 300" {
    var buf: [9]u8 = undefined;
    const result = encode(300, &buf);
    try t.expectEqual(2, result.len);
    try t.expectEqual(300, result.value);
    try t.expectEqual(@as(u8, 0x82), buf[0]);
    try t.expectEqual(@as(u8, 0x2C), buf[1]);
}

test "encode max 8-byte value" {
    // 2^56 - 1 = 0x00ff_ffff_ffff_ffff
    var buf: [9]u8 = undefined;
    const result = encode(0x00ff_ffff_ffff_ffff, &buf);
    try t.expectEqual(8, result.len);
    try t.expectEqual(0x00ff_ffff_ffff_ffff, result.value);
}

test "encode max 9-byte value" {
    // 2^64 - 1
    var buf: [9]u8 = undefined;
    const result = encode(0xffff_ffff_ffff_ffff, &buf);
    try t.expectEqual(9, result.len);
    try t.expectEqual(0xffff_ffff_ffff_ffff, result.value);
}

test "lenFor zero" {
    try t.expectEqual(1, lenFor(0));
}

test "lenFor 300" {
    try t.expectEqual(2, lenFor(300));
}

test "lenFor max 8-byte" {
    try t.expectEqual(8, lenFor(0x00ff_ffff_ffff_ffff));
}

test "lenFor max 9-byte" {
    try t.expectEqual(9, lenFor(0xffff_ffff_ffff_ffff));
}

test "encodeAppend roundtrip" {
    var list = try std.ArrayList(u8).initCapacity(t.allocator, 1);
    defer list.deinit(t.allocator);
    try encodeAppend(300, t.allocator, &list);
    try t.expectEqualSlices(u8, &[_]u8{ 0x82, 0x2C }, list.items);
}
