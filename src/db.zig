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

const Self = @This();

pub fn from_file(io: Io, alloc: Allocator, filename: []const u8) !Self {
    const f = try Io.Dir.openFileAbsolute(io, filename, .{ .mode = .read_write });

    var header_buffer: [cnst.HEADER_SIZE]u8 = undefined;
    var reader_buf: [256]u8 = undefined;
    var file_reader = f.reader(io, &reader_buf);
    try file_reader.interface.readSliceAll(&header_buffer);

    var pgmer = try pgm.new(alloc, io, f);

    return .{
        .pager = pgmer,
        .header = try pg.parse_header(&header_buffer),
        .tables_metadata = try Self.collect_table_metadata(&pgmer, alloc),
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

        const create = try sql.parse_create_statement(create_stmt.String.str, alloc);

        const first_page = try cur.field(3) orelse return error.MissingTableFirstPage;

        return TableMetadata{
            .name = create.statement.CreateTable.name,
            .cols = create.statement.CreateTable.cols,
            .first_page = @intCast(first_page.Int),
        };
    }
};

// cotrm
fn collect_table_metadata(pager: *pgm, alloc: Allocator) ![]TableMetadata {
    var metadata = try std.ArrayList(TableMetadata).initCapacity(alloc, 1);
    var scn = try Scanner.new(pager, alloc, 1);

    var next = try scn.next_record();
    while (next != null) : ({
        next = try scn.next_record();
    }) {
        try metadata.append(alloc, try TableMetadata.from_cursor(&next.?, alloc) orelse continue);
    }

    return metadata.toOwnedSlice(alloc);
}
