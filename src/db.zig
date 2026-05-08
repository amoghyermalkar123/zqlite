const std = @import("std");
const Io = std.Io;
const pg = @import("page.zig");
const pgm = @import("pager_manager.zig");
const Allocator = std.mem.Allocator;
const cnst = @import("constants.zig");
const Scanner = @import("scanner.zig");
const ast = @import("parser/ast/ast.zig");
const cursor = @import("cursor.zig");
const sql = @import("parser/parser.zig");

header: pg.DbHeader,
pager: pgm,
tables_metadata: []TableMetadata,
alloc: Allocator,

const Self = @This();

pub fn deinit(self: *Self) void {
    for (self.tables_metadata) |tm| freeTableMetadata(self.alloc, tm);
    self.alloc.free(self.tables_metadata);
    self.pager.deinit();
}

pub fn from_file(io: Io, alloc: Allocator, filename: []const u8) !Self {
    const f = try Io.Dir.cwd().openFile(io, filename, .{ .mode = .read_write });

    // This is reading the database header. Actual page layouts
    // start after the database header.
    // This contains the metadata about the entire database
    var header_buffer: [cnst.HEADER_SIZE]u8 = undefined;
    var reader_buf: [256]u8 = undefined;
    var file_reader = f.reader(io, &reader_buf);
    try file_reader.interface.readSliceAll(&header_buffer);

    var pgmer = try pgm.new(alloc, io, f);
    errdefer pgmer.deinit();

    const tms = try Self.collect_table_metadata(&pgmer, alloc);

    return .{
        .alloc = alloc,
        .pager = pgmer,
        .header = try pg.parse_header(&header_buffer),
        .tables_metadata = tms,
    };
}

pub fn scanner(self: *Self, alloc: Allocator, page_num: usize) !Scanner {
    return try Scanner.new(&self.pager, alloc, page_num);
}

pub const TableMetadata = struct {
    name: []const u8,
    cols: []ast.Create.ColumnDef,
    first_page: usize,

    fn from_cursor(cur: *cursor.Cursor, alloc: Allocator) !?TableMetadata {
        const tv = try cur.field(0) orelse return error.MissingTypeField;

        if (!std.mem.eql(u8, tv.String.str, "table")) return null;

        const create_stmt = try cur.field(4) orelse return error.MissingCreateStmt;

        var create = try sql.parse_create_statement(create_stmt.String.str, alloc);
        defer create.deinit();

        const crt_stmt = create.statement.CreateTable;
        const name = try alloc.dupe(u8, crt_stmt.name);
        errdefer alloc.free(name);

        const coldefs = try alloc.alloc(ast.Create.ColumnDef, crt_stmt.cols.len);
        errdefer alloc.free(coldefs);

        errdefer for (coldefs) |c| alloc.free(c.name);

        for (coldefs, crt_stmt.cols) |*l, r| {
            l.name = try alloc.dupe(u8, r.name);
            l.col_type = r.col_type;
        }

        const first_page = try cur.field(3) orelse return error.MissingTableFirstPage;

        return TableMetadata{
            .name = name,
            .cols = coldefs,
            .first_page = @intCast(first_page.Int),
        };
    }
};

fn freeTableMetadata(alloc: Allocator, tm: TableMetadata) void {
    alloc.free(tm.name);
    for (tm.cols) |c| alloc.free(c.name);
    alloc.free(tm.cols);
}

// cotrm
fn collect_table_metadata(pager: *pgm, alloc: Allocator) ![]TableMetadata {
    var metadata = try std.ArrayList(TableMetadata).initCapacity(alloc, 1);
    errdefer {
        for (metadata.items) |tm| freeTableMetadata(alloc, tm);
        metadata.deinit(alloc);
    }

    var scn = try Scanner.new(pager, alloc, 1);
    defer scn.page_stack.deinit(alloc);

    var next = try scn.next_record();
    while (next != null) : ({
        next = try scn.next_record();
    }) {
        defer next.?.deinit();
        try metadata.append(alloc, try TableMetadata.from_cursor(&next.?, alloc) orelse continue);
    }

    return metadata.toOwnedSlice(alloc);
}
