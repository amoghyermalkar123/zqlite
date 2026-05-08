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
        self.scanner.page_stack.deinit(self.alloc);
        self.alloc.free(self.fields);
    }

    pub fn next_row(self: *Self) !?[]const OwnedValue {
        var rec = try self.scanner.next_record() orelse return null;
        defer rec.deinit();

        // Free previous row values and clear buffer
        for (self.row_buffer.items) |*ov| ov.deinit();
        self.row_buffer.clearRetainingCapacity();

        for (self.fields) |f| {
            const val = try rec.field(f) orelse return error.MissingRecordField;
            self.row_buffer.appendAssumeCapacity(try OwnedValue.from(self.alloc, val));
        }

        return self.row_buffer.items;
    }
};
