const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("scanner.zig");
const OwnedValue = @import("cursor.zig").OwnedValue;

// cotrm
pub const SeqScan = struct {
    alloc: Allocator,
    fields: []const usize,
    scanner: Scanner,
    row_buffer: std.ArrayList(OwnedValue) = .empty,

    const Self = @This();

    pub fn new(alloc: Allocator, fields: []const usize, scanner: Scanner) !Self {
        return .{
            .alloc = alloc,
            .fields = fields,
            .scanner = scanner,
            .row_buffer = try .initCapacity(alloc, fields.len),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.row_buffer.items) |*ov| ov.deinit();
        self.row_buffer.deinit(self.alloc);
    }

    pub fn next_row(self: *Self) !?[]const OwnedValue {
        var rec = try self.scanner.next_record() orelse return null;
        defer rec.deinit(self.alloc);

        for (self.fields, 0..) |f, ix| {
            self.row_buffer.items[ix] = try OwnedValue.from(self.alloc, try rec.field(f) orelse return error.MissingRecordField);
        }

        return self.row_buffer.items;
    }
};
