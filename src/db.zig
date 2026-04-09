const std = @import("std");
const pg = @import("page.zig");
const pgm = @import("pager_manager.zig");
const Allocator = std.mem.Allocator;
const cnst = @import("constants.zig");
const Scanner = @import("scanner.zig");

header: pg.DbHeader,
pager: pgm,

const Self = @This();

pub fn from_file(alloc: Allocator, filename: []const u8) !Self {
    const f = try std.fs.openFileAbsolute(filename, .{ .mode = .read_write });

    var header_buffer: [cnst.HEADER_SIZE]u8 = undefined;
    _ = try f.read(&header_buffer);

    const pgmer = try pgm.new(alloc, f);

    return .{
        .pager = pgmer,
        .header = try pg.parse_header(&header_buffer),
    };
}

pub fn scanner(self: *Self, alloc: Allocator, page_num: usize) !Scanner {
    return try Scanner.new(&self.pager, alloc, page_num);
}
