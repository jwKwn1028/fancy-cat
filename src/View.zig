//! The page view, like zathura's continuous mode: units (pages, or spreads in
//! two-page mode) stacked top to bottom and scrolled by the pixel. Each unit
//! is rendered once into strips that stay in the terminal, so scrolling only
//! moves their placements and renders nothing.
const Self = @This();
const std = @import("std");
const RenderWorker = @import("RenderWorker.zig");
const Config = @import("config/Config.zig");
const Graphics = @import("Graphics.zig");
const Transport = Graphics.Transport;
const Tmux = @import("Tmux.zig");
const vaxis = @import("vaxis");
const PdfHandler = @import("handlers/PdfHandler.zig");
const Utilities = @import("utilities/Utilities.zig");
const c = PdfHandler.c;

const Writer = std.Io.Writer;

/// Strip height in pixels: small enough that scrolling into a new page
/// renders a little at a time.
const strip_height: i32 = 256;
/// Strips wider than this split into columns half as wide; Ghostty takes
/// images up to 10000 pixels a side.
const max_strip_width: i32 = 4096;
/// Kitty and Ghostty draw images with a z-index below this under cells that
/// have a background color, so bars and link labels show over the page.
const below_backgrounds: i32 = -1_073_741_825;
const selection_width = 256;
const selection_height = 64;
const Overlay = enum {
    selection,
    match,
    active_match,

    fn color(self: Overlay) [4]u8 {
        return switch (self) {
            .selection => .{ 48, 130, 255, 100 },
            .match => .{ 255, 230, 0, 115 },
            .active_match => .{ 255, 140, 0, 155 },
        };
    }
};
const max_zoom = 30.0;
pub const max_visible = 64;

pub const Visible = struct {
    unit: u16,
    layout: PdfHandler.Layout,
    /// Position and size, in pixels from the view's top-left corner.
    left: i32,
    top: i32,
    width: i32,
    height: i32,

    pub fn layoutToPixels(self: Visible, zoom: f32) c.fz_matrix {
        return c.fz_concat(c.fz_scale(zoom, zoom), c.fz_translate(@floatFromInt(self.left), @floatFromInt(self.top)));
    }
};

pub const PagePoint = struct { page: u16, point: c.fz_point };

const TileKey = RenderWorker.Key;
const Request = RenderWorker.Request;
const Tile = struct {
    id: u32,
    bytes: usize,
    visible: u64,
    nearby: u64,
    older: ?TileKey = null,
    newer: ?TileKey = null,
};
const LocalImage = struct {
    image: RenderWorker.Image,
    sent: bool = false,
    refresh: bool = false,
    replay: bool = false,
};
const replay_delay = 60 * std.time.ns_per_ms;
const retire_delay = 16 * std.time.ns_per_ms;
const Placement = struct { id: u32, x: i32, y: i32, sx: i32, sy: i32, sw: i32, sh: i32 };
const VisibleStrip = struct { key: TileKey, placement: Placement };
const Frame = struct {
    show: bool,
    unit: u16,
    top: i32,
    x: i32,
    width: i32,
    height: i32,
    cell_w: i32,
    cell_h: i32,
    generation: u64,
};
const Highlights = struct { selection: u64, search: u64, hit: ?PdfHandler.Hit };

allocator: std.mem.Allocator,
config: *Config,
transport: Transport = .direct,
pdf: *PdfHandler = undefined,
// The view's size and the cell size, in pixels; zero until the terminal
// reports them.
width: i32 = 0,
height: i32 = 0,
cell_w: i32 = 0,
cell_h: i32 = 0,
// Pixels per point; zero until the first fit.
zoom: f32 = 0,
// Whether the zoom follows the window, fitting the width or the whole page.
fitted: bool = true,
width_mode: bool = true,
// The unit at the top of the view, and how many of its pixels are above it.
unit: u16 = 0,
y: f32 = 0,
// How far units wider than the view are panned, in pixels.
x: f32 = 0,
// Pixels down to center a document shorter than the view.
center: f32 = 0,
layouts: std.AutoHashMap(u16, PdfHandler.Layout),
tiles: std.AutoHashMap(TileKey, Tile),
tile_bytes: usize = 0,
tick: u64 = 0,
oldest: ?TileKey = null,
newest: ?TileKey = null,
document: u64 = 0,
generation: u64 = 0,
previous_frame: ?Frame = null,
previous_highlights: ?Highlights = null,
forward: bool = true,
next_id: u32 = 1,
// Images placed in the last frame; images to delete in the next.
placed: std.AutoHashMap(u32, Placement),
placed_cell_size: [2]i32 = .{ 0, 0 },
shown: std.AutoHashMap(u32, Placement),
failed: std.AutoHashMap(TileKey, void),
doomed: std.ArrayList(u32) = .{},
files: std.AutoHashMap(u32, LocalImage),
replay_timer: ?std.time.Timer = null,
retired_images: std.ArrayList(u32) = .{},
retire_timer: ?std.time.Timer = null,
holding_viewport: bool = false,
strips: std.ArrayList(VisibleStrip) = .{},
requests: [RenderWorker.capacity]Request = undefined,
request_count: usize = 0,
planned_bytes: usize = 0,
unit_marks: std.ArrayList(RenderWorker.Mark) = .{},
tile_marks: std.ArrayList(RenderWorker.Mark) = .{},
overlay_images: [3]?u32 = @splat(null),
overlay_placed: [3]bool = @splat(false),
// Places to return to with Ctrl+o and Ctrl+i, and the session's marks.
jumps: std.ArrayList(Position) = .{},
jump_at: usize = 0,
marks: [52]?Position = [_]?Position{null} ** 52,

pub fn init(allocator: std.mem.Allocator, config: *Config, first_page: u16) Self {
    return .{
        .allocator = allocator,
        .config = config,
        .unit = first_page,
        .layouts = .init(allocator),
        .tiles = .init(allocator),
        .placed = .init(allocator),
        .shown = .init(allocator),
        .failed = .init(allocator),
        .files = .init(allocator),
    };
}

/// Called once the document has its final address.
pub fn attach(self: *Self, pdf: *PdfHandler) void {
    self.pdf = pdf;
    self.unit = pdf.unitOf(@min(self.unit, pdf.total_pages - 1));
}

/// Deletes the strips from the terminal.
pub fn deinit(self: *Self, w: *Writer) void {
    var it = self.tiles.valueIterator();
    while (it.next()) |tile| self.disposeImage(w, tile.id) catch {};
    for (self.doomed.items) |id| self.disposeImage(w, id) catch {};
    var files = self.files.valueIterator();
    while (files.next()) |file| file.image.deinit(self.allocator);
    self.files.deinit();
    for (self.overlay_images) |image| if (image) |id| self.disposeImage(w, id) catch {};
    var batch: Graphics.TmuxBatch = .{ .writer = w };
    self.deleteRetired(&batch) catch {};
    batch.finish() catch {};
    self.retired_images.deinit(self.allocator);
    w.flush() catch {};
    self.layouts.deinit();
    self.tiles.deinit();
    self.placed.deinit();
    self.shown.deinit();
    self.doomed.deinit(self.allocator);
    self.failed.deinit();
    self.strips.deinit(self.allocator);
    self.unit_marks.deinit(self.allocator);
    self.tile_marks.deinit(self.allocator);
    self.jumps.deinit(self.allocator);
}

fn ready(self: *Self) bool {
    return self.width > 0 and self.height > 0 and self.cell_w > 0 and self.cell_h > 0;
}

/// Sizes the view to the terminal, less `reserved_rows` at the bottom.
pub fn setGeometry(self: *Self, cols: u16, rows: u16, width_pix: u16, height_pix: u16, reserved_rows: u16) void {
    if (cols == 0 or rows == 0 or width_pix < cols or height_pix < rows) {
        self.width = 0;
        return;
    }
    const cell_w = @divFloor(@as(i32, width_pix), cols);
    const cell_h = @divFloor(@as(i32, height_pix), rows);
    if (self.transport == .tmux and (self.cell_w != cell_w or self.cell_h != cell_h)) {
        self.holding_viewport = false;
        self.placed.clearRetainingCapacity();
        self.clearTiles();
    }
    self.cell_w = cell_w;
    self.cell_h = cell_h;
    self.width = @as(i32, cols) * self.cell_w;
    self.height = @as(i32, rows -| reserved_rows) * self.cell_h;
    if (self.height <= 0) return;
    if (self.zoom > 0 and self.fitted) self.rescale(self.fitZoom(), false);
    self.normalize();
}

// --- zoom ---------------------------------------------------------------

fn limit(self: *Self, zoom: f32) f32 {
    return std.math.clamp(zoom, self.config.general.zoom_min, max_zoom);
}

fn fitZoom(self: *Self) f32 {
    const layout = self.layoutOf(self.unit);
    const w: f32 = @floatFromInt(self.width);
    const h: f32 = @floatFromInt(self.height);
    var zoom = w / @max(layout.width, 1);
    if (!self.width_mode) zoom = @min(zoom, h / @max(layout.height, 1));
    return self.limit(zoom * self.config.general.size);
}

// Changes the zoom, keeping the view's center (or top) on the same spot.
fn rescale(self: *Self, zoom: f32, keep_center: bool) void {
    const old = self.zoom;
    if (old == zoom) return;
    self.zoom = zoom;
    self.clearTiles();
    if (old <= 0) return;
    const f = zoom / old;
    const half_h: f32 = if (keep_center) @as(f32, @floatFromInt(self.height)) / 2 else 0;
    const half_w: f32 = if (keep_center) @as(f32, @floatFromInt(self.width)) / 2 else 0;
    self.y = (self.y + half_h) * f - half_h;
    self.x = (self.x + half_w) * f - half_w;
}

/// Multiplies the zoom by `factor`, as + and - do.
pub fn zoomBy(self: *Self, factor: f32) void {
    if (!self.ready()) return;
    self.normalize();
    self.fitted = false;
    self.rescale(self.limit(self.zoom * factor), true);
    self.normalize();
}

/// Sets the zoom as a percentage of the page's printed size, as :100% does.
pub fn setZoomPercent(self: *Self, percent: f32) void {
    if (!self.ready()) return;
    self.normalize();
    var dpi = self.config.general.dpi;
    if (self.config.general.detect_dpi) dpi = Utilities.getDPI() orelse dpi;
    self.fitted = false;
    self.rescale(self.limit(percent * dpi / 7200.0), true);
    self.normalize();
}

/// Fits the width (s) or the whole page (a).
pub fn fit(self: *Self, width: bool) void {
    self.width_mode = width;
    self.refit();
}

/// Fits the zoom to the window again, showing the current unit from its top.
pub fn refit(self: *Self) void {
    self.fitted = true;
    if (!self.ready()) return;
    self.unit = self.currentUnit();
    self.y = 0;
    self.x = 0;
    self.rescale(self.fitZoom(), false);
    self.normalize();
}

// --- layouts and drawing state -----------------------------------------

fn layoutOf(self: *Self, unit: u16) PdfHandler.Layout {
    if (self.layouts.get(unit)) |layout| return layout;
    // A US Letter page stands in while a page cannot be loaded.
    const layout = self.pdf.layoutOf(unit) orelse return .{ .width = 612, .height = 792 };
    self.layouts.put(unit, layout) catch {};
    return layout;
}

fn scaled(self: *Self, points: f32) i32 {
    return @max(1, @as(i32, @intFromFloat(@round(points * self.zoom))));
}

fn alignUp(self: *Self, pixels: i32, cell: i32) i32 {
    if (self.transport == .direct or cell == 0) return pixels;
    return @divFloor(pixels + cell - 1, cell) * cell;
}

fn snap(self: *Self, pixels: f32, cell: i32) i32 {
    if (self.transport == .direct or cell == 0) return @intFromFloat(@round(pixels));
    const step: f32 = @floatFromInt(cell);
    return @as(i32, @intFromFloat(@round(pixels / step))) * cell;
}

fn unitHeight(self: *Self, unit: u16) f32 {
    return @floatFromInt(self.alignUp(self.scaled(self.layoutOf(unit).height), self.cell_h));
}

fn gap(self: *Self) f32 {
    return @floatFromInt(self.snap(@max(0, self.config.general.page_gap), self.cell_h));
}

/// The page layout changed: keep the page in view and discard old strips.
pub fn layoutChanged(self: *Self, page: u16) void {
    self.layouts.clearRetainingCapacity();
    self.clearTiles();
    self.unit = self.pdf.unitOf(page);
    self.y = 0;
    self.x = 0;
    if (self.fitted and self.ready()) self.zoom = self.fitZoom();
    self.normalize();
}

/// The document was reloaded: keeps the place and draws everything again.
pub fn reloaded(self: *Self) void {
    self.document +%= 1;
    self.holding_viewport = self.placed.count() != 0;
    self.layouts.clearRetainingCapacity();
    self.clearTiles();
    self.unit = self.pdf.unitOf(@min(self.unit, self.pdf.total_pages - 1));
    self.normalize();
}

/// Colors changed: draws the pages again.
pub fn redraw(self: *Self) void {
    self.clearTiles();
}

/// A returning pane or newly attached client can need the cached files again.
pub fn refreshTmuxImages(self: *Self) void {
    var it = self.files.valueIterator();
    while (it.next()) |file| file.refresh = true;
    self.previous_frame = null;
}

fn clearTiles(self: *Self) void {
    self.generation +%= 1;
    self.failed.clearRetainingCapacity();
    self.oldest = null;
    self.newest = null;
    var it = self.tiles.valueIterator();
    while (it.next()) |tile| self.doomed.append(self.allocator, tile.id) catch {};
    self.tiles.clearRetainingCapacity();
    self.tile_bytes = 0;
}

// --- position -----------------------------------------------------------

// Moves the position into the unit at the top of the view, and keeps the
// view within the document: no space above the first unit or below the last.
fn normalize(self: *Self) void {
    if (!self.ready()) return;
    if (self.zoom <= 0) self.zoom = self.fitZoom();
    const gap_px = self.gap();
    const view_h: f32 = @floatFromInt(self.height);

    _ = self.walkUp();
    while (self.y >= self.unitHeight(self.unit) + gap_px) {
        const next = self.pdf.nextUnit(self.unit) orelse break;
        self.y -= self.unitHeight(self.unit) + gap_px;
        self.unit = next;
    }

    // Content from the view's top down; at the end, pull the view back up.
    var below = self.unitHeight(self.unit) - self.y;
    var unit = self.unit;
    while (below < view_h) {
        const next = self.pdf.nextUnit(unit) orelse break;
        unit = next;
        below += gap_px + self.unitHeight(next);
    }
    self.center = 0;
    if (below < view_h) {
        self.y -= view_h - below;
        // Past the start, the whole document is shorter than the view.
        if (self.walkUp()) |short_by| self.center = @round(short_by / 2);
    }
    self.y = @round(self.y);
    self.clampX();
}

// Moves up while the view starts above its unit. Returns how far the view
// starts above the first unit, if it does.
fn walkUp(self: *Self) ?f32 {
    while (self.y < 0) {
        const prev = self.pdf.prevUnit(self.unit) orelse {
            const short_by = -self.y;
            self.y = 0;
            return short_by;
        };
        self.unit = prev;
        self.y += self.unitHeight(prev) + self.gap();
    }
    return null;
}

fn clampX(self: *Self) void {
    var widest: i32 = 0;
    var buf: [max_visible]Visible = undefined;
    for (self.visible(&buf)) |v| widest = @max(widest, v.width);
    const room: f32 = @floatFromInt(@max(0, widest - self.width));
    self.x = std.math.clamp(self.x, 0, room);
}

fn box(self: *Self, unit: u16, top: i32) Visible {
    const layout = self.layoutOf(unit);
    const w = self.alignUp(self.scaled(layout.width), self.cell_w);
    const h = self.alignUp(self.scaled(layout.height), self.cell_h);
    const offset: f32 = if (w <= self.width)
        @floatFromInt(@divFloor(self.width - w, 2))
    else
        -@min(self.x, @as(f32, @floatFromInt(w - self.width)));
    const left = self.snap(offset, self.cell_w);
    return .{ .unit = unit, .layout = layout, .left = left, .top = top, .width = w, .height = h };
}

/// The units in view, top to bottom.
pub fn visible(self: *Self, out: []Visible) []Visible {
    if (!self.ready() or self.zoom <= 0) return out[0..0];
    const gap_px: i32 = @intFromFloat(self.gap());
    var n: usize = 0;
    var top: i32 = self.snap(self.center - self.y, self.cell_h);
    var unit = self.unit;
    while (n < out.len and top < self.height) {
        out[n] = self.box(unit, top);
        top += out[n].height + gap_px;
        n += 1;
        unit = self.pdf.nextUnit(unit) orelse break;
    }
    return out[0..n];
}

/// Converts terminal mouse coordinates to the pixel grid used for painting.
pub fn mousePoint(self: *Self, col: u16, row: u16, dx: u16, dy: u16) c.fz_point {
    return .{
        .x = @floatFromInt(@as(i32, col) * self.cell_w + dx),
        .y = @floatFromInt(@as(i32, row) * self.cell_h + dy),
    };
}

/// The page and page-local point under a position in the viewport.
pub fn pageAt(self: *Self, point: c.fz_point) ?PagePoint {
    if (point.x < 0 or point.y < 0 or
        point.x >= @as(f32, @floatFromInt(self.width)) or point.y >= @as(f32, @floatFromInt(self.height))) return null;
    var buf: [max_visible]Visible = undefined;
    for (self.visible(&buf)) |v| {
        const in_layout = c.fz_transform_point(point, c.fz_invert_matrix(v.layoutToPixels(self.zoom)));
        for (v.layout.columns) |col| {
            const column = col orelse continue;
            if (c.fz_is_point_inside_rect(in_layout, column.bounds) != 0) {
                return .{
                    .page = column.page,
                    .point = c.fz_transform_point(in_layout, c.fz_invert_matrix(column.transform)),
                };
            }
        }
    }
    return null;
}

/// Maps a drag endpoint to the page it began on, stopping at the page edge.
pub fn pointOnPage(self: *Self, page: u16, point: c.fz_point) ?c.fz_point {
    var buf: [max_visible]Visible = undefined;
    for (self.visible(&buf)) |v| {
        for (v.layout.columns) |col| {
            const column = col orelse continue;
            if (column.page != page) continue;
            const bounds = column.bounds;
            const local = c.fz_transform_point(point, c.fz_invert_matrix(v.layoutToPixels(self.zoom)));
            return c.fz_transform_point(.{
                .x = std.math.clamp(local.x, bounds.x0, bounds.x1),
                .y = std.math.clamp(local.y, bounds.y0, bounds.y1),
            }, c.fz_invert_matrix(column.transform));
        }
    }
    return null;
}

/// The unit being read: the one at the top, or the next when the top one
/// fills less than a third of the view.
pub fn currentUnit(self: *Self) u16 {
    if (!self.ready() or self.zoom <= 0) return self.unit;
    const shown_px = self.unitHeight(self.unit) - self.y;
    if (shown_px * 3 < @as(f32, @floatFromInt(self.height))) {
        if (self.pdf.nextUnit(self.unit)) |next| return next;
    }
    return self.unit;
}

/// Shows the unit holding `page` (0-based) from its top.
pub fn goToPage(self: *Self, page: u16) void {
    self.unit = self.pdf.unitOf(@min(page, self.pdf.total_pages - 1));
    self.y = 0;
    self.normalize();
}

/// Shows the end of the document.
pub fn goToEnd(self: *Self) void {
    self.unit = self.pdf.lastUnit();
    // The last unit's bottom at the view's top; normalize pulls the view
    // back until that bottom meets the view's bottom. A huge offset would
    // lose the unit's height to rounding.
    self.y = if (self.zoom > 0) self.unitHeight(self.unit) else 0;
    self.normalize();
}

/// Moves `count` units forward or back, showing the new one from its top.
pub fn turn(self: *Self, forward: bool, count: u32) void {
    const previous_unit = self.unit;
    const previous_top = self.snap(self.center - self.y, self.cell_h);
    var unit = self.currentUnit();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        unit = (if (forward) self.pdf.nextUnit(unit) else self.pdf.prevUnit(unit)) orelse break;
    }
    self.unit = unit;
    self.y = 0;
    self.normalize();
    if (self.placed.count() != 0 and (self.unit != previous_unit or self.snap(self.center - self.y, self.cell_h) != previous_top)) {
        self.holding_viewport = true;
    }
}

/// Scrolls down by `pixels`, or up when negative, across pages.
pub fn scrollBy(self: *Self, pixels: f32) void {
    self.y += pixels;
    self.normalize();
}

/// Pans right by `pixels`, or left when negative.
pub fn panBy(self: *Self, pixels: f32) void {
    self.x += pixels;
    self.clampX();
}

/// Puts the point at height y of `page`, in the page's own coordinates, at
/// the top of the view; a NaN y shows the page from its top.
pub fn goToPoint(self: *Self, page: u16, y: f32) void {
    self.goToPage(page);
    if (std.math.isNan(y) or self.zoom <= 0) return;
    const point = self.pdf.layoutPoint(page, 0, y) orelse return;
    self.y = point.y * self.zoom;
    self.normalize();
}

/// Centers a rectangle of the layout of the unit holding `page`.
pub fn showRect(self: *Self, page: u16, rect: c.fz_rect) void {
    self.unit = self.pdf.unitOf(page);
    self.normalize();
    if (self.zoom <= 0) return;
    self.y = (rect.y0 + rect.y1) / 2 * self.zoom - @as(f32, @floatFromInt(self.height)) / 2;
    self.x = (rect.x0 + rect.x1) / 2 * self.zoom - @as(f32, @floatFromInt(self.width)) / 2;
    self.normalize();
}

/// Shows the current unit from its top (H).
pub fn pageTop(self: *Self) void {
    self.unit = self.currentUnit();
    self.y = 0;
    self.normalize();
}

/// Puts the current unit's bottom at the view's bottom (L).
pub fn pageBottom(self: *Self) void {
    if (!self.ready()) return;
    self.unit = self.currentUnit();
    self.y = self.unitHeight(self.unit) - @as(f32, @floatFromInt(self.height));
    self.normalize();
}

/// Shows the current unit from its top-left corner (P).
pub fn snapToPage(self: *Self) void {
    self.x = 0;
    self.pageTop();
}

// --- jumps and marks ----------------------------------------------------

/// A place that survives zoom changes: a unit's first page and how far the
/// view's top is into it, in points.
pub const Position = struct { page: u16, y: f32 };

const max_jumps = 100;

pub fn position(self: *Self) Position {
    return .{ .page = self.unit, .y = if (self.zoom > 0) self.y / self.zoom else 0 };
}

pub fn restore(self: *Self, p: Position) void {
    self.goToPage(p.page);
    if (self.zoom <= 0) return;
    self.y = p.y * self.zoom;
    self.normalize();
}

/// Remembers the place before a jump, for Ctrl+o.
pub fn recordJump(self: *Self) void {
    self.jumps.shrinkRetainingCapacity(self.jump_at);
    self.pushJump(self.position());
    self.jump_at = self.jumps.items.len;
}

fn pushJump(self: *Self, p: Position) void {
    const items = self.jumps.items;
    if (items.len > 0 and items[items.len - 1].page == p.page and @abs(items[items.len - 1].y - p.y) < 1) return;
    self.jumps.append(self.allocator, p) catch return;
    if (self.jumps.items.len > max_jumps) _ = self.jumps.orderedRemove(0);
}

/// Ctrl+o: back to the place before the last jump.
pub fn jumpBack(self: *Self) void {
    if (self.jump_at >= self.jumps.items.len) {
        // Keep the place being left, so Ctrl+i returns to it.
        self.pushJump(self.position());
        if (self.jumps.items.len == 0) return;
        self.jump_at = self.jumps.items.len - 1;
    }
    if (self.jump_at == 0) return;
    self.jump_at -= 1;
    self.restore(self.jumps.items[self.jump_at]);
}

/// Ctrl+i: forward again after Ctrl+o.
pub fn jumpForward(self: *Self) void {
    if (self.jump_at + 1 >= self.jumps.items.len) return;
    self.jump_at += 1;
    self.restore(self.jumps.items[self.jump_at]);
}

fn markSlot(letter: u21) ?usize {
    return switch (letter) {
        'a'...'z' => letter - 'a',
        'A'...'Z' => 26 + letter - 'A',
        else => null,
    };
}

/// m{a-z}: remembers the place under a letter. False for other keys.
pub fn setMark(self: *Self, letter: u21) bool {
    const slot = markSlot(letter) orelse return false;
    self.marks[slot] = self.position();
    return true;
}

/// '{a-z}: returns to a mark. False when none is set under the letter.
pub fn goToMark(self: *Self, letter: u21) bool {
    const slot = markSlot(letter) orelse return false;
    const p = self.marks[slot] orelse return false;
    self.recordJump();
    self.restore(p);
    return true;
}

// --- strips in the terminal ---------------------------------------------

fn budget(self: *Self) usize {
    if (!self.config.cache.enabled) return 0;
    return @as(usize, self.config.cache.memory_mb) * 1024 * 1024;
}

fn stripHeight(self: *Self) i32 {
    if (self.transport == .direct) return strip_height;
    return @max(self.cell_h, @divFloor(strip_height, self.cell_h) * self.cell_h);
}

fn tileWidth(self: *Self, width: i32) i32 {
    if (self.transport == .direct) return if (width <= max_strip_width) width else max_strip_width / 2;
    return @min(width, self.cell_w * @max(1, @min(Tmux.cell_limit, @divFloor(max_strip_width, self.cell_w))));
}

fn tileArea(self: *Self, v: Visible, row: i32, col: i32) c.fz_irect {
    const tile_w = self.tileWidth(v.width);
    const strip_h = self.stripHeight();
    const x0 = col * tile_w;
    const y0 = row * strip_h;
    return .{ .x0 = x0, .y0 = y0, .x1 = @min(v.width, x0 + tile_w), .y1 = @min(v.height, y0 + strip_h) };
}

fn nextImageId(self: *Self) u32 {
    const id = self.next_id;
    self.next_id +%= 1;
    if (self.next_id == 0) self.next_id = 1;
    return id;
}

// A placeholder cell carries one image. Blend highlights into affected
// strips while retaining their unmarked counterparts in the cache.
fn collectMarks(self: *Self, visible_unit: Visible) !void {
    self.unit_marks.clearRetainingCapacity();
    if (self.transport != .tmux) return;
    for (visible_unit.layout.columns) |column| {
        const col = column orelse continue;
        const transform = c.fz_concat(col.transform, c.fz_scale(self.zoom, self.zoom));
        for (self.pdf.hitsOn(col.page), 0..) |quad, index| {
            const active = if (self.pdf.search_hit) |hit| hit.page == col.page and hit.index == index else false;
            try self.addMark(quad, transform, if (active) .active_match else .match);
        }
        if (self.pdf.selection_page == col.page) {
            for (self.pdf.selection_quads.items) |quad| try self.addMark(quad, transform, .selection);
        }
    }
}

fn addMark(self: *Self, quad: c.fz_quad, transform: c.fz_matrix, style: Overlay) !void {
    try self.unit_marks.append(self.allocator, .{
        .rect = c.fz_round_rect(c.fz_transform_rect(c.fz_rect_from_quad(quad), transform)),
        .color = style.color(),
    });
}

fn marksOnTile(self: *Self, area: c.fz_irect) !void {
    for (self.unit_marks.items) |mark| {
        const r = c.fz_intersect_irect(area, mark.rect);
        if (r.x0 >= r.x1 or r.y0 >= r.y1) continue;
        try self.tile_marks.append(self.allocator, .{
            .rect = .{ .x0 = r.x0 - area.x0, .x1 = r.x1 - area.x0, .y0 = r.y0 - area.y0, .y1 = r.y1 - area.y0 },
            .color = mark.color,
        });
    }
}

// Collect visible placements and build the visible-first render queue. The
// first planned strip need not start at the top of a tall zoomed page.
fn collect(self: *Self, v: Visible, lo: i32, hi: i32, foreground: bool, forward: bool) !void {
    const tile_w = self.tileWidth(v.width);
    const strip_h = self.stripHeight();
    const start = @max(0, @divFloor(lo - v.top, strip_h));
    const end = @min(@divFloor(v.height - 1, strip_h), @divFloor(hi - 1 - v.top, strip_h));
    if (start > end) return;
    try self.collectMarks(v);
    var row = if (forward) start else end;
    const step: i32 = if (forward) 1 else -1;
    while (row >= start and row <= end) : (row += step) {
        if (!foreground and (self.request_count == RenderWorker.capacity or self.planned_bytes >= self.budget())) return;
        var col: i32 = @max(0, @divFloor(-v.left, tile_w));
        while (col * tile_w < v.width and v.left + col * tile_w < self.width) : (col += 1) {
            const area = self.tileArea(v, row, col);
            const x = v.left + area.x0;
            const y = v.top + area.y0;
            if (!foreground and y < self.height and y + area.y1 - area.y0 > 0) continue;
            const bytes: usize = @intCast((area.x1 - area.x0) * (area.y1 - area.y0) * 3);
            if (!foreground and self.planned_bytes + bytes > self.budget()) continue;
            const mark_start = self.tile_marks.items.len;
            try self.marksOnTile(area);
            const marks = self.tile_marks.items[mark_start..];
            const key: TileKey = .{
                .unit = v.unit,
                .row = @intCast(row),
                .col = @intCast(col),
                .tint = if (marks.len == 0) 0 else std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(marks)) | 1,
            };
            var keep_marks = false;
            defer if (!keep_marks) self.tile_marks.shrinkRetainingCapacity(mark_start);
            if (self.failed.contains(key)) continue;
            if (self.tiles.getPtr(key)) |tile| {
                tile.nearby = self.tick;
                if (foreground) {
                    tile.visible = self.tick;
                    self.touch(key, tile);
                }
            } else {
                if (self.request_count == RenderWorker.capacity) continue;
                self.requests[self.request_count] = .{
                    .key = key,
                    .area = area,
                    .bytes = bytes,
                    .visible = foreground,
                    .mark_start = mark_start,
                    .mark_count = marks.len,
                };
                self.request_count += 1;
                keep_marks = true;
            }
            self.planned_bytes += bytes;
            if (!foreground) continue;

            const sx0 = @max(0, -x);
            const sy0 = @max(0, -y);
            const sx1 = @min(area.x1 - area.x0, self.width - x);
            const sy1 = @min(area.y1 - area.y0, self.height - y);
            if (sx1 <= sx0 or sy1 <= sy0) continue;
            try self.strips.append(self.allocator, .{
                .key = key,
                .placement = .{ .id = 0, .x = x + sx0, .y = y + sy0, .sx = sx0, .sy = sy0, .sw = sx1 - sx0, .sh = sy1 - sy0 },
            });
        }
    }
}

fn lookAhead(self: *Self, start: i32, forward: bool, distance: i32) !void {
    const gap_px: i32 = @intFromFloat(self.gap());
    const lo = if (forward) self.height else -distance;
    const hi = if (forward) self.height + distance else 0;
    var top = start;
    var unit: ?u16 = self.unit;
    for (0..max_visible) |_| {
        const u = unit orelse break;
        if ((forward and top >= hi) or self.request_count == RenderWorker.capacity or self.planned_bytes >= self.budget()) break;
        const v = self.box(u, top);
        if (v.top + v.height <= lo and !forward) break;
        try self.collect(v, lo, hi, false, forward);
        if (forward) {
            top += v.height + gap_px;
            unit = self.pdf.nextUnit(u);
        } else {
            unit = self.pdf.prevUnit(u);
            if (unit) |prev| top -= gap_px + self.alignUp(self.scaled(self.layoutOf(prev).height), self.cell_h);
        }
    }
}

/// Replace queued work on a viewport change. A completed image is admitted
/// only if its generation and strip are still wanted by the current plan.
pub fn present(self: *Self, w: *Writer, worker: *RenderWorker, show: bool) !bool {
    const frame: Frame = .{
        .show = show and self.ready() and self.zoom > 0,
        .unit = self.unit,
        .top = self.snap(self.center - self.y, self.cell_h),
        .x = self.snap(self.x, self.cell_w),
        .width = self.width,
        .height = self.height,
        .cell_w = self.cell_w,
        .cell_h = self.cell_h,
        .generation = self.generation,
    };
    const highlights: Highlights = .{
        .selection = self.pdf.selection_revision,
        .search = self.pdf.search_revision,
        .hit = self.pdf.search_hit,
    };
    const moved = self.previous_frame == null or !std.meta.eql(self.previous_frame.?, frame);
    const highlights_changed = self.previous_highlights == null or !std.meta.eql(self.previous_highlights.?, highlights);
    const overlay_changed = moved or highlights_changed;
    const repaint_tiles = self.transport == .tmux and highlights_changed;
    if (repaint_tiles and self.previous_highlights != null and self.placed.count() != 0) self.holding_viewport = true;
    var result = worker.take();
    defer if (result) |ready_tile| if (ready_tile.image) |image| image.deinit(self.allocator);
    if (!moved and !overlay_changed and result == null) return false;

    var visible_buf: [max_visible]Visible = undefined;
    const units = if (frame.show) self.visible(&visible_buf) else visible_buf[0..0];
    const replan = moved or result != null or repaint_tiles;
    if (replan) {
        self.tick +%= 1;
        self.tile_marks.clearRetainingCapacity();
        self.strips.clearRetainingCapacity();
        self.request_count = 0;
        self.planned_bytes = 0;
        if (self.previous_frame) |last| {
            if (frame.unit != last.unit) {
                self.forward = frame.unit > last.unit;
            } else if (frame.top != last.top) {
                self.forward = frame.top < last.top;
            }
        }
        for (units) |v| try self.collect(v, 0, self.height, true, true);
        if (self.transport == .tmux and frame.show and (moved or repaint_tiles)) {
            // Publish placeholder cells only after every visible strip is
            // prepared, so tmux gets one screen update per viewport swap.
            for (self.requests[0..self.request_count]) |request| {
                if (request.visible) {
                    self.holding_viewport = true;
                    break;
                }
            }
        }
        if (frame.show and self.planned_bytes < self.budget()) {
            try self.lookAhead(frame.top, self.forward, self.height);
            try self.lookAhead(frame.top, !self.forward, @divFloor(self.height, 2));
        }
    }

    // A reload or zoom can invalidate images that are still holding the
    // screen. Keep their IDs queued for deletion with the viewport swap.
    var retired: usize = 0;
    for (self.doomed.items) |id| {
        if (self.holding_viewport and self.placed.contains(id)) {
            self.doomed.items[retired] = id;
            retired += 1;
        } else {
            try self.disposeImage(w, id);
            _ = self.placed.remove(id);
        }
    }
    self.doomed.shrinkRetainingCapacity(retired);
    var upload: ?Request = null;
    if (result) |ready_tile| {
        if (ready_tile.job.generation == self.generation) {
            for (self.requests[0..self.request_count], 0..) |request, i| {
                if (!std.meta.eql(request.key, ready_tile.job.request.key)) continue;
                self.request_count -= 1;
                std.mem.copyForwards(Request, self.requests[i..self.request_count], self.requests[i + 1 .. self.request_count + 1]);
                if (ready_tile.image != null) {
                    if (try self.reserve(w, request.bytes, request.visible)) upload = request;
                } else {
                    try self.failed.put(request.key, {});
                }
                break;
            }
        }
    }

    if (replan) try worker.replace(.{
        .generation = self.generation,
        .document = self.document,
        .transport = self.transport,
        .snapshot = self.pdf.snapshot,
        .zoom = self.zoom,
        .dual_page = self.pdf.dual_page,
        .rotation = self.pdf.rotation,
        .general = self.config.general,
    }, self.requests[0..self.request_count], self.tile_marks.items);

    if (upload) |request| {
        try self.tiles.ensureUnusedCapacity(1);
        const id = self.nextImageId();
        const image = result.?.image.?;
        if (image.file != null) {
            try self.files.putNoClobber(id, .{ .image = image });
            result.?.image.?.file = null;
        } else {
            try image.transmit(w, id);
        }
        self.tiles.putAssumeCapacityNoClobber(request.key, .{
            .id = id,
            .bytes = request.bytes,
            .visible = if (request.visible) self.tick else 0,
            .nearby = self.tick,
        });
        self.appendNewest(request.key, self.tiles.getPtr(request.key).?);
        self.tile_bytes += request.bytes;
    }

    // Keep the old image placements until the entire replacement viewport
    // can be placed in one terminal update.
    var syncing = false;
    const swapping_viewport = self.holding_viewport;
    if (swapping_viewport) {
        self.previous_frame = frame;
        self.previous_highlights = if (self.transport == .tmux) highlights else null;
        for (self.strips.items) |strip| {
            if (!self.tiles.contains(strip.key) and !self.failed.contains(strip.key)) return false;
        }
        self.holding_viewport = false;
        for (self.doomed.items) |id| {
            if (self.transport == .direct) try sync(w, &syncing);
            try self.disposeImage(w, id);
            _ = self.placed.remove(id);
        }
        self.doomed.clearRetainingCapacity();
    }

    const cell_size = [2]i32{ frame.cell_w, frame.cell_h };
    const resized = !std.meta.eql(self.placed_cell_size, cell_size);
    var changed = swapping_viewport or resized;
    self.shown.clearRetainingCapacity();
    var batch: Graphics.TmuxBatch = .{ .writer = w };
    for (self.strips.items) |strip| {
        const tile = self.tiles.get(strip.key) orelse continue;
        var p = strip.placement;
        p.id = tile.id;
        try self.shown.put(p.id, p);
        if (self.files.getPtr(p.id)) |file| {
            if (!file.sent or file.refresh) {
                try self.sendLocalImage(&batch, p.id, file.image);
                file.sent = true;
                file.refresh = false;
                file.replay = true;
                self.replay_timer = try std.time.Timer.start();
            } else if (file.replay and self.replay_timer == null) {
                self.replay_timer = try std.time.Timer.start();
            }
        }
        const previous = self.placed.get(p.id);
        if (!resized and previous != null and std.meta.eql(previous.?, p)) continue;
        changed = true;
        if (self.transport == .direct) {
            try sync(w, &syncing);
            // Retain the cached pixels. Older Kitty graphics implementations
            // could leak a placement when a put reused its ID.
            if (previous != null) try w.print("\x1b_Ga=d,d=i,i={d},p=1,q=2\x1b\\", .{p.id});
            try self.place(w, p, 1, below_backgrounds - 2);
        }
    }
    try batch.finish();
    var it = self.placed.keyIterator();
    while (it.next()) |id| {
        if (self.shown.contains(id.*)) continue;
        changed = true;
        if (self.transport == .direct) {
            try sync(w, &syncing);
            try unplace(w, id.*);
        }
    }
    std.mem.swap(std.AutoHashMap(u32, Placement), &self.placed, &self.shown);
    self.placed_cell_size = cell_size;
    if (self.transport == .direct and overlay_changed and (self.pdf.selection_page != null or self.pdf.search_needle != null or
        self.overlay_placed[0] or self.overlay_placed[1] or self.overlay_placed[2]))
    {
        try sync(w, &syncing);
        try self.presentHighlights(w, units);
    }
    if (syncing) try w.writeAll("\x1b8\x1b[?2026l");
    _ = try self.reserve(w, 0, false);
    self.previous_frame = frame;
    self.previous_highlights = highlights;
    return changed;
}

pub fn drawTmux(self: *Self, win: vaxis.Window, arena: std.mem.Allocator) !void {
    try self.eachTmuxTile(win, arena, Tmux.drawTile);
}

/// Run after every overlay is drawn; see `Tmux.repairRuns`.
pub fn repairTmuxRuns(self: *Self, win: vaxis.Window, arena: std.mem.Allocator) !void {
    try self.eachTmuxTile(win, arena, Tmux.repairRuns);
}

fn eachTmuxTile(self: *Self, win: vaxis.Window, arena: std.mem.Allocator, comptime op: anytype) !void {
    if (self.cell_w <= 0 or self.cell_h <= 0) return;
    var it = self.placed.valueIterator();
    while (it.next()) |p| {
        try op(win, arena, p.id, @intCast(@divFloor(p.x, self.cell_w)), @intCast(@divFloor(p.y, self.cell_h)), @intCast(@divFloor(p.sx, self.cell_w)), @intCast(@divFloor(p.sy, self.cell_h)), @intCast(@divFloor(p.sw, self.cell_w)), @intCast(@divFloor(p.sh, self.cell_h)));
    }
}

fn sync(w: *Writer, started: *bool) !void {
    if (started.*) return;
    try w.writeAll("\x1b[?2026h\x1b7");
    started.* = true;
}

fn unplace(w: *Writer, id: u32) !void {
    try w.print("\x1b_Ga=d,d=i,i={d},q=2\x1b\\", .{id});
}

fn place(self: *Self, w: *Writer, p: Placement, placement: u32, z: i32) !void {
    const col = @divFloor(p.x, self.cell_w);
    const row = @divFloor(p.y, self.cell_h);
    try w.print("\x1b[{d};{d}H\x1b_Ga=p,i={d},p={d},x={d},y={d},w={d},h={d},X={d},Y={d},z={d},C=1,q=2\x1b\\", .{
        row + 1,                 col + 1,
        p.id,                    placement,
        p.sx,                    p.sy,
        p.sw,                    p.sh,
        p.x - col * self.cell_w, p.y - row * self.cell_h,
        z,
    });
}

// Reuse one small translucent image per overlay color. Cropping and
// repeating its placements keeps base tile pixels independent of the query.
fn presentHighlights(self: *Self, w: *Writer, units: []const Visible) !void {
    for (self.overlay_images, &self.overlay_placed) |image, *placed| {
        if (placed.*) try unplace(w, image.?);
        placed.* = false;
    }
    var next = [3]u32{ 1, 1, 1 };
    for (units) |v| {
        for (v.layout.columns) |col| {
            const column = col orelse continue;
            const transform = c.fz_concat(column.transform, v.layoutToPixels(self.zoom));
            if (self.pdf.selection_page == column.page) {
                for (self.pdf.selection_quads.items) |quad| {
                    const rect = c.fz_round_rect(c.fz_transform_rect(c.fz_rect_from_quad(quad), transform));
                    try self.placeHighlight(w, rect, .selection, &next);
                }
            }
            for (self.pdf.hitsOn(column.page), 0..) |quad, i| {
                const active = if (self.pdf.search_hit) |hit| hit.page == column.page and hit.index == i else false;
                const rect = c.fz_round_rect(c.fz_transform_rect(c.fz_rect_from_quad(quad), transform));
                try self.placeHighlight(w, rect, if (active) .active_match else .match, &next);
            }
        }
    }
    const selection = @intFromEnum(Overlay.selection);
    if (!self.overlay_placed[selection]) {
        if (self.overlay_images[selection]) |id| try self.disposeImage(w, id);
        self.overlay_images[selection] = null;
    }
}

fn placeHighlight(self: *Self, w: *Writer, rect: c.fz_irect, kind: Overlay, next: *[3]u32) !void {
    var y = @max(rect.y0, 0);
    const bottom = @min(rect.y1, self.height);
    const left = @max(rect.x0, 0);
    const right = @min(rect.x1, self.width);
    if (left >= right or y >= bottom) return;
    const slot = @intFromEnum(kind);
    const id = self.overlay_images[slot] orelse blk: {
        const pixels = switch (kind) {
            inline else => |color| &(color.color() ** (selection_width * selection_height)),
        };
        var encoder: RenderWorker.Encoder = .{ .allocator = self.allocator };
        defer encoder.deinit();
        const image = try encoder.pixels(32, selection_width, selection_height, pixels);
        defer self.allocator.free(image.data);
        const id = self.nextImageId();
        try image.transmit(w, id);
        self.overlay_images[slot] = id;
        break :blk id;
    };
    self.overlay_placed[slot] = true;
    const z = if (kind == .selection) below_backgrounds else below_backgrounds - 1;
    while (y < bottom) : (y += selection_height) {
        var x = left;
        while (x < right) : (x += selection_width) {
            try self.place(w, .{
                .id = id,
                .x = x,
                .y = y,
                .sx = 0,
                .sy = 0,
                .sw = @min(selection_width, right - x),
                .sh = @min(selection_height, bottom - y),
            }, next[slot], z);
            next[slot] += 1;
        }
    }
}

fn disposeImage(self: *Self, w: *Writer, id: u32) !void {
    if (self.files.fetchRemove(id)) |entry| {
        entry.value.image.deinit(self.allocator);
        if (entry.value.sent) {
            // The old placeholder grid can still be on screen when the
            // replacement is queued. Retire its images after the redraw.
            try self.retired_images.append(self.allocator, id);
            self.retire_timer = try std.time.Timer.start();
        }
        return;
    }
    if (self.transport == .direct) try Graphics.delete(w, id);
}

fn sendLocalImage(self: *Self, batch: *Graphics.TmuxBatch, id: u32, image: RenderWorker.Image) !void {
    try image.transmitFile(batch, id, image.width / @as(usize, @intCast(self.cell_w)), image.height / @as(usize, @intCast(self.cell_h)));
}

fn deleteRetired(self: *Self, batch: *Graphics.TmuxBatch) !void {
    for (self.retired_images.items) |id| try batch.deleteImage(id);
    self.retired_images.clearRetainingCapacity();
    self.retire_timer = null;
}

fn remaining(timer: *?std.time.Timer, delay: u64) ?u64 {
    const clock = if (timer.*) |*value| value else return null;
    return delay -| clock.read();
}

pub fn tmuxDelay(self: *Self) ?u64 {
    const replay = remaining(&self.replay_timer, replay_delay);
    const retire = remaining(&self.retire_timer, retire_delay);
    if (replay == null) return retire;
    if (retire == null) return replay;
    return @min(replay.?, retire.?);
}

/// tmux can discard passthrough while a client is redrawing. Replay new
/// visible uploads once, after the placeholder cells have reached the pane.
pub fn maintainTmuxImages(self: *Self, w: *Writer) !void {
    var batch: Graphics.TmuxBatch = .{ .writer = w };
    if (remaining(&self.retire_timer, retire_delay) == 0) try self.deleteRetired(&batch);
    if (remaining(&self.replay_timer, replay_delay) == 0) {
        self.replay_timer = null;
        var it = self.placed.keyIterator();
        while (it.next()) |id| {
            const file = self.files.getPtr(id.*) orelse continue;
            if (!file.replay) continue;
            try self.sendLocalImage(&batch, id.*, file.image);
            file.replay = false;
        }
    }
    try batch.finish();
}

fn unlink(self: *Self, tile: Tile) void {
    if (tile.older) |older| self.tiles.getPtr(older).?.newer = tile.newer else self.oldest = tile.newer;
    if (tile.newer) |newer| self.tiles.getPtr(newer).?.older = tile.older else self.newest = tile.older;
}

fn appendNewest(self: *Self, key: TileKey, tile: *Tile) void {
    tile.older = self.newest;
    tile.newer = null;
    if (self.newest) |newest| self.tiles.getPtr(newest).?.newer = key else self.oldest = key;
    self.newest = key;
}

fn touch(self: *Self, key: TileKey, tile: *Tile) void {
    if (tile.newer == null) return;
    self.unlink(tile.*);
    self.appendNewest(key, tile);
}

// Reserve before transmitting. The displayed and incoming viewports can
// temporarily share space during a swap. Prefetch stays within the budget.
fn reserve(self: *Self, w: *Writer, bytes: usize, foreground: bool) !bool {
    var candidate = self.oldest;
    while (self.tile_bytes + bytes > self.budget()) {
        const key = candidate orelse return foreground;
        const tile = self.tiles.get(key).?;
        candidate = tile.newer;
        if (tile.visible == self.tick or (!foreground and tile.nearby == self.tick and bytes != 0)) continue;
        if (self.holding_viewport and self.placed.contains(tile.id)) continue;

        try self.disposeImage(w, tile.id);
        _ = self.placed.remove(tile.id);
        self.unlink(tile);
        _ = self.tiles.remove(key);
        self.tile_bytes -= tile.bytes;
    }
    return true;
}
