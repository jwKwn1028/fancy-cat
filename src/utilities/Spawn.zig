const std = @import("std");

pub fn detached(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    file: ?[]const u8,
    page: ?u16,
) !void {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    if (file) |f| try env.put("FILE", f);
    var page_buf: [8]u8 = undefined;
    if (page) |p| try env.put("PAGE", try std.fmt.bufPrint(&page_buf, "{d}", .{p}));

    // A new session keeps it off the viewer's terminal and alive after it exits.
    var full = try std.ArrayList([]const u8).initCapacity(allocator, argv.len + 2);
    defer full.deinit(allocator);
    full.appendSliceAssumeCapacity(&.{ "setsid", "-f" });
    full.appendSliceAssumeCapacity(argv);

    var child = std.process.Child.init(full.items, allocator);
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawnAndWait();
}
