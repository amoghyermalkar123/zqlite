const std = @import("std");
const pg = @import("page.zig");
const RecordHeader = @import("page.zig").RecordHeader;
const Pager = @import("pager_manager.zig");
const Cursor = @import("cursor.zig").Cursor;
const Allocator = std.mem.Allocator;
const PositionedPage = @import("positioned_page.zig");

const Self = @This();

pager: *Pager,
page: usize,
cell: usize = 0,
page_stack: std.ArrayList(PositionedPage) = .empty,
alloc: Allocator,
initial_page: usize,

pub fn new(pager: *Pager, alloc: Allocator, page_num: usize) !Self {
    return .{
        .pager = pager,
        .page = page_num,
        .alloc = alloc,
        .initial_page = page_num,
        .page_stack = try .initCapacity(alloc, 3),
    };
}

// Caller owns the Cursor
pub fn next_record(self: *Self) !?Cursor {
    while (true) {
        switch (try self.next_element() orelse {
            if (self.page_stack.items.len > 1) {
                _ = self.page_stack.pop();
                continue;
            } else return null;
        }) {
            .Cursor => |c| return c,
            .Page => |page_num| {
                try self.page_stack.append(
                    self.alloc,
                    PositionedPage{
                        .cell = 0,
                        .page = page_num,
                        .page_manager = self.pager,
                    },
                );
            },
        }
    }
}

// ScannedElement returns either a page or a cursor,
// the items within are owned by the caller
pub const ScannedElement = union(enum) {
    Page: u32,
    Cursor: Cursor,
};

fn next_element(self: *Self) !?ScannedElement {
    const pe = try self.current_page();

    const nextpe = try pe.next_page();

    if (nextpe != null) return ScannedElement{ .Page = nextpe.? };

    const cell = try pe.next_cell() orelse return null;

    switch (cell) {
        .Interior => |c| {
            return ScannedElement{
                .Page = c.left_child_page,
            };
        },

        .Leaf => |c| {
            const header = try pg.parse_record_header(self.alloc, c.payload);

            return ScannedElement{
                .Cursor = .{
                    .payload = try self.alloc.dupe(u8, c.payload),
                    .header = header,
                },
            };
        },
    }
}

fn current_page(self: *Self) !*PositionedPage {
    if (self.page_stack.items.len == 0) {
        try self.page_stack.append(self.alloc, .{
            .page = self.initial_page,
            .cell = 0,
            .page_manager = self.pager,
        });
    }

    return &self.page_stack.items[self.page_stack.items.len - 1];
}

const t = std.testing;
