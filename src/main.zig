const std = @import("std");
const pg = @import("page.zig");
const pgm = @import("pager_manager.zig");
const Allocator = std.mem.Allocator;
const cnst = @import("constants.zig");
const Scanner = @import("scanner.zig");
const db = @import("db.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("usage: zsqlite <db-file>\n", .{});
        return error.MissingDatabasePath;
    }

    var new_db = try db.from_file(alloc, args[1]);
    try cli(alloc, &new_db);
}

fn cli(alloc: Allocator, dba: *db) !void {
    var stdin_buf: [1024]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;

    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
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
            try display_tables(alloc, dba);
        } else {
            try stdout.print("unknown command: {s}\n", .{input});
            try stdout.flush();
        }
    }
}

fn display_tables(alloc: Allocator, dba: *db) !void {
    var scan = try dba.scanner(alloc, 1);
    while (true) {
        var rec = scan.next_record() catch {
            std.debug.print("end of scanner, exiting\n", .{});
            break;
        };

        const tv = try rec.field(1) orelse {
            std.debug.print("missing name field", .{});
            break;
        };

        std.debug.print("field: {any}", .{tv});
    }
}
