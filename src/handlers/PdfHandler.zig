const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");
const types = @import("./types.zig");
const Snapshot = @import("../services/PdfSnapshot.zig");

pub const c = @cImport({
    @cInclude("fitz-z.h");
    @cInclude("mupdf/fitz.h");
    @cInclude("mupdf/pdf.h");
});

allocator: std.mem.Allocator,
ctx: [*c]c.fz_context,
doc: [*c]c.fz_document,
total_pages: u16,
path: []const u8,
snapshot: *Snapshot,
dual_page: bool = false,
// Degrees clockwise: 0, 90, 180 or 270.
rotation: u16 = 0,
picture_cache: [2]?PageRects = .{ null, null },
// The active search, if any: its text, direction and the hit shown last.
search_needle: ?[:0]u8 = null,
search_backward: bool = false,
search_hit: ?Hit = null,
hit_cache: [8]?PageHits = @splat(null),
hit_next: usize = 0,
search_revision: u64 = 0,
marks_cache: [max_marks]?PageMarks = [_]?PageMarks{null} ** max_marks,
marks_next: u8 = 0,
lists: [max_lists]?PageList = [_]?PageList{null} ** max_lists,
lists_next: u8 = 0,
text_pages: [16]?TextPage = @splat(null),
text_clock: u64 = 0,
selection_revision: u64 = 0,
selection_page: ?u16 = null,
selection_quads: std.ArrayList(c.fz_quad) = .empty,
config: *Config,

pub fn init(
    allocator: std.mem.Allocator,
    path: []const u8,
    config: *Config,
) !Self {
    const snapshot = try Snapshot.capture(allocator, path, null);
    defer snapshot.release();
    return initWithStore(allocator, path, config, c.FZ_STORE_UNLIMITED, snapshot);
}

pub fn initWithStore(allocator: std.mem.Allocator, path: []const u8, config: *Config, store: usize, snapshot: *Snapshot) !Self {
    const ctx = c.fz_new_context(null, null, store) orelse {
        std.debug.print("Failed to create mupdf context\n", .{});
        return types.DocumentError.FailedToCreateContext;
    };
    errdefer c.fz_drop_context(ctx);

    c.fz_set_error_callback(ctx, null, null);
    c.fz_set_warning_callback(ctx, null, null);
    if (c.fz_register_document_handlers_z(ctx) == 0) return types.DocumentError.FailedToCreateContext;

    const doc = c.fz_open_document_z(ctx, snapshot.path.ptr) orelse return types.DocumentError.FailedToOpenDocument;
    errdefer c.fz_drop_document(ctx, doc);

    const count = c.fz_count_pages_z(ctx, doc);
    if (count <= 0 or count > std.math.maxInt(u16)) return types.DocumentError.InvalidPageNumber;
    const total_pages: u16 = @intCast(count);
    snapshot.retain();

    return .{
        .allocator = allocator,
        .ctx = ctx,
        .doc = doc,
        .total_pages = total_pages,
        .path = path,
        .snapshot = snapshot,
        .config = config,
    };
}

pub fn deinit(self: *Self) void {
    self.clearSearch();
    self.dropLists();
    self.dropText();
    self.selection_quads.deinit(self.allocator);
    c.fz_drop_document(self.ctx, self.doc);
    c.fz_drop_context(self.ctx);
    self.snapshot.release();
}

pub fn toggleColor(self: *Self) void {
    self.config.general.colorize = !self.config.general.colorize;
}

// Space between the two pages of a spread, in PDF points.
const page_gap = 6.0;

pub fn toggleDualPage(self: *Self) void {
    self.dual_page = !self.dual_page;
}

// The pages in each column of the spread holding `page`. With
// first_page_column 2, zathura's default, page 1 sits alone on the right.
pub fn spread(self: *Self, page: u16) [2]?u16 {
    const first: u32 = if (self.config.general.first_page_column == 1) 0 else 1;
    const slot = @as(u32, page) + first;
    const left_slot = slot - slot % 2;
    const left: ?u16 = if (left_slot >= first) @as(u16, @intCast(left_slot - first)) else null;
    const right_index = left_slot + 1 - first;
    const right: ?u16 = if (right_index < self.total_pages) @as(u16, @intCast(right_index)) else null;
    return .{ left, right };
}

pub fn rotateClockwise(self: *Self) void {
    self.rotation = (self.rotation + 90) % 360;
}

// The view scrolls through units: single pages, or spreads in two-page mode.

/// The first page of the unit holding `page`.
pub fn unitOf(self: *Self, page: u16) u16 {
    if (!self.dual_page) return page;
    const columns = self.spread(page);
    return columns[0] orelse columns[1].?;
}

pub fn nextUnit(self: *Self, unit: u16) ?u16 {
    var last = unit;
    if (self.dual_page) {
        const columns = self.spread(unit);
        last = columns[1] orelse columns[0].?;
    }
    if (@as(u32, last) + 1 >= self.total_pages) return null;
    return self.unitOf(last + 1);
}

pub fn prevUnit(self: *Self, unit: u16) ?u16 {
    var first = unit;
    if (self.dual_page) {
        const columns = self.spread(unit);
        first = columns[0] orelse columns[1].?;
    }
    if (first == 0) return null;
    return self.unitOf(first - 1);
}

pub fn lastUnit(self: *Self) u16 {
    return self.unitOf(self.total_pages - 1);
}

/// Renders one base strip. The worker owns the pixmap and its MuPDF context.
pub fn renderTile(self: *Self, unit: u16, zoom: f32, area: c.fz_irect) ?[*c]c.fz_pixmap {
    if (unit >= self.total_pages) return null;
    const loaded = self.loadSpread(unit) orelse return null;
    defer loaded.deinit(self.ctx);
    const layout = self.computeLayout(loaded) orelse return null;

    const bbox = c.fz_make_irect(0, 0, area.x1 - area.x0, area.y1 - area.y0);
    var pix: [*c]c.fz_pixmap = null;
    const dev = c.fz_new_tile_device_z(self.ctx, bbox, &pix) orelse return null;
    var keep_pixmap = false;
    defer if (!keep_pixmap) c.fz_drop_pixmap(self.ctx, pix);
    defer c.fz_drop_device(self.ctx, dev);

    // From layout points to this tile's pixels.
    const ctm = c.fz_concat(
        c.fz_scale(zoom, zoom),
        c.fz_translate(-@as(f32, @floatFromInt(area.x0)), -@as(f32, @floatFromInt(area.y0))),
    );
    const scissor = c.fz_rect_from_irect(bbox);
    for (loaded.pages, layout.columns) |page, column| {
        const col = column orelse continue;
        const transform = c.fz_concat(col.transform, ctm);
        const list = self.displayList(page, col.page);
        const ok = if (list != null)
            c.fz_run_display_list_z(self.ctx, list, dev, transform, scissor)
        else
            c.fz_run_page_z(self.ctx, page, dev, transform);
        if (ok == 0) return null;
    }
    if (c.fz_close_device_z(self.ctx, dev) == 0) return null;

    if (self.config.general.colorize) {
        if (self.config.general.recolor_keephue) {
            self.recolorKeepHue(pix, loaded, layout, ctm);
        } else if (c.fz_tint_pixmap_z(self.ctx, pix, self.config.general.black, self.config.general.white) == 0) return null;
    }
    keep_pixmap = true;
    return pix;
}

const max_lists = 6;

const PageList = struct {
    page: u16,
    list: *c.fz_display_list,
};

// A page's drawing commands, recorded once so each strip replays only its
// part instead of interpreting the whole page again.
fn displayList(self: *Self, page: [*c]c.fz_page, number: u16) ?*c.fz_display_list {
    for (self.lists) |entry| {
        if (entry) |cached| {
            if (cached.page == number) return cached.list;
        }
    }
    const list = c.fz_new_display_list_from_page_z(self.ctx, page) orelse return null;
    if (self.lists[self.lists_next]) |old| c.fz_drop_display_list(self.ctx, old.list);
    self.lists[self.lists_next] = .{ .page = number, .list = list };
    self.lists_next = (self.lists_next + 1) % max_lists;
    return list;
}

fn dropLists(self: *Self) void {
    for (&self.lists) |*entry| {
        if (entry.*) |cached| c.fz_drop_display_list(self.ctx, cached.list);
        entry.* = null;
    }
}

/// A point on `page`, in the page's own coordinates, in its unit's layout.
pub fn layoutPoint(self: *Self, page: u16, x: f32, y: f32) ?c.fz_point {
    const layout = self.layoutOf(page) orelse return null;
    for (layout.columns) |column| {
        const col = column orelse continue;
        if (col.page == page) return c.fz_transform_point(.{ .x = x, .y = y }, col.transform);
    }
    return null;
}

/// A search hit's rectangle in its unit's layout.
pub fn hitRect(self: *Self, hit: Hit) ?c.fz_rect {
    const hits = self.hitsOn(hit.page);
    if (hit.index >= hits.len) return null;
    const rect = c.fz_rect_from_quad(hits[hit.index]);
    const layout = self.layoutOf(hit.page) orelse return null;
    for (layout.columns) |column| {
        const col = column orelse continue;
        if (col.page == hit.page) return c.fz_transform_rect(rect, col.transform);
    }
    return null;
}

pub const Column = struct {
    page: u16,
    // From the page's coordinates to the layout's.
    transform: c.fz_matrix,
    bounds: c.fz_rect,
};

/// The caller frees a matching link's URI.
pub fn linkAt(self: *Self, number: u16, point: c.fz_point) !?[:0]u8 {
    const page = c.fz_load_page_z(self.ctx, self.doc, number) orelse return null;
    defer c.fz_drop_page(self.ctx, page);
    const links = c.fz_load_links_z(self.ctx, page);
    defer c.fz_drop_link(self.ctx, links);
    var link = links;
    while (link != null) : (link = link.*.next) {
        if (link.*.uri != null and c.fz_is_point_inside_rect(point, link.*.rect) != 0) {
            return try self.allocator.dupeZ(u8, std.mem.span(link.*.uri));
        }
    }
    return null;
}

const TextPage = struct { page: u16, search: bool, text: *anyopaque, used: u64 };

fn textOn(self: *Self, number: u16, search: bool) ?*anyopaque {
    self.text_clock +%= 1;
    var oldest: usize = 0;
    for (&self.text_pages, 0..) |*entry, i| {
        if (entry.*) |*cached| {
            if (cached.page == number and cached.search == search) {
                cached.used = self.text_clock;
                return cached.text;
            }
            if (self.text_pages[oldest]) |prior| {
                if (cached.used < prior.used) oldest = i;
            }
        } else {
            oldest = i;
        }
    }
    const page = c.fz_load_page_z(self.ctx, self.doc, number) orelse return null;
    defer c.fz_drop_page(self.ctx, page);
    const text = c.fz_load_text_z(self.ctx, page, @intFromBool(search)) orelse return null;
    if (self.text_pages[oldest]) |prior| c.fz_drop_text_z(self.ctx, prior.text);
    self.text_pages[oldest] = .{ .page = number, .search = search, .text = text, .used = self.text_clock };
    return text;
}

fn dropText(self: *Self) void {
    for (&self.text_pages) |*entry| {
        if (entry.*) |cached| c.fz_drop_text_z(self.ctx, cached.text);
        entry.* = null;
    }
}

/// A character's quad under the pointer. Whitespace can start a pan.
pub fn textAt(self: *Self, number: u16, point: c.fz_point) ?c.fz_quad {
    const text = self.textOn(number, false) orelse return null;
    var quad: c.fz_quad = undefined;
    return if (c.fz_text_at_z(text, point, &quad) != 0) quad else null;
}

pub fn clearSelection(self: *Self) void {
    if (self.selection_page != null) self.selection_revision +%= 1;
    self.selection_page = null;
    self.selection_quads.clearRetainingCapacity();
}

pub fn highlightSelection(self: *Self, number: u16, a: c.fz_point, b: c.fz_point) !void {
    self.clearSelection();
    const text = self.textOn(number, false) orelse return;
    var limit = @max(32, self.selection_quads.capacity);
    while (true) {
        try self.selection_quads.resize(self.allocator, limit);
        const count: usize = @intCast(c.fz_highlight_selection_z(self.ctx, text, a, b, self.selection_quads.items.ptr, @intCast(limit)));
        if (count < limit) {
            self.selection_quads.shrinkRetainingCapacity(count);
            if (count != 0) {
                self.selection_page = number;
                self.selection_revision +%= 1;
            }
            return;
        }
        limit *= 2;
    }
}

/// The caller releases the returned UTF-8 text with fz_free.
pub fn copySelection(self: *Self, number: u16, a: c.fz_point, b: c.fz_point) ?[*:0]u8 {
    if (self.selection_page != number) return null;
    const text = self.textOn(number, false) orelse return null;
    return c.fz_copy_selection_z(self.ctx, text, a, b);
}

/// Expands the endpoints to the edges of the word.
pub fn snapWord(self: *Self, number: u16, a: *c.fz_point, b: *c.fz_point) void {
    const text = self.textOn(number, false) orelse return;
    c.fz_snap_word_z(self.ctx, text, a, b);
}

/// Where the pages of a spread sit, rotated, in one coordinate space.
pub const Layout = struct {
    columns: [2]?Column = .{ null, null },
    width: f32 = 0,
    height: f32 = 0,
};

const LoadedSpread = struct {
    numbers: [2]?u16,
    pages: [2][*c]c.fz_page,

    fn deinit(self: LoadedSpread, ctx: [*c]c.fz_context) void {
        for (self.pages) |page| c.fz_drop_page(ctx, page);
    }
};

const max_pictures = 32;

const PageRects = struct {
    page: u16,
    len: u8,
    rects: [max_pictures]c.fz_rect,
};

// The pictures on a page, from a two-entry cache. The slice is valid until
// the next call.
fn pictureRects(self: *Self, page: [*c]c.fz_page, number: u16) []const c.fz_rect {
    for (&self.picture_cache) |*entry| {
        if (entry.*) |*cached| {
            if (cached.page == number) return cached.rects[0..cached.len];
        }
    }
    var fresh = PageRects{ .page = number, .len = 0, .rects = undefined };
    const n = c.fz_page_image_rects_z(self.ctx, page, &fresh.rects, max_pictures);
    fresh.len = @intCast(@max(0, n));
    self.picture_cache[1] = self.picture_cache[0];
    self.picture_cache[0] = fresh;
    return self.picture_cache[0].?.rects[0..fresh.len];
}

// RGB weights for lightness, as in zathura.
const weights = [3]f64{ 0.30, 0.59, 0.11 };
const epsilon = std.math.floatEps(f64);

fn lightness(rgb: [3]f64) f64 {
    return weights[0] * rgb[0] + weights[1] * rgb[1] + weights[2] * rgb[2];
}

fn rgbOf(color: i32) [3]f64 {
    const bits: u32 = @bitCast(color);
    return .{
        @as(f64, @floatFromInt((bits >> 16) & 0xff)) / 255,
        @as(f64, @floatFromInt((bits >> 8) & 0xff)) / 255,
        @as(f64, @floatFromInt(bits & 0xff)) / 255,
    };
}

// zathura's colorumax: how far a color can move along hue h from lightness l
// before a channel leaves [0, 1], scaled for the interval [l1, l2].
fn colorumax(h: [3]f64, l: f64, l1: f64, l2: f64) f64 {
    if (@abs(h[0]) <= epsilon and @abs(h[1]) <= epsilon and @abs(h[2]) <= epsilon) return 0;
    if (@abs(l2 - l1) <= epsilon) return 0;

    const lv = (l - l1) / (l2 - l1);
    var u = std.math.floatMax(f64);
    var v = std.math.floatMax(f64);
    for (h) |hk| {
        if (hk > epsilon) {
            u = @min(@abs((1 - l) / hk), u);
            v = @min(@abs((1 - lv) / hk), v);
        } else if (hk < -epsilon) {
            u = @min(@abs(l / hk), u);
            v = @min(@abs(lv / hk), v);
        }
    }
    v = @abs(l2 - l1) * v;
    return @min(u, v);
}

// zathura's recolor-keephue for opaque colors: white becomes the light color,
// black the dark one, and other colors keep their hue and saturation.
fn recolorPixel(rgb: [3]f64, dark: [3]f64, light: [3]f64) [3]u8 {
    const l1 = lightness(dark);
    const l2 = lightness(light);
    const original = lightness(rgb);
    const h = [3]f64{ rgb[0] - original, rgb[1] - original, rgb[2] - original };

    const u = colorumax(h, original, 0, 1);
    const s: f64 = if (@abs(u) > epsilon) 1.0 / u else 0.0;
    const l = original * (l2 - l1) + l1;
    const su = s * colorumax(h, l, l1, l2);

    const tr1 = 1 - @max(@max(rgb[0], rgb[1]), rgb[2]);
    const tr2 = @min(@min(rgb[0], rgb[1]), rgb[2]);
    var out: [3]u8 = undefined;
    for (0..3) |k| {
        const value = tr1 * (dark[k] - l1) + tr2 * (light[k] - l2) + (l + su * h[k]);
        out[k] = @intFromFloat(@round(255 * std.math.clamp(value, 0, 1)));
    }
    return out;
}

// With recolor_reverse_video, pictures keep their colors, as in zathura.
fn recolorKeepHue(self: *Self, pix: [*c]c.fz_pixmap, loaded: LoadedSpread, layout: Layout, ctm: c.fz_matrix) void {
    const dark = rgbOf(self.config.general.black);
    const light = rgbOf(self.config.general.white);

    var keep: [2 * max_pictures]c.fz_irect = undefined;
    var keep_len: usize = 0;
    if (self.config.general.recolor_reverse_video) {
        for (loaded.pages, layout.columns) |page, column| {
            const col = column orelse continue;
            for (self.pictureRects(page, col.page)) |r| {
                const on_image = c.fz_transform_rect(c.fz_transform_rect(r, col.transform), ctm);
                keep[keep_len] = c.fz_round_rect(on_image);
                keep_len += 1;
            }
        }
    }

    const width: usize = @intCast(c.fz_pixmap_width(self.ctx, pix));
    const height: usize = @intCast(c.fz_pixmap_height(self.ctx, pix));
    const stride: usize = @intCast(c.fz_pixmap_stride(self.ctx, pix));
    const samples = c.fz_pixmap_samples(self.ctx, pix);
    // Text pages hold few colors, so remember each one's result; a key's top
    // bit marks the slot as filled.
    const slots = 4096;
    var memo_key = [_]u32{0} ** slots;
    var memo_out: [slots][3]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            if (keep_len > 0 and insideAny(keep[0..keep_len], x, y)) continue;
            const i = y * stride + x * 3;
            const packed_rgb = (@as(u32, samples[i]) << 16) | (@as(u32, samples[i + 1]) << 8) | samples[i + 2];
            const key = packed_rgb | 0x8000_0000;
            const slot = (packed_rgb *% 2654435761) >> 20 & (slots - 1);
            if (memo_key[slot] != key) {
                const rgb = [3]f64{
                    @as(f64, @floatFromInt(samples[i])) / 255,
                    @as(f64, @floatFromInt(samples[i + 1])) / 255,
                    @as(f64, @floatFromInt(samples[i + 2])) / 255,
                };
                memo_out[slot] = recolorPixel(rgb, dark, light);
                memo_key[slot] = key;
            }
            const out = memo_out[slot];
            samples[i] = out[0];
            samples[i + 1] = out[1];
            samples[i + 2] = out[2];
        }
    }
}

fn insideAny(rects: []const c.fz_irect, x: usize, y: usize) bool {
    const xi: i32 = @intCast(x);
    const yi: i32 = @intCast(y);
    for (rects) |r| {
        if (xi >= r.x0 and xi < r.x1 and yi >= r.y0 and yi < r.y1) return true;
    }
    return false;
}

pub const max_hits = 256;

pub const Hit = struct {
    page: u16,
    index: u16,
};

const PageHits = struct {
    page: u16,
    len: u16,
    quads: [max_hits]c.fz_quad,
};

pub fn setSearch(self: *Self, needle: []const u8, backward: bool) !void {
    if (self.search_needle) |previous| {
        if (std.mem.eql(u8, previous, needle)) {
            self.search_backward = backward;
            self.search_hit = null;
            return;
        }
    }
    const owned = try self.allocator.dupeZ(u8, needle);
    self.clearSearch();
    self.search_needle = owned;
    self.search_backward = backward;
}

pub fn clearSearch(self: *Self) void {
    if (self.search_needle) |needle| self.allocator.free(needle);
    self.search_needle = null;
    self.search_hit = null;
    self.search_revision +%= 1;
    self.hit_cache = @splat(null);
    self.hit_next = 0;
}

// The slice is valid until the next call.
pub fn hitsOn(self: *Self, number: u16) []const c.fz_quad {
    const needle = self.search_needle orelse return &.{};
    for (&self.hit_cache) |*entry| {
        if (entry.*) |*cached| {
            if (cached.page == number) return cached.quads[0..cached.len];
        }
    }
    const entry = &self.hit_cache[self.hit_next];
    self.hit_next = (self.hit_next + 1) % self.hit_cache.len;
    entry.* = .{ .page = number, .len = 0, .quads = undefined };
    const fresh = &entry.*.?;
    if (self.textOn(number, true)) |text| {
        const n = c.fz_search_text_z(self.ctx, text, needle.ptr, &fresh.quads, max_hits);
        fresh.len = @intCast(@max(0, n));
    }
    return fresh.quads[0..fresh.len];
}

pub const Search = struct {
    page: u16,
    from: ?u16,
    forward: bool,
    step: u32 = 0,

    pub const Progress = union(enum) { hit: Hit, none, pending };

    /// Search one page. A repeat that reaches its starting page wraps to
    /// the first or last match there.
    pub fn advance(self: *Search, pdf: *Self) Progress {
        const total: u32 = pdf.total_pages;
        if (self.step >= total + @as(u32, @intFromBool(self.from != null))) return .none;
        const offset = self.step % total;
        const page: u16 = @intCast(if (self.forward) (self.page + offset) % total else (self.page + total - offset) % total);
        const hits = pdf.hitsOn(page);
        const first = self.step == 0;
        self.step += 1;
        if (first) {
            if (self.from) |index| {
                if (self.forward and index + 1 < hits.len) return .{ .hit = .{ .page = page, .index = index + 1 } };
                if (!self.forward and index > 0 and index - 1 < hits.len) return .{ .hit = .{ .page = page, .index = index - 1 } };
                return .pending;
            }
        }
        if (hits.len == 0) return .pending;
        return .{ .hit = .{ .page = page, .index = if (self.forward) 0 else @intCast(hits.len - 1) } };
    }
};

const max_marks = 8;

const PageMarks = struct {
    page: u16,
    rect: c.fz_rect,
};

// A page's area in its own coordinates: its bounds, or with trim_margins what
// is printed on it plus trim_padding, so the PDF's white margins take no room.
fn pageBox(self: *Self, page: [*c]c.fz_page, number: u16) ?c.fz_rect {
    var bounds: c.fz_rect = undefined;
    if (c.fz_bound_page_z(self.ctx, page, &bounds) == 0) return null;
    if (!self.config.general.trim_margins) return bounds;
    const marks = self.pageMarks(page, number);
    if (c.fz_is_empty_rect(marks) != 0) return bounds;
    const box = c.fz_intersect_rect(c.fz_expand_rect(marks, self.config.general.trim_padding), bounds);
    return if (c.fz_is_empty_rect(box) != 0) bounds else box;
}

// What is printed on a page, from a small cache; measuring runs the page.
fn pageMarks(self: *Self, page: [*c]c.fz_page, number: u16) c.fz_rect {
    for (self.marks_cache) |entry| {
        if (entry) |cached| {
            if (cached.page == number) return cached.rect;
        }
    }
    const rect = c.fz_page_marks_z(self.ctx, page);
    self.marks_cache[self.marks_next] = .{ .page = number, .rect = rect };
    self.marks_next = (self.marks_next + 1) % max_marks;
    return rect;
}

/// Turns margin trimming on or off and fits the zoom again.
pub fn toggleTrim(self: *Self) void {
    self.config.general.trim_margins = !self.config.general.trim_margins;
}

// Two-page mode loads the spread holding page_number; either column may be
// empty. Null when MuPDF cannot load a page yet, as while the file is written.
fn loadSpread(self: *Self, page_number: u16) ?LoadedSpread {
    const numbers = if (self.dual_page) self.spread(page_number) else [2]?u16{ page_number, null };
    var loaded = LoadedSpread{ .numbers = numbers, .pages = .{ null, null } };
    for (numbers, 0..) |number, i| {
        const n = number orelse continue;
        loaded.pages[i] = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, n));
        if (loaded.pages[i] == null) {
            loaded.deinit(self.ctx);
            return null;
        }
    }
    return loaded;
}

// Rotates each page and sets the pages side by side with their tops aligned,
// so trimmed pages line up. An empty column keeps the other page's width, as
// in zathura.
fn computeLayout(self: *Self, loaded: LoadedSpread) ?Layout {
    const turn = c.fz_rotate(@floatFromInt(self.rotation));
    const empty = c.fz_rect{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    var boxes = [2]c.fz_rect{ empty, empty };
    for (loaded.pages, 0..) |page, i| {
        if (page != null) {
            const box = self.pageBox(page, loaded.numbers[i].?) orelse return null;
            boxes[i] = c.fz_transform_rect(box, turn);
        }
    }
    const left_width = if (loaded.pages[0] != null) rectWidth(boxes[0]) else rectWidth(boxes[1]);
    const right_width: f32 = if (!self.dual_page) 0 else if (loaded.pages[1] != null) rectWidth(boxes[1]) else left_width;
    const gap: f32 = if (self.dual_page) page_gap else 0;

    var layout = Layout{
        .width = left_width + gap + right_width,
        .height = @max(rectHeight(boxes[0]), rectHeight(boxes[1])),
    };
    const lefts = [2]f32{ 0, left_width + gap };
    for (loaded.pages, 0..) |page, i| {
        if (page == null) continue;
        const offset = c.fz_translate(lefts[i] - boxes[i].x0, -boxes[i].y0);
        layout.columns[i] = .{
            .page = loaded.numbers[i].?,
            .transform = c.fz_concat(turn, offset),
            .bounds = c.fz_transform_rect(boxes[i], offset),
        };
    }
    return layout;
}

/// The layout of the spread holding page_number, as it would be drawn now.
pub fn layoutOf(self: *Self, page_number: u16) ?Layout {
    const loaded = self.loadSpread(page_number) orelse return null;
    defer loaded.deinit(self.ctx);
    return self.computeLayout(loaded);
}

fn rectWidth(r: c.fz_rect) f32 {
    return r.x1 - r.x0;
}

fn rectHeight(r: c.fz_rect) f32 {
    return r.y1 - r.y0;
}
