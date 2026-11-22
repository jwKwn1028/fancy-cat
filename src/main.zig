const std = @import("std");
const Context = @import("Context.zig").Context;
const Tmux = @import("Tmux.zig");

// Types for build.zig.zon
// For now metadata is only used in main.zig, but can move it to types.zig if needed eleswhere
// This wont be necessary once https://github.com/ziglang/zig/pull/22907 is merged

const PackageName = enum { fancy_cat };

const DependencyType = struct {
    url: []const u8,
    hash: []const u8,
};

const DependenciesType = struct {
    vaxis: DependencyType,
    fastb64z: DependencyType,
};

const MetadataType = struct {
    name: PackageName,
    fingerprint: u64,
    version: []const u8,
    minimum_zig_version: []const u8,
    dependencies: DependenciesType,
    paths: []const []const u8,
};

const metadata: MetadataType = @import("metadata");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v"))) {
        try stdout.print("fancy-cat version {s}\n", .{metadata.version});
        try stdout.flush();
        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--tmux-supported")) {
        const client = Tmux.client(std.heap.page_allocator);
        if (client == null or !client.?.inline_graphics) std.process.exit(1);
        return;
    }

    const preview = @import("services/Preview.zig");
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--remote")) {
        if (args.len < 5) return error.MissingRemoteArguments;
        return preview.send(std.heap.page_allocator, args[2], args[3..]);
    }

    var first: usize = 1;
    var socket_path: ?[]const u8 = null;
    var inverse: ?[]const u8 = null;
    while (first + 1 < args.len) : (first += 2) {
        if (std.mem.eql(u8, args[first], "--listen")) {
            socket_path = args[first + 1];
        } else if (std.mem.eql(u8, args[first], "--inverse-search")) {
            inverse = args[first + 1];
        } else break;
    }
    const positional = args[first..];
    if (positional.len == 0 or positional.len > 2 or (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try stderr.writeAll("Usage: fancy-cat [--listen SOCKET] [--inverse-search PROGRAM] PDF [PAGE]\n       fancy-cat --remote SOCKET goto-page PAGE [TEXT]\n       fancy-cat --remote SOCKET forward-search ABSOLUTE_SOURCE LINE [COLUMN]\n");
        try stderr.flush();
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    const initial_page = if (positional.len == 2) try std.fmt.parseInt(u16, positional[1], 10) else null;
    var app = try Context.init(allocator, positional[0], initial_page);
    defer app.deinit();

    app.inverse_program = inverse;
    app.socket_path = socket_path;
    try app.run();
}
