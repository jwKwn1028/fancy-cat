//! Last pages, as "PAGE\tPATH" lines in $XDG_STATE_HOME/fancy-cat/positions.
const std = @import("std");

const max_entries = 1000;
const max_size = 4 * 1024 * 1024;

fn filePath(allocator: std.mem.Allocator) ?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |state| {
        defer allocator.free(state);
        return std.fmt.allocPrint(allocator, "{s}/fancy-cat/positions", .{state}) catch null;
    } else |_| {}
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.local/state/fancy-cat/positions", .{home}) catch null;
}

/// The 1-based page last shown for `document`, an absolute path.
pub fn load(allocator: std.mem.Allocator, document: []const u8) ?u16 {
    const path = filePath(allocator) orelse return null;
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, max_size) catch return null;
    defer allocator.free(content);

    var page: ?u16 = null;
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (!std.mem.eql(u8, line[tab + 1 ..], document)) continue;
        page = std.fmt.parseInt(u16, line[0..tab], 10) catch continue;
    }
    return page;
}

pub fn save(allocator: std.mem.Allocator, document: []const u8, page: u16) void {
    if (std.mem.indexOfAny(u8, document, "\t\n") != null) return;
    const path = filePath(allocator) orelse return;
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, max_size) catch null;
    defer if (content) |text| allocator.free(text);
    var kept = std.ArrayList([]const u8){};
    defer kept.deinit(allocator);
    if (content) |text| {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            if (std.mem.eql(u8, line[tab + 1 ..], document)) continue;
            kept.append(allocator, line) catch return;
        }
    }

    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();

    const start = if (kept.items.len >= max_entries) kept.items.len - (max_entries - 1) else 0;
    for (kept.items[start..]) |line| {
        file.writeAll(line) catch return;
        file.writeAll("\n") catch return;
    }
    var buf: [16]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{d}\t", .{page}) catch return;
    file.writeAll(prefix) catch return;
    file.writeAll(document) catch return;
    file.writeAll("\n") catch return;
}
