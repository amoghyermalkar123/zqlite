//! Scanner is an iterator of elements
//! it incrementally yields the next page or the next cell
//! relies on positioned page and cursor implementation
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
    // read the current page
    const pe = try self.current_page();

    // check if we have next page
    const nextpe = try pe.next_page();

    // if we do, return the page
    if (nextpe != null) return ScannedElement{ .Page = nextpe.? };

    // if we dont have next page we go to the next cell
    const cell = try pe.next_cell() orelse return null;

    switch (cell) {
        // if current page is interior return the child page in the next depth that this cell points to
        .Interior => |c| {
            return ScannedElement{
                .Page = c.left_child_page,
            };
        },
        // if current page is leaf, return the currently read leaf cell
        .Leaf => |c| {
            const header = try pg.parse_record_header(self.alloc, c.payload);
            var payload = try std.ArrayList(u8).initCapacity(self.alloc, c.payload.len);
            errdefer payload.deinit(self.alloc);
            try payload.appendSlice(self.alloc, c.payload);

            return ScannedElement{
                .Cursor = .{
                    .alloc = self.alloc,
                    .cell_payload = payload,
                    .record_header = header,
                    .pager = self.pager,
                    .next_overflow_page = c.first_overflow,
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
