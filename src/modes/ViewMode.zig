const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const Commands = @import("../Commands.zig");
const CommandMode = @import("./CommandMode.zig");
const View = @import("../View.zig");
const c = @import("../handlers/PdfHandler.zig").c;

context: *Context,
// Keys of a sequence such as `gg` typed so far, and a count such as the 5 in
// `5J`.
pending: [Config.max_sequence]vaxis.Key = undefined,
pending_len: u8 = 0,
count: ?u32 = null,
// After m or ', the next key names a mark.
mark: ?enum { set, jump } = null,
last_zoom_ms: i64 = 0,
gesture: ?Gesture = null,
last_click: ?Click = null,

const Gesture = struct {
    start: c.fz_point,
    last: c.fz_point,
    page: ?View.PagePoint,
    char: ?c.fz_quad,
    moved: bool = false,
    selection_end: ?c.fz_point = null,
};

const Click = struct { position: c.fz_point, page: u16, timer: std.time.Timer };
const drag_threshold = 3;
const double_click_ns = 350 * std.time.ns_per_ms;

// Terminals send a burst of wheel events per notch (Ghostty's
// mouse-scroll-multiplier); Ctrl+wheel zooms once per burst.
const zoom_notch_ms = 40;

const Action = struct {
    // A KeyMap field name.
    name: []const u8,
    run: *const fn (*Context, ?u32) void,
    scrolls: bool = false,
};

const actions = [_]Action{
    .{ .name = "next", .run = nextPage },
    .{ .name = "prev", .run = prevPage },
    .{ .name = "first_page", .run = firstPage },
    .{ .name = "last_page", .run = lastPage },
    .{ .name = "scroll_up", .run = scrollUp, .scrolls = true },
    .{ .name = "scroll_up_mult", .run = scrollUpMult, .scrolls = true },
    .{ .name = "scroll_down", .run = scrollDown, .scrolls = true },
    .{ .name = "scroll_down_mult", .run = scrollDownMult, .scrolls = true },
    .{ .name = "scroll_left", .run = scrollLeft },
    .{ .name = "scroll_left_mult", .run = scrollLeftMult },
    .{ .name = "scroll_right", .run = scrollRight },
    .{ .name = "scroll_right_mult", .run = scrollRightMult },
    .{ .name = "half_up", .run = halfUp, .scrolls = true },
    .{ .name = "half_down", .run = halfDown, .scrolls = true },
    .{ .name = "half_left", .run = halfLeft },
    .{ .name = "half_right", .run = halfRight },
    .{ .name = "full_up", .run = fullUp, .scrolls = true },
    .{ .name = "full_down", .run = fullDown, .scrolls = true },
    .{ .name = "full_left", .run = fullLeft },
    .{ .name = "full_right", .run = fullRight },
    .{ .name = "page_top", .run = pageTop },
    .{ .name = "page_bottom", .run = pageBottom },
    .{ .name = "snap_to_page", .run = snapToPage },
    .{ .name = "jump_back", .run = jumpBack },
    .{ .name = "jump_forward", .run = jumpForward },
    .{ .name = "mark_set", .run = markSet },
    .{ .name = "mark_jump", .run = markJump },
    .{ .name = "zoom_in", .run = zoomIn },
    .{ .name = "zoom_in_mult", .run = zoomInMult },
    .{ .name = "zoom_out", .run = zoomOut },
    .{ .name = "zoom_out_mult", .run = zoomOutMult },
    .{ .name = "width_mode", .run = widthMode },
    .{ .name = "best_fit", .run = bestFit },
    .{ .name = "dual_page", .run = dualPage },
    .{ .name = "cycle_first_column", .run = cycleFirstColumn },
    .{ .name = "rotate", .run = rotate },
    .{ .name = "search_forward", .run = searchForward },
    .{ .name = "search_backward", .run = searchBackward },
    .{ .name = "search_next", .run = searchNext },
    .{ .name = "search_prev", .run = searchPrev },
    .{ .name = "index", .run = openIndex },
    .{ .name = "follow_link", .run = followLink },
    .{ .name = "display_link", .run = displayLink },
    .{ .name = "copy_link", .run = copyLink },
    .{ .name = "reload", .run = reload },
    .{ .name = "copy_path", .run = copyPath },
    .{ .name = "trim_margins", .run = trimMargins },
    .{ .name = "colorize", .run = colorize },
    .{ .name = "full_screen", .run = fullScreen },
    .{ .name = "enter_command_mode", .run = commandMode },
    .{ .name = "quit", .run = quit },
};

pub fn init(context: *Context) Self {
    return .{
        .context = context,
    };
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    self.cancelMouseGesture();
    self.context.clearMessage();
    if (self.mark) |kind| {
        self.context.finishScroll();
        self.mark = null;
        if (key.matches(vaxis.Key.escape, .{})) return;
        const letter: u21 = if (key.text) |t| (if (t.len == 1) t[0] else 0) else key.codepoint;
        const view = &self.context.view;
        switch (kind) {
            .set => _ = view.setMark(letter),
            .jump => if (!view.goToMark(letter)) self.context.showMessage("Mark not set", .{}),
        }
        return;
    }
    if (self.pending_len == 0 and isCountDigit(key, self.count != null)) {
        const digit = @as(u32, key.codepoint - '0');
        self.count = (self.count orelse 0) *| 10 +| digit;
        return;
    }
    if (key.matches(vaxis.Key.escape, .{})) {
        self.reset();
        self.context.finishScroll();
        self.context.clearSearch();
        self.context.document_handler.pdf_handler.clearSelection();
        return;
    }

    if (self.pending_len == Config.max_sequence) self.pending_len = 0;
    self.pending[self.pending_len] = key;
    self.pending_len += 1;
    if (self.dispatch(km)) return;

    // No binding starts with these keys; try the last one on its own.
    if (self.pending_len > 1) {
        self.pending[0] = key;
        self.pending_len = 1;
        if (self.dispatch(km)) return;
    }
    self.reset();
}

// Runs the action whose binding the pending keys complete. Returns true when
// one ran or when the keys begin a longer binding.
fn dispatch(self: *Self, km: Config.KeyMap) bool {
    const typed = self.pending[0..self.pending_len];
    var waiting = false;
    // Maps come first, so they can replace a built-in binding.
    for (self.context.config.maps) |map| {
        switch (map.binding.match(typed)) {
            .full => {
                const ctx = self.context;
                self.reset();
                ctx.finishScroll();
                Commands.execute(ctx, map.command);
                return true;
            },
            .prefix => waiting = true,
            .none => {},
        }
    }
    inline for (actions) |action| {
        switch (@field(km, action.name).match(typed)) {
            .full => {
                const count = self.count;
                const ctx = self.context;
                self.reset();
                // The action may switch modes, which replaces this ViewMode,
                // so nothing may touch self afterwards.
                if (!action.scrolls) ctx.finishScroll();
                action.run(ctx, count);
                return true;
            },
            .prefix => waiting = true,
            .none => {},
        }
    }
    return waiting;
}

fn reset(self: *Self) void {
    self.pending_len = 0;
    self.count = null;
}

fn isCountDigit(key: vaxis.Key, started: bool) bool {
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return false;
    if (key.codepoint < '0' or key.codepoint > '9') return false;
    return key.codepoint != '0' or started;
}

fn countOf(count: ?u32) u32 {
    return @max(1, @min(count orelse 1, 10_000));
}

fn nextPage(s: *Context, count: ?u32) void {
    s.view.turn(true, countOf(count));
}

fn prevPage(s: *Context, count: ?u32) void {
    s.view.turn(false, countOf(count));
}

// gg: the first page, or page N with a count.
fn firstPage(s: *Context, count: ?u32) void {
    s.view.recordJump();
    s.view.goToPage(@intCast(@min(countOf(count), 65535) - 1));
}

// G: the end of the document, or page N with a count.
fn lastPage(s: *Context, count: ?u32) void {
    s.view.recordJump();
    if (count) |n| {
        s.view.goToPage(@intCast(@min(@max(n, 1), 65535) - 1));
    } else {
        s.view.goToEnd();
    }
}

// Scrolling runs on across pages, as in zathura's continuous view.
fn scrollBy(s: *Context, steps: f32) void {
    s.scroll(steps * s.config.general.scroll_step);
}

fn panBy(s: *Context, steps: f32) void {
    s.view.panBy(steps * s.config.general.scroll_step);
}

fn amount(count: ?u32) f32 {
    return @floatFromInt(countOf(count));
}

fn scrollDown(s: *Context, count: ?u32) void {
    scrollBy(s, amount(count));
}

fn scrollDownMult(s: *Context, count: ?u32) void {
    scrollBy(s, s.config.general.scroll_mult * amount(count));
}

fn scrollUp(s: *Context, count: ?u32) void {
    scrollBy(s, -amount(count));
}

fn scrollUpMult(s: *Context, count: ?u32) void {
    scrollBy(s, -s.config.general.scroll_mult * amount(count));
}

fn scrollLeft(s: *Context, count: ?u32) void {
    panBy(s, -amount(count));
}

fn scrollLeftMult(s: *Context, count: ?u32) void {
    panBy(s, -s.config.general.scroll_mult * amount(count));
}

fn scrollRight(s: *Context, count: ?u32) void {
    panBy(s, amount(count));
}

fn scrollRightMult(s: *Context, count: ?u32) void {
    panBy(s, s.config.general.scroll_mult * amount(count));
}

// Zathura's half and full scrolls move by half or all of the view.
fn scrollView(s: *Context, vertical: bool, fraction: f32, count: ?u32) void {
    const size: f32 = @floatFromInt(if (vertical) s.view.height else s.view.width);
    const by = size * fraction * amount(count);
    if (vertical) s.scroll(by) else s.view.panBy(by);
}

fn halfUp(s: *Context, count: ?u32) void {
    scrollView(s, true, -0.5, count);
}

fn halfDown(s: *Context, count: ?u32) void {
    scrollView(s, true, 0.5, count);
}

fn halfLeft(s: *Context, count: ?u32) void {
    scrollView(s, false, -0.5, count);
}

fn halfRight(s: *Context, count: ?u32) void {
    scrollView(s, false, 0.5, count);
}

fn fullUp(s: *Context, count: ?u32) void {
    scrollView(s, true, -1, count);
}

fn fullDown(s: *Context, count: ?u32) void {
    scrollView(s, true, 1, count);
}

fn fullLeft(s: *Context, count: ?u32) void {
    scrollView(s, false, -1, count);
}

fn fullRight(s: *Context, count: ?u32) void {
    scrollView(s, false, 1, count);
}

fn pageTop(s: *Context, _: ?u32) void {
    s.view.pageTop();
}

fn pageBottom(s: *Context, _: ?u32) void {
    s.view.pageBottom();
}

fn snapToPage(s: *Context, _: ?u32) void {
    s.view.snapToPage();
}

fn jumpBack(s: *Context, _: ?u32) void {
    s.view.jumpBack();
}

fn jumpForward(s: *Context, _: ?u32) void {
    s.view.jumpForward();
}

fn markSet(s: *Context, _: ?u32) void {
    s.current_mode.view.mark = .set;
}

fn markJump(s: *Context, _: ?u32) void {
    s.current_mode.view.mark = .jump;
}

fn zoomBy(s: *Context, in: bool, multiplier: f32, count: ?u32) void {
    const step = s.config.general.zoom_step * multiplier;
    const times: f32 = @floatFromInt(@min(countOf(count), 50));
    const factor = std.math.pow(f32, step, times);
    s.view.zoomBy(if (in) factor else 1 / factor);
}

fn zoomIn(s: *Context, count: ?u32) void {
    zoomBy(s, true, 1.0, count);
}

fn zoomInMult(s: *Context, count: ?u32) void {
    zoomBy(s, true, s.config.general.zoom_mult, count);
}

fn zoomOut(s: *Context, count: ?u32) void {
    zoomBy(s, false, 1.0, count);
}

fn zoomOutMult(s: *Context, count: ?u32) void {
    zoomBy(s, false, s.config.general.zoom_mult, count);
}

fn widthMode(s: *Context, _: ?u32) void {
    s.view.fit(true);
}

fn bestFit(s: *Context, _: ?u32) void {
    s.view.fit(false);
}

// D: page 1 alone on the right of spreads, or paired with page 2.
fn cycleFirstColumn(s: *Context, _: ?u32) void {
    const general = &s.config.general;
    general.first_page_column = if (general.first_page_column == 1) 2 else 1;
    if (s.document_handler.pdf_handler.dual_page) s.view.layoutChanged(s.currentPage());
}

fn dualPage(s: *Context, _: ?u32) void {
    const page = s.currentPage();
    s.document_handler.pdf_handler.toggleDualPage();
    s.view.layoutChanged(page);
}

// r: a quarter turn clockwise, as in zathura.
fn rotate(s: *Context, _: ?u32) void {
    s.document_handler.pdf_handler.rotateClockwise();
    s.view.layoutChanged(s.currentPage());
}

fn prompt(s: *Context, kind: CommandMode.Kind) void {
    s.changeMode(.command);
    s.current_mode.command.kind = kind;
    s.beginSearchPrompt();
}

fn searchForward(s: *Context, _: ?u32) void {
    prompt(s, .search_forward);
}

fn searchBackward(s: *Context, _: ?u32) void {
    prompt(s, .search_backward);
}

// n and N repeat the search, with a count as many times.
fn searchNext(s: *Context, count: ?u32) void {
    s.searchAgain(false, countOf(count));
}

fn searchPrev(s: *Context, count: ?u32) void {
    s.searchAgain(true, countOf(count));
}

fn openIndex(s: *Context, _: ?u32) void {
    s.openIndex();
}

fn followLink(s: *Context, _: ?u32) void {
    s.openHints(.follow);
}

fn displayLink(s: *Context, _: ?u32) void {
    s.openHints(.display);
}

fn copyLink(s: *Context, _: ?u32) void {
    s.openHints(.copy);
}

fn reload(s: *Context, _: ?u32) void {
    s.reload();
}

fn copyPath(s: *Context, _: ?u32) void {
    s.copyToClipboard(s.absolute_path orelse s.document_handler.getPath());
}

fn trimMargins(s: *Context, _: ?u32) void {
    s.document_handler.pdf_handler.toggleTrim();
    s.view.layoutChanged(s.currentPage());
}

fn colorize(s: *Context, _: ?u32) void {
    s.document_handler.toggleColor();
    s.view.redraw();
}

fn fullScreen(s: *Context, _: ?u32) void {
    s.toggleFullScreen();
}

fn commandMode(s: *Context, _: ?u32) void {
    s.changeMode(.command);
}

fn quit(s: *Context, _: ?u32) void {
    s.should_quit = true;
}

pub fn cancelMouseGesture(self: *Self) void {
    self.gesture = null;
    self.last_click = null;
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) !void {
    if (mouse.button == .left or (mouse.button == .none and mouse.type == .release)) {
        try self.handleLeftMouse(mouse);
        return;
    }
    if (mouse.type != .press) return;
    // Shift+wheel and sideways wheel pan. Ctrl+wheel zooms once per notch.
    const s = self.context;
    const step = s.config.general.wheel_step;
    switch (mouse.button) {
        .wheel_up, .wheel_down => {
            const down = mouse.button == .wheel_down;
            if (mouse.mods.ctrl) {
                s.finishScroll();
                const now = std.time.milliTimestamp();
                if (now - self.last_zoom_ms < zoom_notch_ms) return;
                self.last_zoom_ms = now;
                const factor = s.config.general.zoom_step;
                s.view.zoomBy(if (down) 1 / factor else factor);
            } else if (mouse.mods.shift) {
                s.finishScroll();
                s.view.panBy(if (down) step else -step);
            } else {
                s.scroll(if (down) step else -step);
            }
        },
        .wheel_left, .wheel_right => {
            s.finishScroll();
            s.view.panBy(if (mouse.button == .wheel_right) step else -step);
        },
        else => {},
    }
}

fn handleLeftMouse(self: *Self, mouse: vaxis.Mouse) !void {
    if (mouse.mods.ctrl) {
        self.cancelMouseGesture();
        return;
    }
    const s = self.context;
    const view = &s.view;
    const pdf = &s.document_handler.pdf_handler;
    // Finish an existing drag while its highlight is being prepared.
    // A fresh click must wait for the new view to appear.
    if (view.holding_viewport and (mouse.type == .press or self.gesture == null)) return;
    if (view.cell_w <= 0 or view.cell_h <= 0) return;
    const pixel = s.vx.state.pixel_mouse;
    const position = view.mousePoint(
        mouse.col,
        mouse.row,
        if (pixel) mouse.xoffset else @intCast(@divFloor(view.cell_w, 2)),
        if (pixel) mouse.yoffset else @intCast(@divFloor(view.cell_h, 2)),
    );
    switch (mouse.type) {
        .press => {
            self.gesture = null;
            if (position.x >= @as(f32, @floatFromInt(view.width)) or
                position.y >= @as(f32, @floatFromInt(view.height))) return;
            // The click refers to the frame on screen, so stop pending easing.
            s.scroll_animation = null;
            s.clearMessage();
            pdf.clearSelection();
            const page = view.pageAt(position);
            self.gesture = .{
                .start = position,
                .last = position,
                .page = page,
                .char = if (page) |p| pdf.textAt(p.page, p.point) else null,
            };
        },
        .drag => try self.dragTo(position),
        .release => {
            if (self.gesture == null) return;
            try self.dragTo(position);
            const gesture = self.gesture.?;
            self.gesture = null;
            if (gesture.moved) {
                if (gesture.selection_end) |end| self.copyText(gesture.page.?.page, gesture.page.?.point, end);
                return;
            }
            const page = gesture.page orelse {
                self.last_click = null;
                return;
            };
            if (try pdf.linkAt(page.page, page.point)) |uri| {
                defer s.allocator.free(uri);
                self.last_click = null;
                s.followLink(uri);
            } else if (gesture.char) |quad| {
                if (self.last_click) |*click| {
                    if (click.page == page.page and mouseDistance(click.position, position) <= drag_threshold and
                        click.timer.read() <= double_click_ns)
                    {
                        self.last_click = null;
                        // Put both ends inside the clicked glyph, so a click
                        // on the last glyph of a word stays in that word.
                        var a = glyphEdge(quad.ul, quad.ll, quad.ur, quad.lr);
                        var b = glyphEdge(quad.ur, quad.lr, quad.ul, quad.ll);
                        pdf.snapWord(page.page, &a, &b);
                        try pdf.highlightSelection(page.page, a, b);
                        self.copyText(page.page, a, b);
                        return;
                    }
                }
                self.last_click = null;
                if (std.time.Timer.start()) |timer| {
                    self.last_click = .{ .position = position, .page = page.page, .timer = timer };
                } else |_| {}
            } else {
                self.last_click = null;
            }
        },
        .motion => {},
    }
}

fn mouseDistance(a: c.fz_point, b: c.fz_point) f32 {
    return @max(@abs(a.x - b.x), @abs(a.y - b.y));
}

fn glyphEdge(a: c.fz_point, b: c.fz_point, opposite_a: c.fz_point, opposite_b: c.fz_point) c.fz_point {
    return .{
        .x = 0.45 * (a.x + b.x) + 0.05 * (opposite_a.x + opposite_b.x),
        .y = 0.45 * (a.y + b.y) + 0.05 * (opposite_a.y + opposite_b.y),
    };
}

fn dragTo(self: *Self, position: c.fz_point) !void {
    const gesture = if (self.gesture) |*active| active else return;
    if (!gesture.moved and mouseDistance(gesture.start, position) <= drag_threshold) return;
    if (mouseDistance(gesture.last, position) == 0) return;
    const s = self.context;
    gesture.moved = true;
    self.last_click = null;
    if (gesture.char != null) {
        const page = gesture.page.?;
        if (s.view.pointOnPage(page.page, position)) |end| {
            try s.document_handler.pdf_handler.highlightSelection(page.page, page.point, end);
            gesture.selection_end = end;
        }
    } else {
        s.view.scrollBy(gesture.last.y - position.y);
        s.view.panBy(gesture.last.x - position.x);
    }
    gesture.last = position;
}

fn copyText(self: *Self, page: u16, a: c.fz_point, b: c.fz_point) void {
    const pdf = &self.context.document_handler.pdf_handler;
    const text = pdf.copySelection(page, a, b) orelse return;
    defer c.fz_free(pdf.ctx, text);
    const utf8 = std.mem.span(text);
    if (utf8.len != 0) self.context.copyToClipboard(utf8);
}
