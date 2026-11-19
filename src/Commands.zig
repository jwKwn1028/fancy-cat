//! Commands typed after ':' and run by keys mapped in the config's "Maps".
const std = @import("std");
const Context = @import("Context.zig").Context;
const Spawn = @import("utilities/Spawn.zig");

pub fn execute(ctx: *Context, cmd: []const u8) void {
    if (quit(ctx, cmd)) return;
    if (goToPage(ctx, cmd)) return;
    if (zoom(ctx, cmd)) return;
    if (scroll(ctx, cmd)) return;
    if (exec(ctx, cmd)) return;
    ctx.showMessage("Unknown command: {s}", .{cmd});
}

fn quit(ctx: *Context, cmd: []const u8) bool {
    if (!std.mem.eql(u8, cmd, "q") and !std.mem.eql(u8, cmd, "quit")) return false;
    ctx.should_quit = true;
    return true;
}

fn goToPage(ctx: *Context, cmd: []const u8) bool {
    const page_num = (std.fmt.parseInt(u16, cmd, 10) catch return false);
    if (page_num < 1 or page_num > ctx.document_handler.getTotalPages()) {
        ctx.showMessage("No page {d}", .{page_num});
        return true;
    }
    ctx.view.recordJump();
    ctx.view.goToPage(page_num - 1);
    return true;
}

fn zoom(ctx: *Context, cmd: []const u8) bool {
    if (!std.mem.endsWith(u8, cmd, "%")) return false;

    const number_str = cmd[0 .. cmd.len - 1];
    if (std.fmt.parseFloat(f32, number_str)) |percent| {
        ctx.view.setZoomPercent(percent);
        return true;
    } else |_| {
        return false;
    }
}

fn scroll(ctx: *Context, cmd: []const u8) bool {
    if (cmd.len < 3) return false;
    const axis = cmd[0];
    const sign = cmd[1];
    if ((axis != 'x' and axis != 'y') or (sign != '+' and sign != '-')) return false;

    const number_str = cmd[2..];

    if (std.fmt.parseFloat(f32, number_str)) |amount| {
        // Pixels: y+ scrolls down, x+ pans right.
        const delta = if (sign == '+') amount else -amount;
        if (axis == 'x') ctx.view.panBy(delta) else ctx.view.scrollBy(delta);
        return true;
    } else |_| {
        return false;
    }
}

// exec CMD: runs CMD with sh, detached, with $FILE set to the document and
// $PAGE to the current page, as zathura's :exec does.
fn exec(ctx: *Context, cmd: []const u8) bool {
    const prefix = "exec ";
    if (!std.mem.startsWith(u8, cmd, prefix)) return false;
    const command = std.mem.trim(u8, cmd[prefix.len..], " ");
    if (command.len == 0) return false;

    const file: []const u8 = ctx.absolute_path orelse ctx.document_handler.getPath();
    const page = ctx.currentPage() + 1;
    Spawn.detached(ctx.allocator, &.{ "/bin/sh", "-c", command }, file, page) catch |err| {
        ctx.showMessage("exec failed: {s}", .{@errorName(err)});
    };
    return true;
}
