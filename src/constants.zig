pub const HEADER_SIZE: usize = 100;

pub const HEADER_PREFIX: []const u8 = "SQLite format 3\x00";
pub const HEADER_PAGE_SIZE_OFFSET: usize = 16;
pub const HEADER_PAGE_SIZE_SIZE: usize = @sizeOf(u16);

pub const PAGE_MAX_SIZE: u32 = 65536;
pub const PAGE_LEAF_HEADER_SIZE: usize = 8;

pub const PAGE_FIRST_FREEBLOCK_OFFSET: usize = 1;
pub const PAGE_CELL_COUNT_OFFSET: usize = 3;
pub const PAGE_CELL_CONTENT_OFFSET: usize = 5;
pub const PAGE_FRAGMENTED_BYTES_COUNT_OFFSET: usize = 7;
