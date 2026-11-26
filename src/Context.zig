const std = @import("std");
const vaxis = @import("vaxis");
const ViewMode = @import("modes/ViewMode.zig");
const CommandMode = @import("modes/CommandMode.zig");
const IndexMode = @import("modes/IndexMode.zig");
const HintMode = @import("modes/HintMode.zig");
const Config = @import("config/Config.zig");
const DocumentHandler = @import("handlers/DocumentHandler.zig");
const PdfHandler = @import("handlers/PdfHandler.zig");
const View = @import("View.zig");
const Tmux = @import("Tmux.zig");
const RenderWorker = @import("RenderWorker.zig");
const ReloadWorker = @import("services/ReloadWorker.zig");
const Snapshot = @import("services/PdfSnapshot.zig");
const History = @import("services/History.zig");
const Positions = @import("services/Positions.zig");
const Spawn = @import("utilities/Spawn.zig");

const Preview = @import("services/Preview.zig");

pub const panic = vaxis.panic_handler;

pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    reload_ready,
    focus_in,
    terminate,
};

/// SIGTERM or SIGHUP (shutdown, closed pane) wakes the loop through a pipe: the handler only writes.
const Termination = struct {
    var pipe: [2]std.posix.fd_t = .{ -1, -1 };

    fn handle(_: c_int) callconv(.c) void {
        _ = std.posix.write(pipe[1], "x") catch {};
    }

    fn watch(loop: *vaxis.Loop(Event)) void {
        var byte: [1]u8 = undefined;
        _ = std.posix.read(pipe[0], &byte) catch return;
        loop.postEvent(.terminate);
    }

    fn install(loop: *vaxis.Loop(Event)) void {
        pipe = std.posix.pipe2(.{ .CLOEXEC = true }) catch return;
        const thread = std.Thread.spawn(.{}, watch, .{loop}) catch return;
        thread.detach();
        var act = std.posix.Sigaction{ .handler = .{ .handler = handle }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
        std.posix.sigaction(std.posix.SIG.HUP, &act, null);
    }
};

pub const ModeType = enum { view, command, index, hints };
pub const Mode = union(ModeType) { view: ViewMode, command: CommandMode, index: IndexMode, hints: HintMode };
pub const ReloadIndicatorState = enum { idle, reload, watching };

pub const Context = struct {
    const Self = @This();
    const scroll_frame_ns = std.time.ns_per_s / 60;
    /// Remember a page once it has been shown this long.
    const position_settle_ns = std.time.ns_per_s;
    const reload_message = "Could not reload PDF. Still showing the previous version.";

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    should_quit: bool,
    inverse_program: ?[]const u8 = null,
    inverse_resolver: ?[]const u8 = null,
    pointer: ?vaxis.Mouse = null,
    socket_path: ?[]const u8 = null,
    remote_buf: [Preview.limit]u8 = undefined,
    remote_len: usize = 0,
    remote_waiting: bool = false,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    document_handler: DocumentHandler,
    status_path: []u8,
    view: View,
    config: *Config,
    current_mode: Mode,
    history: History,
    reloader: ?*ReloadWorker = null,
    reload_timer: ?std.time.Timer = null,
    current_reload_indicator_state: ReloadIndicatorState,
    reload_indicator_active: bool,
    buf: []u8,
    absolute_path: ?[]u8,
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,
    tmux_cell: ?Tmux.CellSize = null,
    ui_dirty: bool = true,
    status_page: ?u16 = null,
    search_task: ?SearchTask = null,
    preview_current: bool = false,
    repeats: std.ArrayList(Repeat) = .empty,
    search_origin: ?View.Position = null,
    scroll_animation: ?[3]f32 = null,
    saved_page: u16 = 0,
    pending_page: u16 = 0,
    position_clock: ?std.time.Timer = null,

    const Repeat = struct { reverse: bool, count: u32 };
    const SearchTask = struct {
        cursor: PdfHandler.Search,
        purpose: enum { preview, commit, repeat },
        remaining: u32 = 1,
    };

    pub fn init(allocator: std.mem.Allocator, path: []const u8, initial_page: ?u16) !Self {
        const config = try allocator.create(Config);
        errdefer allocator.destroy(config);
        config.* = Config.init(allocator);
        errdefer config.deinit();

        var document_handler = try DocumentHandler.init(allocator, path, initial_page, config);
        errdefer document_handler.deinit();

        const absolute_path = std.fs.cwd().realpathAlloc(allocator, path) catch null;
        errdefer if (absolute_path) |p| allocator.free(p);
        const status_path = try formatStatusPath(allocator, absolute_path orelse path);
        errdefer allocator.free(status_path);
        var start_page = document_handler.initial_page;
        if (initial_page == null and config.general.remember_page) {
            if (absolute_path) |p| {
                if (Positions.load(allocator, p)) |page| {
                    if (page >= 1 and page <= document_handler.getTotalPages()) start_page = page - 1;
                }
            }
        }

        const vx = try vaxis.init(allocator, .{});
        const buf = try allocator.alloc(u8, 4096);
        const tty = try vaxis.Tty.init(buf);
        const history = History.init(allocator, config);
        var view = View.init(allocator, config, start_page);
        const tmux = Tmux.client(allocator);
        if (tmux != null and tmux.?.inline_graphics) {
            view.transport = .tmux;
            view.next_id = std.crypto.random.int(u32) | 1;
        }

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .should_quit = false,
            .tty = tty,
            .vx = vx,
            .document_handler = document_handler,
            .status_path = status_path,
            .view = view,
            .tmux_cell = if (view.transport == .tmux) tmux.?.size else null,
            .config = config,
            .current_mode = undefined,
            .history = history,
            .current_reload_indicator_state = .idle,
            .reload_indicator_active = false,
            .buf = buf,
            .absolute_path = absolute_path,
            .saved_page = start_page + 1,
            .pending_page = start_page + 1,
        };
    }

    pub fn deinit(self: *Self) void {
        self.leaveMode();
        self.allocator.free(self.status_path);

        self.history.deinit();
        self.repeats.deinit(self.allocator);
        self.savePosition();
        if (self.absolute_path) |p| self.allocator.free(p);
        self.view.deinit(self.tty.writer());
        self.document_handler.deinit();
        if (self.config.general.progress_bar) self.tty.writer().writeAll("\x1b]9;4;0;0\x07") catch {};
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.config.deinit();
        self.allocator.destroy(self.config);
        self.arena.deinit();
        self.allocator.free(self.buf);
    }

    fn reloadReady(context: *anyopaque) void {
        const loop: *vaxis.Loop(Event) = @ptrCast(@alignCast(context));
        loop.postEvent(.reload_ready);
    }

    fn stopReloader(reloader: *ReloadWorker, loop: *vaxis.Loop(Event)) void {
        reloader.beginStop();
        // The worker may be posting its final notification to a full queue.
        while (!reloader.stopped.load(.acquire)) {
            while (loop.tryEvent() != null) {}
            std.Thread.sleep(std.time.ns_per_ms);
        }
        reloader.join();
    }

    pub fn run(self: *Self) !void {
        self.current_mode = .{ .view = ViewMode.init(self) };
        self.view.attach(&self.document_handler.pdf_handler);

        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };

        try loop.init();
        try loop.start();
        defer loop.stop();
        Termination.install(&loop);
        try self.vx.enterAltScreen(self.tty.writer());
        if (self.view.transport == .tmux) {
            // Focus events prompt fresh uploads when a client attaches.
            try self.tty.writer().writeAll("\x1b[?1004h\x1b[>4;2m");
            if (vaxis.Tty.getWinsize(self.tty.fd)) |ws| loop.postEvent(.{ .winsize = ws }) else |_| {}
        } else {
            try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);
            if (!self.vx.caps.kitty_graphics) return error.NoGraphicsCapability;
        }
        defer if (self.view.transport == .tmux) {
            self.tty.writer().writeAll("\x1b[?1004l\x1b[>4;0m") catch {};
        };
        // The view places its own images; vaxis would delete them every frame.
        self.vx.caps.kitty_graphics = false;
        try self.vx.setMouseMode(self.tty.writer(), true);
        // Title the terminal (or tmux pane) after the document; restore the old title on exit.
        const name = std.fs.path.basename(self.document_handler.getPath());
        const titled = for (name) |c| {
            if (c < 0x20 or c == 0x7f) break false;
        } else true;
        if (titled) {
            try self.tty.writer().writeAll("\x1b[22;2t");
            try self.vx.setTitle(self.tty.writer(), name);
        }
        defer if (titled) {
            self.tty.writer().writeAll("\x1b[23;2t") catch {};
        };

        if (self.config.file_monitor.enabled) {
            self.current_reload_indicator_state = .watching;
            if (self.config.file_monitor.reload_indicator_duration > 0) {
                self.reload_indicator_active = self.config.general.progress_bar;
                if (!self.reload_indicator_active and self.config.status_bar.enabled) {
                    for (self.config.status_bar.items) |item| {
                        if (item == .reload_aware) {
                            self.reload_indicator_active = true;
                            break;
                        }
                    }
                }
            }
        }

        var worker: RenderWorker = .{
            .allocator = self.allocator,
            .path = self.document_handler.pdf_handler.path,
            .config = self.config.*,
        };
        try worker.launch();
        defer worker.stop();

        var reloader: ReloadWorker = .{
            .allocator = self.allocator,
            .path = self.document_handler.getPath(),
            .config = self.config,
            .monitor = self.config.file_monitor,
            .initial = self.document_handler.pdf_handler.snapshot.stamp,
            .notify = reloadReady,
            .notify_context = &loop,
            .delay = ReloadWorker.seconds(self.config.general.retry_delay),
            .timeout = ReloadWorker.seconds(self.config.general.timeout),
            .clock = try std.time.Timer.start(),
        };
        try reloader.launch();
        self.reloader = &reloader;
        defer {
            self.reloader = null;
            stopReloader(&reloader, &loop);
        }

        const remote = if (self.socket_path) |path| try Preview.listen(path) else null;
        defer if (remote) |fd| {
            std.posix.close(fd);
            std.fs.cwd().deleteFile(self.socket_path.?) catch {};
        };

        var frame_clock = try std.time.Timer.start();
        var wheel: i64 = 0;
        var wheel_clock: ?std.time.Timer = null;
        const tmux_wheel_interval = 12 * std.time.ns_per_ms;
        while (!self.should_quit) {
            const search_delay = if (self.current_mode == .command) self.current_mode.command.searchDelay() else null;
            const indicator_delay = self.indicatorDelay();
            var idle_delay = indicator_delay;
            const wheel_delay = if (wheel != 0 and wheel_clock != null) tmux_wheel_interval -| wheel_clock.?.read() else null;
            for ([_]?u64{ search_delay, self.view.tmuxDelay(), wheel_delay, self.positionDelay() }) |pending| {
                if (pending) |delay| idle_delay = @min(delay, idle_delay orelse delay);
            }
            if (self.scroll_animation != null) {
                std.Thread.sleep(scroll_frame_ns -| frame_clock.read());
            } else if (self.search_task == null and loop.queue.isEmpty() and !worker.waitForWork()) {
                if (idle_delay) |delay| {
                    if (delay > 0) std.Thread.sleep(@min(delay, 3 * std.time.ns_per_ms));
                } else if (remote) |fd| {
                    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
                    _ = try std.posix.poll(&fds, 20);
                } else {
                    loop.pollEvent();
                }
            }

            while (loop.tryEvent()) |event| {
                if (event == .terminate) {
                    // Save now: stopping the terminal reader can wait on a terminal that is gone.
                    self.savePosition();
                    self.should_quit = true;
                    continue;
                }
                if (event == .mouse) self.pointer = event.mouse;
                if (self.should_quit or event == .reload_ready or (event == .mouse and event.mouse.type == .motion)) continue;
                if (self.wheelDirection(event)) |direction| {
                    if (wheel != 0 and (wheel > 0) != (direction > 0)) self.flushWheel(&wheel);
                    wheel += direction;
                    continue;
                }
                self.flushWheel(&wheel);
                try self.update(event);
            }
            if (wheel != 0 and (wheel_clock == null or wheel_clock.?.read() >= tmux_wheel_interval)) {
                self.flushWheel(&wheel);
                if (self.view.transport == .tmux) wheel_clock = try std.time.Timer.start();
            }
            if (self.should_quit) break;

            try self.applyReload();
            if (remote) |fd| self.receiveRemote(fd) catch |err| {
                self.showMessage("Preview command failed: {s}", .{@errorName(err)});
            };
            if (self.indicatorDelay() == 0) try self.endReloadIndicator();
            frame_clock.reset();
            self.advanceScroll();
            try self.frame(&worker);
            self.trackPosition();

            if (!loop.queue.isEmpty()) continue;
            var search_changed = false;
            if (self.current_mode == .command and self.current_mode.command.searchDelay() == 0) {
                self.current_mode.command.runSearch();
                search_changed = true;
            }
            if (self.search_task != null) search_changed = self.advanceSearch(&loop) or search_changed;
            if (search_changed) try self.frame(&worker);
        }
    }

    fn receiveRemote(self: *Self, fd: std.posix.socket_t) !void {
        var buf: [Preview.limit + 1]u8 = undefined;
        var publication = false;
        // Coalesce navigation without dropping reload notifications.
        // Bound each drain to keep terminal input responsive.
        for (0..32) |_| {
            const n = std.posix.recv(fd, &buf, 0) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (n > Preview.limit) return error.CommandTooLong;
            const command = try Preview.Command.parse(buf[0..n]);
            if (command == .reload) {
                publication = true;
                continue;
            }
            @memcpy(self.remote_buf[0..n], buf[0..n]);
            self.remote_len = n;
            self.remote_waiting = false;
        }
        if (publication) if (self.reloader) |worker| worker.notifyChanged();
        if (self.remote_len == 0 or self.remote_waiting) return;
        const pdf = &self.document_handler.pdf_handler;
        if ((self.config.file_monitor.enabled or publication) and
            !std.meta.eql(Snapshot.Stamp.read(pdf.path), @as(?Snapshot.Stamp, pdf.snapshot.stamp)))
        {
            // Release outline/link objects and defer navigation until reload completes.
            self.changeMode(.view);
            self.remote_waiting = true;
            if (!publication) if (self.reloader) |worker| worker.notifyChanged();
            return;
        }
        const command = try Preview.Command.parse(self.remote_buf[0..self.remote_len]);
        self.remote_len = 0;
        const point = switch (command) {
            .reload => unreachable,
            .page => null,
            .forward => |f| try Preview.forward(self.allocator, self.absolute_path orelse pdf.path, f.source, f.line, f.column),
        };
        const page = if (point) |p| p.page else command.page.number;
        if (page == 0 or page > pdf.total_pages) return error.PageOutOfRange;
        self.changeMode(.view);
        self.clearMessage();
        self.clearSearch();
        self.search_origin = null;
        self.preview_current = false;
        self.scroll_animation = null;
        self.view.recordJump();
        self.view.goToPage(page - 1);
        if (point) |p| {
            if (pdf.layoutPoint(page - 1, p.x, p.y)) |q| self.view.showRect(page - 1, .{ .x0 = q.x, .x1 = q.x, .y0 = q.y, .y1 = q.y });
        } else if (command.page.text) |needle| {
            if (needle.len == 0) return;
            try pdf.setSearch(needle, false);
            if (pdf.hitsOn(page - 1).len > 0) self.showHit(.{ .page = page - 1, .index = 0 }, false);
        }
    }

    fn wheelDirection(self: *Self, event: Event) ?i64 {
        if (self.current_mode != .view or event != .mouse or self.config.general.smooth_scroll) return null;
        const step = self.config.general.wheel_step;
        if (!std.math.isFinite(step) or step != @trunc(step)) return null;
        const mouse = event.mouse;
        if (mouse.type != .press or @as(u3, @bitCast(mouse.mods)) != 0) return null;
        return switch (mouse.button) {
            .wheel_up => -1,
            .wheel_down => 1,
            else => null,
        };
    }

    fn flushWheel(self: *Self, count: *i64) void {
        if (count.* == 0) return;
        self.scroll(@as(f32, @floatFromInt(count.*)) * self.config.general.wheel_step);
        count.* = 0;
    }

    pub fn scroll(self: *Self, pixels: f32) void {
        if (!self.config.general.smooth_scroll) {
            self.view.scrollBy(pixels);
            return;
        }

        const distance = @round(pixels);
        if (distance == 0) return;
        const frames = self.scroll_animation orelse [3]f32{ 0, 0, 0 };
        const total = distance + frames[0] + frames[1] + frames[2];
        if (@abs(total) > @as(f32, @floatFromInt(self.view.height))) {
            self.scroll_animation = null;
            self.view.scrollBy(total);
            return;
        }

        const first = @round(distance * 0.6);
        const second = @round(distance * 0.9);
        self.scroll_animation = .{
            frames[0] + first,
            frames[1] + (second - first),
            frames[2] + (distance - second),
        };
    }

    pub fn finishScroll(self: *Self) void {
        if (self.scroll_animation) |frames| {
            self.scroll_animation = null;
            self.view.scrollBy(frames[0] + frames[1] + frames[2]);
        }
    }

    fn advanceScroll(self: *Self) void {
        const frames = self.scroll_animation orelse return;
        self.scroll_animation = if (frames[1] == 0 and frames[2] == 0)
            null
        else
            .{ frames[1], frames[2], 0 };

        const delta = frames[0];
        if (delta == 0) return;
        const unit = self.view.unit;
        const y = self.view.y;
        self.view.scrollBy(delta);
        if (self.view.unit == unit and self.view.y == y and
            delta * frames[1] >= 0 and delta * frames[2] >= 0)
        {
            self.scroll_animation = null;
        }
    }

    fn frame(self: *Self, worker: *RenderWorker) !void {
        const page = if (self.config.status_bar.enabled and self.current_mode != .index) self.currentPage() else null;
        const buffered = self.tty.writer();
        const tmux = self.view.transport == .tmux;
        if (tmux and try self.view.present(buffered, worker, self.current_mode != .index)) self.ui_dirty = true;
        if (self.ui_dirty or page != self.status_page) {
            try self.draw();
            // Synchronized output keeps tmux < 3.8 from dropping placeholder diacritics.
            try self.vx.render(buffered);
            self.ui_dirty = false;
            self.status_page = page;
        }
        if (tmux) {
            try self.view.maintainTmuxImages(buffered);
        } else {
            _ = try self.view.present(buffered, worker, self.current_mode != .index);
        }
        try buffered.flush();
        _ = self.arena.reset(.retain_capacity);
    }

    fn leaveMode(self: *Self) void {
        switch (self.current_mode) {
            .view => {},
            .command => |*state| state.deinit(),
            .index => |*state| state.deinit(),
            .hints => |*state| state.deinit(),
        }
    }

    pub fn openIndex(self: *Self) void {
        const index = IndexMode.init(self) orelse {
            self.showMessage("This document has no index", .{});
            return;
        };
        self.leaveMode();
        self.current_mode = .{ .index = index };
        self.ui_dirty = true;
    }

    pub fn openHints(self: *Self, kind: HintMode.Kind) void {
        const hints = HintMode.init(self, kind) orelse {
            self.showMessage("No links in view", .{});
            return;
        };
        self.leaveMode();
        self.current_mode = .{ .hints = hints };
        self.ui_dirty = true;
    }

    pub fn changeMode(self: *Self, new_state: ModeType) void {
        self.leaveMode();
        self.ui_dirty = true;

        switch (new_state) {
            .view => self.current_mode = .{ .view = ViewMode.init(self) },
            .command => self.current_mode = .{ .command = CommandMode.init(self) },
            .index, .hints => unreachable,
        }
    }

    pub fn handleKeyStroke(self: *Self, key: vaxis.Key) !void {
        const km = self.config.key_map;

        // Ghostty reports modifiers as keys; they must not cancel a count or sequence.
        if (key.isModifier()) return;

        // Ctrl+c quits from any mode; the quit binding only in view mode, so it stays typable.
        if (key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return;
        }

        if (self.current_mode != .view) self.ui_dirty = true;
        try switch (self.current_mode) {
            .view => |*state| state.handleKeyStroke(key, km),
            .command => |*state| state.handleKeyStroke(key, km),
            .index => |*state| state.handleKeyStroke(key, km),
            .hints => |*state| state.handleKeyStroke(key, km),
        };
    }

    pub fn update(self: *Self, event: Event) !void {
        switch (event) {
            .key_press => |key| try self.handleKeyStroke(key),
            .mouse => |mouse| {
                switch (self.current_mode) {
                    .view => |*state| try state.handleMouse(mouse),
                    .command, .index, .hints => {},
                }
            },
            .winsize => |ws| {
                self.pointer = null;
                if (self.view.transport == .tmux) self.tmux_cell = Tmux.cellSize(self.allocator) orelse self.tmux_cell;
                self.ui_dirty = true;
                if (self.current_mode == .view) self.current_mode.view.cancelMouseGesture();
                self.finishScroll();
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
                self.layoutView();
            },
            .focus_in => {
                if (self.view.transport == .tmux) {
                    self.tmux_cell = Tmux.cellSize(self.allocator) orelse self.tmux_cell;
                    self.layoutView();
                    self.view.refreshTmuxImages();
                    self.ui_dirty = true;
                    self.vx.queueRefresh();
                }
            },
            .reload_ready, .terminate => {},
        }
    }

    /// Save the page once it has stayed put for `position_settle_ns`.
    fn trackPosition(self: *Self) void {
        if (!self.config.general.remember_page or self.absolute_path == null) return;
        const page = self.currentPage() + 1;
        if (page != self.pending_page) {
            self.pending_page = page;
            self.position_clock = std.time.Timer.start() catch null;
        } else if (page == self.saved_page) {
            self.position_clock = null;
        } else if (self.position_clock) |*clock| {
            if (clock.read() >= position_settle_ns) self.savePosition();
        }
    }

    fn positionDelay(self: *Self) ?u64 {
        const clock = if (self.position_clock) |*timer| timer else return null;
        return position_settle_ns -| clock.read();
    }

    fn savePosition(self: *Self) void {
        const path = self.absolute_path orelse return;
        if (!self.config.general.remember_page) return;
        const page = self.currentPage() + 1;
        self.position_clock = null;
        if (page == self.saved_page) return;
        Positions.save(self.allocator, path, page);
        self.saved_page = page;
        self.pending_page = page;
    }

    pub fn drawStatusBar(self: *Self, win: vaxis.Window) !void {
        // The render still reads this text; the run loop resets the arena after.
        const arena = self.arena.allocator();

        const bottom_rows: u16 = if (self.current_mode == .command or self.message_len > 0) 2 else 1;
        const status_bar = win.child(.{
            .x_off = 0,
            .y_off = win.height -| bottom_rows,
            .width = win.width,
            .height = 1,
        });

        // Expand all items into styled sub-items
        var expanded_items = std.array_list.Managed(Config.StatusBar.StyledItem).init(arena);
        defer expanded_items.deinit();

        for (self.config.status_bar.items) |item| {
            switch (item) {
                .styled => |styled| {
                    try expandPlaceholders(&expanded_items, styled);
                },
                .mode_aware => |mode_aware| {
                    switch (self.current_mode) {
                        .view, .index, .hints => try expandPlaceholders(&expanded_items, mode_aware.view),
                        .command => try expandPlaceholders(&expanded_items, mode_aware.command),
                    }
                },
                .reload_aware => |reload_aware| {
                    switch (self.current_reload_indicator_state) {
                        .idle => try expandPlaceholders(&expanded_items, reload_aware.idle),
                        .reload => try expandPlaceholders(&expanded_items, reload_aware.reload),
                        .watching => try expandPlaceholders(&expanded_items, reload_aware.watching),
                    }
                },
            }
        }

        const items = expanded_items.items;

        // Find the separator
        var separator_index: usize = items.len;
        for (items, 0..) |item, i| {
            if (std.mem.eql(u8, item.text, Config.StatusBar.SEPARATOR)) {
                separator_index = i;
                break;
            }
        }

        if (separator_index < items.len) {
            status_bar.fill(vaxis.Cell{ .style = items[separator_index].style });
        } else {
            status_bar.fill(vaxis.Cell{ .style = self.config.status_bar.style });
        }

        // Left side
        var left_col: usize = 0;
        for (0..separator_index) |i| {
            try self.drawStatusText(status_bar, items[i], &left_col, true, arena);
        }

        // Right side
        if (separator_index < items.len - 1) {
            var right_col: usize = win.width;
            for (0..(items.len - separator_index - 1)) |j| {
                try self.drawStatusText(status_bar, items[items.len - 1 - j], &right_col, false, arena);
            }
        }
    }

    fn expandPlaceholders(list: *std.array_list.Managed(Config.StatusBar.StyledItem), styled_text: Config.StatusBar.StyledItem) !void {
        const text = styled_text.text;
        var last_index: usize = 0;

        while (last_index < text.len) {
            const open = std.mem.indexOfScalarPos(u8, text, last_index, '<') orelse {
                if (last_index < text.len) {
                    try list.append(.{ .text = text[last_index..], .style = styled_text.style });
                }
                break;
            };

            if (open > last_index) {
                try list.append(.{ .text = text[last_index..open], .style = styled_text.style });
            }

            const close = std.mem.indexOfScalarPos(u8, text, open, '>') orelse {
                try list.append(.{ .text = text[open..], .style = styled_text.style });
                break;
            };

            try list.append(.{ .text = text[open .. close + 1], .style = styled_text.style });

            last_index = close + 1;
        }
    }

    fn withinDirectory(path: []const u8, directory: []const u8) ?[]const u8 {
        if (directory.len == 0) return null;
        const prefix = std.mem.trimEnd(u8, directory, "/");
        if (!std.mem.startsWith(u8, path, prefix) or path.len <= prefix.len or path[prefix.len] != '/') return null;
        return path[prefix.len + 1 ..];
    }

    fn formatStatusPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) {
            if (std.fs.cwd().realpathAlloc(allocator, ".")) |cwd| {
                defer allocator.free(cwd);
                if (withinDirectory(path, cwd)) |relative| return allocator.dupe(u8, relative);
            } else |_| {}
            if (std.posix.getenv("HOME")) |home| {
                if (withinDirectory(path, home)) |relative| return std.fmt.allocPrint(allocator, "~/{s}", .{relative});
            }
        }
        return allocator.dupe(u8, path);
    }

    fn drawStatusText(self: *Self, status_bar: vaxis.Window, item: Config.StatusBar.StyledItem, col_offset: *usize, left_aligned: bool, allocator: std.mem.Allocator) !void {
        var text = item.text;
        if (std.mem.eql(u8, text, Config.StatusBar.PATH)) {
            text = self.status_path;
        } else if (std.mem.eql(u8, text, Config.StatusBar.PAGE)) {
            text = try std.fmt.allocPrint(allocator, "{}", .{self.currentPage() + 1});
        } else if (std.mem.eql(u8, text, Config.StatusBar.TOTAL_PAGES)) {
            text = try std.fmt.allocPrint(allocator, "{}", .{self.document_handler.getTotalPages()});
        } else if (std.mem.eql(u8, text, Config.StatusBar.SEPARATOR)) {
            text = "";
        }

        const width = vaxis.gwidth.gwidth(text, .wcwidth);

        if (!left_aligned) col_offset.* -|= width;
        if (col_offset.* >= status_bar.width) return;

        _ = status_bar.print(
            &.{.{ .text = text, .style = item.style }},
            .{ .col_offset = @intCast(col_offset.*) },
        );

        if (left_aligned) col_offset.* += width;
    }

    pub fn draw(self: *Self) !void {
        const win = self.vx.window();
        win.clear();

        if (self.current_mode == .index) {
            self.current_mode.index.draw(win);
            return;
        }

        if (self.view.transport == .tmux) try self.view.drawTmux(win, self.arena.allocator());

        if (self.current_mode == .hints) {
            self.current_mode.hints.draw(win, &self.view);
        }

        if (self.config.status_bar.enabled) {
            try self.drawStatusBar(win);
        }

        const style = self.config.status_bar.style;
        if (self.current_mode == .command) {
            const bar = win.child(.{ .x_off = 0, .y_off = win.height -| 1, .width = win.width, .height = 1 });
            bar.fill(.{ .style = style });
            self.current_mode.command.drawCommandBar(win, style);
        } else if (self.message_len > 0) {
            const bar = win.child(.{ .x_off = 0, .y_off = win.height -| 1, .width = win.width, .height = 1 });
            bar.fill(.{ .style = style });
            _ = bar.print(&.{.{ .text = self.message_buf[0..self.message_len], .style = style }}, .{ .wrap = .none });
        }

        if (self.view.transport == .tmux) try self.view.repairTmuxRuns(win, self.arena.allocator());
    }

    pub fn reload(self: *Self) void {
        if (self.reloader) |worker| worker.request();
    }

    fn applyReload(self: *Self) !void {
        // The outline still owns MuPDF objects from the active document.
        if (self.current_mode == .index or self.current_mode == .hints) return;
        const result = self.reloader.?.take() orelse return;
        if (result == .failed) {
            self.remote_len = 0;
            self.remote_waiting = false;
            self.showMessage(reload_message, .{});
            return;
        }
        self.finishScroll();
        if (self.current_mode == .view) self.current_mode.view.cancelMouseGesture();
        const current = &self.document_handler.pdf_handler;
        var previous = current.*;
        current.* = result.pdf;
        current.dual_page = previous.dual_page;
        current.rotation = previous.rotation;
        current.search_needle = previous.search_needle;
        previous.search_needle = null;
        current.search_backward = previous.search_backward;
        previous.deinit();

        self.view.reloaded();
        self.remote_waiting = false;
        self.search_task = null;
        self.preview_current = false;
        self.repeats.clearRetainingCapacity();
        if (self.current_mode == .command) self.current_mode.command.restartSearch();
        if (std.mem.eql(u8, self.message_buf[0..self.message_len], reload_message)) self.clearMessage();
        self.ui_dirty = true;
        if (self.reload_indicator_active) {
            self.reload_timer = try std.time.Timer.start();
            self.current_reload_indicator_state = .reload;
            if (self.config.general.progress_bar) try self.tty.writer().writeAll("\x1b]9;4;1;100\x07");
        }
    }

    fn indicatorDelay(self: *Self) ?u64 {
        const timer = if (self.reload_timer) |*clock| clock else return null;
        return ReloadWorker.seconds(self.config.file_monitor.reload_indicator_duration) -| timer.read();
    }

    fn endReloadIndicator(self: *Self) !void {
        self.reload_timer = null;
        self.current_reload_indicator_state = .watching;
        self.ui_dirty = true;
        if (self.config.general.progress_bar) try self.tty.writer().writeAll("\x1b]9;4;0;0\x07");
    }

    pub fn copyToClipboard(self: *Self, text: []const u8) void {
        self.vx.copyToSystemClipboard(self.tty.writer(), text, self.allocator) catch {};
    }

    pub fn followLink(self: *Self, uri: [:0]const u8) void {
        const pdf = &self.document_handler.pdf_handler;
        const c = PdfHandler.c;
        if (c.fz_is_external_link(pdf.ctx, uri.ptr) != 0) {
            if (!canOpenExternalLink(uri)) {
                self.showMessage("Only HTTP, HTTPS and mailto links can be opened", .{});
                return;
            }
            Spawn.detached(self.allocator, &.{ "xdg-open", uri }, null, null) catch |err| {
                self.showMessage("Could not open the link: {s}", .{@errorName(err)});
            };
            return;
        }

        var x: f32 = 0;
        var y = std.math.nan(f32);
        const page = c.fz_resolve_link_page_z(pdf.ctx, pdf.doc, uri.ptr, &x, &y);
        if (page < 0 or page >= pdf.total_pages) {
            self.showMessage("The link has no target in this document", .{});
            return;
        }
        self.view.recordJump();
        self.view.goToPoint(@intCast(page), y);
    }

    fn canOpenExternalLink(uri: []const u8) bool {
        const end = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
        const scheme = uri[0..end];
        if (!std.ascii.eqlIgnoreCase(scheme, "http") and
            !std.ascii.eqlIgnoreCase(scheme, "https") and
            !std.ascii.eqlIgnoreCase(scheme, "mailto")) return false;
        for (uri) |byte| {
            if (std.ascii.isControl(byte)) return false;
        }
        return true;
    }

    /// The page being read, 0-based; in two-page mode, the spread's first.
    pub fn currentPage(self: *Self) u16 {
        return self.view.currentUnit();
    }

    pub fn layoutView(self: *Self) void {
        const screen = self.vx.screen;
        const reserved: u16 = if (self.config.status_bar.enabled) 1 else 0;
        if (self.tmux_cell) |size| {
            self.view.setGeometry(screen.width, screen.height, screen.width *| size.width, screen.height *| size.height, reserved);
        } else {
            self.view.setGeometry(screen.width, screen.height, screen.width_pix, screen.height_pix, reserved);
        }
    }

    pub fn beginSearchPrompt(self: *Self) void {
        self.search_task = null;
        self.repeats.clearRetainingCapacity();
        self.preview_current = false;
        self.search_origin = if (self.config.general.incremental_search) self.view.position() else null;
    }

    pub fn invalidateSearchPreview(self: *Self) void {
        if (self.search_task) |task| if (task.purpose == .preview) {
            self.search_task = null;
        };
        self.preview_current = false;
    }

    pub fn cancelSearchPrompt(self: *Self) void {
        self.invalidateSearchPreview();
        const origin = self.search_origin orelse return;
        self.search_origin = null;
        self.clearSearch();
        self.view.restore(origin);
    }

    pub fn searchAsYouType(self: *Self, needle: []const u8, backward: bool) void {
        const origin = self.search_origin orelse return;
        const pdf = &self.document_handler.pdf_handler;
        self.view.restore(origin);
        if (needle.len == 0) {
            self.clearSearch();
            return;
        }
        pdf.setSearch(needle, backward) catch return;
        self.preview_current = true;
        self.search_task = .{
            .cursor = .{ .page = self.currentPage(), .from = null, .forward = !backward },
            .purpose = .preview,
        };
    }

    pub fn search(self: *Self, needle: []const u8, backward: bool) void {
        const origin = self.search_origin;
        self.search_origin = null;
        if (origin) |position| self.view.restore(position);

        const pdf = &self.document_handler.pdf_handler;
        const reuse = self.preview_current and pdf.search_backward == backward and
            (if (pdf.search_needle) |previous| std.mem.eql(u8, previous, needle) else false);
        self.preview_current = false;
        if (reuse) {
            if (self.search_task) |*task| {
                task.purpose = .commit;
            } else if (pdf.search_hit) |hit| {
                self.showHit(hit, true);
            } else {
                self.showMessage("Pattern not found: {s}", .{needle});
            }
            return;
        }

        self.search_task = null;
        pdf.setSearch(needle, backward) catch return;
        self.search_task = .{
            .cursor = .{ .page = self.currentPage(), .from = null, .forward = !backward },
            .purpose = .commit,
        };
    }

    pub fn searchAgain(self: *Self, reverse: bool, count: u32) void {
        const pdf = &self.document_handler.pdf_handler;
        if (pdf.search_needle == null) {
            self.showMessage("No previous search", .{});
            return;
        }
        const repeat: Repeat = .{ .reverse = reverse, .count = count };
        if (self.search_task == null) {
            self.startRepeat(repeat);
        } else if (self.repeats.getLastOrNull()) |last| {
            if (last.reverse == reverse) {
                self.repeats.items[self.repeats.items.len - 1].count +|= count;
            } else {
                self.repeats.append(self.allocator, repeat) catch {};
            }
        } else {
            self.repeats.append(self.allocator, repeat) catch {};
        }
    }

    fn startRepeat(self: *Self, repeat: Repeat) void {
        const pdf = &self.document_handler.pdf_handler;
        const last = pdf.search_hit;
        self.search_task = .{
            .cursor = .{
                .page = if (last) |hit| hit.page else self.currentPage(),
                .from = if (last) |hit| hit.index else null,
                .forward = pdf.search_backward == repeat.reverse,
            },
            .purpose = .repeat,
            .remaining = repeat.count,
        };
    }

    // Yield at page boundaries, so a long search leaves time for input and renders.
    fn advanceSearch(self: *Self, loop: *vaxis.Loop(Event)) bool {
        var timer = std.time.Timer.start() catch return false;
        const pdf = &self.document_handler.pdf_handler;
        while (self.search_task) |*task| {
            switch (task.cursor.advance(pdf)) {
                .pending => {},
                .hit => |hit| {
                    self.showHit(hit, task.purpose != .preview);
                    if (task.remaining > 1) {
                        task.remaining -= 1;
                        task.cursor = .{ .page = hit.page, .from = hit.index, .forward = task.cursor.forward };
                    } else {
                        self.finishSearch();
                    }
                    return true;
                },
                .none => {
                    if (task.purpose != .preview) {
                        if (pdf.search_needle) |needle| self.showMessage("Pattern not found: {s}", .{needle});
                    }
                    self.finishSearch();
                    return true;
                },
            }
            if (!loop.queue.isEmpty() or timer.read() >= 4 * std.time.ns_per_ms) break;
        }
        return false;
    }

    fn finishSearch(self: *Self) void {
        self.search_task = null;
        if (self.repeats.items.len != 0) self.startRepeat(self.repeats.orderedRemove(0));
    }

    fn showHit(self: *Self, hit: PdfHandler.Hit, record: bool) void {
        const pdf = &self.document_handler.pdf_handler;
        pdf.search_hit = hit;
        if (record) self.view.recordJump();
        if (pdf.hitRect(hit)) |rect| self.view.showRect(hit.page, rect) else self.view.goToPage(hit.page);
    }

    pub fn clearSearch(self: *Self) void {
        self.search_task = null;
        self.repeats.clearRetainingCapacity();
        if (self.document_handler.pdf_handler.search_needle != null) self.document_handler.pdf_handler.clearSearch();
    }

    pub fn showMessage(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(text);
        const n = @min(text.len, self.message_buf.len);
        @memcpy(self.message_buf[0..n], text[0..n]);
        self.message_len = n;
        self.ui_dirty = true;
    }

    pub fn clearMessage(self: *Self) void {
        if (self.message_len == 0) return;
        self.message_len = 0;
        self.ui_dirty = true;
    }

    pub fn toggleFullScreen(self: *Self) void {
        self.ui_dirty = true;
        self.config.status_bar.enabled = !self.config.status_bar.enabled;
        self.layoutView();
    }
};
