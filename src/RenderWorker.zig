const Self = @This();
const std = @import("std");
const fastb64z = @import("fastb64z");
const Config = @import("config/Config.zig");
const PdfHandler = @import("handlers/PdfHandler.zig");
const Snapshot = @import("services/PdfSnapshot.zig");
const c = PdfHandler.c;
const Graphics = @import("Graphics.zig");
const Transport = Graphics.Transport;
const zlib = @cImport(@cInclude("zlib.h"));

pub const Key = struct { unit: u16, row: u16, col: u16, tint: u64 = 0 };
pub const Mark = struct { rect: c.fz_irect, color: [4]u8 };
pub const Request = struct {
    key: Key,
    area: c.fz_irect,
    bytes: usize,
    visible: bool,
    mark_start: usize = 0,
    mark_count: usize = 0,
};
pub const capacity = 32;

pub const Settings = struct {
    generation: u64,
    document: u64,
    transport: Transport,
    snapshot: *Snapshot,
    zoom: f32,
    dual_page: bool,
    rotation: u16,
    general: Config.General,
};

pub const Image = struct {
    data: []u8,
    file: ?[]u8 = null,
    format: u8,
    width: usize,
    height: usize,
    compressed: bool,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        if (self.file) |path| disposeFile(allocator, path);
    }

    pub fn transmitFile(self: Image, batch: *Graphics.TmuxBatch, id: u32, cols: usize, rows: usize) !void {
        const encoder = fastb64z.standard.Encoder;
        var encoded: [std.fs.max_path_bytes * 2]u8 = undefined;
        const path = encoder.encode(&encoded, self.file.?);
        const w = try batch.beginCommand();
        try w.print("a=T,t=f,U=1,i={d},c={d},r={d},f={d},s={d},v={d},q=2{s};{s}", .{
            id, cols, rows, self.format, self.width, self.height, if (self.compressed) ",o=z" else "", path,
        });
        try batch.endCommand();
    }

    // Write a whole multipart image before allowing any other TTY output.
    pub fn transmit(self: Image, w: *std.Io.Writer, id: u32) !void {
        var start: usize = 0;
        while (true) {
            const end = @min(start + 4096, self.data.len);
            const more: u8 = if (end < self.data.len) 1 else 0;
            if (start == 0) {
                try w.print("\x1b_Ga=t,f={d},s={d},v={d},i={d},q=2,m={d}{s};", .{
                    self.format, self.width, self.height, id, more, if (self.compressed) ",o=z" else "",
                });
            } else {
                try w.print("\x1b_Gm={d};", .{more});
            }
            try w.writeAll(self.data[start..end]);
            try w.writeAll("\x1b\\");
            if (more == 0) break;
            start = end;
        }
    }
};

pub fn disposeFile(allocator: std.mem.Allocator, path: []u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    allocator.free(path);
}

fn writeTileFile(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "";
    const parent = if (std.fs.path.isAbsolute(tmpdir)) tmpdir else "/tmp";
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const name = std.fmt.bytesToHex(random, .lower);
    const path = try std.fmt.allocPrint(allocator, "{s}/tty-graphics-protocol-fancy-cat-{s}", .{ parent, name });
    errdefer allocator.free(path);
    const file = try std.fs.cwd().createFile(path, .{ .exclusive = true, .mode = 0o600 });
    defer file.close();
    errdefer std.fs.cwd().deleteFile(path) catch {};
    try file.writeAll(data);
    return path;
}

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    compressed: std.ArrayList(u8) = .empty,
    packed_rows: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Encoder) void {
        self.compressed.deinit(self.allocator);
        self.packed_rows.deinit(self.allocator);
    }

    fn pixmap(self: *Encoder, ctx: [*c]c.fz_context, pix: [*c]c.fz_pixmap, transport: Transport) !Image {
        const width: usize = @intCast(c.fz_pixmap_width(ctx, pix));
        const height: usize = @intCast(c.fz_pixmap_height(ctx, pix));
        const stride: usize = @intCast(c.fz_pixmap_stride(ctx, pix));
        const samples = c.fz_pixmap_samples(ctx, pix);
        const row_len = width * 3;
        const raw_len = row_len * height;
        if (stride == row_len) return self.encodePixels(24, width, height, samples[0..raw_len], transport);

        try self.packed_rows.resize(self.allocator, raw_len);
        for (0..height) |y| {
            @memcpy(self.packed_rows.items[y * row_len ..][0..row_len], samples[y * stride ..][0..row_len]);
        }
        return self.encodePixels(24, width, height, self.packed_rows.items, transport);
    }

    // Deflate flat text strips. Sampling avoids spending CPU on noisy scans.
    fn compress(self: *Encoder, pixels_data: []const u8, channels: usize) ?[]const u8 {
        if (pixels_data.len < 32 * 1024) return null;
        const sample_count = 128;
        const step = (pixels_data.len / channels - 2) / sample_count * channels;
        var flat: usize = 0;
        for (0..sample_count) |i| {
            const start = i * step;
            const next = start + channels;
            if (std.mem.eql(u8, pixels_data[start..next], pixels_data[next..][0..channels])) flat += 1;
        }
        if (flat < sample_count * 7 / 8) return null;

        self.compressed.resize(self.allocator, pixels_data.len / 2) catch return null;
        var size: c_ulong = @intCast(self.compressed.items.len);
        const result = zlib.compress2(self.compressed.items.ptr, &size, pixels_data.ptr, @intCast(pixels_data.len), zlib.Z_BEST_SPEED);
        return if (result == zlib.Z_OK) self.compressed.items[0..@intCast(size)] else null;
    }

    pub fn pixels(self: *Encoder, format: u8, width: usize, height: usize, data: []const u8) !Image {
        return self.encodePixels(format, width, height, data, .direct);
    }

    fn encodePixels(self: *Encoder, format: u8, width: usize, height: usize, data: []const u8, transport: Transport) !Image {
        const compressed = self.compress(data, format / 8);
        const payload = compressed orelse data;
        if (transport == .tmux) {
            return .{
                .data = &.{},
                .file = try writeTileFile(self.allocator, payload),
                .format = format,
                .width = width,
                .height = height,
                .compressed = compressed != null,
            };
        }
        const encoder = fastb64z.standard.Encoder;
        const encoded = try self.allocator.alloc(u8, encoder.calcSize(payload.len));
        _ = encoder.encode(encoded, payload);
        return .{ .data = encoded, .format = format, .width = width, .height = height, .compressed = compressed != null };
    }
};

const Pending = struct { request: Request, marks: []Mark };

const Job = struct {
    request: Request,
    generation: u64,
};
pub const Result = struct {
    job: Job,
    image: ?Image,
};

allocator: std.mem.Allocator,
path: []const u8,
config: Config,
mutex: std.Thread.Mutex = .{},
wake: std.Thread.Condition = .{},
settings: ?Settings = null,
pending: [capacity]Pending = undefined,
count: usize = 0,
active: ?Job = null,
completed: ?Result = null,
stopping: bool = false,
thread: std.Thread = undefined,

pub fn launch(self: *Self) !void {
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn stop(self: *Self) void {
    self.mutex.lock();
    self.stopping = true;
    self.wake.signal();
    self.mutex.unlock();
    self.thread.join();
    self.clearPending();
    if (self.settings) |settings| settings.snapshot.release();
    if (self.completed) |result| if (result.image) |image| image.deinit(self.allocator);
}

pub fn replace(self: *Self, settings: Settings, requests: []const Request, marks: []const Mark) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.settings == null or self.settings.?.snapshot != settings.snapshot) {
        settings.snapshot.retain();
        if (self.settings) |previous| previous.snapshot.release();
    }
    self.settings = settings;
    self.clearPending();
    for (requests) |request| {
        const job: Job = .{ .request = request, .generation = settings.generation };
        if (matches(self.active, job) or matches(if (self.completed) |result| result.job else null, job)) continue;
        self.pending[self.count] = .{
            .request = request,
            .marks = if (request.mark_count != 0) try self.allocator.dupe(Mark, marks[request.mark_start..][0..request.mark_count]) else &.{},
        };
        self.count += 1;
    }
    self.wake.signal();
}

fn matches(other: ?Job, job: Job) bool {
    const candidate = other orelse return false;
    return candidate.generation == job.generation and std.meta.eql(candidate.request.key, job.request.key);
}

pub fn take(self: *Self) ?Result {
    self.mutex.lock();
    defer self.mutex.unlock();
    const result = self.completed orelse return null;
    self.completed = null;
    self.clearPending();
    return result;
}

fn clearPending(self: *Self) void {
    for (self.pending[0..self.count]) |entry| self.allocator.free(entry.marks);
    self.count = 0;
}

/// When rendering, allow the worker to wake the view early, but check the
/// terminal's separate input queue again within one millisecond.
pub fn waitForWork(self: *Self) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.completed != null) return true;
    if (self.active == null and self.count == 0) return false;
    self.wake.timedWait(&self.mutex, std.time.ns_per_ms) catch {};
    return true;
}

fn run(self: *Self) void {
    var config = self.config;
    var pdf: ?PdfHandler = null;
    defer if (pdf) |*handler| handler.deinit();
    var document: ?u64 = null;
    var encoder: Encoder = .{ .allocator = self.allocator };
    defer encoder.deinit();

    while (true) {
        self.mutex.lock();
        while (!self.stopping and (self.count == 0 or self.completed != null)) self.wake.wait(&self.mutex);
        if (self.stopping) {
            self.mutex.unlock();
            return;
        }
        const settings = self.settings.?;
        const pending = self.pending[0];
        const job: Job = .{ .request = pending.request, .generation = settings.generation };
        self.count -= 1;
        std.mem.copyForwards(Pending, self.pending[0..self.count], self.pending[1 .. self.count + 1]);
        self.active = job;
        const new_document = document == null or document.? != settings.document;
        if (new_document) settings.snapshot.retain();
        self.mutex.unlock();

        config.general = settings.general;
        if (new_document) {
            defer settings.snapshot.release();
            if (pdf) |*handler| handler.deinit();
            pdf = PdfHandler.initWithStore(self.allocator, self.path, &config, 64 * 1024 * 1024, settings.snapshot) catch null;
            if (pdf != null) settings.snapshot.unlink();
            document = settings.document;
        }
        const image = if (pdf) |*handler| render(handler, &encoder, job.request, settings, pending.marks) else null;
        self.allocator.free(pending.marks);

        self.mutex.lock();
        self.active = null;
        self.completed = .{ .job = job, .image = image };
        self.wake.signal();
        self.mutex.unlock();
    }
}

fn render(pdf: *PdfHandler, encoder: *Encoder, request: Request, settings: Settings, marks: []const Mark) ?Image {
    pdf.dual_page = settings.dual_page;
    pdf.rotation = settings.rotation;
    const pix = pdf.renderTile(request.key.unit, settings.zoom, request.area) orelse return null;
    defer c.fz_drop_pixmap(pdf.ctx, pix);
    if (marks.len != 0) {
        const samples = c.fz_pixmap_samples(pdf.ctx, pix);
        const stride: usize = @intCast(c.fz_pixmap_stride(pdf.ctx, pix));
        for (marks) |mark| {
            const alpha: u16 = mark.color[3];
            const rect = mark.rect;
            for (@as(usize, @intCast(rect.y0))..@as(usize, @intCast(rect.y1))) |y| {
                for (@as(usize, @intCast(rect.x0))..@as(usize, @intCast(rect.x1))) |x| {
                    const pixel = samples[y * stride + x * 3 ..][0..3];
                    for (pixel, mark.color[0..3]) |*channel, color|
                        channel.* = @intCast((@as(u16, channel.*) * (255 - alpha) + @as(u16, color) * alpha) / 255);
                }
            }
        }
    }
    return encoder.pixmap(pdf.ctx, pix, settings.transport) catch null;
}
