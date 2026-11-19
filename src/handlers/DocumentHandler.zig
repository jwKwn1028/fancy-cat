const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");
const PdfHandler = @import("./PdfHandler.zig");
const types = @import("./types.zig");

pub const FileFormat = enum {
    pdf,
    // epub,

    pub fn fromPath(path: []const u8) !FileFormat {
        if (std.mem.endsWith(u8, path, ".pdf")) {
            return .pdf;
        } // else if (std.mem.endsWith(u8, path, ".epub")) {
        //     return .epub;
        // }
        return types.DocumentError.UnsupportedFileFormat;
    }
};

pdf_handler: PdfHandler,
// The 0-based page to open at; the view keeps the position afterwards.
initial_page: u16,
file_format: FileFormat,

pub fn init(
    allocator: std.mem.Allocator,
    path: []const u8,
    initial_page: ?u16,
    config: *Config,
) !Self {
    // TODO use this for conditional rendering
    const format = try FileFormat.fromPath(path);

    var pdf_handler = try PdfHandler.init(allocator, path, config);
    errdefer pdf_handler.deinit();

    const first = if (initial_page) |page| blk: {
        if (page < 1 or page > pdf_handler.total_pages) {
            return types.DocumentError.InvalidPageNumber;
        }
        break :blk page - 1;
    } else 0;

    return .{
        .pdf_handler = pdf_handler,
        .initial_page = first,
        .file_format = format,
    };
}

pub fn deinit(self: *Self) void {
    self.pdf_handler.deinit();
}

pub fn toggleColor(self: *Self) void {
    self.pdf_handler.toggleColor();
}

pub fn getPath(self: *Self) []const u8 {
    return self.pdf_handler.path;
}

pub fn getTotalPages(self: *Self) u16 {
    return self.pdf_handler.total_pages;
}
