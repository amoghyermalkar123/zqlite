const std = @import("std");
const Io = std.Io;
const pg = @import("page.zig");
const pgm = @import("pager_manager.zig");
const Allocator = std.mem.Allocator;
const cnst = @import("constants.zig");
const Scanner = @import("scanner.zig");

header: pg.DbHeader,
pager: pgm,

const Self = @This();

pub fn from_file(io: Io, alloc: Allocator, filename: []const u8) !Self {
    const f = try Io.Dir.openFileAbsolute(io, filename, .{ .mode = .read_write });

    var header_buffer: [cnst.HEADER_SIZE]u8 = undefined;
    var reader_buf: [256]u8 = undefined;
    var file_reader = f.reader(io, &reader_buf);
    try file_reader.interface.readSliceAll(&header_buffer);

    const pgmer = try pgm.new(alloc, io, f);

    return .{
        .pager = pgmer,
        .header = try pg.parse_header(&header_buffer),
    };
}

pub fn scanner(self: *Self, alloc: Allocator, page_num: usize) !Scanner {
    return try Scanner.new(&self.pager, alloc, page_num);
}
