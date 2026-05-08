//! Page is a unit of I/O in zsqlite
//! when stored in the file, they are stored at 0-based offsets
//! but represented as 1 based
const std = @import("std");
const cnst = @import("constants.zig");
const Allocator = std.mem.Allocator;

pub const OverflowPage = struct {
    next: ?usize,
    payload: []u8,
};

pub const DbHeader = struct {
    page_size: u32,
    page_reserved_size: u8,

    pub fn usable_page_size(self: DbHeader) usize {
        return @as(usize, self.page_size) - @as(usize, self.page_reserved_size);
    }
};

pub fn parse_header(buffer: []const u8) !DbHeader {
    if (buffer.len < cnst.HEADER_SIZE) {
        return error.InvalidHeaderSize;
    }

    if (!std.mem.startsWith(u8, buffer, cnst.HEADER_PREFIX)) {
        return error.InvalidHeaderPrefix;
    }

    // read 2 bytes which represent the sizes of the pages.
    const page_size_raw = std.mem.readInt(u16, buffer[cnst.HEADER_PAGE_SIZE_OFFSET..][0..cnst.HEADER_PAGE_SIZE_SIZE], .big);

    // page_size 1 is used to indicate max page size
    return DbHeader{
        .page_size = if (page_size_raw == 1) cnst.PAGE_MAX_SIZE else if (page_size_raw & (page_size_raw - 1) == 0 and page_size_raw != 0) page_size_raw else return error.InvalidPageSize,
        .page_reserved_size = buffer[cnst.HEADER_PAGE_RESERVED_SIZE_OFFSET],
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

// Page header contains metadata about a page
// it's generic and represents both internal and leaf pages
pub const PageHeader = struct {
    page_type: PageType,
    first_free_block: u16,
    cell_count: u16,
    cell_content_offset: u32,
    fragmented_byts_count: u8,
    // only stored when the page is interior
    // points to the sibling interior page at the same depth
    rightmost_pointer: ?u32 = null,

    /// Compute local payload size
    pub fn local_payload_size(self: *const @This(), db_header: DbHeader, payload_size: usize) !usize {
        switch (self.page_type) {
            .Interior => return error.NoPayloadSizeForInteriorPage,
            .Leaf => {
                // NOTE: The FORMULAS used here are verbatim from the followed article which are picked
                // from the sqlite source code. As of writing this  (6.5.26) I have yet to make
                // sense of the `why` of these formulas
                const usable = db_header.usable_page_size();
                // X = U - 35, which is the overflow threshold: if the payload size
                // is less than or equal to X it will be stored entirely in a B-tree leaf cell,
                // without overflow
                const max_size = usable - 35;
                if (payload_size <= max_size) return payload_size;
                // M = ((U-12)*32/255)-23, the minimum local payload size
                const min_size = ((usable - 12) * 32 / 255) - 23;
                // the maximum local payload size
                const k = min_size + @as(usize, @mod(payload_size - min_size, usable - 4));
                // return final size
                return if (k <= max_size) k else min_size;
            },
        }
    }

    pub fn local_and_overflow_size(self: *const @This(), db_header: DbHeader, payload_size: usize) !struct { usize, ?usize } {
        const local = try self.local_payload_size(db_header, payload_size);

        if (local == payload_size) {
            return .{ local, null };
        }

        return .{ local, payload_size -| local };
    }
};

// An Actual cell which contains the data
pub const TableLeafCell = struct {
    size: i64,
    row_id: i64,
    payload: []const u8,
    first_overflow: ?usize,
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

pub fn parse_overflow_page(alloc: Allocator, buffer: []const u8) !OverflowPage {
    const next_raw = std.mem.readInt(u32, buffer[0..4], .big);

    const payload = try alloc.dupe(u8, buffer[4..]);

    return OverflowPage{
        .payload = payload,
        .next = if (next_raw != 0) @as(usize, next_raw) else null,
    };
}

pub fn parse_page(alloc: Allocator, buffer: []const u8, page_num: usize, db_header: *const DbHeader) !Page {
    const page_offset = if (page_num == 1) cnst.HEADER_SIZE else 0;

    var decoder = Decoder{ .buffer = buffer };

    const pt = try decoder.read_enum(page_offset, PageType);

    if (pt != .Leaf and pt != .Interior) return error.UnknownPageType;

    return parse_table_leaf_page(alloc, &decoder, page_offset, db_header);
}

fn parse_table_leaf_page(alloc: Allocator, decoder: *Decoder, page_offset: usize, db_header: *const DbHeader) !Page {
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
                try cells.append(alloc, try parse_table_leaf_cell(decoder, cell_ptr, db_header, &pg_hdr));
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

fn parse_table_leaf_cell(decoder: *Decoder, cell_ptr: u16, db_header: *const DbHeader, page_header: *const PageHeader) !TableLeafCell {
    const size_result = try read_varint_at(decoder, cell_ptr);
    const row_id_offset = cell_ptr + size_result.n;
    const row_id_result = try read_varint_at(decoder, row_id_offset);
    const payload_offset = row_id_offset + row_id_result.n;

    const sizes = try page_header.local_and_overflow_size(db_header.*, @intCast(size_result.res));
    const local_size = sizes[0];
    const overflow_size = sizes[1];

    const payload = try decoder.read_slice(payload_offset, local_size);

    // pointer to the first overflow page
    const first_overflow = if (overflow_size != null)
        @as(usize, try decoder.read_int(payload_offset + local_size, u32))
    else
        null;

    return TableLeafCell{
        .payload = payload,
        .row_id = row_id_result.res,
        .size = size_result.res,
        .first_overflow = first_overflow,
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
        // this is indicated by the continuation bit being set to 0
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

    pub fn end_offset(self: RecordField) usize {
        const size: usize = switch (self.field_type) {
            .Null => 0,
            .I8 => 1,
            .I16 => 2,
            .I24 => 3,
            .I32 => 4,
            .I48 => 5,
            .I64 => 8,
            .Float => 8,
            .Zero => 0,
            .One => 0,
            .String => |n| n,
            .Blob => |n| n,
        };

        return self.offset + size;
    }
};

pub const RecordHeader = struct {
    fields: []RecordField,
};

// SQLite Record Format (cell payload)
// ====================================
//
// +------------------+------------------+-----+------------------+------------------+-----+------------------+
// |   Header Size    |   Type Code 1    | ... |   Type Code N    |   Field Data 1   | ... |   Field Data N   |
// |    (varint)      |    (varint)      |     |    (varint)      |   (variable)     |     |   (variable)     |
// +------------------+------------------+-----+------------------+------------------+-----+------------------+
// |<------------------- Header (header_size bytes) ------------->|<---------- Payload Data ------------>|
//
// Header Size: Total bytes in header including this varint
// Type Codes:  Discriminators that encode field type and size:
//              0       -> NULL
//              1       -> 8-bit signed int
//              2       -> 16-bit signed int (big-endian)
//              3       -> 24-bit signed int (big-endian)
//              4       -> 32-bit signed int (big-endian)
//              5       -> 48-bit signed int (big-endian)
//              6       -> 64-bit signed int (big-endian)
//              7       -> 64-bit IEEE float (big-endian)
//              8       -> Integer constant 0
//              9       -> Integer constant 1
//              >=12 even -> BLOB of size (N-12)/2
//              >=13 odd  -> String of size (N-13)/2
//
pub fn parse_record_header(alloc: Allocator, cell_payload: []const u8) !RecordHeader {
    var decoder = Decoder{ .buffer = cell_payload };
    // let's read the record header
    const header_data = try read_varint_at(&decoder, 0);
    // byte width of the `Header Size` varint itself
    // the value of this is the starting offset in the header buffer
    // from where we can start reading the type code values
    var record_header_cursor = header_data.n;
    // this gives us the entire length of the record header
    // the value of this is the starting offset from where
    // we can start reading the field data i.e. the actual
    // fields payload
    var field_payload_cursor: usize = @intCast(header_data.res);

    var fields = try std.ArrayList(RecordField).initCapacity(alloc, 10);
    errdefer fields.deinit(alloc);

    while (@as(i64, record_header_cursor) < header_data.res) {
        // we read the discriminant here, i.e. the field information
        // stored in the record header
        const discr_data = try read_varint_at(&decoder, record_header_cursor);
        // the size of the header bytes read, this is the value
        // we advance our record header cursor by
        record_header_cursor += discr_data.n;
        // now parse the actual type of the field as indicated by the value of the type code we just read
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
            .offset = field_payload_cursor,
        });

        // we've decoded the field, now since the types of the field are a great
        // way to understand their sizes, we can advance the field payload cursor
        // by the size of the type of the field i.e. 1 for I8, 2 for I16, etc.
        field_payload_cursor += field_data.field_size;
    }

    return .{ .fields = try fields.toOwnedSlice(alloc) };
}

const t = std.testing;

fn page_encoder() []const u8 {}

test "parse_page_rest" {
    var buf = [_]u8{0} ** 123;
    const db_header = DbHeader{
        .page_size = 4096,
        .page_reserved_size = 0,
    };
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
    var pg = try parse_page(t.allocator, &buf, 2, &db_header); // page 2, no header offset
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
    const db_header = DbHeader{
        .page_size = 4096,
        .page_reserved_size = 0,
    };
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

    var pg = try parse_page(t.allocator, &buf, 1, &db_header);
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
