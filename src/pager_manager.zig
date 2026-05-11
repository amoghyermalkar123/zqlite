const std = @import("std");
const Io = std.Io;
const Page = @import("page.zig");
const parse_header = @import("page.zig").parse_header;
const cnst = @import("constants.zig");
const Allocator = std.mem.Allocator;

pub const CachedPage = union(enum) {
    page: Page.Page,
    overflow: Page.OverflowPage,
};

io: Io,
f: Io.File,
page_size: usize,
bufs: std.AutoHashMap(usize, []u8),
pages: std.AutoHashMap(usize, CachedPage),
alloc: Allocator,
header: Page.DbHeader,

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
        .header = header,
        .bufs = .init(alloc),
        .pages = .init(alloc),
        .alloc = alloc,
    };
}

pub fn deinit(self: *Self) void {
    var it = self.bufs.iterator();
    while (it.next()) |entry| self.alloc.free(entry.value_ptr.*);
    self.bufs.deinit();

    var pit = self.pages.iterator();
    while (pit.next()) |entry| {
        switch (entry.value_ptr.*) {
            .page => |*cached_page| switch (cached_page.*) {
                .Interior => |*pg| {
                    self.alloc.free(pg.cell_pointers);
                    pg.cells.deinit(self.alloc);
                },
                .Leaf => |*pg| {
                    self.alloc.free(pg.cell_pointers);
                    pg.cells.deinit(self.alloc);
                },
            },
            .overflow => |*ov| {
                self.alloc.free(ov.payload);
            },
        }
    }

    self.pages.deinit();
}

pub fn read_page(self: *Self, n: usize) !*const Page.Page {
    if (!self.pages.contains(n)) {
        const pg = try self.load_page(n);
        try self.pages.put(n, .{ .page = pg });
    }

    const cached = self.pages.getPtr(n) orelse unreachable;

    return switch (cached.*) {
        .page => |*pg| pg,
        .overflow => error.CachedPageTypeMismatch,
    };
}

pub fn read_overflow(self: *Self, n: usize) !*const Page.OverflowPage {
    if (!self.pages.contains(n)) {
        const pg = try self.load_overflow(n);
        try self.pages.put(n, .{ .overflow = pg });
    }

    const cached = self.pages.getPtr(n) orelse unreachable;

    return switch (cached.*) {
        .page => error.CachedPageTypeMismatch,
        .overflow => |*pg| pg,
    };
}

fn load_raw(self: *Self, n: usize) ![]u8 {
    if (self.bufs.contains(n)) return self.bufs.get(n) orelse unreachable;
    const buffer = try self.alloc.alloc(u8, self.header.page_size);
    try self.bufs.put(n, buffer);
    errdefer {
        self.alloc.free(buffer);
        _ = self.bufs.remove(n);
    }
    const offset = (n - 1) * self.page_size;

    var readbuf: [1024]u8 = undefined;
    var filereader = self.f.reader(self.io, &readbuf);
    try filereader.seekTo(@intCast(offset));
    try filereader.interface.readSliceAll(buffer);

    return buffer;
}

fn load_page(self: *Self, n: usize) !Page.Page {
    if (n == 0) return error.InvalidPageNumber;
    const rawbuf = try self.load_raw(n);
    return Page.parse_page(
        self.alloc,
        rawbuf[0..self.header.usable_page_size()],
        n,
        &self.header,
    );
}

fn load_overflow(self: *Self, n: usize) !Page.OverflowPage {
    if (n == 0) return error.InvalidPageNumber;
    const rawbuf = try self.load_raw(n);
    return Page.parse_overflow_page(self.alloc, rawbuf);
}

const t = std.testing;

test "load_page" {
    var scratch: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(t.io, "data.bin", .{
        .read = true,
    });
    defer file.close(t.io);

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

    var writer_buf: [256]u8 = undefined;
    var file_writer = file.writer(t.io, &writer_buf);
    try file_writer.interface.writeAll(&full_page);

    var pm = try Self.new(fba.allocator(), t.io, file);

    const page = try load_page(&pm, 1);
    try t.expectEqual(Page.PageType.Leaf, page.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 1), page.Leaf.header.cell_count);
    try t.expectEqual(@as(usize, 1), page.Leaf.cells.items.len);
    try t.expectEqual(@as(i64, 1), page.Leaf.cells.items[0].row_id);
    try t.expectEqual(@as(usize, 4096), pm.page_size);
}
