const std = @import("std");
const cnst = @import("constants.zig");

pub const DbHeader = struct {
    page_size: u32,
};

pub fn parse_header(buffer: []const u8) !DbHeader {
    if (buffer.len < cnst.HEADER_SIZE) {
        return error.InvalidHeaderSize;
    }

    if (!std.mem.startsWith(u8, buffer, cnst.HEADER_PREFIX)) {
        return error.InvalidHeaderPrefix;
    }

    const page_size_raw = std.mem.readInt(u16, buffer[cnst.HEADER_PAGE_SIZE_OFFSET..][0..cnst.HEADER_PAGE_SIZE_SIZE], .big);
    // page_size 1 is used to indicate max page size
    return DbHeader{
        .page_size = if (page_size_raw == 1) cnst.PAGE_MAX_SIZE else if (page_size_raw & (page_size_raw - 1) == 0 and page_size_raw != 0) page_size_raw else return error.InvalidPageSize,
    };
}
