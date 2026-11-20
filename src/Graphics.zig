const std = @import("std");
const Writer = std.Io.Writer;

pub const Transport = enum {
    direct,
    tmux,
};

pub fn delete(w: *Writer, id: u32) !void {
    try w.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{id});
}

/// tmux resets modes after each passthrough envelope; batch a frame's images.
pub const TmuxBatch = struct {
    writer: *Writer,
    started: bool = false,

    pub fn beginCommand(self: *TmuxBatch) !*Writer {
        if (!self.started) {
            try self.writer.writeAll("\x1bPtmux;");
            self.started = true;
        }
        try self.writer.writeAll("\x1b\x1b_G");
        return self.writer;
    }

    pub fn endCommand(self: *TmuxBatch) !void {
        try self.writer.writeAll("\x1b\x1b\\");
    }

    pub fn deleteImage(self: *TmuxBatch, id: u32) !void {
        const w = try self.beginCommand();
        try w.print("a=d,d=I,i={d},q=2", .{id});
        try self.endCommand();
    }

    pub fn finish(self: *TmuxBatch) !void {
        if (self.started) try self.writer.writeAll("\x1b\\");
    }
};
