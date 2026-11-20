const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const Commands = @import("../Commands.zig");
const TextInput = vaxis.widgets.TextInput;

pub const Kind = enum { command, search_forward, search_backward };

context: *Context,
text_input: TextInput,
history_prefix: ?[]const u8 = null,
kind: Kind = .command,
// Wait for a short pause before starting a new incremental query.
search_timer: ?std.time.Timer = null,

pub fn init(context: *Context) Self {
    return .{
        .context = context,
        .text_input = TextInput.init(context.allocator),
    };
}

pub fn deinit(self: *Self) void {
    const win = self.context.vx.window();
    win.hideCursor();
    self.text_input.deinit();
    if (self.history_prefix) |history_prefix| self.context.allocator.free(history_prefix);
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    if (km.exit_command_mode.matchesKey(key) or
        (key.matches(vaxis.Key.backspace, .{}) and self.text_input.buf.realLength() == 0))
    {
        const ctx = self.context;
        const searching = self.kind != .command;
        ctx.changeMode(.view);
        if (searching) ctx.cancelSearchPrompt();
        return;
    }

    if (km.execute_command.matchesKey(key)) {
        // Leaving the prompt replaces this CommandMode, so keep what is needed.
        const ctx = self.context;
        const kind = self.kind;
        const text_input = try self.text_input.buf.toOwnedSlice();
        defer ctx.allocator.free(text_input);
        ctx.changeMode(.view);

        const line = std.mem.trim(u8, text_input, &std.ascii.whitespace);
        if (line.len > 0) {
            switch (kind) {
                .command => {
                    ctx.history.addToHistory(line);
                    Commands.execute(ctx, line);
                },
                .search_forward => ctx.search(line, false),
                .search_backward => ctx.search(line, true),
            }
        } else if (kind != .command) {
            ctx.cancelSearchPrompt();
        }
        return;
    }

    // Command history
    if (self.kind == .command and (km.history_back.matchesKey(key) or km.history_forward.matchesKey(key))) {
        if (self.history_prefix == null) {
            const text_input = try self.text_input.buf.toOwnedSlice();
            defer self.context.allocator.free(text_input);
            self.history_prefix = try self.context.allocator.dupe(u8, text_input);
        }

        const history_prefix = self.history_prefix.?;
        var filtered = std.ArrayList([]const u8){};
        defer filtered.deinit(self.context.allocator);

        for (self.context.history.items.items) |cmd| {
            if (std.mem.startsWith(u8, cmd, history_prefix)) {
                try filtered.append(self.context.allocator, cmd);
            }
        }

        const count = @as(isize, @intCast(filtered.items.len));
        if (count > 0) {
            if (km.history_back.matchesKey(key)) {
                if (self.context.history.index == -1) {
                    self.context.history.index = count - 1;
                } else if (self.context.history.index > 0) {
                    self.context.history.index -= 1;
                }
            } else if (km.history_forward.matchesKey(key)) {
                if (self.context.history.index >= 0 and self.context.history.index < count - 1) {
                    self.context.history.index += 1;
                } else {
                    self.context.history.index = -1;
                }
            }
        }

        const input_to_display = if (self.context.history.index == -1 or count == 0)
            history_prefix
        else
            filtered.items[@as(usize, @intCast(self.context.history.index))];

        self.text_input.buf.clearRetainingCapacity();
        self.text_input.reset();
        try self.text_input.insertSliceAtCursor(input_to_display);

        return;
    }

    if (self.history_prefix) |history_prefix| {
        self.context.allocator.free(history_prefix);
        self.history_prefix = null;
    }
    self.context.history.index = -1;

    try self.text_input.update(.{ .key_press = key });
    self.restartSearch();
}

pub fn restartSearch(self: *Self) void {
    if (self.kind == .command or !self.context.config.general.incremental_search) return;
    self.context.invalidateSearchPreview();
    self.search_timer = std.time.Timer.start() catch null;
}

pub fn searchDelay(self: *Self) ?u64 {
    const timer = if (self.search_timer) |*timer| timer else return null;
    return 30 * std.time.ns_per_ms -| timer.read();
}

pub fn runSearch(self: *Self) void {
    self.search_timer = null;
    const buf = self.text_input.buf;
    const text = std.mem.concat(self.context.allocator, u8, &.{ buf.firstHalf(), buf.secondHalf() }) catch return;
    defer self.context.allocator.free(text);
    const needle = std.mem.trim(u8, text, &std.ascii.whitespace);
    self.context.searchAsYouType(needle, self.kind == .search_backward);
}

pub fn drawCommandBar(self: *Self, win: vaxis.Window, style: vaxis.Cell.Style) void {
    const command_bar = win.child(.{
        .x_off = 0,
        .y_off = win.height - 1,
        .width = win.width,
        .height = 1,
    });
    const prompt = switch (self.kind) {
        .command => ":",
        .search_forward => "/",
        .search_backward => "?",
    };
    _ = command_bar.print(&.{.{ .text = prompt, .style = style }}, .{ .col_offset = 0 });

    self.text_input.drawWithStyle(command_bar.child(.{ .x_off = 1 }), style);
}

pub fn executeCommand(self: *Self, cmd: []const u8) void {
    Commands.execute(self.context, cmd);
}
