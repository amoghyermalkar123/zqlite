const std = @import("std");
const cnst = @import("../constants.zig");
const page = @import("../page.zig");
const encode_page = @import("../encode_page.zig");

const Allocator = std.mem.Allocator;
const t = std.testing;

pub const EncodedCell = struct {
    data: []u8,
};

pub const PageBuilder = struct {
    alloc: Allocator,
    page_type: page.PageType,
    db_header: page.DbHeader,
    cells: std.ArrayList(EncodedCell),
    rightmost_pointer: ?u32 = null,

    pub fn init(alloc: Allocator, page_type: page.PageType, db_header: page.DbHeader) !PageBuilder {
        return .{
            .alloc = alloc,
            .page_type = page_type,
            .db_header = db_header,
            .cells = try std.ArrayList(EncodedCell).initCapacity(alloc, 0),
        };
    }

    pub fn addLeafCell(self: *PageBuilder, rowid: u64, values: []const encode_page.RecordFieldEntry) !void {
        const record = try encode_page.encode_record(self.alloc, values);
        defer self.alloc.free(record);

        const cell = try encode_page.encode_table_leaf_cell(self.alloc, self.db_header, rowid, record, null);
        try self.cells.append(self.alloc, .{ .data = cell });
    }

    pub fn addInteriorCell(self: *PageBuilder, left_child_page: u32, key: u64) !void {
        const cell = try encode_page.encode_table_interior_cell(self.alloc, left_child_page, key);
        try self.cells.append(self.alloc, .{ .data = cell });
    }

    pub fn setRightmostPointer(self: *PageBuilder, rightmost_pointer: u32) void {
        self.rightmost_pointer = rightmost_pointer;
    }

    pub fn build(self: *PageBuilder) ![]u8 {
        const header_size: usize = switch (self.page_type) {
            .Leaf => cnst.PAGE_LEAF_HEADER_SIZE,
            .Interior => cnst.PAGE_INTERIOR_HEADER_SIZE,
        };
        const pointer_bytes = self.cells.items.len * 2;
        const page_size: usize = self.db_header.page_size;

        var total_cell_bytes: usize = 0;
        for (self.cells.items) |cell| total_cell_bytes += cell.data.len;

        if (header_size + pointer_bytes + total_cell_bytes > page_size) {
            return error.PageTooSmall;
        }

        const buf = try self.alloc.alloc(u8, page_size);
        errdefer self.alloc.free(buf);
        @memset(buf, 0);

        buf[0] = @intFromEnum(self.page_type);
        std.mem.writeInt(u16, buf[cnst.PAGE_FIRST_FREEBLOCK_OFFSET..][0..2], 0, .big);
        std.mem.writeInt(u16, buf[cnst.PAGE_CELL_COUNT_OFFSET..][0..2], @intCast(self.cells.items.len), .big);
        buf[cnst.PAGE_FRAGMENTED_BYTES_COUNT_OFFSET] = 0;

        switch (self.page_type) {
            .Leaf => {
                if (self.rightmost_pointer != null) return error.UnexpectedRightmostPointer;
            },
            .Interior => {
                const rightmost = self.rightmost_pointer orelse return error.MissingRightmostPointer;
                std.mem.writeInt(u32, buf[cnst.RIGHTMOST_POINTER_OFFSET..][0..4], rightmost, .big);
            },
        }

        var content_cursor: usize = page_size;
        for (self.cells.items, 0..) |cell, i| {
            content_cursor -= cell.data.len;
            @memcpy(buf[content_cursor .. content_cursor + cell.data.len], cell.data);

            const ptr_offset = header_size + i * 2;
            std.mem.writeInt(u16, buf[ptr_offset..][0..2], @intCast(content_cursor), .big);
        }

        const content_offset: u16 = if (content_cursor == cnst.PAGE_MAX_SIZE) 0 else @intCast(content_cursor);
        std.mem.writeInt(u16, buf[cnst.PAGE_CELL_CONTENT_OFFSET..][0..2], content_offset, .big);

        return buf;
    }

    pub fn buildPageFile(self: *PageBuilder, page_num: usize) ![]u8 {
        if (page_num == 0) return error.InvalidPageNumber;

        if (page_num == 1) {
            const page_offset = cnst.HEADER_SIZE;
            const header_size: usize = switch (self.page_type) {
                .Leaf => cnst.PAGE_LEAF_HEADER_SIZE,
                .Interior => cnst.PAGE_INTERIOR_HEADER_SIZE,
            };
            const pointer_bytes = self.cells.items.len * 2;
            const page_size: usize = self.db_header.page_size;

            var total_cell_bytes: usize = 0;
            for (self.cells.items) |cell| total_cell_bytes += cell.data.len;

            if (page_offset + header_size + pointer_bytes + total_cell_bytes > page_size) {
                return error.PageTooSmall;
            }

            const buf = try self.alloc.alloc(u8, page_size);
            errdefer self.alloc.free(buf);
            @memset(buf, 0);

            @memcpy(buf[0..cnst.HEADER_PREFIX.len], cnst.HEADER_PREFIX);
            const raw_page_size: u16 = if (self.db_header.page_size == cnst.PAGE_MAX_SIZE) 1 else @intCast(self.db_header.page_size);
            std.mem.writeInt(u16, buf[cnst.HEADER_PAGE_SIZE_OFFSET..][0..2], raw_page_size, .big);
            buf[cnst.HEADER_PAGE_RESERVED_SIZE_OFFSET] = self.db_header.page_reserved_size;

            buf[page_offset] = @intFromEnum(self.page_type);
            std.mem.writeInt(u16, buf[page_offset + cnst.PAGE_FIRST_FREEBLOCK_OFFSET ..][0..2], 0, .big);
            std.mem.writeInt(u16, buf[page_offset + cnst.PAGE_CELL_COUNT_OFFSET ..][0..2], @intCast(self.cells.items.len), .big);
            buf[page_offset + cnst.PAGE_FRAGMENTED_BYTES_COUNT_OFFSET] = 0;

            switch (self.page_type) {
                .Leaf => {
                    if (self.rightmost_pointer != null) return error.UnexpectedRightmostPointer;
                },
                .Interior => {
                    const rightmost = self.rightmost_pointer orelse return error.MissingRightmostPointer;
                    std.mem.writeInt(u32, buf[page_offset + cnst.RIGHTMOST_POINTER_OFFSET ..][0..4], rightmost, .big);
                },
            }

            var content_cursor: usize = page_size;
            for (self.cells.items, 0..) |cell, i| {
                content_cursor -= cell.data.len;
                @memcpy(buf[content_cursor .. content_cursor + cell.data.len], cell.data);

                const ptr_offset = page_offset + header_size + i * 2;
                std.mem.writeInt(u16, buf[ptr_offset..][0..2], @intCast(content_cursor), .big);
            }

            const content_offset: u16 = if (content_cursor == cnst.PAGE_MAX_SIZE) 0 else @intCast(content_cursor);
            std.mem.writeInt(u16, buf[page_offset + cnst.PAGE_CELL_CONTENT_OFFSET ..][0..2], content_offset, .big);

            return buf;
        }

        const page_size: usize = self.db_header.page_size;
        const raw_page = try self.build();
        defer self.alloc.free(raw_page);

        const file_len = page_num * page_size;
        const buf = try self.alloc.alloc(u8, file_len);
        errdefer self.alloc.free(buf);
        @memset(buf, 0);

        @memcpy(buf[0..cnst.HEADER_PREFIX.len], cnst.HEADER_PREFIX);
        const raw_page_size: u16 = if (self.db_header.page_size == cnst.PAGE_MAX_SIZE) 1 else @intCast(self.db_header.page_size);
        std.mem.writeInt(u16, buf[cnst.HEADER_PAGE_SIZE_OFFSET..][0..2], raw_page_size, .big);
        buf[cnst.HEADER_PAGE_RESERVED_SIZE_OFFSET] = self.db_header.page_reserved_size;

        const page_offset = (page_num - 1) * page_size;
        @memcpy(buf[page_offset .. page_offset + page_size], raw_page);

        return buf;
    }

    pub fn deinit(self: *PageBuilder) void {
        for (self.cells.items) |cell| {
            self.alloc.free(cell.data);
        }
        self.cells.deinit(self.alloc);
    }
};

test "PageBuilder builds leaf page with one cell" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(t.allocator, .Leaf, db_header);
    defer builder.deinit();

    try builder.addLeafCell(5, &.{.{ .String = "abc" }});
    const raw_page = try builder.build();
    defer t.allocator.free(raw_page);

    var parsed = try page.parse_page(t.allocator, raw_page, 2, &db_header);
    defer t.allocator.free(parsed.Leaf.cell_pointers);
    defer parsed.Leaf.cells.deinit(t.allocator);

    try t.expectEqual(page.PageType.Leaf, parsed.Leaf.header.page_type);
    try t.expectEqual(@as(u16, 1), parsed.Leaf.header.cell_count);
    try t.expectEqual(@as(i64, 5), parsed.Leaf.cells.items[0].row_id);
}

test "PageBuilder builds leaf page with multiple cells" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(t.allocator, .Leaf, db_header);
    defer builder.deinit();

    try builder.addLeafCell(1, &.{.{ .I8 = 7 }});
    try builder.addLeafCell(2, &.{.{ .String = "hello" }});

    const raw_page = try builder.build();
    defer t.allocator.free(raw_page);

    var parsed = try page.parse_page(t.allocator, raw_page, 2, &db_header);
    defer t.allocator.free(parsed.Leaf.cell_pointers);
    defer parsed.Leaf.cells.deinit(t.allocator);

    try t.expectEqual(@as(usize, 2), parsed.Leaf.cells.items.len);
    try t.expectEqual(@as(i64, 1), parsed.Leaf.cells.items[0].row_id);
    try t.expectEqual(@as(i64, 2), parsed.Leaf.cells.items[1].row_id);
    try t.expect(parsed.Leaf.cell_pointers[0] > parsed.Leaf.cell_pointers[1]);
}

test "PageBuilder builds interior page" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(t.allocator, .Interior, db_header);
    defer builder.deinit();

    builder.setRightmostPointer(9);
    try builder.addInteriorCell(2, 100);
    try builder.addInteriorCell(5, 300);

    const raw_page = try builder.build();
    defer t.allocator.free(raw_page);

    var parsed = try page.parse_page(t.allocator, raw_page, 2, &db_header);
    defer t.allocator.free(parsed.Interior.cell_pointers);
    defer parsed.Interior.cells.deinit(t.allocator);

    try t.expectEqual(page.PageType.Interior, parsed.Interior.header.page_type);
    try t.expectEqual(@as(?u32, 9), parsed.Interior.header.rightmost_pointer);
    try t.expectEqual(@as(usize, 2), parsed.Interior.cells.items.len);
    try t.expectEqual(@as(u32, 2), parsed.Interior.cells.items[0].left_child_page);
    try t.expectEqual(@as(i64, 100), parsed.Interior.cells.items[0].key);
    try t.expectEqual(@as(u32, 5), parsed.Interior.cells.items[1].left_child_page);
    try t.expectEqual(@as(i64, 300), parsed.Interior.cells.items[1].key);
}

test "PageBuilder roundtrip record payload" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(t.allocator, .Leaf, db_header);
    defer builder.deinit();

    try builder.addLeafCell(11, &.{
        .{ .I32 = 42 },
        .{ .String = "phase5" },
        .{ .Null = {} },
    });

    const raw_page = try builder.build();
    defer t.allocator.free(raw_page);

    var parsed = try page.parse_page(t.allocator, raw_page, 2, &db_header);
    defer t.allocator.free(parsed.Leaf.cell_pointers);
    defer parsed.Leaf.cells.deinit(t.allocator);

    const header = try page.parse_record_header(t.allocator, parsed.Leaf.cells.items[0].payload);
    defer t.allocator.free(header.fields);

    try t.expectEqual(@as(i64, 11), parsed.Leaf.cells.items[0].row_id);
    try t.expectEqual(@as(usize, 3), header.fields.len);
    try t.expectEqual(page.RecordFieldType.I32, header.fields[0].field_type);
    try t.expectEqual(@as(std.meta.Tag(page.RecordFieldType), .String), @as(std.meta.Tag(page.RecordFieldType), header.fields[1].field_type));
    try t.expectEqual(page.RecordFieldType.Null, header.fields[2].field_type);
}

test "PageBuilder builds page 1 file image" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(t.allocator, .Leaf, db_header);
    defer builder.deinit();

    try builder.addLeafCell(5, &.{.{ .String = "abc" }});
    const file_page = try builder.buildPageFile(1);
    defer t.allocator.free(file_page);

    try t.expectEqualSlices(u8, cnst.HEADER_PREFIX, file_page[0..cnst.HEADER_PREFIX.len]);

    var parsed = try page.parse_page(t.allocator, file_page, 1, &db_header);
    defer t.allocator.free(parsed.Leaf.cell_pointers);
    defer parsed.Leaf.cells.deinit(t.allocator);

    try t.expectEqual(page.PageType.Leaf, parsed.Leaf.header.page_type);
    try t.expectEqual(@as(i64, 5), parsed.Leaf.cells.items[0].row_id);
}

test "PageBuilder builds file image for page 2" {
    const db_header = page.DbHeader{
        .page_size = 512,
        .page_reserved_size = 0,
    };

    var builder = try PageBuilder.init(t.allocator, .Leaf, db_header);
    defer builder.deinit();

    try builder.addLeafCell(7, &.{.{ .String = "p2" }});
    const file_buf = try builder.buildPageFile(2);
    defer t.allocator.free(file_buf);

    try t.expectEqual(@as(usize, 1024), file_buf.len);
    try t.expectEqualSlices(u8, cnst.HEADER_PREFIX, file_buf[0..cnst.HEADER_PREFIX.len]);

    var parsed = try page.parse_page(t.allocator, file_buf[512..1024], 2, &db_header);
    defer t.allocator.free(parsed.Leaf.cell_pointers);
    defer parsed.Leaf.cells.deinit(t.allocator);

    try t.expectEqual(page.PageType.Leaf, parsed.Leaf.header.page_type);
    try t.expectEqual(@as(i64, 7), parsed.Leaf.cells.items[0].row_id);
}
