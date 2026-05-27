pub const RecordFieldEntry = union(enum) {
    Null,
    I8: i8,
    I16: i16,
    I24: i32,
    I32: i32,
    I48: i64,
    I64: i64,
    Float: f64,
    String: []const u8,
    Blob: []const u8,
};

pub fn serialTypeFor(entry: RecordFieldEntry) u64 {
    const serial_code = switch (entry) {
        .Null => 0,
        .I8 => 1,
        .I16 => 2,
        .I24 => 3,
        .I32 => 4,
        .I48 => 5,
        .I64 => 6,
        .Float => 7,
        .String => |s| 13 + 2 * s.len,
        .Blob => |b| 12 + 2 * b.len,
    };

    return @intCast(serial_code);
}

pub fn payloadSizeFor(entry: RecordFieldEntry) usize {
    const size: usize = switch (entry) {
        .Null => 0,
        .I8 => 1,
        .I16 => 2,
        .I24 => 3,
        .I32 => 4,
        .I48 => 5,
        .I64 => 8,
        .Float => 8,
        .String => |n| n.len,
        .Blob => |n| n.len,
    };

    return size;
}

/// encodes an entire record for a leaf cell given the provided `fields`
/// this involves encoding the overflow bytes as well. It is the caller's responsibility
/// to properly slice the overflow bytes and store them in the overflow pages
/// caller owns the returned memory
pub fn encode_record(alloc: Allocator, fields: []const RecordFieldEntry) ![]u8 {
    var sum_of_serial_types_for_all_fields: usize = 0;
    var sum_of_payload: usize = 0;
    // compute payload and serial type sums
    for (fields) |field| {
        const serialType = serialTypeFor(field);
        sum_of_serial_types_for_all_fields += varint.lenFor(serialType);
        sum_of_payload += payloadSizeFor(field);
    }
    // calculate the header_size varint
    const record_header_size = varint.lenFor(sum_of_serial_types_for_all_fields) + sum_of_serial_types_for_all_fields;
    // we know the payload size now, so allocate memory for record_buffer
    const total_size = record_header_size + sum_of_payload;
    var record_buffer = try std.ArrayList(u8).initCapacity(alloc, total_size);
    errdefer record_buffer.deinit(alloc);

    try tw.check(.after_record_buffer_alloc);

    // start writing to the record payload
    // first write the header_size varint
    const header_slice = try record_buffer.addManyAtBounded(0, varint.lenFor(record_header_size));
    _ = varint.encode(record_header_size, header_slice);
    // then start writing the serial types
    for (fields) |f| {
        try varint.encodeAppend(serialTypeFor(f), alloc, &record_buffer);
    }
    // and then finally we write the field payloads
    var payload_cursor: usize = record_header_size;
    for (fields) |f| {
        switch (f) {
            .I8 => |n| {
                const slice = try record_buffer.addManyAtBounded(payload_cursor, 1);
                std.mem.writeInt(i8, slice[0..1], n, .big);
                payload_cursor += 1;
            },
            .I16 => |n| {
                const slice = try record_buffer.addManyAtBounded(payload_cursor, 2);
                std.mem.writeInt(i16, slice[0..2], n, .big);
                payload_cursor += 2;
            },
            .I24 => |n| {
                const slice = try record_buffer.addManyAtBounded(payload_cursor, 3);
                std.mem.writeInt(i24, slice[0..3], @as(i24, @intCast(n)), .big);
                payload_cursor += 3;
            },
            .I32 => |n| {
                const slice = try record_buffer.addManyAtBounded(payload_cursor, 4);
                std.mem.writeInt(i32, slice[0..4], n, .big);
                payload_cursor += 4;
            },
            .I48 => |n| {
                const slice = try record_buffer.addManyAtBounded(payload_cursor, 6);
                std.mem.writeInt(i48, slice[0..6], @as(i48, @intCast(n)), .big);
                payload_cursor += 6;
            },
            .I64 => |n| {
                const slice = try record_buffer.addManyAtBounded(payload_cursor, 8);
                std.mem.writeInt(i64, slice[0..8], n, .big);
                payload_cursor += 8;
            },
            .Float => |n| {
                const slice = try record_buffer.addManyAtBounded(payload_cursor, 8);
                const bits: u64 = @bitCast(n);
                std.mem.writeInt(u64, slice[0..8], bits, .big);
                payload_cursor += 8;
            },
            .String => |s| {
                const slice = try record_buffer.addManyAtBounded(payload_cursor, s.len);
                @memcpy(slice[0..s.len], s);
                payload_cursor += s.len;
            },
            .Blob => |b| {
                const slice = try record_buffer.addManyAtBounded(payload_cursor, b.len);
                @memcpy(slice[0..b.len], b);
                payload_cursor += b.len;
            },
            .Null => {},
        }
    }
    // return the buffer as owned by the callee
    return record_buffer.toOwnedSlice(alloc);
}

/// just a helper to reduce boilerplate to get local and overflow size
pub fn table_leaf_payload_layout(db_header: page.DbHeader, payload_len: usize) !struct { local: usize, overflow_bytes: ?usize } {
    const hd = page.PageHeader{
        .page_type = .Leaf,
        .first_free_block = 0,
        .cell_count = 0,
        .cell_content_offset = 0,
        .fragmented_byts_count = 0,
    };
    const pair = try hd.local_and_overflow_size(db_header, payload_len);
    return .{ .local = pair[0], .overflow_bytes = pair[1] };
}

pub fn encode_overflow_page(alloc: Allocator, db_header: page.DbHeader, next_page: ?u32, chunk: []const u8) ![]u8 {
    const page_size: usize = @intCast(db_header.page_size);
    const max_chunk = db_header.usable_page_size() - 4;
    if (chunk.len > max_chunk) return error.OverflowChunkTooLarge;

    const buf = try alloc.alloc(u8, page_size);
    errdefer alloc.free(buf);
    @memset(buf, 0);

    const next_raw: u32 = next_page orelse 0;
    std.mem.writeInt(u32, buf[0..4], next_raw, .big);
    @memcpy(buf[4 .. 4 + chunk.len], chunk);
    return buf;
}

/// [payload_size varint][rowid varint][local payload bytes][overflow ptr?]
/// Copies record_payload internally and owns it
pub fn encode_table_leaf_cell(alloc: Allocator, db_header: page.DbHeader, rowid: u64, record_payload: []const u8, first_ov_page: ?u32) ![]u8 {
    const payload_size = record_payload.len;
    const hd = page.PageHeader{
        .page_type = .Leaf,
        .first_free_block = 0,
        .cell_count = 0,
        .cell_content_offset = 0,
        .fragmented_byts_count = 0,
    };

    const local_size = try hd.local_payload_size(db_header, payload_size);
    const has_overflow = payload_size > local_size;
    if (has_overflow and first_ov_page == null) return error.MissingOverflowPagePointer;
    if (!has_overflow and first_ov_page != null) return error.UnexpectedOverflowpage;

    const total_size = varint.lenFor(payload_size) + varint.lenFor(rowid) + local_size + (if (has_overflow) @as(usize, 4) else 0);

    var leaf_cell = try std.ArrayList(u8).initCapacity(alloc, total_size);
    errdefer leaf_cell.deinit(alloc);

    try varint.encodeAppend(@intCast(payload_size), alloc, &leaf_cell);
    try varint.encodeAppend(rowid, alloc, &leaf_cell);
    try leaf_cell.appendSliceBounded(record_payload[0..local_size]);
    if (has_overflow) {
        const slice = try leaf_cell.addManyAtBounded(leaf_cell.items.len, 4);
        std.mem.writeInt(u32, slice[0..4], first_ov_page.?, .big);
    }
    return leaf_cell.toOwnedSlice(alloc);
}

pub fn encode_table_interior_cell(alloc: Allocator, left_child_page: u32, key: u64) ![]u8 {
    const total_size = 4 + varint.lenFor(key);

    var interior_cell = try std.ArrayList(u8).initCapacity(alloc, total_size);
    errdefer interior_cell.deinit(alloc);

    const slice = try interior_cell.addManyAtBounded(interior_cell.items.len, 4);
    std.mem.writeInt(u32, slice[0..4], left_child_page, .big);

    try varint.encodeAppend(key, alloc, &interior_cell);

    return interior_cell.toOwnedSlice(alloc);
}

pub fn encode_leaf_page(alloc: Allocator, db_header: page.DbHeader, cells: []const []const u8) ![]u8 {
    const page_size: usize = db_header.page_size;
    const header_size = cnst.PAGE_LEAF_HEADER_SIZE;
    const pointer_bytes = cells.len * 2;

    var total_cell_bytes: usize = 0;
    for (cells) |cell| total_cell_bytes += cell.len;

    if (header_size + pointer_bytes + total_cell_bytes > page_size) {
        return error.PageTooSmall;
    }

    const buf = try alloc.alloc(u8, page_size);
    errdefer alloc.free(buf);
    @memset(buf, 0);

    buf[0] = @intFromEnum(page.PageType.Leaf);
    std.mem.writeInt(u16, buf[cnst.PAGE_FIRST_FREEBLOCK_OFFSET..][0..2], 0, .big);
    std.mem.writeInt(u16, buf[cnst.PAGE_CELL_COUNT_OFFSET..][0..2], @intCast(cells.len), .big);
    buf[cnst.PAGE_FRAGMENTED_BYTES_COUNT_OFFSET] = 0;

    // write backwards because after cell pointers we store free space
    var content_cursor: usize = page_size;
    for (cells, 0..) |cell, i| {
        content_cursor -= cell.len;
        @memcpy(buf[content_cursor .. content_cursor + cell.len], cell);

        const ptr_offset = header_size + i * 2;
        std.mem.writeInt(u16, buf[ptr_offset..][0..2], @intCast(content_cursor), .big);
    }

    const content_offset: u16 = if (content_cursor == cnst.PAGE_MAX_SIZE) 0 else @intCast(content_cursor);
    std.mem.writeInt(u16, buf[cnst.PAGE_CELL_CONTENT_OFFSET..][0..2], content_offset, .big);

    return buf;
}

const std = @import("std");
const cnst = @import("constants.zig");
const varint = @import("varint.zig");
const page = @import("page.zig");
const PageBuilder = @import("testing/page_builder.zig").PageBuilder;

const Allocator = std.mem.Allocator;
const t = std.testing;

test "encode empty record" {
    const buf = try encode_record(t.allocator, &.{});
    defer t.allocator.free(buf);
    try t.expectEqualSlices(u8, &[_]u8{0x01}, buf);
}

test "encode single I8" {
    const buf = try encode_record(t.allocator, &.{.{ .I8 = 42 }});
    defer t.allocator.free(buf);
    // header_size=2 (1 byte for serial type + 1 byte for header_size varint)
    // serial_type=1 (1 byte)
    // payload=42 (1 byte)
    try t.expectEqual(@as(u8, 0x02), buf[0]); // header size
    try t.expectEqual(@as(u8, 0x01), buf[1]); // serial type for I8
    try t.expectEqual(@as(u8, 42), buf[2]); // payload
}

test "encode I64 and String" {
    const buf = try encode_record(t.allocator, &.{
        .{ .I64 = 0x0102030405060708 },
        .{ .String = "hi" },
    });
    defer t.allocator.free(buf);
    // serial types: 6 (1 byte), 17 (1 byte) -> sum=2
    // header_size = 2 + 1 = 3
    try t.expectEqual(@as(u8, 0x03), buf[0]); // header size
    try t.expectEqual(@as(u8, 0x06), buf[1]); // serial type for I64
    try t.expectEqual(@as(u8, 0x11), buf[2]); // serial type for String len=2: 13+2*2=17
    try t.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, buf[3..11]);
    try t.expectEqualSlices(u8, "hi", buf[11..13]);
}

test "encode Null" {
    const buf = try encode_record(t.allocator, &.{ .{ .Null = {} }, .{ .I8 = 1 } });
    defer t.allocator.free(buf);
    // serial types: 0, 1 -> both 1 byte each
    // header_size = 2 + 1 = 3
    try t.expectEqual(@as(u8, 0x03), buf[0]);
    try t.expectEqual(@as(u8, 0x00), buf[1]); // Null serial
    try t.expectEqual(@as(u8, 0x01), buf[2]); // I8 serial
    try t.expectEqual(@as(u8, 1), buf[3]); // I8 payload
    try t.expectEqual(@as(usize, 4), buf.len);
}

test "encode Blob" {
    const buf = try encode_record(t.allocator, &.{.{ .Blob = &[_]u8{ 0xDE, 0xAD } }});
    defer t.allocator.free(buf);
    // serial type for Blob len=2: 12+2*2=16 (1 byte)
    // header_size = 1 + 1 = 2
    try t.expectEqual(@as(u8, 0x02), buf[0]);
    try t.expectEqual(@as(u8, 0x10), buf[1]); // serial type 16
    try t.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD }, buf[2..4]);
}

test "roundtrip encode then decode record header" {
    const buf = try encode_record(t.allocator, &.{
        .{ .I32 = 42 },
        .{ .String = "hello" },
        .{ .Null = {} },
    });
    defer t.allocator.free(buf);

    const header = try page.parse_record_header(t.allocator, buf);
    defer t.allocator.free(header.fields);

    try t.expectEqual(3, header.fields.len);
    try t.expectEqual(page.RecordFieldType.I32, header.fields[0].field_type);
    try t.expectEqual(@as(std.meta.Tag(page.RecordFieldType), .String), @as(std.meta.Tag(page.RecordFieldType), header.fields[1].field_type));
    try t.expectEqual(page.RecordFieldType.Null, header.fields[2].field_type);
}

test "encode table leaf cell without overflow" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    const cell = try encode_table_leaf_cell(t.allocator, db_header, 7, "abc", null);
    defer t.allocator.free(cell);

    try t.expectEqualSlices(u8, &[_]u8{ 0x03, 0x07, 'a', 'b', 'c' }, cell);
}

test "encode table leaf cell with overflow" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };
    const leaf_header = page.PageHeader{
        .page_type = .Leaf,
        .first_free_block = 0,
        .cell_count = 0,
        .cell_content_offset = 0,
        .fragmented_byts_count = 0,
    };

    const payload = try t.allocator.alloc(u8, 500);
    defer t.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i % 251);

    const local_size = try leaf_header.local_payload_size(db_header, payload.len);
    try t.expect(local_size < payload.len);

    const overflow_page: u32 = 1234;
    const cell = try encode_table_leaf_cell(t.allocator, db_header, 9, payload, overflow_page);
    defer t.allocator.free(cell);

    const payload_size = try varint.decode(cell, 0);
    try t.expectEqual(payload.len, payload_size.value);

    const rowid = try varint.decode(cell, payload_size.len);
    try t.expectEqual(9, rowid.value);

    const payload_start = payload_size.len + rowid.len;
    try t.expectEqual(payload_start + local_size + 4, cell.len);
    try t.expectEqualSlices(u8, payload[0..local_size], cell[payload_start .. payload_start + local_size]);
    try t.expectEqual(overflow_page, std.mem.readInt(u32, cell[cell.len - 4 ..][0..4], .big));
}

test "encode table leaf cell errors when overflow pointer is missing" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    const payload = try t.allocator.alloc(u8, 500);
    defer t.allocator.free(payload);

    try t.expectError(
        error.MissingOverflowPagePointer,
        encode_table_leaf_cell(t.allocator, db_header, 1, payload, null),
    );
}

test "encode overflow page roundtrip" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    const chunk = "overflow-chunk-data";
    const raw = try encode_overflow_page(t.allocator, db_header, 42, chunk);
    defer t.allocator.free(raw);

    const parsed = try page.parse_overflow_page(t.allocator, raw);
    defer t.allocator.free(parsed.payload);

    try t.expectEqual(@as(?usize, 42), parsed.next);
    try t.expectEqualSlices(u8, chunk, parsed.payload[0..chunk.len]);
}

test "encode overflow page last page has zero next pointer" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    const raw = try encode_overflow_page(t.allocator, db_header, null, "tail");
    defer t.allocator.free(raw);

    const parsed = try page.parse_overflow_page(t.allocator, raw);
    defer t.allocator.free(parsed.payload);

    try t.expect(parsed.next == null);
}

test "encode overflow page rejects oversized chunk" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    const oversized = try t.allocator.alloc(u8, db_header.usable_page_size() - 3);
    defer t.allocator.free(oversized);

    try t.expectError(
        error.OverflowChunkTooLarge,
        encode_overflow_page(t.allocator, db_header, null, oversized),
    );
}

test "encode table leaf cell errors when overflow pointer is unexpected" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    try t.expectError(
        error.UnexpectedOverflowpage,
        encode_table_leaf_cell(t.allocator, db_header, 1, "abc", 99),
    );
}

test "encode table interior cell byte layout" {
    const cell = try encode_table_interior_cell(t.allocator, 0x01020304, 300);
    defer t.allocator.free(cell);

    try t.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x82, 0x2C }, cell);
}

test "encode table interior cell decodes back" {
    const left_child_page: u32 = 0x0A0B0C0D;
    const key: u64 = 12345;

    const cell = try encode_table_interior_cell(t.allocator, left_child_page, key);
    defer t.allocator.free(cell);

    try t.expectEqual(left_child_page, std.mem.readInt(u32, cell[0..4], .big));

    const decoded_key = try varint.decode(cell, 4);
    try t.expectEqual(key, decoded_key.value);
    try t.expectEqual(4 + decoded_key.len, cell.len);
}

test "encode leaf page with one cell" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    const record = try encode_record(t.allocator, &.{.{ .String = "abc" }});
    defer t.allocator.free(record);

    const cell = try encode_table_leaf_cell(t.allocator, db_header, 5, record, null);
    defer t.allocator.free(cell);

    const page_buf = try encode_leaf_page(t.allocator, db_header, &.{cell});
    defer t.allocator.free(page_buf);

    try t.expectEqual(@as(u8, 0x0D), page_buf[0]);
    try t.expectEqual(@as(u16, 1), std.mem.readInt(u16, page_buf[cnst.PAGE_CELL_COUNT_OFFSET..][0..2], .big));

    const cell_ptr = std.mem.readInt(u16, page_buf[cnst.PAGE_LEAF_HEADER_SIZE..][0..2], .big);
    const content_offset = std.mem.readInt(u16, page_buf[cnst.PAGE_CELL_CONTENT_OFFSET..][0..2], .big);
    try t.expectEqual(content_offset, cell_ptr);
    try t.expectEqualSlices(u8, cell, page_buf[cell_ptr .. cell_ptr + cell.len]);
}

test "encode leaf page with multiple cells" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    const record1 = try encode_record(t.allocator, &.{.{ .I8 = 1 }});
    defer t.allocator.free(record1);
    const record2 = try encode_record(t.allocator, &.{.{ .String = "hello" }});
    defer t.allocator.free(record2);

    const cell1 = try encode_table_leaf_cell(t.allocator, db_header, 1, record1, null);
    defer t.allocator.free(cell1);
    const cell2 = try encode_table_leaf_cell(t.allocator, db_header, 2, record2, null);
    defer t.allocator.free(cell2);

    const page_buf = try encode_leaf_page(t.allocator, db_header, &.{ cell1, cell2 });
    defer t.allocator.free(page_buf);

    const ptr1 = std.mem.readInt(u16, page_buf[cnst.PAGE_LEAF_HEADER_SIZE..][0..2], .big);
    const ptr2 = std.mem.readInt(u16, page_buf[cnst.PAGE_LEAF_HEADER_SIZE + 2 ..][0..2], .big);

    try t.expect(ptr1 > ptr2);
    try t.expectEqualSlices(u8, cell1, page_buf[ptr1 .. ptr1 + cell1.len]);
    try t.expectEqualSlices(u8, cell2, page_buf[ptr2 .. ptr2 + cell2.len]);
}

test "encode leaf page roundtrip parse" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(t.allocator, .Leaf, db_header);
    defer builder.deinit();
    try builder.addLeafCell(5, &.{.{ .String = "abc" }});
    try builder.addLeafCell(6, &.{.{ .I16 = 42 }});

    const page_buf = try builder.build();
    defer t.allocator.free(page_buf);

    var parsed = try page.parse_page(t.allocator, page_buf, 2, &db_header);
    defer page.deinitPage(t.allocator, &parsed);

    try t.expectEqual(page.PageType.Leaf, parsed.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 2), parsed.Leaf.header.cell_count);
    try t.expectEqual(@as(i64, 5), parsed.Leaf.cells.items[0].row_id);
    try t.expectEqual(@as(i64, 6), parsed.Leaf.cells.items[1].row_id);
    try t.expectEqualSlices(u8, &[_]u8{ 0x02, 0x13, 'a', 'b', 'c' }, parsed.Leaf.cells.items[0].payload);
    try t.expectEqualSlices(u8, &[_]u8{ 0x02, 0x02, 0x00, 0x2A }, parsed.Leaf.cells.items[1].payload);
}

const tw = @import("tripwire").module(enum {
    after_record_buffer_alloc,
}, @TypeOf(encode_record));

fn encode_record_tripwire_impl(alloc: Allocator) !void {
    errdefer tw.reset();

    tw.errorAlways(.after_record_buffer_alloc, error.OutOfMemory);
    try t.expectError(
        error.OutOfMemory,
        encode_record(alloc, &.{.{ .I8 = 42 }}),
    );
    try tw.end(.reset);
}

test "encode_record frees record_buffer on post-allocation failure" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer std.debug.assert(gpa.deinit() == .ok);

    try encode_record_tripwire_impl(gpa.allocator());
}
