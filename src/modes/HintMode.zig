//! Link hints, as zathura's f: each link in view gets a number. Typing it
//! follows the link once no longer number could match; Enter follows what is
//! typed, Backspace deletes a digit, and Escape or q cancel.
const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const c = @import("../handlers/PdfHandler.zig").c;
const View = @import("../View.zig");

const Hint = struct {
    // The link's top-left corner, in pixels from the view's top-left.
    x: f32,
    y: f32,
    uri: [:0]u8,
    // Drawn text must outlive the frame, so the label lives here.
    label: [8]u8 = undefined,
    label_len: u8 = 0,
};

/// What choosing a link does: f follows it, F shows its target, c copies it.
pub const Kind = enum { follow, display, copy };

context: *Context,
kind: Kind,
hints: std.ArrayList(Hint) = .{},
typed: u32 = 0,

/// Null when no link is in view.
pub fn init(context: *Context, kind: Kind) ?Self {
    var self = Self{ .context = context, .kind = kind };
    self.collect() catch {
        self.deinit();
        return null;
    };
    if (self.hints.items.len == 0) {
        self.deinit();
        return null;
    }
    for (self.hints.items, 1..) |*hint, number| {
        const text = std.fmt.bufPrint(&hint.label, "{d}", .{number}) catch "";
        hint.label_len = @intCast(text.len);
    }
    return self;
}

pub fn deinit(self: *Self) void {
    for (self.hints.items) |hint| self.context.allocator.free(hint.uri);
    self.hints.deinit(self.context.allocator);
}

// The links at least partly in view, ordered top to bottom, then left to
// right.
fn collect(self: *Self) !void {
    const allocator = self.context.allocator;
    const pdf = &self.context.document_handler.pdf_handler;
    const view = &self.context.view;
    const width: f32 = @floatFromInt(view.width);
    const height: f32 = @floatFromInt(view.height);
    var buf: [View.max_visible]View.Visible = undefined;
    for (view.visible(&buf)) |v| {
        const to_view = v.layoutToPixels(view.zoom);
        for (v.layout.columns) |column| {
            const col = column orelse continue;
            const page = c.fz_load_page_z(pdf.ctx, pdf.doc, @as(c_int, col.page));
            if (page == null) continue;
            defer c.fz_drop_page(pdf.ctx, page);
            const links = c.fz_load_links_z(pdf.ctx, page);
            defer c.fz_drop_link(pdf.ctx, links);

            var link = links;
            while (link != null) : (link = link.*.next) {
                if (link.*.uri == null) continue;
                const on_layout = c.fz_transform_rect(link.*.rect, col.transform);
                const r = c.fz_transform_rect(on_layout, to_view);
                if (r.x1 <= 0 or r.y1 <= 0 or r.x0 >= width or r.y0 >= height) continue;
                const uri = try allocator.dupeZ(u8, std.mem.span(link.*.uri));
                errdefer allocator.free(uri);
                try self.hints.append(allocator, .{ .x = @max(r.x0, 0), .y = @max(r.y0, 0), .uri = uri });
            }
        }
    }
    std.mem.sort(Hint, self.hints.items, {}, before);
}

fn before(_: void, a: Hint, b: Hint) bool {
    if (a.y != b.y) return a.y < b.y;
    return a.x < b.x;
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, _: Config.KeyMap) !void {
    const count = self.hints.items.len;
    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
        self.context.changeMode(.view);
    } else if (key.matches(vaxis.Key.backspace, .{})) {
        self.typed /= 10;
    } else if (key.matches(vaxis.Key.enter, .{})) {
        if (self.typed >= 1 and self.typed <= count) {
            self.follow(self.typed - 1);
        } else {
            self.context.changeMode(.view);
        }
    } else if (!key.mods.ctrl and !key.mods.alt and key.codepoint >= '0' and key.codepoint <= '9') {
        const typed = self.typed *| 10 +| @as(u32, key.codepoint - '0');
        if (typed == 0 or typed > count) return;
        self.typed = typed;
        // Follow at once unless another digit could pick a different link.
        if (@as(usize, typed) * 10 > count) self.follow(typed - 1);
    }
}

// Opens external links with xdg-open; internal ones jump to their target.
fn follow(self: *Self, i: usize) void {
    const ctx = self.context;
    const pdf = &ctx.document_handler.pdf_handler;
    const uri = self.hints.items[i].uri;

    switch (self.kind) {
        .follow => {},
        .copy => {
            ctx.copyToClipboard(uri);
            ctx.changeMode(.view);
            return;
        },
        .display => {
            var x: f32 = 0;
            var y: f32 = 0;
            const page = if (c.fz_is_external_link(pdf.ctx, uri.ptr) != 0)
                -1
            else
                c.fz_resolve_link_page_z(pdf.ctx, pdf.doc, uri.ptr, &x, &y);
            if (page >= 0) ctx.showMessage("Page {d}", .{page + 1}) else ctx.showMessage("{s}", .{uri});
            // Leaving frees uri; the message holds a copy.
            ctx.changeMode(.view);
            return;
        },
    }

    ctx.followLink(uri);
    ctx.changeMode(.view);
}

/// Labels each link, over the page, at its top-left corner; labels that no
/// longer match the typed digits are hidden.
pub fn draw(self: *Self, win: vaxis.Window, view: *View) void {
    if (view.cell_w <= 0 or view.cell_h <= 0) return;
    const cell_w: f32 = @floatFromInt(view.cell_w);
    const cell_h: f32 = @floatFromInt(view.cell_h);

    var typed_buf: [12]u8 = undefined;
    const typed = if (self.typed > 0) std.fmt.bufPrint(&typed_buf, "{d}", .{self.typed}) catch "" else "";
    const style = vaxis.Cell.Style{
        .fg = .{ .rgb = .{ 0, 0, 0 } },
        .bg = .{ .rgb = .{ 255, 230, 0 } },
        .bold = true,
    };
    for (self.hints.items) |*hint| {
        const label = hint.label[0..hint.label_len];
        if (!std.mem.startsWith(u8, label, typed)) continue;
        const col: u32 = @intFromFloat(hint.x / cell_w);
        const row: u32 = @intFromFloat(hint.y / cell_h);
        if (col >= win.width or row >= win.height) continue;
        _ = win.print(&.{.{ .text = label, .style = style }}, .{
            .col_offset = @intCast(col),
            .row_offset = @intCast(row),
            .wrap = .none,
        });
    }
}
