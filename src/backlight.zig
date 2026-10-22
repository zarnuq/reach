// backlight.zig — hardware panel backlight for the `brightness` action.
//
// A laptop's brightness keys should drive the real backlight (actual power
// saving); a desktop has no backlight device, so the same action falls back to
// reach's gamma dimming. action.zig picks backlight when available() else gamma,
// and ipc.zig publishes whichever is live so the panel's OSD tracks the right one.
//
// The sysfs node (e.g. amdgpu_bl0/brightness) is made wheel-writable by the
// user's 99-powermode.rules udev rule; reach runs in `wheel`, so no root is
// needed. Without the rule step() logs once and no-ops — gamma is NOT a safe
// fallback once a panel is detected, or the keys would do two different things.
//
// libc file + dir IO, like confparse.zig: this Zig's std.posix is gutted and the
// rest of the tree already calls libc directly.

const std = @import("std");
const log = std.log.scoped(.backlight);
const c = std.c;

const base = "/sys/class/backlight";
const min_pct: i64 = 1;

var dir_buf: [256]u8 = undefined;
var dir: ?[:0]const u8 = null; // chosen device directory, NUL-terminated
var max: i64 = 0;

/// Find the first backlight device and read its max_brightness. Called once at
/// startup; if none is found available() stays false and the action uses gamma.
pub fn init() void {
    const d = c.opendir(base) orelse return;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (name.len == 0 or name[0] == '.') continue;
        dir = std.fmt.bufPrintZ(&dir_buf, "{s}/{s}", .{ base, name }) catch return;
        max = readIntZ("max_brightness") orelse 0;
        if (max > 0) {
            log.info("backlight: {s} (max {d})", .{ dir.?, max });
            return;
        }
        dir = null;
    }
}

pub fn available() bool {
    return dir != null;
}

fn pathZ(buf: []u8, file: []const u8) ?[:0]const u8 {
    const d = dir orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ d, file }) catch null;
}

fn readIntZ(file: []const u8) ?i64 {
    var pbuf: [320]u8 = undefined;
    const p = pathZ(&pbuf, file) orelse return null;
    const f = c.fopen(p.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var fbuf: [32]u8 = undefined;
    const got = c.fread(&fbuf, 1, fbuf.len, f); // sysfs: one short read, no seek
    if (got == 0) return null;
    const s = std.mem.trim(u8, fbuf[0..got], " \n\r\t");
    return std.fmt.parseInt(i64, s, 10) catch null;
}

/// Current brightness as a percent (0-100); 100 when unavailable or unreadable.
pub fn brightness() i32 {
    if (dir == null or max <= 0) return 100;
    const cur = readIntZ("brightness") orelse return 100;
    return @intCast(@divTrunc(cur * 100, max));
}

/// Step brightness by `delta` percent, clamped to [min_pct, 100].
pub fn step(delta: i32) void {
    if (dir == null or max <= 0) return;
    const cur: i64 = brightness();
    const next = std.math.clamp(cur + delta, min_pct, 100);
    if (next == cur) return;
    const val = @divTrunc(next * max, 100);

    var pbuf: [320]u8 = undefined;
    const p = pathZ(&pbuf, "brightness") orelse return;
    const f = c.fopen(p.ptr, "w") orelse {
        log.warn("backlight not writable (99-powermode.rules udev rule missing?)", .{});
        return;
    };
    defer _ = c.fclose(f);
    var vbuf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&vbuf, "{d}", .{val}) catch return;
    _ = c.fwrite(s.ptr, 1, s.len, f);
}
