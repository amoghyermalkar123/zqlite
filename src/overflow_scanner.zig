const std = @import("std");
const Allocator = std.mem.Allocator;
const Pager = @import("pager_manager.zig");

pager: *Pager,
alloc: Allocator,

const Self = @This();

pub fn new(alloc: Allocator, pager: *Pager) Self {
    return .{
        .pager = pager,
        .alloc = alloc,
    };
}

pub fn read(self: *Self, first_page: usize, size: usize) !struct { next_overflow_page: ?usize, data: []u8 } {
    var buf = try std.ArrayList(u8).initCapacity(self.alloc, size);
    errdefer buf.deinit(self.alloc);

    var nextpe: ?usize = first_page;

    while (buf.items.len < size and nextpe != null) {
        const overflow = try self.pager.read_overflow(nextpe.?);
        nextpe = overflow.next;

        const remaining = size - buf.items.len;
        const chunk_len = @min(remaining, overflow.payload.len);
        try buf.appendSlice(self.alloc, overflow.payload[0..chunk_len]);
    }

    return .{
        .next_overflow_page = nextpe,
        .data = try buf.toOwnedSlice(self.alloc),
    };
}
