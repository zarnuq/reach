// render/utils.zig — small helpers shared by the font and bar code.
//
// These wrap the two foreign libraries (fcft for fonts, pixman for compositing)
// in the couple of conversions Confluence actually needs: UTF-8 → UTF-32 (fcft
// rasterizes codepoint arrays), measuring a rasterized run's width, and turning
// our 0xRRGGBBAA config colors into pixman's 16-bit-per-channel `Color`.

const std = @import("std");
const mem = std.mem;
const unicode = std.unicode;

const fcft = @import("fcft");
const pixman = @import("pixman");

/// Decode a UTF-8 byte slice into an owned array of Unicode codepoints. fcft's
/// text-run rasterizer takes `[]const u32`. Caller frees with `gpa.free`.
pub fn toUtf8(gpa: mem.Allocator, bytes: []const u8) ![]u32 {
    const view = try unicode.Utf8View.init(bytes);
    var iter = view.iterator();

    var runes = try std.ArrayList(u32).initCapacity(gpa, bytes.len);
    while (iter.nextCodepoint()) |rune| {
        runes.appendAssumeCapacity(rune);
    }
    return try runes.toOwnedSlice(gpa);
}

/// Total horizontal advance (pixels) of a rasterized text run — i.e. how wide
/// the string will be once drawn. Used to right-align the status text.
pub fn textWidth(text: *const fcft.TextRun) u32 {
    var width: u32 = 0;
    for (0..text.count) |i| {
        width += @intCast(text.glyphs[i].advance.x);
    }
    return width;
}

/// Convert a packed 0xRRGGBBAA color (the form used throughout config.zig) into
/// a pixman 16-bit-per-channel color. Each 8-bit channel is scaled to 16 bits by
/// the usual `*257` (0xFF → 0xFFFF) expansion.
pub fn color(rgba: u32) pixman.Color {
    const r: u16 = @intCast((rgba >> 24) & 0xff);
    const g: u16 = @intCast((rgba >> 16) & 0xff);
    const b: u16 = @intCast((rgba >> 8) & 0xff);
    const a: u16 = @intCast(rgba & 0xff);
    return .{
        .red = r * 257,
        .green = g * 257,
        .blue = b * 257,
        .alpha = a * 257,
    };
}
