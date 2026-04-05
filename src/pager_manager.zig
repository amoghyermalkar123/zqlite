const std = @import("std");
const Page = @import("page.zig");
const Allocator = std.mem.Allocator;

f: std.fs.File,
page_size: usize,
pages: std.AutoHashMap(usize, Page.Page),

const Self = @This();

pub fn new(alloc: Allocator, f: std.fs.File, page_size: usize) !Self {
    return .{
        .f = f,
        .page_size = page_size,
        .pages = .init(alloc),
    };
}

pub fn read_page(self: *Self, n: usize) !*const Page {
    if (self.pages.contains(n)) {
        return self.pages.get(n) orelse unreachable;
    }
}

fn load_page(self: *Self, alloc: Allocator, n: usize) !Page.Page {
    if (n == 0) return error.InvalidPageNumber;

    const page_index = n - 1;
    const offset = page_index * self.page_size;

    try self.f.seekTo(@intCast(offset));

    const buffer = try alloc.alloc(u8, self.page_size);
    errdefer alloc.free(buffer);

    const nread = try self.f.readAll(buffer);
    if (nread != buffer.len) return error.EndOfStream;

    return Page.parse_page(alloc, buffer, n);
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
    full_page[0] = 0x00; // page type: Leaf
    full_page[1] = 0x00;
    full_page[2] = 0x00; // first free block
    full_page[3] = 0x00;
    full_page[4] = 0x01; // cell count = 1
    full_page[5] = 0x00;
    full_page[6] = 0x74; // cell content offset = 116
    full_page[7] = 0x00; // fragmented bytes count
    full_page[8] = 0x00;
    full_page[9] = 0x74; // one cell pointer -> byte offset 116

    full_page[116] = 0x05; // varint: payload size = 5
    full_page[117] = 0x01; // varint: row_id = 1
    full_page[118] = 0xAA;
    full_page[119] = 0xBB;
    full_page[120] = 0xCC;
    full_page[121] = 0xDD;
    full_page[122] = 0xEE; // payload

    try file.writeAll(&full_page);

    var pm = Self{
        .page_size = 4096,
        .pages = .init(fba.allocator()),
        .f = file,
    };

    const page = try load_page(&pm, fba.allocator(), 1);
    try t.expectEqual(Page.PageType.Leaf, page.Leaf.header.page_type);
}
