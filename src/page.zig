//! Page is a unit of I/O in zsqlite
//! when stored in the file, they are stored at 0-based offsets
//! but represented as 1 based

const std = @import("std");
const cnst = @import("constants.zig");
const Allocator = std.mem.Allocator;

pub const DbHeader = struct {
    page_size: u32,
};

pub fn parse_header(buffer: []const u8) !DbHeader {
    if (buffer.len < cnst.HEADER_SIZE) {
        return error.InvalidHeaderSize;
    }

    if (!std.mem.startsWith(u8, buffer, cnst.HEADER_PREFIX)) {
        return error.InvalidHeaderPrefix;
    }

    const page_size_raw = std.mem.readInt(u16, buffer[cnst.HEADER_PAGE_SIZE_OFFSET..][0..cnst.HEADER_PAGE_SIZE_SIZE], .big);
    // page_size 1 is used to indicate max page size
    return DbHeader{
        .page_size = if (page_size_raw == 1) cnst.PAGE_MAX_SIZE else if (page_size_raw & (page_size_raw - 1) == 0 and page_size_raw != 0) page_size_raw else return error.InvalidPageSize,
    };
}

pub const Page = union(PageType) {
    Leaf: TableLeafPage,
    Interior: TableInteriorPage,
};

// A leaf page is the complete representation of a full page
// consisting of header metadata, pointers to cells and then actual cells
// each cell has the actual payload
pub const TableLeafPage = struct {
    header: PageHeader,
    cell_pointers: []u16,
    cells: std.ArrayList(TableLeafCell),
};

// An interior page holds info about where next pages are based on
// ordered keys
pub const TableInteriorPage = struct {
    header: PageHeader,
    cell_pointers: []u16,
    cells: std.ArrayList(TableInteriorCell),
};

// Page header contains metadata
pub const PageHeader = struct {
    page_type: PageType,
    first_free_block: u16,
    cell_count: u16,
    cell_content_offset: u32,
    fragmented_byts_count: u8,
    // only stored when the page is interior
    // points to the sibling interior page at the same depth
    rightmost_pointer: ?u32 = null,
};

// An Actual cell which contains the data
pub const TableLeafCell = struct {
    size: i64,
    row_id: i64,
    payload: []const u8,
};

// a cell which holds tuple data which points to the next subtree containing the key
pub const TableInteriorCell = struct {
    left_child_page: u32,
    key: i64,
};

pub const PageType = enum(u8) {
    Leaf = 0x0D,
    Interior = 0x05,
};

pub const Decoder = struct {
    buffer: []const u8,

    const Self = @This();

    pub fn read_int(self: *const Self, index: usize, comptime T: type) !T {
        var ix = index;
        const int_size = @divExact(@typeInfo(T).int.bits, 8);
        if (ix + int_size > self.buffer.len) return error.BufferExhausted;
        defer ix += int_size;

        return std.mem.readInt(T, self.buffer[ix .. ix + int_size][0..int_size], .big);
    }

    pub fn read_enum(self: *const Self, index: usize, comptime T: type) !T {
        return std.enums.fromInt(T, try self.read_int(index, std.meta.Tag(T))) orelse error.InvalidEnumTag;
    }

    pub fn read_slice(self: *const Self, from: usize, len: usize) ![]const u8 {
        if (from + len > self.buffer.len) return error.BufferExhausted;
        return self.buffer[from .. from + len];
    }
};

pub fn parse_page(alloc: Allocator, buffer: []const u8, page_num: usize) !Page {
    const page_offset = if (page_num == 1) cnst.HEADER_SIZE else 0;

    var decoder = Decoder{ .buffer = buffer };

    const pt = try decoder.read_enum(page_offset, PageType);

    if (pt != .Leaf and pt != .Interior) return error.UnknownPageType;

    return parse_table_leaf_page(alloc, &decoder, page_offset);
}

fn parse_table_leaf_page(alloc: Allocator, decoder: *Decoder, page_offset: usize) !Page {
    const pg_hdr = try parse_page_header(decoder, page_offset);
    // parse cell pointers
    const cell_pointers = try parse_cell_pointers(alloc, decoder, page_offset, pg_hdr.cell_count, switch (pg_hdr.page_type) {
        .Leaf => cnst.PAGE_LEAF_HEADER_SIZE,
        .Interior => cnst.PAGE_INTERIOR_HEADER_SIZE,
    });

    // parse cells
    switch (pg_hdr.page_type) {
        .Leaf => {
            var cells = try std.ArrayList(TableLeafCell).initCapacity(alloc, cell_pointers.len);
            for (cell_pointers) |cell_ptr| {
                try cells.append(alloc, try parse_table_leaf_cell(decoder, cell_ptr));
            }

            return Page{
                .Leaf = .{
                    .header = pg_hdr,
                    .cell_pointers = cell_pointers,
                    .cells = cells,
                },
            };
        },
        .Interior => {
            var cells = try std.ArrayList(TableInteriorCell).initCapacity(alloc, cell_pointers.len);
            for (cell_pointers) |cell_ptr| {
                try cells.append(alloc, try parse_table_internal_cell(decoder, cell_ptr));
            }

            return Page{
                .Interior = .{
                    .header = pg_hdr,
                    .cell_pointers = cell_pointers,
                    .cells = cells,
                },
            };
        },
    }
}

pub fn parse_page_header(decoder: *Decoder, page_offset: usize) !PageHeader {
    const pt = try decoder.read_enum(page_offset, PageType);
    if (pt != .Leaf and pt != .Interior) return error.InvalidPageType;

    const first_free_block = try decoder.read_int(page_offset + cnst.PAGE_FIRST_FREEBLOCK_OFFSET, u16);
    const cell_count_offset = try decoder.read_int(page_offset + cnst.PAGE_CELL_COUNT_OFFSET, u16);
    var cell_content_offset = @as(u32, try decoder.read_int(page_offset + cnst.PAGE_CELL_CONTENT_OFFSET, u16));
    const fragmented_byts_count = try decoder.read_int(page_offset + cnst.PAGE_FRAGMENTED_BYTES_COUNT_OFFSET, u8);

    if (cell_content_offset == 0) cell_content_offset = 65536;

    return PageHeader{
        .page_type = pt,
        .fragmented_byts_count = fragmented_byts_count,
        .cell_content_offset = cell_content_offset,
        .cell_count = cell_count_offset,
        .first_free_block = first_free_block,
        .rightmost_pointer = if (pt == .Interior) try decoder.read_int(page_offset + cnst.PAGE_LEAF_HEADER_SIZE, u32) else null,
    };
}

// caller owns the returned slice
fn parse_cell_pointers(alloc: Allocator, decoder: *const Decoder, page_offset: usize, n: usize, header_size: usize) ![]u16 {
    var pointers = try std.ArrayList(u16).initCapacity(alloc, n);
    errdefer pointers.deinit(alloc);

    for (0..n) |ix| {
        // absolute positions of the pointers of the cells need to be pushed to the array
        try pointers.append(alloc, try decoder.read_int(page_offset + header_size + 2 * ix, u16));
    }

    return pointers.toOwnedSlice(alloc);
}

fn parse_table_leaf_cell(decoder: *Decoder, cell_ptr: u16) !TableLeafCell {
    const size_result = try read_varint_at(decoder, cell_ptr);
    const row_id_offset = cell_ptr + size_result.n;
    const row_id_result = try read_varint_at(decoder, row_id_offset);
    const payload_offset = row_id_offset + row_id_result.n;
    // payload starts from payload_offset and payload length is in size_result.res
    const payload = try decoder.read_slice(payload_offset, @intCast(size_result.res));

    return TableLeafCell{
        .payload = payload,
        .row_id = row_id_result.res,
        .size = size_result.res,
    };
}

fn parse_table_internal_cell(decoder: *Decoder, cell_ptr: u16) !TableInteriorCell {
    const left_child_page = try decoder.read_int(cell_ptr, u32);
    const key_res = try read_varint_at(decoder, cell_ptr + 4);

    return TableInteriorCell{
        .left_child_page = left_child_page,
        .key = key_res.res,
    };
}

// docs can be found for this in docs/varint.md
pub fn read_varint_at(decoder: *Decoder, offset: usize) !struct { n: u8, res: i64 } {
    var bytes_read: u8 = 0;
    var result: i64 = 0;
    var ofs = offset;

    // sqlite varint is 9 bytes long
    while (bytes_read < 9) {
        const current_byte = @as(i64, try decoder.read_int(ofs, u8));

        if (bytes_read == 8) {
            // this shifts 8 bits to the left in result,
            // moves bits from cur_byte to result
            // since this is the last byte, all bits represent info
            // there is no control bit in here hence no masking required
            result = (result << 8) | current_byte;
        } else {
            // masking is basically for removing the control bit
            // shifting bits is for making space for the new bits of the cur_byte
            // remember, result is a 64 bit integer
            result = (result << 7) | (current_byte & 0b0111_1111);
        }

        ofs += 1;
        bytes_read += 1;

        // stop at last byte
        if (current_byte & 0b1000_0000 == 0) break;
    }

    return .{
        .n = bytes_read,
        .res = result,
    };
}

pub const RecordFieldType = union(enum) {
    Null,
    I8,
    I16,
    I24,
    I32,
    I48,
    I64,
    Float,
    Zero,
    One,
    String: usize,
    Blob: usize,
};

pub const RecordField = struct {
    offset: usize,
    field_type: RecordFieldType,
};

pub const RecordHeader = struct {
    fields: []RecordField,
};

/// SQLite record payload layout:
///
/// |<----------- record header ----------->|<------ record body ------>|
/// | header_size varint | serial type ...  | field 0 bytes | field ... |
///
/// Example payload:
///
///   [03] [01] [0F] [2A] [68]
///    |    |    |    |    |
///    |    |    |    |    field 1 body byte
///    |    |    |    field 0 body byte
///    |    |    serial type for field 1
///    |    serial type for field 0
///    header_size varint
///
/// For that example:
///
/// - `header_size = 3`, so header bytes are `[03][01][0F]`
/// - body starts at byte offset `3`
/// - serial type `1` maps to `I8`, so field 0 starts at offset `3`
/// - serial type `15` maps to `String(1)`, so field 1 starts at offset `4`
///
/// Cursor meaning inside this function:
///
/// - `buffer_cur` walks serial-type varints inside the header
/// - `field_payl_cur` walks field data inside the body
///
/// Final parsed header for the example:
///
///   fields = [
///     { offset = 3, field_type = I8 },
///     { offset = 4, field_type = String(1) },
///   ]
///
// returns a parsed `RecordHeader`, the caller owns `fields memory`
pub fn parse_record_header(alloc: Allocator, cell_payload: []const u8) !RecordHeader {
    var decoder = Decoder{ .buffer = cell_payload };

    const header_data = try read_varint_at(&decoder, 0);

    var fields = try std.ArrayList(RecordField).initCapacity(alloc, 10);
    errdefer fields.deinit(alloc);

    var buffer_cur = header_data.n;
    var field_payl_cur: usize = @intCast(header_data.res);

    while (@as(i64, buffer_cur) < header_data.res) {
        const discr_data = try read_varint_at(&decoder, buffer_cur);
        buffer_cur += discr_data.n;

        const field_data: struct { field_type: RecordFieldType, field_size: usize } = switch (discr_data.res) {
            0 => .{ .field_type = RecordFieldType.Null, .field_size = 0 },
            1 => .{ .field_type = RecordFieldType.I8, .field_size = 1 },
            2 => .{ .field_type = RecordFieldType.I16, .field_size = 2 },
            3 => .{ .field_type = RecordFieldType.I24, .field_size = 3 },
            4 => .{ .field_type = RecordFieldType.I32, .field_size = 4 },
            5 => .{ .field_type = RecordFieldType.I48, .field_size = 6 },
            6 => .{ .field_type = RecordFieldType.I64, .field_size = 8 },
            7 => .{ .field_type = RecordFieldType.Float, .field_size = 8 },
            8 => .{ .field_type = RecordFieldType.Zero, .field_size = 0 },
            9 => .{ .field_type = RecordFieldType.One, .field_size = 0 },
            else => blk: {
                if (discr_data.res >= 12 and @rem(discr_data.res, 2) == 0) {
                    const sz: usize = @intCast(@divTrunc(discr_data.res - 12, 2));
                    break :blk .{ .field_type = .{ .Blob = sz }, .field_size = sz };
                }

                if (discr_data.res >= 13 and @rem(discr_data.res, 2) == 1) {
                    const sz: usize = @intCast(@divTrunc(discr_data.res - 13, 2));
                    break :blk .{ .field_type = .{ .String = sz }, .field_size = sz };
                }

                return error.UnsupportedRecordFieldType;
            },
        };

        try fields.append(alloc, .{
            .field_type = field_data.field_type,
            .offset = field_payl_cur,
        });

        field_payl_cur += field_data.field_size;
    }

    return .{ .fields = try fields.toOwnedSlice(alloc) };
}

const t = std.testing;

test "parse_page_rest" {
    var buf = [_]u8{0} ** 123;
    buf[0] = 0x0D;
    buf[1] = 0x00;
    buf[2] = 0x00; // first free block
    buf[3] = 0x00;
    buf[4] = 0x01; // cell count = 1
    buf[5] = 0x00;
    buf[6] = 0x10; // cell content offset
    buf[7] = 0x00; // fragmented bytes count
    buf[8] = 0x00;
    buf[9] = 0x10; // first cell pointer
    buf[16] = 0x10; // first cell pointer
    buf[16] = 0x03; // varint: payload size = 3
    buf[17] = 0x05; // varint: row_id = 5
    buf[18] = 0x11; // payload byte 1
    buf[19] = 0x22; // payload byte 2
    buf[20] = 0x33; // payload byte 3
    var pg = try parse_page(t.allocator, &buf, 2); // page 2, no header offset
    defer t.allocator.free(pg.Leaf.cell_pointers);
    defer pg.Leaf.cells.deinit(t.allocator);
    try t.expectEqual(PageType.Leaf, pg.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 1), pg.Leaf.header.cell_count);
    try t.expectEqual(@as(u16, 16), pg.Leaf.cell_pointers[0]);
    try t.expectEqual(@as(i64, 3), pg.Leaf.cells.items[0].size);
    try t.expectEqual(@as(i64, 5), pg.Leaf.cells.items[0].row_id);
    try t.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33 }, pg.Leaf.cells.items[0].payload);
}

// TODO: change this test to use an encoder instead of defining a raw byte array
test "parse_page" {
    var buf = [_]u8{0} ** 123;
    buf[100] = 0x0D; // page type: SQLite table leaf page
    buf[101] = 0x00;
    buf[102] = 0x00; // first free block
    buf[103] = 0x00;
    buf[104] = 0x01; // cell count = 1
    buf[105] = 0x00;
    buf[106] = 0x74; // cell content offset = 116
    buf[107] = 0x00; // fragmented bytes count
    buf[108] = 0x00;
    buf[109] = 0x74; // one cell pointer -> absolute byte offset 116 in page 1
    buf[116] = 0x05; // varint: payload size = 5
    buf[117] = 0x01; // varint: row_id = 1
    buf[118] = 0xAA;
    buf[119] = 0xBB;
    buf[120] = 0xCC;
    buf[121] = 0xDD;
    buf[122] = 0xEE; // payload

    var pg = try parse_page(t.allocator, &buf, 1);
    defer t.allocator.free(pg.Leaf.cell_pointers);
    defer pg.Leaf.cells.deinit(t.allocator);
    try t.expectEqual(PageType.Leaf, pg.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 1), pg.Leaf.header.cell_count);
    try t.expectEqual(@as(usize, 1), pg.Leaf.cell_pointers.len);
    try t.expectEqual(@as(u16, 116), pg.Leaf.cell_pointers[0]);
    try t.expectEqual(@as(usize, 1), pg.Leaf.cells.items.len);
    try t.expectEqual(@as(i64, 5), pg.Leaf.cells.items[0].size);
    try t.expectEqual(@as(i64, 1), pg.Leaf.cells.items[0].row_id);
    try t.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE }, pg.Leaf.cells.items[0].payload);
}
