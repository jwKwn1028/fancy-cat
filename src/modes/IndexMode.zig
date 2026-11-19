//! The document outline, opened with Tab as zathura's index: j/k move, l/h
//! open and close entries, gg/G go to the first and last, Enter jumps, and
//! Tab, Escape or q close it.
const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const c = @import("../handlers/PdfHandler.zig").c;

const Entry = struct {
    node: [*c]c.fz_outline,
    depth: u16,
    // 0-based, or -1 for entries without a page in this document.
    page: i32,
    // The page number as drawn; drawn text must outlive the frame.
    number: [12]u8 = undefined,
    number_len: u8 = 0,
};

context: *Context,
outline: [*c]c.fz_outline,
// The visible entries; children show while their parent is open.
entries: std.ArrayList(Entry) = .{},
selected: usize = 0,
top: usize = 0,
pending_g: bool = false,

/// Null when the document has no outline.
pub fn init(context: *Context) ?Self {
    const pdf = &context.document_handler.pdf_handler;
    const outline = c.fz_load_outline_z(pdf.ctx, pdf.doc);
    if (outline == null) return null;

    var self = Self{ .context = context, .outline = outline };
    self.rebuild() catch {
        self.deinit();
        return null;
    };
    if (self.entries.items.len == 0) {
        self.deinit();
        return null;
    }
    // Start on the last entry at or before the current page.
    const current: i32 = context.currentPage();
    for (self.entries.items, 0..) |entry, i| {
        if (entry.page >= 0 and entry.page <= current) self.selected = i;
    }
    return self;
}

pub fn deinit(self: *Self) void {
    self.entries.deinit(self.context.allocator);
    c.fz_drop_outline(self.context.document_handler.pdf_handler.ctx, self.outline);
}

fn rebuild(self: *Self) error{OutOfMemory}!void {
    self.entries.clearRetainingCapacity();
    try self.walk(self.outline, 0);
    if (self.selected >= self.entries.items.len) self.selected = self.entries.items.len -| 1;
}

fn walk(self: *Self, first: [*c]c.fz_outline, depth: u16) error{OutOfMemory}!void {
    const pdf = &self.context.document_handler.pdf_handler;
    var node = first;
    while (node != null) : (node = node.*.next) {
        const page = c.fz_outline_page_z(pdf.ctx, pdf.doc, node);
        var entry = Entry{ .node = node, .depth = depth, .page = page };
        if (page >= 0) {
            const text = std.fmt.bufPrint(&entry.number, " {d}", .{page + 1}) catch "";
            entry.number_len = @intCast(text.len);
        }
        try self.entries.append(self.context.allocator, entry);
        if (node.*.is_open != 0 and node.*.down != null) try self.walk(node.*.down, depth + 1);
    }
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, _: Config.KeyMap) !void {
    const was_g = self.pending_g;
    self.pending_g = false;
    const last = self.entries.items.len -| 1;

    if (key.matches(vaxis.Key.escape, .{}) or key.matches(vaxis.Key.tab, .{}) or key.matches('q', .{})) {
        self.context.changeMode(.view);
    } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
        self.jump();
    } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        self.selected = @min(self.selected + 1, last);
    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        self.selected -|= 1;
    } else if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
        try self.setOpen(true);
    } else if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
        try self.close();
    } else if (key.matches('g', .{})) {
        if (was_g) self.selected = 0 else self.pending_g = true;
    } else if (key.matches('g', .{ .shift = true })) {
        self.selected = last;
    }
}

fn setOpen(self: *Self, open: bool) !void {
    const node = self.entries.items[self.selected].node;
    if (node.*.down == null) return;
    node.*.is_open = @intFromBool(open);
    try self.rebuild();
}

// h closes an open entry, or moves to the parent of a closed one.
fn close(self: *Self) !void {
    const entry = self.entries.items[self.selected];
    if (entry.node.*.down != null and entry.node.*.is_open != 0) return self.setOpen(false);
    var i = self.selected;
    while (i > 0) {
        i -= 1;
        if (self.entries.items[i].depth < entry.depth) {
            self.selected = i;
            return;
        }
    }
}

// Goes to the entry's page and position, and back to the page view.
fn jump(self: *Self) void {
    const entry = self.entries.items[self.selected];
    if (entry.page < 0) return;
    const page: u16 = @intCast(entry.page);
    const y = entry.node.*.y;
    const ctx = self.context;
    // Leaving drops the outline and this IndexMode; use only copies after.
    ctx.changeMode(.view);
    ctx.view.recordJump();
    ctx.view.goToPoint(page, y);
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const rows: usize = win.height;
    if (rows == 0 or self.entries.items.len == 0) return;
    if (self.selected < self.top) self.top = self.selected;
    if (self.selected >= self.top + rows) self.top = self.selected + 1 - rows;

    const end = @min(self.entries.items.len, self.top + rows);
    for (self.entries.items[self.top..end], 0..) |*entry, row| {
        const node = entry.node;
        const style = vaxis.Cell.Style{ .reverse = self.top + row == self.selected };
        const line = win.child(.{ .y_off = @intCast(row), .height = 1 });
        line.fill(.{ .style = style });

        const marker = if (node.*.down == null) "  " else if (node.*.is_open != 0) "▾ " else "▸ ";
        const title: []const u8 = if (node.*.title != null) std.mem.span(node.*.title) else "";
        const indent: u16 = @intCast(@min(@as(usize, entry.depth) * 2, win.width));
        _ = line.print(&.{
            .{ .text = marker, .style = style },
            .{ .text = title, .style = style },
        }, .{ .col_offset = indent, .wrap = .none });

        const number = entry.number[0..entry.number_len];
        _ = line.print(&.{.{ .text = number, .style = style }}, .{
            .col_offset = @intCast(win.width -| number.len),
            .wrap = .none,
        });
    }
}
