const std = @import("std");
const Io = std.Io;
const pg = @import("page.zig");
const pgm = @import("pager_manager.zig");
const Allocator = std.mem.Allocator;
const cnst = @import("constants.zig");
const Scanner = @import("scanner.zig");
const db = @import("db.zig");
const sql = @import("parser/parser.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("usage: zsqlite <db-file>\n", .{});
        return error.MissingDatabasePath;
    }

    var new_db = try db.from_file(io, alloc, args[1]);
    try cli(io, alloc, &new_db);
}

fn cli(io: Io, alloc: Allocator, dba: *db) !void {
    var stdin_buf: [1024]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;

    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    while (true) {
        try stdout.print("zsqlite> ", .{});
        try stdout.flush();

        const line_opt = try stdin.takeDelimiter('\n');
        const line = line_opt orelse break;

        const input = std.mem.trim(u8, line, " \r\n\t");

        if (input.len == 0) continue;

        if (std.mem.eql(u8, input, ".exit")) {
            break;
        } else if (std.mem.eql(u8, input, ".tables")) {
            try display_tables(dba);
        } else {
            var result = try sql.parse_statement(input, alloc, true);
            defer result.deinit();
            std.debug.print("sql: {any}\n", .{result.statement});
            try stdout.flush();
        }
    }
}

fn display_tables(dba: *db) !void {
    for (dba.tables_metadata) |tb| {
        std.debug.print("field: {s}\n", .{tb.name});
    }
}
