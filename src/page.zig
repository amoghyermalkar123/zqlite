//! Page is a unit of I/O in zsqlite
//! when stored in the file, they are stored at 0-based offsets
//! but represented as 1 based
const std = @import("std");
const cnst = @import("constants.zig");
const Allocator = std.mem.Allocator;
pub const Decoder = @import("decode_page.zig").Decoder;

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
    /// TODO: move this out of PageHeader container
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

    /// TODO: move this out of PageHeader container
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
    payload: []u8,
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

pub fn parse_overflow_page(alloc: Allocator, buffer: []const u8) !OverflowPage {
    const next_raw = std.mem.readInt(u32, buffer[0..4], .big);

    const payload = try alloc.dupe(u8, buffer[4..]);

    return OverflowPage{
        .payload = payload,
        .next = if (next_raw != 0) @as(usize, next_raw) else null,
    };
}

pub fn deinitPage(alloc: Allocator, page: *Page) void {
    switch (page.*) {
        .Leaf => |*leaf| deinitLeafPage(alloc, leaf),
        .Interior => |*interior| {
            alloc.free(interior.cell_pointers);
            interior.cells.deinit(alloc);
        },
    }
}

pub fn deinitLeafPage(alloc: Allocator, leaf: *TableLeafPage) void {
    for (leaf.cells.items) |cell| alloc.free(cell.payload);
    alloc.free(leaf.cell_pointers);
    leaf.cells.deinit(alloc);
}

pub fn parse_page(alloc: Allocator, buffer: []const u8, page_num: usize, db_header: *const DbHeader) !Page {
    const page_offset = if (page_num == 1) cnst.HEADER_SIZE else 0;

    var decoder = Decoder.initAt(buffer, page_offset);

    const pt = try decoder.readEnum(PageType);

    if (pt != .Leaf and pt != .Interior) return error.UnknownPageType;

    return parse_table_leaf_page(alloc, &decoder, page_offset, db_header);
}

fn parse_table_leaf_page(alloc: Allocator, decoder: *Decoder, page_offset: usize, db_header: *const DbHeader) !Page {
    const pg_hdr = try parse_page_header(decoder, page_offset);
    // parse cell pointers
    const cell_pointers = try parse_cell_pointers(alloc, decoder.buffer, page_offset, pg_hdr.cell_count, switch (pg_hdr.page_type) {
        .Leaf => cnst.PAGE_LEAF_HEADER_SIZE,
        .Interior => cnst.PAGE_INTERIOR_HEADER_SIZE,
    });

    // parse cells
    switch (pg_hdr.page_type) {
        .Leaf => {
            var cells = try std.ArrayList(TableLeafCell).initCapacity(alloc, cell_pointers.len);
            for (cell_pointers) |cell_ptr| {
                try cells.append(alloc, try parse_table_leaf_cell(alloc, decoder.buffer, cell_ptr, db_header, &pg_hdr));
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
                try cells.append(alloc, try parse_table_internal_cell(decoder.buffer, cell_ptr));
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
    decoder.seekTo(page_offset);

    const pt = try decoder.readEnum(PageType);
    if (pt != .Leaf and pt != .Interior) return error.InvalidPageType;

    const first_free_block = try decoder.readInt(u16);
    const cell_count_offset = try decoder.readInt(u16);
    var cell_content_offset = @as(u32, try decoder.readInt(u16));
    const fragmented_byts_count = try decoder.readInt(u8);

    if (cell_content_offset == 0) cell_content_offset = 65536;

    return PageHeader{
        .page_type = pt,
        .fragmented_byts_count = fragmented_byts_count,
        .cell_content_offset = cell_content_offset,
        .cell_count = cell_count_offset,
        .first_free_block = first_free_block,
        .rightmost_pointer = if (pt == .Interior) try decoder.readInt(u32) else null,
    };
}

// caller owns the returned slice
fn parse_cell_pointers(alloc: Allocator, raw_buf: []const u8, page_offset: usize, n: usize, header_size: usize) ![]u16 {
    var decoder = Decoder.initAt(raw_buf, page_offset + header_size);

    var pointers = try std.ArrayList(u16).initCapacity(alloc, n);
    errdefer pointers.deinit(alloc);

    for (0..n) |_| {
        // absolute positions of the pointers of the cells need to be pushed to the array
        try pointers.append(alloc, try decoder.readInt(u16));
    }

    return pointers.toOwnedSlice(alloc);
}

fn parse_table_leaf_cell(alloc: Allocator, raw_buf: []const u8, cell_ptr: u16, db_header: *const DbHeader, page_header: *const PageHeader) !TableLeafCell {
    var decoder = Decoder.initAt(raw_buf, cell_ptr);

    const payload_size = try decoder.readVarint();
    const rowId = try decoder.readVarint();

    const sizes = try page_header.local_and_overflow_size(db_header.*, @intCast(payload_size.value));
    const local_size = sizes[0];
    const overflow_size = sizes[1];

    const borrowed = try decoder.readSlice(local_size);
    const payload = try alloc.dupe(u8, borrowed);
    errdefer alloc.free(payload);

    // pointer to the first overflow page
    const first_overflow = if (overflow_size != null)
        @as(usize, try decoder.readInt(u32))
    else
        null;

    return TableLeafCell{
        .payload = payload,
        .row_id = @intCast(rowId.value),
        .size = @intCast(payload_size.value),
        .first_overflow = first_overflow,
    };
}

fn parse_table_internal_cell(raw_buf: []const u8, cell_ptr: u16) !TableInteriorCell {
    var decoder = Decoder.initAt(raw_buf, cell_ptr);
    const left_child_page = try decoder.readInt(u32);
    const key_res = try decoder.readVarint();

    return TableInteriorCell{
        .left_child_page = left_child_page,
        .key = @intCast(key_res.value),
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
    var decoder = Decoder.init(cell_payload);
    // let's read the record header
    // first we read the header_size varint
    const headerSize = try decoder.readVarint();
    // byte width of the `Header Size` varint itself
    // the value of this is the starting offset in the header buffer
    // from where we can start reading the type code values
    var record_header_cursor = headerSize.len;
    // this gives us the entire length of the record header
    // the value of this is the starting offset from where
    // we can start reading the field data i.e. the actual
    // fields payload
    var field_payload_cursor: usize = @intCast(headerSize.value);
    // TODO: can the mem alloc get better here?
    var fields = try std.ArrayList(RecordField).initCapacity(alloc, 10);
    errdefer fields.deinit(alloc);
    while (@as(i64, record_header_cursor) < headerSize.value) {
        // we read the discriminant here, i.e. the field information
        // stored in the record header
        const typeCode = try decoder.readVarint();
        // the size of the header bytes read, this is the value
        // we advance our record header cursor by
        record_header_cursor += typeCode.len;
        // now parse the actual type of the field as indicated by the value of the type code we just read
        const columnFieldData: struct { field_type: RecordFieldType, field_size: usize } = switch (typeCode.value) {
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
                if (typeCode.value >= 12 and @rem(typeCode.value, 2) == 0) {
                    const sz: usize = @intCast(@divTrunc(typeCode.value - 12, 2));
                    break :blk .{ .field_type = .{ .Blob = sz }, .field_size = sz };
                }

                if (typeCode.value >= 13 and @rem(typeCode.value, 2) == 1) {
                    const sz: usize = @intCast(@divTrunc(typeCode.value - 13, 2));
                    break :blk .{ .field_type = .{ .String = sz }, .field_size = sz };
                }

                return error.UnsupportedRecordFieldType;
            },
        };
        // TODO: is type coercion possible here?
        try fields.append(alloc, .{
            .field_type = columnFieldData.field_type,
            .offset = field_payload_cursor,
        });
        // we've decoded the field, now since the types of the field are a great
        // way to understand their sizes, we can advance the field payload cursor
        // by the size of the type of the field i.e. 1 for I8, 2 for I16, etc.
        field_payload_cursor += columnFieldData.field_size;
    }

    return .{ .fields = try fields.toOwnedSlice(alloc) };
}

const t = std.testing;
const encode_page = @import("encode_page.zig");
const PageBuilder = @import("testing/page_builder.zig").PageBuilder;

test "parse record header with multibyte type code" {
    const long_string = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdef";
    const record = try encode_page.encode_record(t.allocator, &.{.{ .String = long_string }});
    defer t.allocator.free(record);

    const header = try parse_record_header(t.allocator, record);
    defer t.allocator.free(header.fields);

    try t.expectEqual(@as(usize, 1), header.fields.len);
    try t.expectEqual(@as(std.meta.Tag(RecordFieldType), .String), @as(std.meta.Tag(RecordFieldType), header.fields[0].field_type));
    try t.expectEqual(@as(usize, 3), header.fields[0].offset);
    try t.expectEqualSlices(u8, long_string, record[header.fields[0].offset .. header.fields[0].end_offset()]);
}

test "parse page 1 uses 100 byte header offset" {
    const db_header = DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(t.allocator, .Leaf, db_header);
    defer builder.deinit();
    try builder.addLeafCell(5, &.{.{ .String = "abc" }});

    const full_buf = try builder.buildPageFile(1);
    defer t.allocator.free(full_buf);

    var pg = try parse_page(t.allocator, full_buf, 1, &db_header);
    defer deinitPage(t.allocator, &pg);

    try t.expectEqual(PageType.Leaf, pg.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 1), pg.Leaf.header.cell_count);
    try t.expectEqual(@as(i64, 5), pg.Leaf.cells.items[0].row_id);
    try t.expectEqualSlices(u8, &[_]u8{ 0x02, 0x13, 'a', 'b', 'c' }, pg.Leaf.cells.items[0].payload);
}
