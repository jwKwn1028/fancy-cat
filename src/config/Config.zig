const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");

pub const max_sequence = 4;
pub const max_alternatives = 4;

pub const Sequence = struct {
    keys: [max_sequence]vaxis.Key = [_]vaxis.Key{.{ .codepoint = 0 }} ** max_sequence,
    len: u8 = 0,

    fn push(self: *Sequence, key: vaxis.Key) bool {
        if (self.len == max_sequence) return false;
        self.keys[self.len] = key;
        self.len += 1;
        return true;
    }
};

pub const Match = enum { none, prefix, full };

/// Keys match loosely, as vaxis does, so `J` matches Shift+j.
pub const Binding = struct {
    alternatives: [max_alternatives]Sequence = [_]Sequence{.{}} ** max_alternatives,
    len: u8 = 0,

    pub fn key(cp: u21, mods: vaxis.Key.Modifiers) Binding {
        var binding = Binding{};
        var seq = Sequence{};
        _ = seq.push(.{ .codepoint = cp, .mods = mods });
        binding.add(seq);
        return binding;
    }

    pub fn keys(cps: []const u21) Binding {
        var binding = Binding{};
        var seq = Sequence{};
        for (cps) |cp| _ = seq.push(.{ .codepoint = cp });
        binding.add(seq);
        return binding;
    }

    pub fn add(self: *Binding, seq: Sequence) void {
        if (self.len == max_alternatives or seq.len == 0) return;
        self.alternatives[self.len] = seq;
        self.len += 1;
    }

    pub fn match(self: Binding, typed: []const vaxis.Key) Match {
        var result: Match = .none;
        for (self.alternatives[0..self.len]) |seq| {
            if (typed.len == 0 or typed.len > seq.len) continue;
            var same = true;
            for (typed, seq.keys[0..typed.len]) |pressed, want| {
                if (!keyMatches(pressed, want)) {
                    same = false;
                    break;
                }
            }
            if (!same) continue;
            if (typed.len == seq.len) return .full;
            result = .prefix;
        }
        return result;
    }

    // Named keys match exactly, or Space would match Shift+Space.
    fn keyMatches(pressed: vaxis.Key, want: vaxis.Key) bool {
        const cp = want.codepoint;
        if (cp <= vaxis.Key.space or cp == vaxis.Key.backspace or cp >= 57344) {
            return pressed.matchExact(cp, want.mods);
        }
        return pressed.matches(cp, want.mods);
    }

    pub fn of(comptime texts: []const []const u8) Binding {
        @setEvalBranchQuota(10_000);
        var binding = Binding{};
        inline for (texts) |text| binding.add((notation(text) orelse @compileError("bad key " ++ text)).alternatives[0]);
        return binding;
    }

    pub fn matchesKey(self: Binding, pressed: vaxis.Key) bool {
        return self.match(&[_]vaxis.Key{pressed}) == .full;
    }

    /// Parses zathura's notation: "gg", "J", "<C-d>", "<Tab>", "<A-+>".
    pub fn notation(text: []const u8) ?Binding {
        var seq = Sequence{};
        var i: usize = 0;
        while (i < text.len) {
            var parsed: vaxis.Key = undefined;
            var next = i + 1;
            const close = if (text[i] == '<') std.mem.indexOfScalarPos(u8, text, i + 1, '>') else null;
            if (close != null and close.? > i + 1) {
                parsed = special(text[i + 1 .. close.?]) orelse return null;
                next = close.? + 1;
            } else {
                const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return null;
                if (i + n > text.len) return null;
                const cp = std.unicode.utf8Decode(text[i .. i + n]) catch return null;
                parsed = plain(cp, .{});
                next = i + n;
            }
            if (!seq.push(parsed)) return null;
            i = next;
        }
        if (seq.len == 0) return null;
        var binding = Binding{};
        binding.add(seq);
        return binding;
    }

    fn plain(cp: u21, base: vaxis.Key.Modifiers) vaxis.Key {
        var mods = base;
        var code = cp;
        if (cp >= 'A' and cp <= 'Z') {
            code = cp + ('a' - 'A');
            mods.shift = true;
        }
        return .{ .codepoint = code, .mods = mods };
    }

    const names = [_]struct { []const u8, u21 }{
        .{ "tab", vaxis.Key.tab },
        .{ "esc", vaxis.Key.escape },
        .{ "escape", vaxis.Key.escape },
        .{ "cr", vaxis.Key.enter },
        .{ "return", vaxis.Key.enter },
        .{ "enter", vaxis.Key.enter },
        .{ "bs", vaxis.Key.backspace },
        .{ "backspace", vaxis.Key.backspace },
        .{ "space", vaxis.Key.space },
        .{ "lt", '<' },
        .{ "gt", '>' },
        .{ "up", vaxis.Key.up },
        .{ "down", vaxis.Key.down },
        .{ "left", vaxis.Key.left },
        .{ "right", vaxis.Key.right },
        .{ "pageup", vaxis.Key.page_up },
        .{ "pagedown", vaxis.Key.page_down },
        .{ "home", vaxis.Key.home },
        .{ "end", vaxis.Key.end },
        .{ "insert", vaxis.Key.insert },
        .{ "delete", vaxis.Key.delete },
        .{ "del", vaxis.Key.delete },
    };

    fn special(inner: []const u8) ?vaxis.Key {
        var rest = inner;
        var mods = vaxis.Key.Modifiers{};
        while (rest.len > 2 and rest[1] == '-') {
            switch (rest[0]) {
                'C', 'c' => mods.ctrl = true,
                'A', 'a', 'M', 'm' => mods.alt = true,
                'S', 's' => mods.shift = true,
                'D', 'd' => mods.super = true,
                else => break,
            }
            rest = rest[2..];
        }
        const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch return null;
        if (n == rest.len) {
            const cp = std.unicode.utf8Decode(rest) catch return null;
            return plain(cp, mods);
        }
        for (names) |entry| {
            if (std.ascii.eqlIgnoreCase(rest, entry[0])) return .{ .codepoint = entry[1], .mods = mods };
        }
        if (vaxis.Key.name_map.get(rest)) |cp| return .{ .codepoint = cp, .mods = mods };
        return null;
    }
};

pub const Map = struct {
    binding: Binding,
    command: []const u8,
};

/// Each binding is a key object, a zathura-style string or a list of those; [] unbinds.
pub const KeyMap = struct {
    next: Binding = Binding.of(&.{ "J", "<PageDown>" }),
    prev: Binding = Binding.of(&.{ "K", "<PageUp>" }),
    first_page: Binding = Binding.of(&.{ "gg", "<Home>" }),
    last_page: Binding = Binding.of(&.{ "G", "<End>" }),
    scroll_up: Binding = Binding.key('k', .{}),
    scroll_up_mult: Binding = .{},
    scroll_down: Binding = Binding.key('j', .{}),
    scroll_down_mult: Binding = .{},
    scroll_left: Binding = Binding.key('h', .{}),
    scroll_left_mult: Binding = .{},
    scroll_right: Binding = Binding.key('l', .{}),
    scroll_right_mult: Binding = .{},
    half_up: Binding = Binding.key('u', .{ .ctrl = true }),
    half_down: Binding = Binding.key('d', .{ .ctrl = true }),
    half_left: Binding = Binding.key('t', .{ .ctrl = true }),
    half_right: Binding = Binding.key('y', .{ .ctrl = true }),
    full_up: Binding = Binding.of(&.{ "<C-b>", "<S-Space>" }),
    full_down: Binding = Binding.of(&.{ "<C-f>", "<Space>" }),
    full_left: Binding = Binding.key('t', .{}),
    full_right: Binding = Binding.key('y', .{}),
    page_top: Binding = Binding.key('h', .{ .shift = true }),
    page_bottom: Binding = Binding.key('l', .{ .shift = true }),
    snap_to_page: Binding = Binding.key('p', .{ .shift = true }),
    jump_back: Binding = Binding.key('o', .{ .ctrl = true }),
    jump_forward: Binding = Binding.key('i', .{ .ctrl = true }),
    mark_set: Binding = Binding.key('m', .{}),
    mark_jump: Binding = Binding.key('\'', .{}),
    zoom_in: Binding = Binding.key('+', .{}),
    zoom_in_mult: Binding = Binding.key('+', .{ .alt = true }),
    zoom_out: Binding = Binding.key('-', .{}),
    zoom_out_mult: Binding = Binding.key('-', .{ .alt = true }),
    width_mode: Binding = Binding.key('s', .{}),
    best_fit: Binding = Binding.key('a', .{}),
    dual_page: Binding = Binding.key('d', .{}),
    cycle_first_column: Binding = Binding.key('d', .{ .shift = true }),
    rotate: Binding = Binding.key('r', .{}),
    search_forward: Binding = Binding.key('/', .{}),
    search_backward: Binding = Binding.key('?', .{}),
    search_next: Binding = Binding.key('n', .{}),
    search_prev: Binding = Binding.key('n', .{ .shift = true }),
    index: Binding = Binding.key(vaxis.Key.tab, .{}),
    follow_link: Binding = Binding.key('f', .{}),
    display_link: Binding = Binding.key('f', .{ .shift = true }),
    copy_link: Binding = Binding.key('c', .{}),
    reload: Binding = Binding.key('r', .{ .shift = true }),
    inverse_search: Binding = Binding.key('l', .{ .ctrl = true }),
    copy_path: Binding = Binding.key('y', .{ .shift = true }),
    trim_margins: Binding = .{},
    colorize: Binding = Binding.key('r', .{ .ctrl = true }),
    quit: Binding = Binding.key('q', .{}),
    full_screen: Binding = Binding.key('n', .{ .ctrl = true }),
    enter_command_mode: Binding = Binding.key(':', .{}),
    exit_command_mode: Binding = Binding.key(vaxis.Key.escape, .{}),
    execute_command: Binding = Binding.key(vaxis.Key.enter, .{}),
    history_back: Binding = Binding.key(vaxis.Key.up, .{}),
    history_forward: Binding = Binding.key(vaxis.Key.down, .{}),

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) KeyMap {
        var keymap = KeyMap{};
        if (val != .object) return keymap;

        inline for (std.meta.fields(KeyMap)) |field| {
            if (val.object.get(field.name)) |raw| {
                @field(keymap, field.name) = parseBinding(raw, allocator, @field(keymap, field.name));
            }
        }

        return keymap;
    }
};

pub const FileMonitor = struct {
    enabled: bool = true,
    // Amount of time in seconds to wait in between polling for file changes
    latency: f16 = 0.1,
    reload_indicator_duration: f16 = 1.0,

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) FileMonitor {
        var file_monitor = FileMonitor{};
        if (val != .object) return file_monitor;

        file_monitor.enabled = parseType(
            bool,
            val.object,
            "enabled",
            allocator,
            file_monitor.enabled,
        );
        file_monitor.latency = parseType(
            f16,
            val.object,
            "latency",
            allocator,
            file_monitor.latency,
        );
        file_monitor.reload_indicator_duration = parseType(
            f16,
            val.object,
            "reload_indicator_duration",
            allocator,
            file_monitor.reload_indicator_duration,
        );

        return file_monitor;
    }
};

pub const General = struct {
    colorize: bool = false,
    white: i32 = 0x000000,
    black: i32 = 0xffffff,
    // size of the pdf
    // 1 is the whole window
    size: f32 = 1.0,
    // percentage
    zoom_step: f32 = 1.25,
    zoom_min: f32 = 1.0,
    // pixels
    scroll_step: f32 = 100.0,
    // multiplier
    zoom_mult: f32 = 2.0,
    scroll_mult: f32 = 10.0,
    // seconds
    retry_delay: f32 = 0.2,
    timeout: f32 = 5.0,
    // resolution
    detect_dpi: bool = true,
    dpi: f32 = 96.0,
    // whole number (possibly 0)
    history: u32 = 1000,
    progress_bar: bool = false,
    // two-page mode: the column (1 or 2) holding page 1, like zathura
    first_page_column: u8 = 2,
    // Ctrl+r keeps each color's hue (zathura's recolor-keephue)...
    recolor_keephue: bool = false,
    // ...and leaves pictures alone (zathura's recolor-reverse-video).
    recolor_reverse_video: bool = false,
    remember_page: bool = true,
    trim_margins: bool = false,
    trim_padding: f32 = 10,
    incremental_search: bool = false,
    // Pixels per mouse wheel event; terminals send several per notch.
    wheel_step: f32 = 24,
    smooth_scroll: bool = false,
    page_gap: f32 = 8,

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) General {
        var general = General{};
        if (val != .object) return general;

        general.colorize = parseType(bool, val.object, "colorize", allocator, general.colorize);

        if (val.object.get("white")) |white| {
            if (parseRGB(white, allocator)) |rgb| {
                general.white = @intCast(
                    (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | @as(u32, rgb[2]),
                );
            }
        }
        if (val.object.get("black")) |black| {
            if (parseRGB(black, allocator)) |rgb| {
                general.black = @intCast(
                    (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | @as(u32, rgb[2]),
                );
            }
        }

        general.size = parseType(f32, val.object, "size", allocator, general.size);
        general.zoom_step = parseType(f32, val.object, "zoom_step", allocator, general.zoom_step);
        general.zoom_min = parseType(f32, val.object, "zoom_min", allocator, general.zoom_min);
        general.scroll_step = parseType(f32, val.object, "scroll_step", allocator, general.scroll_step);
        general.zoom_mult = parseType(f32, val.object, "zoom_mult", allocator, general.zoom_mult);
        general.scroll_mult = parseType(f32, val.object, "scroll_mult", allocator, general.scroll_mult);
        general.retry_delay = parseType(f32, val.object, "retry_delay", allocator, general.retry_delay);
        general.timeout = parseType(f32, val.object, "timeout", allocator, general.timeout);
        general.detect_dpi = parseType(bool, val.object, "detect_dpi", allocator, general.detect_dpi);
        general.dpi = parseType(f32, val.object, "dpi", allocator, general.dpi);
        general.history = parseType(u32, val.object, "history", allocator, general.history);
        general.progress_bar = parseType(bool, val.object, "progress_bar", allocator, general.progress_bar);
        general.first_page_column = parseType(u8, val.object, "first_page_column", allocator, general.first_page_column);
        general.recolor_keephue = parseType(bool, val.object, "recolor_keephue", allocator, general.recolor_keephue);
        general.recolor_reverse_video = parseType(bool, val.object, "recolor_reverse_video", allocator, general.recolor_reverse_video);
        general.remember_page = parseType(bool, val.object, "remember_page", allocator, general.remember_page);
        general.trim_margins = parseType(bool, val.object, "trim_margins", allocator, general.trim_margins);
        general.trim_padding = parseType(f32, val.object, "trim_padding", allocator, general.trim_padding);
        general.wheel_step = parseType(f32, val.object, "wheel_step", allocator, general.wheel_step);
        general.smooth_scroll = parseType(bool, val.object, "smooth_scroll", allocator, general.smooth_scroll);
        general.incremental_search = parseType(bool, val.object, "incremental_search", allocator, general.incremental_search);
        general.page_gap = parseType(f32, val.object, "page_gap", allocator, general.page_gap);

        return general;
    }
};

pub const StatusBar = struct {
    pub const StyledItem = struct {
        text: []const u8,
        style: vaxis.Cell.Style,
    };
    pub const ModeAwareItem = struct {
        view: StyledItem,
        command: StyledItem,
    };
    pub const ReloadAwareItem = struct {
        idle: StyledItem,
        reload: StyledItem,
        watching: StyledItem,
    };
    pub const Item = union(enum) {
        styled: StyledItem,
        mode_aware: ModeAwareItem,
        reload_aware: ReloadAwareItem,
    };

    const default_style = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 0, 0, 0 } },
        .fg = .{ .rgb = .{ 255, 255, 255 } },
    };

    pub const PATH = "<path>";
    pub const SEPARATOR = "<separator>";
    pub const PAGE = "<page>";
    pub const TOTAL_PAGES = "<total_pages>";

    pub const default_items: []const StatusBar.Item = &.{
        .{ .styled = .{ .text = " ", .style = default_style } },
        .{ .mode_aware = .{
            .view = .{ .text = "VIS", .style = default_style },
            .command = .{ .text = "CMD", .style = default_style },
        } },
        .{ .styled = .{ .text = "   ", .style = default_style } },
        .{ .styled = .{ .text = PATH, .style = default_style } },
        .{ .styled = .{ .text = " ", .style = default_style } },
        .{ .reload_aware = .{
            .idle = .{ .text = " ", .style = default_style },
            .reload = .{ .text = "*", .style = default_style },
            .watching = .{ .text = " ", .style = default_style },
        } },
        .{ .styled = .{ .text = SEPARATOR, .style = default_style } },
        .{ .styled = .{ .text = PAGE, .style = default_style } },
        .{ .styled = .{ .text = ":", .style = default_style } },
        .{ .styled = .{ .text = TOTAL_PAGES, .style = default_style } },
        .{ .styled = .{ .text = " ", .style = default_style } },
    };

    enabled: bool = true,
    style: vaxis.Cell.Style = default_style,
    items: []const StatusBar.Item = default_items,

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) StatusBar {
        var status_bar = StatusBar{};
        if (val != .object) return status_bar;

        status_bar.enabled = parseType(bool, val.object, "enabled", allocator, status_bar.enabled);
        status_bar.style = parseStyle(val.object, allocator, status_bar.style);
        status_bar.items = parseItems(val.object, allocator, status_bar.style);

        return status_bar;
    }
};

pub const Cache = struct {
    enabled: bool = true,
    // Unused: pages are cached in strips, bounded by memory_mb.
    lru_size: u16 = 10,
    // Megabytes of strips kept in the terminal; Ghostty holds up to 320 MB of images.
    memory_mb: u32 = 192,

    pub fn parse(val: std.json.Value, allocator: std.mem.Allocator) Cache {
        var cache = Cache{};
        if (val != .object) return cache;

        cache.enabled = parseType(bool, val.object, "enabled", allocator, cache.enabled);
        // XXX temporary change to u16 from usize due to bug in std
        cache.lru_size = parseType(u16, val.object, "lru_size", allocator, cache.lru_size);
        cache.memory_mb = parseType(u32, val.object, "memory_mb", allocator, cache.memory_mb);

        return cache;
    }
};

arena: std.heap.ArenaAllocator,

key_map: KeyMap = .{},
file_monitor: FileMonitor = .{},
general: General = .{},
status_bar: StatusBar = .{},
cache: Cache = .{},
// "Maps": {"T": "exec ..."}, keys in zathura notation.
maps: []const Map = &.{},

legacy_path: bool = false,

pub fn init(allocator: std.mem.Allocator) Self {
    var self = Self{ .arena = std.heap.ArenaAllocator.init(allocator) };
    const arena_allocator = self.arena.allocator();

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return self;
    defer allocator.free(home);

    var path: []u8 = "";
    const xdg_config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
    if (xdg_config_home) |x| {
        path = std.fmt.allocPrint(allocator, "{s}/fancy-cat/config.json", .{x}) catch return self;
        allocator.free(x);
    } else path = std.fmt.allocPrint(allocator, "{s}/.config/fancy-cat/config.json", .{home}) catch return self;
    defer allocator.free(path);

    var content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch null;
    if (content == null) {
        const legacy_path = std.fmt.allocPrint(allocator, "{s}/.fancy-cat", .{home}) catch return self;
        defer allocator.free(legacy_path);

        content = std.fs.cwd().readFileAlloc(allocator, legacy_path, 1024 * 1024) catch null;
        if (content == null) {
            if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
            const file = std.fs.createFileAbsolute(path, .{}) catch return self;
            file.close();
            return self;
        }
        self.legacy_path = true;
    }
    defer allocator.free(content.?);

    if (content.?.len == 0) return self;

    var parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, content.?, .{}) catch return self;
    defer parsed.deinit();

    if (parsed.value.object.get("KeyMap")) |key_map| self.key_map = KeyMap.parse(key_map, arena_allocator);
    if (parsed.value.object.get("FileMonitor")) |file_monitor| self.file_monitor = FileMonitor.parse(file_monitor, arena_allocator);
    if (parsed.value.object.get("General")) |general| self.general = General.parse(general, arena_allocator);
    if (parsed.value.object.get("StatusBar")) |status_bar| self.status_bar = StatusBar.parse(status_bar, arena_allocator);
    if (parsed.value.object.get("Cache")) |cache| self.cache = Cache.parse(cache, arena_allocator);
    if (parsed.value.object.get("Maps")) |maps| self.maps = parseMaps(maps, arena_allocator);

    return self;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

fn parseMaps(val: std.json.Value, allocator: std.mem.Allocator) []const Map {
    if (val != .object) return &.{};
    var maps = std.ArrayList(Map){};
    var entries = val.object.iterator();
    while (entries.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const binding = Binding.notation(entry.key_ptr.*) orelse continue;
        const command = allocator.dupe(u8, entry.value_ptr.string) catch continue;
        maps.append(allocator, .{ .binding = binding, .command = command }) catch continue;
    }
    return maps.items;
}

pub fn parseBinding(val: std.json.Value, allocator: std.mem.Allocator, fallback: Binding) Binding {
    switch (val) {
        .string => |text| return Binding.notation(text) orelse fallback,
        .object => |obj| {
            const key = parseKeyObject(obj, allocator) orelse return fallback;
            return Binding.key(key.codepoint, key.mods);
        },
        .array => |list| {
            if (list.items.len == 0) return Binding{};
            var binding = Binding{};
            for (list.items) |item| {
                switch (item) {
                    .string => |text| if (Binding.notation(text)) |one| binding.add(one.alternatives[0]),
                    .object => |obj| if (parseKeyObject(obj, allocator)) |key| {
                        binding.add(Binding.key(key.codepoint, key.mods).alternatives[0]);
                    },
                    else => {},
                }
            }
            return if (binding.len > 0) binding else fallback;
        },
        else => return fallback,
    }
}

fn parseKeyObject(obj: std.json.ObjectMap, allocator: std.mem.Allocator) ?vaxis.Key {
    const key_str = parseType([]const u8, obj, "key", allocator, "");
    if (key_str.len == 0) return null;

    var binding = vaxis.Key{ .codepoint = vaxis.Key.name_map.get(key_str) orelse @as(u21, key_str[0]) };

    var mods = vaxis.Key.Modifiers{};
    const modifiers = obj.get("modifiers") orelse return binding;
    if (modifiers != .array) return binding;

    for (modifiers.array.items) |mod| {
        if (mod != .string) continue;
        if (std.mem.eql(u8, mod.string, "shift")) mods.shift = true;
        if (std.mem.eql(u8, mod.string, "alt")) mods.alt = true;
        if (std.mem.eql(u8, mod.string, "ctrl")) mods.ctrl = true;
        if (std.mem.eql(u8, mod.string, "super")) mods.super = true;
        if (std.mem.eql(u8, mod.string, "hyper")) mods.hyper = true;
        if (std.mem.eql(u8, mod.string, "meta")) mods.meta = true;
        if (std.mem.eql(u8, mod.string, "caps_lock")) mods.caps_lock = true;
        if (std.mem.eql(u8, mod.string, "num_lock")) mods.num_lock = true;
    }

    binding.mods = mods;

    return binding;
}

fn parseType(comptime T: type, obj: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator, fallback: T) T {
    if (obj.get(key)) |raw_key| {
        return std.json.innerParseFromValue(T, allocator, raw_key, .{}) catch fallback;
    }
    return fallback;
}

fn parseStyle(obj: std.json.ObjectMap, allocator: std.mem.Allocator, fallback: vaxis.Cell.Style) vaxis.Cell.Style {
    const val = obj.get("style") orelse return fallback;
    if (val != .object) return fallback;

    var style = fallback;
    inline for (std.meta.fields(vaxis.Cell.Style)) |field| {
        if (val.object.get(field.name)) |field_val| {
            if (comptime std.mem.eql(u8, field.name, "fg") or std.mem.eql(u8, field.name, "bg") or std.mem.eql(u8, field.name, "ul")) {
                if (parseRGB(field_val, allocator)) |rgb| {
                    @field(style, field.name) = .{ .rgb = rgb };
                } else {
                    @field(style, field.name) = std.json.innerParseFromValue(field.type, allocator, field_val, .{}) catch @field(style, field.name);
                }
            } else {
                @field(style, field.name) = std.json.innerParseFromValue(field.type, allocator, field_val, .{}) catch @field(style, field.name);
            }
        }
    }

    return style;
}

fn parseRGB(val: std.json.Value, allocator: std.mem.Allocator) ?[3]u8 {
    switch (val) {
        .string => |str| {
            var hex = str;
            if (hex.len == 0) return null;
            if (std.mem.startsWith(u8, hex, "#")) hex = hex[1..];
            if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) hex = hex[2..];
            if (hex.len != 6) return null;

            const rgb_int = std.fmt.parseInt(u32, hex, 16) catch return null;
            const r = @as(u8, @intCast((rgb_int >> 16) & 0xFF));
            const g = @as(u8, @intCast((rgb_int >> 8) & 0xFF));
            const b = @as(u8, @intCast(rgb_int & 0xFF));
            return .{ r, g, b };
        },
        .object => |obj| {
            const rgb_val = obj.get("rgb") orelse return null;
            const rgb = std.json.innerParseFromValue([3]u8, allocator, rgb_val, .{}) catch return null;
            return rgb;
        },
        else => return null,
    }
}

fn parseItems(obj: std.json.ObjectMap, allocator: std.mem.Allocator, fallback_style: vaxis.Cell.Style) []const StatusBar.Item {
    const raw_items = obj.get("items") orelse {
        const items = allocator.alloc(StatusBar.Item, StatusBar.default_items.len) catch return StatusBar.default_items;
        for (StatusBar.default_items, 0..) |item, i| {
            items[i] = applyStyle(item, fallback_style, allocator);
        }
        return items;
    };

    if (raw_items != .array) return StatusBar.default_items;

    const items = allocator.alloc(StatusBar.Item, raw_items.array.items.len) catch return StatusBar.default_items;
    for (raw_items.array.items, 0..) |item, i| {
        items[i] = parseItem(item, allocator, fallback_style);
    }
    return items;
}

fn applyStyle(item: StatusBar.Item, style: vaxis.Cell.Style, allocator: std.mem.Allocator) StatusBar.Item {
    var styled_item: StatusBar.Item = .{ .styled = StatusBar.StyledItem{ .text = "", .style = style } };
    var mode_aware_item: StatusBar.Item = .{ .mode_aware = StatusBar.ModeAwareItem{
        .view = StatusBar.StyledItem{ .text = "", .style = style },
        .command = StatusBar.StyledItem{ .text = "", .style = style },
    } };
    var reload_aware_item: StatusBar.Item = .{ .reload_aware = StatusBar.ReloadAwareItem{
        .idle = StatusBar.StyledItem{ .text = "", .style = style },
        .reload = StatusBar.StyledItem{ .text = "", .style = style },
        .watching = StatusBar.StyledItem{ .text = "", .style = style },
    } };

    switch (item) {
        .styled => |styled| {
            styled_item.styled.text = allocator.dupe(u8, styled.text) catch styled_item.styled.text;
            return styled_item;
        },
        .mode_aware => |mode_aware| {
            mode_aware_item.mode_aware.view.text = allocator.dupe(u8, mode_aware.view.text) catch mode_aware_item.mode_aware.view.text;
            mode_aware_item.mode_aware.command.text = allocator.dupe(u8, mode_aware.command.text) catch mode_aware_item.mode_aware.command.text;
            return mode_aware_item;
        },
        .reload_aware => |reload_aware| {
            reload_aware_item.reload_aware.idle.text = allocator.dupe(u8, reload_aware.idle.text) catch reload_aware_item.reload_aware.idle.text;
            reload_aware_item.reload_aware.reload.text = allocator.dupe(u8, reload_aware.reload.text) catch reload_aware_item.reload_aware.reload.text;
            reload_aware_item.reload_aware.watching.text = allocator.dupe(u8, reload_aware.watching.text) catch reload_aware_item.reload_aware.watching.text;
            return reload_aware_item;
        },
    }
}

fn parseItem(val: std.json.Value, allocator: std.mem.Allocator, fallback_style: vaxis.Cell.Style) StatusBar.Item {
    var styled_item: StatusBar.Item = .{ .styled = StatusBar.StyledItem{ .text = "", .style = fallback_style } };
    var mode_aware_item: StatusBar.Item = .{ .mode_aware = StatusBar.ModeAwareItem{
        .view = StatusBar.StyledItem{ .text = "", .style = fallback_style },
        .command = StatusBar.StyledItem{ .text = "", .style = fallback_style },
    } };
    var reload_aware_item: StatusBar.Item = .{ .reload_aware = StatusBar.ReloadAwareItem{
        .idle = StatusBar.StyledItem{ .text = "", .style = fallback_style },
        .reload = StatusBar.StyledItem{ .text = "", .style = fallback_style },
        .watching = StatusBar.StyledItem{ .text = "", .style = fallback_style },
    } };

    switch (val) {
        .string => |str| {
            styled_item.styled.text = allocator.dupe(u8, str) catch "";
            return styled_item;
        },

        .object => |obj| {
            if (obj.contains("view") or obj.contains("command")) {
                mode_aware_item.mode_aware.view = parseStyledItem(obj.get("view"), allocator, mode_aware_item.mode_aware.view);
                mode_aware_item.mode_aware.command = parseStyledItem(obj.get("command"), allocator, mode_aware_item.mode_aware.command);
                return mode_aware_item;
            }
            if (obj.contains("idle") or obj.contains("reload") or obj.contains("watching")) {
                reload_aware_item.reload_aware.idle = parseStyledItem(obj.get("idle"), allocator, reload_aware_item.reload_aware.idle);
                reload_aware_item.reload_aware.reload = parseStyledItem(obj.get("reload"), allocator, reload_aware_item.reload_aware.reload);
                reload_aware_item.reload_aware.watching = parseStyledItem(obj.get("watching"), allocator, reload_aware_item.reload_aware.watching);
                return reload_aware_item;
            }

            styled_item.styled = parseStyledItem(val, allocator, styled_item.styled);
            return styled_item;
        },

        else => return styled_item,
    }
}

fn parseStyledItem(val: ?std.json.Value, allocator: std.mem.Allocator, fallback: StatusBar.StyledItem) StatusBar.StyledItem {
    const item = val orelse return fallback;

    var styled_item = fallback;
    switch (item) {
        .string => |str| {
            styled_item.text = allocator.dupe(u8, str) catch fallback.text;
            return styled_item;
        },
        .object => |obj| {
            if (obj.get("text")) |raw_text| {
                const text = std.json.innerParseFromValue([]const u8, allocator, raw_text, .{}) catch return styled_item;
                styled_item.text = allocator.dupe(u8, text) catch fallback.text;
            } else {
                styled_item.text = fallback.text;
            }
            if (obj.get("style")) |raw_style| {
                if (raw_style == .object)
                    styled_item.style = parseStyle(obj, allocator, fallback.style);
            }

            return styled_item;
        },
        else => return styled_item,
    }
}
