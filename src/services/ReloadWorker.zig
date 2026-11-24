const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");
const PdfHandler = @import("../handlers/PdfHandler.zig");
const Snapshot = @import("PdfSnapshot.zig");

pub const Result = union(enum) {
    pdf: PdfHandler,
    failed,

    fn deinit(self: *Result) void {
        if (self.* == .pdf) self.pdf.deinit();
    }
};
const Pending = struct { due: u64, expires: u64 };

allocator: std.mem.Allocator,
path: []const u8,
config: *Config,
monitor: Config.FileMonitor,
initial: Snapshot.Stamp,
notify: *const fn (*anyopaque) void,
notify_context: *anyopaque,
delay: u64,
timeout: u64,
clock: std.time.Timer,
mutex: std.Thread.Mutex = .{},
wake: std.Thread.Condition = .{},
stopping: std.atomic.Value(bool) = .init(false),
stopped: std.atomic.Value(bool) = .init(false),
manual: bool = false,
notified: bool = false,
ready: ?Result = null,
thread: std.Thread = undefined,

pub fn seconds(value: f64) u64 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@min(value, std.time.s_per_day) * std.time.ns_per_s);
}

pub fn launch(self: *Self) !void {
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn request(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.manual = true;
    self.wake.signal();
}

/// Check for a new publication; skip unchanged files.
pub fn notifyChanged(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.notified = true;
    self.wake.signal();
}

pub fn take(self: *Self) ?Result {
    self.mutex.lock();
    defer self.mutex.unlock();
    defer self.ready = null;
    return self.ready;
}

pub fn beginStop(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.stopping.store(true, .release);
    self.wake.signal();
}

pub fn join(self: *Self) void {
    self.thread.join();
    if (self.take()) |value| {
        var result = value;
        result.deinit();
    }
}

fn publish(self: *Self, result: Result) void {
    if (self.take()) |old| {
        var stale = old;
        stale.deinit();
    }
    self.mutex.lock();
    self.ready = result;
    self.mutex.unlock();
    self.notify(self.notify_context);
}

fn load(self: *Self) !PdfHandler {
    const snapshot = try Snapshot.capture(self.allocator, self.path, &self.stopping);
    defer snapshot.release();
    var pdf = try PdfHandler.initWithStore(self.allocator, self.path, self.config, PdfHandler.c.FZ_STORE_UNLIMITED, snapshot);
    errdefer pdf.deinit();
    // A page count alone may succeed on a PDF with an incomplete page tree.
    const c = PdfHandler.c;
    const page = c.fz_load_page_z(pdf.ctx, pdf.doc, 0) orelse return error.InvalidPdfPage;
    defer c.fz_drop_page(pdf.ctx, page);
    var bounds: c.fz_rect = undefined;
    if (c.fz_bound_page_z(pdf.ctx, page, &bounds) == 0) return error.InvalidPdfPage;
    if (!std.meta.eql(Snapshot.Stamp.read(self.path), @as(?Snapshot.Stamp, snapshot.stamp))) return error.PdfChanged;
    return pdf;
}

fn run(self: *Self) void {
    defer self.stopped.store(true, .release);
    const interval = @max(seconds(self.monitor.latency), 10 * std.time.ns_per_ms);
    const retry = @max(self.delay, std.time.ns_per_ms);
    var seen: ?Snapshot.Stamp = self.initial;
    var pending: ?Pending = null;
    var next_check: u64 = if (self.monitor.enabled) 0 else std.math.maxInt(u64);
    while (!self.stopping.load(.acquire)) {
        const now = self.clock.read();
        self.mutex.lock();
        const manual = self.manual;
        self.manual = false;
        const notified = self.notified;
        self.notified = false;
        self.mutex.unlock();

        if (now >= next_check or notified) {
            const stamp = Snapshot.Stamp.read(self.path);
            if (!std.meta.eql(seen, stamp)) {
                // Load publications immediately; let other writes settle.
                const replaced = if (seen) |old| if (stamp) |new| old.inode != new.inode else false else false;
                seen = stamp;
                const due = if (replaced or notified) now else now + interval;
                const expires = if (pending) |old| old.expires else due + self.timeout;
                pending = .{ .due = due, .expires = expires };
            }
            if (self.monitor.enabled) next_check = now + interval;
        }

        if (manual) pending = .{ .due = now, .expires = now + self.timeout };

        if (pending) |job| {
            if (now >= job.due) {
                if (self.load()) |pdf| {
                    seen = pdf.snapshot.stamp;
                    pending = null;
                    self.publish(.{ .pdf = pdf });
                } else |_| {
                    if (self.stopping.load(.acquire)) break;
                    pending.?.due = @min(self.clock.read() + retry, job.expires);
                }
            }
            if (pending != null and self.clock.read() >= job.expires) {
                pending = null;
                self.publish(.failed);
            }
        }

        self.mutex.lock();
        if (!self.manual and !self.notified and !self.stopping.load(.acquire)) {
            const wake_at = if (pending) |job| @min(job.due, next_check) else next_check;
            if (wake_at == std.math.maxInt(u64)) {
                self.wake.wait(&self.mutex);
            } else {
                self.wake.timedWait(&self.mutex, wake_at -| self.clock.read()) catch {};
            }
        }
        self.mutex.unlock();
    }
}
