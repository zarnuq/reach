// render/font.zig — fcft-backed text rendering.
//
// fcft does the heavy lifting (fontconfig name resolution, freetype
// rasterization, antialiasing, fallback fonts for Nerd Font glyphs). We keep a
// thin wrapper that loads a font by name and blits a rasterized run into a bar
// buffer. This is the same library dwlb and kwm use, so "JetBrainsMono Nerd
// Font:size=11" renders identically to the user's current bar.
//
// One Font is shared process-wide (loaded once in main). reach assumes
// scale 1 (no fractional-scale handling yet), so we ask fcft for the default dpi.

const std = @import("std");
const log = std.log.scoped(.font);

const fcft = @import("fcft");
const pixman = @import("pixman");

const utils = @import("utils.zig");
const Buffer = @import("buffer.zig");

font: *fcft.Font,

const Self = @This();

/// Initialise the fcft library itself. Must be called once before loading fonts.
pub fn initLibrary() !void {
    // (colorize logs: auto, no syslog, only surface fcft errors)
    if (!fcft.init(.auto, false, .err)) return error.FcftInitFailed;
}

/// Load a font described by an fcft/fontconfig name like
/// "JetBrainsMono Nerd Font:size=11".
pub fn init(self: *Self, gpa: std.mem.Allocator, font_name: []const u8) !void {
    const name = try gpa.dupeZ(u8, font_name);
    defer gpa.free(name);

    var names = [_][*:0]const u8{name.ptr};
    self.* = .{ .font = try fcft.Font.fromName(&names, null) };
    log.info("loaded font '{s}' (height {d}px)", .{ font_name, self.font.height });
}

pub fn deinit(self: *Self) void {
    self.font.destroy();
}

/// Cell height of the font in pixels — the bar's natural height.
pub inline fn height(self: *const Self) i32 {
    return self.font.height;
}

/// Pixel width a string would occupy if drawn (0 on failure). Used to size the
/// bar's tag cells and right-align the status.
pub fn strWidth(self: *const Self, gpa: std.mem.Allocator, str: []const u8) i32 {
    const run = self.rasterize(gpa, str) orelse return 0;
    defer run.destroy();
    return @intCast(utils.textWidth(run));
}

/// Rasterize a UTF-8 string into a reusable text run, or null on failure. Caller
/// must `.destroy()` the returned run. Antialiasing is on; subpixel off (we draw
/// over an arbitrary background, where subpixel order can't be assumed).
pub fn rasterize(self: *const Self, gpa: std.mem.Allocator, str: []const u8) ?*const fcft.TextRun {
    const utf8 = utils.toUtf8(gpa, str) catch return null;
    defer gpa.free(utf8);
    return self.font.rasterizeTextRunUtf32(utf8, .none) catch |err| {
        log.warn("rasterize failed: {}", .{err});
        return null;
    };
}

/// Blit a rasterized run into `buffer` at baseline-corrected (x, y), in color
/// `c`. Returns the total advance (how far x moved), so callers can chain runs.
/// Mirrors kwm/dwlb: each glyph is an alpha mask, composited via a solid-fill
/// source so the glyph takes the requested color.
pub fn renderRun(
    self: *const Self,
    buffer: *Buffer,
    text: *const fcft.TextRun,
    c: *const pixman.Color,
    x: i32,
    y: i32,
) i32 {
    const src = pixman.Image.createSolidFill(c) orelse {
        log.err("createSolidFill failed", .{});
        return 0;
    };
    defer _ = src.unref();

    var offset: i32 = 0;
    for (0..text.count) |i| {
        const glyph = text.glyphs[i];
        offset += @intCast(glyph.x);
        pixman.Image.composite32(
            .over,
            src,
            glyph.pix, // glyph alpha mask
            buffer.image,
            0,
            0,
            0,
            0,
            x + offset,
            y + self.font.ascent - glyph.y,
            glyph.width,
            glyph.height,
        );
        offset += @intCast(glyph.advance.x - glyph.x);
        if (x + offset >= buffer.width) break;
    }
    return offset;
}

/// Convenience: rasterize a UTF-8 string and render it in one call, returning
/// its advance. Used for short single-color labels (layout symbol, title).
pub fn renderStr(
    self: *const Self,
    gpa: std.mem.Allocator,
    buffer: *Buffer,
    str: []const u8,
    c: *const pixman.Color,
    x: i32,
    y: i32,
) i32 {
    const text = self.rasterize(gpa, str) orelse return 0;
    defer text.destroy();
    return self.renderRun(buffer, text, c, x, y);
}
