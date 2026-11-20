const Self = @This();
const std = @import("std");

pub const Stamp = struct {
    inode: std.fs.File.INode,
    size: u64,
    mtime: i128,
    ctime: i128,

    pub fn read(path: []const u8) ?Stamp {
        return fromStat(std.fs.cwd().statFile(path) catch return null);
    }

    fn fromStat(stat: std.fs.File.Stat) ?Stamp {
        if (stat.kind != .file) return null;
        return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime, .ctime = stat.ctime };
    }
};

path: [:0]u8,
stamp: Stamp,
allocator: std.mem.Allocator,
refs: std.atomic.Value(u32) = .init(1),
linked: std.atomic.Value(bool) = .init(true),

/// A private copy for both MuPDF contexts, even if the source is truncated in place.
pub fn capture(allocator: std.mem.Allocator, source: []const u8, stopping: ?*const std.atomic.Value(bool)) !*Self {
    const stamp = Stamp.read(source) orelse return error.InvalidPdfFile;
    if (stamp.size == 0) return error.EmptyPdf;
    const input = try std.fs.cwd().openFile(source, .{});
    defer input.close();
    if (!std.meta.eql(Stamp.fromStat(try input.stat()), @as(?Stamp, stamp))) return error.PdfChanged;

    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    var name_buffer: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "fancy-cat-{s}.pdf", .{hex}) catch unreachable;
    const tmpdir = std.posix.getenv("TMPDIR") orelse "";
    const parent = if (tmpdir.len != 0) tmpdir else "/tmp";
    const path = try std.fs.path.joinZ(allocator, &.{ parent, name });
    errdefer allocator.free(path);
    const output = try std.fs.cwd().createFile(path, .{ .exclusive = true, .mode = 0o600 });
    defer output.close();
    errdefer std.fs.cwd().deleteFile(path) catch {};

    var offset: u64 = 0;
    while (offset < stamp.size) {
        if (stopping) |flag| if (flag.load(.acquire)) return error.Cancelled;
        const bytes = @min(1024 * 1024, stamp.size - offset);
        if (try input.copyRangeAll(offset, output, offset, bytes) != bytes) return error.PdfChanged;
        offset += bytes;
    }
    if (!std.meta.eql(Stamp.read(source), @as(?Stamp, stamp))) return error.PdfChanged;

    const snapshot = try allocator.create(Self);
    snapshot.* = .{ .path = path, .stamp = stamp, .allocator = allocator };
    return snapshot;
}

pub fn retain(self: *Self) void {
    _ = self.refs.fetchAdd(1, .monotonic);
}

/// The open documents keep the bytes; unlinking also cleans up after a crash.
pub fn unlink(self: *Self) void {
    if (!self.linked.swap(false, .acq_rel)) return;
    std.fs.cwd().deleteFile(self.path) catch self.linked.store(true, .release);
}

pub fn release(self: *Self) void {
    if (self.refs.fetchSub(1, .acq_rel) != 1) return;
    self.unlink();
    self.allocator.free(self.path);
    self.allocator.destroy(self);
}
