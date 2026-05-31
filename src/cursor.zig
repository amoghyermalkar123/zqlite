const std = @import("std");
const pg = @import("page.zig");
const RecordHeader = @import("page.zig").RecordHeader;
const Pager = @import("pager_manager.zig");
const Allocator = std.mem.Allocator;
const OverflowScanner = @import("overflow_scanner.zig");

// strings are borrowed from page payload
pub const Value = union(enum) {
    Null,
    String: struct { str: []const u8 },
    Blob: struct { str: []const u8 },
    Int: i64,
    Float: f64,
};

// Owns the underlying slices
pub const OwnedValue = struct {
    alloc: Allocator,
    value: Value,

    pub fn from(alloc: Allocator, v: Value) !OwnedValue {
        switch (v) {
            .String => |tk| {
                return OwnedValue{
                    .alloc = alloc,
                    .value = .{
                        .String = .{
                            .str = try alloc.dupe(u8, tk.str),
                        },
                    },
                };
            },
            .Blob => |tk| {
                return OwnedValue{
                    .alloc = alloc,
                    .value = .{
                        .Blob = .{
                            .str = try alloc.dupe(u8, tk.str),
                        },
                    },
                };
            },
            else => return OwnedValue{
                .alloc = alloc,
                .value = v,
            },
        }
    }

    pub fn deinit(self: *OwnedValue) void {
        switch (self.*.value) {
            .String => |tk| self.alloc.free(tk.str),
            .Blob => |tk| self.alloc.free(tk.str),
            else => return,
        }
    }
};

// Uniquely indentifies a single record
// it is a cursor over a cell in a leaf page
// a record is a cell basically
pub const Cursor = struct {
    record_header: RecordHeader,
    cell_payload: std.ArrayList(u8),
    pager: *Pager,
    next_overflow_page: ?usize,
    alloc: Allocator,

    const Self = @This();

    pub fn deinit(self: *Cursor) void {
        self.cell_payload.deinit(self.alloc);
        self.alloc.free(self.record_header.fields);
    }

    fn ensurePayloadLoaded(self: *Self, end_offset: usize) !void {
        if (end_offset <= self.cell_payload.items.len) return;

        const first_overflow = self.next_overflow_page orelse return error.RecordFieldOutOfBounds;

        const missing = end_offset - self.cell_payload.items.len;
        var overflow_scanner = OverflowScanner.new(self.alloc, self.pager);
        const ovd = try overflow_scanner.read(first_overflow, missing);
        defer self.alloc.free(ovd.data);

        self.next_overflow_page = ovd.next_overflow_page;
        try self.cell_payload.appendSlice(self.alloc, ovd.data);

        if (end_offset > self.cell_payload.items.len) return error.RecordFieldOutOfBounds;
    }

    // given `n` returns back the nth gield in the record (i.e. row) if found
    // else returns null
    pub fn field(self: *Self, n: usize) !?Value {
        if (n >= self.record_header.fields.len) return null;

        const record_field = self.record_header.fields[n];
        try self.ensurePayloadLoaded(record_field.end_offset());

        var decoder = pg.Decoder.initAt(self.cell_payload.items, record_field.offset);

        switch (record_field.field_type) {
            .Null => return .Null,
            .I8 => return .{ .Int = try decoder.readInt(i8) },
            .I16 => return .{ .Int = try decoder.readInt(i16) },
            .I24 => return .{ .Int = try decoder.readInt(i32) },
            .I32 => return .{ .Int = try decoder.readInt(i32) },
            .I48 => return .{ .Int = try decoder.readInt(i64) },
            .I64 => return .{ .Int = try decoder.readInt(i64) },
            .Float => return .{ .Float = @bitCast(try decoder.readInt(u64)) },
            .String => |length| {
                return .{
                    .String = .{
                        .str = try decoder.readSlice(length),
                    },
                };
            },
            .Blob => |length| {
                return .{
                    .Blob = .{
                        .str = try decoder.readSlice(length),
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
    var payload_buf = try std.ArrayList(u8).initCapacity(fba.allocator(), payload.len);
    try payload_buf.appendSlice(fba.allocator(), &payload);

    var cursor = Cursor{
        .record_header = header,
        .cell_payload = payload_buf,
        .pager = undefined,
        .next_overflow_page = null,
        .alloc = fba.allocator(),
    };
    defer cursor.deinit();

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
