const std = @import("std");
const Io = std.Io;
const Page = @import("page.zig");
const parse_header = @import("page.zig").parse_header;
const cnst = @import("constants.zig");
const Allocator = std.mem.Allocator;

io: Io,
f: Io.File,
page_size: usize,
pages: std.AutoHashMap(usize, Page.Page),
alloc: Allocator,

const Self = @This();

pub fn new(alloc: Allocator, io: Io, f: Io.File) !Self {
    var header_buffer: [cnst.HEADER_SIZE]u8 = undefined;
    var reader_buf: [256]u8 = undefined;
    var file_reader = f.reader(io, &reader_buf);
    try file_reader.seekTo(0);
    try file_reader.interface.readSliceAll(&header_buffer);

    const header = try parse_header(&header_buffer);

    return .{
        .io = io,
        .f = f,
        .page_size = @intCast(header.page_size),
        .pages = .init(alloc),
        .alloc = alloc,
    };
}

pub fn read_page(self: *Self, n: usize) !*const Page.Page {
    // cache hit
    if (self.pages.contains(n)) {
        return self.pages.getPtr(n) orelse unreachable;
    }

    // cache miss
    const pg = try self.load_page(n);
    try self.pages.put(n, pg);

    return self.pages.getPtr(n) orelse unreachable;
}

fn load_page(self: *Self, n: usize) !Page.Page {
    if (n == 0) return error.InvalidPageNumber;

    const page_index = n - 1;
    const offset = page_index * self.page_size;

    const buffer = try self.alloc.alloc(u8, self.page_size);
    errdefer self.alloc.free(buffer);

    var reader_buf: [1024]u8 = undefined;
    var file_reader = self.f.reader(self.io, &reader_buf);
    try file_reader.seekTo(@intCast(offset));
    try file_reader.interface.readSliceAll(buffer);

    return Page.parse_page(self.alloc, buffer, n);
}

const t = std.testing;

test "load_page" {
    var scratch: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);

    var file = try std.fs.cwd().createFile("data.bin", .{
        .read = true,
    });

    defer file.close();
    defer std.fs.cwd().deleteFile("data.bin") catch {};

    var full_page = [_]u8{0} ** 4096;
    @memcpy(full_page[0..cnst.HEADER_PREFIX.len], cnst.HEADER_PREFIX);
    full_page[16] = 0x10;
    full_page[17] = 0x00; // page size = 4096
    full_page[100] = 0x0D; // page type: SQLite table leaf page
    full_page[101] = 0x00;
    full_page[102] = 0x00; // first free block
    full_page[103] = 0x00;
    full_page[104] = 0x01; // cell count = 1
    full_page[105] = 0x00;
    full_page[106] = 0x74; // cell content offset = 116
    full_page[107] = 0x00; // fragmented bytes count
    full_page[108] = 0x00;
    full_page[109] = 0x74; // one cell pointer -> absolute byte offset 116 in page 1

    full_page[116] = 0x05; // varint: payload size = 5
    full_page[117] = 0x01; // varint: row_id = 1
    full_page[118] = 0xAA;
    full_page[119] = 0xBB;
    full_page[120] = 0xCC;
    full_page[121] = 0xDD;
    full_page[122] = 0xEE; // payload

    try file.writeAll(&full_page);

    var pm = try Self.new(fba.allocator(), file);

    const page = try load_page(&pm, 1);
    try t.expectEqual(Page.PageType.Leaf, page.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 1), page.Leaf.header.cell_count);
    try t.expectEqual(@as(usize, 1), page.Leaf.cells.items.len);
    try t.expectEqual(@as(i64, 1), page.Leaf.cells.items[0].row_id);
    try t.expectEqual(@as(usize, 4096), pm.page_size);
}
