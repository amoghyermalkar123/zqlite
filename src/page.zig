//! Page is a unit of I/O in zsqlite
//! when stored in the file, they are stored at 0-based offsets
//! but represented as 1 based

const std = @import("std");
const cnst = @import("constants.zig");
const Allocator = std.mem.Allocator;

pub const Page = union(PageType) {
    Leaf: TableLeafPage,
};

// A leaf page is the complete representation of a full page
// consisting of header metadata, pointers to cells and then actual cells
// each cell has the actual payload
pub const TableLeafPage = struct {
    header: PageHeader,
    cell_pointers: []u16,
    cells: std.ArrayList(TableLeafCell),
};

// Page header contains metadata
pub const PageHeader = struct {
    page_type: PageType,
    first_free_block: u16,
    cell_count: u16,
    cell_content_offset: u32,
    fragmented_byts_count: u8,
};

// An Actual cell which contains the data
pub const TableLeafCell = struct {
    size: i64,
    row_id: i64,
    payload: []const u8,
};

pub const PageType = enum(u8) {
    Leaf = 0x00,
};

const Decoder = struct {
    buffer: []const u8,

    const Self = @This();

    fn read_int(self: *const Self, index: usize, comptime T: type) !T {
        var ix = index;
        if (ix + @sizeOf(T) > self.buffer.len) return error.BufferExhausted;
        defer ix += @sizeOf(T);

        return std.mem.readInt(T, self.buffer[ix .. ix + @sizeOf(T)][0..@sizeOf(T)], .big);
    }

    // fn read_int_at(self: *Self, from: usize, comptime T: type) !T {}

    fn read_enum(self: *const Self, index: usize, comptime T: type) !T {
        return std.enums.fromInt(T, try self.read_int(index, std.meta.Tag(T))) orelse error.InvalidEnumTag;
    }

    fn read_slice(self: *const Self, from: usize, len: usize) ![]const u8 {
        if (from + len > self.buffer.len) return error.BufferExhausted;
        return self.buffer[from .. from + len];
    }
};

pub fn parse_page(alloc: Allocator, buffer: []const u8, page_num: usize) !Page {
    // if 1st page read from 100 for actual page content and skip metadata
    // NOTE: pages are 1-based
    const ptr_offset = if (page_num == 1) @as(u16, cnst.HEADER_SIZE) else 0;
    const pt: PageType = @enumFromInt(buffer[0]);

    if (pt != .Leaf) return error.UnknownPageType;

    var decoder = Decoder{ .buffer = buffer };
    return parse_table_leaf_page(alloc, &decoder, ptr_offset);
}

fn parse_table_leaf_page(alloc: Allocator, decoder: *Decoder, ptr_offset: u16) !Page {
    const pg_hdr = try parse_page_header(decoder);
    // parse cell pointers
    const cell_pointers = try parse_cell_pointers(alloc, decoder, pg_hdr.cell_count, ptr_offset);
    // parse cells
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
}

fn parse_page_header(decoder: *Decoder) !PageHeader {
    const pt = try decoder.read_enum(0, PageType);
    if (pt != .Leaf) return error.InvalidPageType;

    const first_free_block = try decoder.read_int(cnst.PAGE_FIRST_FREEBLOCK_OFFSET, u16);
    const cell_count_offset = try decoder.read_int(cnst.PAGE_CELL_COUNT_OFFSET, u16);
    var cell_content_offset = @as(u32, try decoder.read_int(cnst.PAGE_CELL_CONTENT_OFFSET, u16));
    const fragmented_byts_count = try decoder.read_int(cnst.PAGE_FRAGMENTED_BYTES_COUNT_OFFSET, u8);

    if (cell_content_offset == 0) cell_content_offset = 65535;

    return PageHeader{
        .page_type = pt,
        .fragmented_byts_count = fragmented_byts_count,
        .cell_content_offset = cell_content_offset,
        .cell_count = cell_count_offset,
        .first_free_block = first_free_block,
    };
}

// caller owns the returned slice
fn parse_cell_pointers(alloc: Allocator, decoder: *const Decoder, n: usize, ptr_offset: u16) ![]u16 {
    var pointers = try std.ArrayList(u16).initCapacity(alloc, n);
    for (0..n) |ix| {
        // absolute positions of the pointers of the cells need to be pushed to the array
        try pointers.append(alloc, try decoder.read_int(cnst.PAGE_LEAF_HEADER_SIZE + 2 * ix, u16) - ptr_offset);
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

fn read_varint_at(decoder: *Decoder, offset: usize) !struct { n: u8, res: i64 } {
    var size: u8 = 0;
    var result: i64 = 0;
    var ofs = offset;

    // sqlite varint is 9 bytes long
    while (size < 9) {
        const cur_byte = @as(i64, try decoder.read_int(ofs, u8));

        if (size == 8) {
            // this shifts 8 bits to the left in result,
            // moves bits from cur_byte to result
            result = (result << 8) | cur_byte;
        } else {
            // shift 7 bits to left
            // mask payload bits (i.e. skip continutation bit) from cur_byte
            // or the shifted result bits and masked bits of cur_byte
            result = (result << 7) | (cur_byte & 0b0111_1111);
        }

        ofs += 1;
        size += 1;

        // stop at last byte
        if (cur_byte & 0b1000_0000 == 0) break;
    }

    return .{
        .n = size,
        .res = result,
    };
}

const t = std.testing;

test "read_varint_at" {
    var dec = Decoder{
        .buffer = &[_]u8{ 0x81, 0x2C },
    };

    const res = try read_varint_at(&dec, 0);
    try t.expectEqual(@as(u8, 2), res.n);
    try t.expectEqual(@as(i64, 172), res.res);
}

// TODO: change this test to use an encoder instead of defining a raw byte array
test "parse_page" {
    const buf = [_]u8{
        0x00, // page type: Leaf in your enum as currently written
        0x00, 0x00, // first free block
        0x00, 0x01, // cell count = 1
        0x00, 0x10, // cell content offset = 16
        0x00, // fragmented bytes count
        0x00, 0x10, // one cell pointer -> byte offset 16
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // filler to reach offset 16
        0x05, // varint: payload size = 5
        0x01, // varint: row_id = 1
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, // payload
    };

    var scratch: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);

    const pg = try parse_page(fba.allocator(), &buf, 0);
    try t.expectEqual(PageType.Leaf, pg.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 1), pg.Leaf.header.cell_count);
    try t.expectEqual(@as(usize, 1), pg.Leaf.cell_pointers.len);
    try t.expectEqual(@as(u16, 16), pg.Leaf.cell_pointers[0]);
    try t.expectEqual(@as(usize, 1), pg.Leaf.cells.items.len);
    try t.expectEqual(@as(i64, 5), pg.Leaf.cells.items[0].size);
    try t.expectEqual(@as(i64, 1), pg.Leaf.cells.items[0].row_id);
    try t.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE }, pg.Leaf.cells.items[0].payload);
}
