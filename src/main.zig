const std = @import("std");
const pg = @import("page.zig");
const pgm = @import("pager_manager.zig");
const cnst = @import("constants.zig");
const Scanner = @import("scanner.zig");
const db = @import("db.zig");
const sql = @import("parser/parser.zig");
const op = @import("operator.zig");
const engine = @import("planner.zig");
const insert = @import("insert.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("usage: zsqlite <db-file>\n", .{});
        return error.MissingDatabasePath;
    }

    var new_db = try db.from_file(io, alloc, args[1]);
    defer new_db.deinit();

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
            eval_query(dba, input, alloc) catch |err| {
                std.debug.print("error: {s}\n", .{@errorName(err)});
            };
            try stdout.flush();
        }
    }
}

fn display_tables(dba: *db) !void {
    for (dba.tables_metadata) |tb| {
        std.debug.print("table: {s}\n", .{tb.name});
    }
}

// TODO: Query evaluation should be it's own file/ module
fn eval_query(dba: *db, query: []const u8, alloc: Allocator) !void {
    var parsed_query = try sql.parse_statement(query, alloc, false);
    defer parsed_query.deinit();

    var en = engine.Planner.new(dba, alloc);
    var oper = try en.compile(parsed_query.statement);
    defer oper.deinit(alloc);

    switch (oper) {
        .Select => |*scan| {
            while (try scan.next_row()) |row| {
                for (row, 0..) |ov, i| {
                    if (i > 0) std.debug.print(" | ", .{});
                    switch (ov.value) {
                        .Null => std.debug.print("NULL", .{}),
                        .Int => |n| std.debug.print("{d}", .{n}),
                        .Float => |f| std.debug.print("{d}", .{f}),
                        .String => |s| std.debug.print("{s}", .{s.str}),
                        .Blob => |b| std.debug.print("<blob:{d}>", .{b.str.len}),
                    }
                }
                std.debug.print("\n", .{});
            }
        },
        .Insert => |*insop| {
            const n = try insert.execute_insert(alloc, dba, insop.*);
            std.debug.print("INSERT OK ({d} row{s})\n", .{ n, if (n == 1) "" else "s" });
        },
    }
}
