const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Page = @import("page.zig");
const cnst = @import("constants.zig");
const parse_header = Page.parse_header;

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
const PageBuilder = @import("testing/page_builder.zig").PageBuilder;

test "load_page" {
    var scratch: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(t.io, "data.bin", .{
        .read = true,
    });
    defer file.close(t.io);

    const db_header = Page.DbHeader{
        .page_size = 4096,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(fba.allocator(), .Leaf, db_header);
    defer builder.deinit();
    try builder.addLeafCell(1, &.{.{ .Blob = &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE } }});
    const full_page = try builder.buildPageFile(1);
    defer fba.allocator().free(full_page);

    var writer_buf: [256]u8 = undefined;
    var file_writer = file.writer(t.io, &writer_buf);
    try file_writer.interface.writeAll(full_page);

    var pm = try Self.new(fba.allocator(), t.io, file);
    defer pm.deinit();

    const page = try load_page(&pm, 1);
    try t.expectEqual(Page.PageType.Leaf, page.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 1), page.Leaf.header.cell_count);
    try t.expectEqual(@as(usize, 1), page.Leaf.cells.items.len);
    try t.expectEqual(@as(i64, 1), page.Leaf.cells.items[0].row_id);
    try t.expectEqual(@as(usize, 4096), pm.page_size);
}

test "load_page from page 2 file image" {
    var scratch: [49152]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(t.io, "data-page-2.bin", .{
        .read = true,
    });
    defer file.close(t.io);

    const db_header = Page.DbHeader{
        .page_size = 4096,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(fba.allocator(), .Leaf, db_header);
    defer builder.deinit();
    try builder.addLeafCell(7, &.{.{ .String = "page2" }});
    const file_image = try builder.buildPageFile(2);
    defer fba.allocator().free(file_image);

    var writer_buf: [256]u8 = undefined;
    var file_writer = file.writer(t.io, &writer_buf);
    try file_writer.interface.writeAll(file_image);

    var pm = try Self.new(fba.allocator(), t.io, file);
    defer pm.deinit();

    const loaded = try load_page(&pm, 2);
    try t.expectEqual(Page.PageType.Leaf, loaded.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 1), loaded.Leaf.header.cell_count);
    try t.expectEqual(@as(usize, 1), loaded.Leaf.cells.items.len);
    try t.expectEqual(@as(i64, 7), loaded.Leaf.cells.items[0].row_id);
}
