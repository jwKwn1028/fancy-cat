const std = @import("std");
const posix = std.posix;
const Spawn = @import("../utilities/Spawn.zig");

pub const limit = 8192;

pub const Command = union(enum) {
    page: struct { number: u16, text: ?[]const u8 },
    forward: struct { source: []const u8, line: u32, column: u32 },

    pub fn parse(data: []const u8) !Command {
        var parts = std.mem.splitScalar(u8, data, 0);
        const name = parts.next() orelse return error.InvalidCommand;
        const arg = parts.next() orelse return error.MissingArgument;
        const cmd: Command = if (std.mem.eql(u8, name, "goto-page")) blk: {
            const number = try std.fmt.parseInt(u16, arg, 10);
            if (number == 0) return error.InvalidPage;
            break :blk .{ .page = .{ .number = number, .text = parts.next() } };
        } else if (std.mem.eql(u8, name, "forward-search")) blk: {
            if (!std.fs.path.isAbsolute(arg)) return error.ExpectedAbsoluteSource;
            const line = try std.fmt.parseInt(u32, parts.next() orelse return error.MissingLine, 10);
            const column = try std.fmt.parseInt(u32, parts.next() orelse "1", 10);
            if (line == 0) return error.InvalidLine;
            break :blk .{ .forward = .{ .source = arg, .line = line, .column = column } };
        } else return error.UnknownCommand;
        if (parts.next() != null) return error.TooManyArguments;
        return cmd;
    }
};

fn socket() !posix.socket_t {
    return posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
}

pub fn listen(path: []const u8) !posix.socket_t {
    const addr = try std.net.Address.initUnix(path);
    const fd = try socket();
    errdefer posix.close(fd);
    try posix.bind(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

pub fn send(allocator: std.mem.Allocator, path: []const u8, args: []const [:0]u8) !void {
    const data = try std.mem.join(allocator, "\x00", args);
    defer allocator.free(data);
    if (data.len > limit) return error.CommandTooLong;
    _ = try Command.parse(data);
    const addr = try std.net.Address.initUnix(path);
    const fd = try socket();
    defer posix.close(fd);
    _ = try posix.sendto(fd, data, 0, &addr.any, addr.getOsSockLen());
}

fn lookup(a: std.mem.Allocator, args: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{ .allocator = a, .argv = args });
    defer a.free(result.stderr);
    errdefer a.free(result.stdout);
    if (result.term != .Exited or result.term.Exited != 0) return error.SyncTeXLookupFailed;
    return result.stdout;
}

fn field(output: []const u8, key: []const u8) ![]const u8 {
    var lines = std.mem.tokenizeAny(u8, output, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) return line[key.len..];
    }
    return error.NoSyncTeXMatch;
}

pub fn forward(a: std.mem.Allocator, pdf: []const u8, source: []const u8, line: u32, column: u32) !struct { page: u16, x: f32, y: f32 } {
    const position = try std.fmt.allocPrint(a, "{d}:{d}:{s}", .{ line, column, source });
    defer a.free(position);
    const out = try lookup(a, &.{ "synctex", "view", "-i", position, "-o", pdf });
    defer a.free(out);
    return .{
        .page = try std.fmt.parseInt(u16, try field(out, "Page:"), 10),
        .x = try std.fmt.parseFloat(f32, try field(out, "x:")),
        .y = try std.fmt.parseFloat(f32, try field(out, "y:")),
    };
}

pub fn inverse(a: std.mem.Allocator, program: []const u8, resolver: ?[]const u8, pdf: []const u8, page: u16, x: f32, y: f32, text: []const u8) !void {
    if (resolver) |helper| {
        const number = try std.fmt.allocPrint(a, "{d}", .{page});
        defer a.free(number);
        const px = try std.fmt.allocPrint(a, "{d:.3}", .{x});
        defer a.free(px);
        const py = try std.fmt.allocPrint(a, "{d:.3}", .{y});
        defer a.free(py);
        const result = try std.process.Child.run(.{ .allocator = a, .argv = &.{ helper, pdf, number, px, py, text } });
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        if (result.term != .Exited) return error.InverseSourceLookupFailed;
        switch (result.term.Exited) {
            0 => {},
            3 => return error.NoMatchingSourceText,
            4 => return error.AmbiguousSourceText,
            5 => return error.NoLiveSourceSession,
            6 => return error.NoSyncTeXSourceLocation,
            else => return error.InverseSourceLookupFailed,
        }
        const location = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (location.len == 0 or std.mem.indexOfAny(u8, location, "\r\n") != null) return error.InvalidSourceLocation;
        const column_at = std.mem.lastIndexOfScalar(u8, location, ':') orelse return error.InvalidSourceLocation;
        const line_at = std.mem.lastIndexOfScalar(u8, location[0..column_at], ':') orelse return error.InvalidSourceLocation;
        if (line_at == 0) return error.InvalidSourceLocation;
        const line_number = std.fmt.parseInt(u32, location[line_at + 1 .. column_at], 10) catch return error.InvalidSourceLocation;
        const column_number = std.fmt.parseInt(u32, location[column_at + 1 ..], 10) catch return error.InvalidSourceLocation;
        if (line_number == 0 or column_number == 0) return error.InvalidSourceLocation;
        try Spawn.detached(a, &.{ program, location }, pdf, page);
        return;
    }
    const pos = try std.fmt.allocPrint(a, "{d}:{d:.3}:{d:.3}:{s}", .{ page, x, y, pdf });
    defer a.free(pos);
    const out = try lookup(a, &.{ "synctex", "edit", "-o", pos });
    defer a.free(out);
    const source = try field(out, "Input:");
    const line = try std.fmt.parseInt(u32, try field(out, "Line:"), 10);
    const col = std.fmt.parseInt(i32, field(out, "Column:") catch "", 10) catch 1;
    const location = try std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ source, line, @max(1, col) });
    defer a.free(location);
    try Spawn.detached(a, &.{ program, location }, null, null);
}
