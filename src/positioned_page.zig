const std = @import("std");
const Io = std.Io;
const pg = @import("page.zig");
const Page = pg.Page;
const pm = @import("pager_manager.zig");

page: usize,
cell: usize,
page_manager: *pm,

const Self = @This();

pub const Cell = union(enum) {
    Leaf: pg.TableLeafCell,
    Interior: pg.TableInteriorCell,
};

// returns either an internal cell or a leaf cell
pub fn next_cell(self: *Self) !?Cell {
    const page = try self.page_manager.read_page(self.page);

    switch (page.*) {
        .Leaf => |leaf| {
            if (self.cell >= leaf.cells.items.len) return null;
            // TODO: what if the underlying array changes, this corrupts the logic
            // what's the best way to achieve this?
            const cell = leaf.cells.items[self.cell];
            self.cell += 1;
            return .{ .Leaf = cell };
        },

        .Interior => |interior| {
            if (self.cell >= interior.cells.items.len) return null;
            const cell = interior.cells.items[self.cell];
            self.cell += 1;
            return .{ .Interior = cell };
        },
    }
}

pub fn next_page(self: *Self) !?u32 {
    const page = try self.page_manager.read_page(self.page);

    switch (page.*) {
        .Leaf => return null,
        .Interior => |interior| {
            if (self.cell == interior.cells.items.len) {
                self.cell += 1;
                return interior.header.rightmost_pointer;
            }

            return null;
        },
    }
}
