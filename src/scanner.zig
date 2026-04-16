const std = @import("std");
const pg = @import("page.zig");
const RecordHeader = @import("page.zig").RecordHeader;
const Pager = @import("pager_manager.zig");
const Cursor = @import("cursor.zig").Cursor;
const Allocator = std.mem.Allocator;

const Self = @This();

pager: *Pager,
page: usize,
cell: usize = 0,
alloc: Allocator,

/// An Element is an item in a page. It can be a Page or a Cursor
pub const Element = struct {};

pub fn new(pager: *Pager, alloc: Allocator, page_num: usize) !Self {
    return .{ .pager = pager, .page = page_num, .alloc = alloc };
}

// TODO: should return Cursor optionally
pub fn next_record(self: *Self) !Cursor {
    const page = try self.pager.read_page(self.page);
    switch (page.*) {
        .Leaf => |pge| {
            const cell = pge.cells.items[self.cell];
            const header = try pg.parse_record_header(self.alloc, cell.payload);

            const record = Cursor{
                .pager = self.pager,
                .page_cell = self.cell,
                .header = header,
                .page_index = self.page,
            };

            self.cell += 1;

            return record;
        },
        .Interior => return error.UnsupportedPageType,
    }
}
