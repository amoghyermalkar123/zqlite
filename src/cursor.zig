const std = @import("std");
const pg = @import("page.zig");
const RecordHeader = @import("page.zig").RecordHeader;
const Pager = @import("pager_manager.zig");

pub const Value = union(enum) {
    Null,
    String: struct { str: []const u8 },
    Blob: struct { str: []const u8 },
    Int: i64,
    Float: f64,
};

// Uniquely indentifies a single record
// it is a cursor over a cell in a leaf page
pub const Cursor = struct {
    header: RecordHeader,
    pager: *Pager,
    page_index: usize,
    page_cell: usize,

    const Self = @This();

    // given `n` returns back the nth gield in the record (i.e. row) if found
    // else returns null
    pub fn field(self: *Self, n: usize) !?Value {
        if (n >= self.header.fields.len) return error.InvalidIndex;

        const record_field = self.header.fields[n];
        const page = try self.pager.read_page(self.page_index);
        const cell = page.Leaf.cells.items[self.page_cell];
        var decoder = pg.Decoder{ .buffer = cell.payload };

        switch (record_field.field_type) {
            .Null => return .Null,
            .I8 => return .{ .Int = try decoder.read_int(record_field.offset, i8) },
            .I16 => return .{ .Int = try decoder.read_int(record_field.offset, i16) },
            .I24 => return .{ .Int = try decoder.read_int(record_field.offset, i24) },
            .I32 => return .{ .Int = try decoder.read_int(record_field.offset, i32) },
            .I48 => return .{ .Int = try decoder.read_int(record_field.offset, i48) },
            .I64 => return .{ .Int = try decoder.read_int(record_field.offset, i64) },
            .Float => return .{ .Float = @bitCast(try decoder.read_int(record_field.offset, u64)) },
            .String => |length| {
                return .{
                    .String = .{
                        .str = try decoder.read_slice(record_field.offset, length),
                    },
                };
            },
            .Blob => |length| {
                return .{
                    .Blob = .{
                        .str = try decoder.read_slice(record_field.offset, length),
                    },
                };
            },
            .Zero => return .{ .Int = 0 },
            .One => return .{ .Int = 1 },
        }
    }
};

const t = std.testing;

test "Cursor.field decodes integer and string fields from cached page" {
    var scratch: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);

    const payload = [_]u8{
        0x03, // header size
        0x01, // serial type: i8
        0x0F, // serial type: string(1)
        0x2A, // field 0 body byte
        0x68, // field 1 body byte
    };

    const header = try pg.parse_record_header(fba.allocator(), &payload);

    var cells = try std.ArrayList(pg.TableLeafCell).initCapacity(fba.allocator(), 1);
    try cells.append(fba.allocator(), .{
        .size = 2,
        .row_id = 1,
        .payload = &payload,
    });
    var cell_pointers = [_]u16{0};

    var pages = std.AutoHashMap(usize, pg.Page).init(fba.allocator());
    defer pages.deinit();

    try pages.put(1, .{
        .Leaf = .{
            .header = .{
                .page_type = .Leaf,
                .first_free_block = 0,
                .cell_count = 1,
                .cell_content_offset = 0,
                .fragmented_byts_count = 0,
            },
            .cell_pointers = cell_pointers[0..],
            .cells = cells,
        },
    });

    var pager: Pager = .{
        .f = undefined,
        .page_size = 4096,
        .pages = pages,
        .alloc = fba.allocator(),
    };

    var cursor = Cursor{
        .header = header,
        .pager = &pager,
        .page_index = 1,
        .page_cell = 0,
    };

    const v0 = (try cursor.field(0)).?;
    switch (v0) {
        .Int => |n| try t.expectEqual(@as(i64, 42), n),
        else => return error.UnexpectedValueType,
    }

    const v1 = (try cursor.field(1)).?;
    switch (v1) {
        .String => |s| try t.expectEqualSlices(u8, "h", s.str),
        else => return error.UnexpectedValueType,
    }
}
