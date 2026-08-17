// shake.zig — shake the mouse, the cursor grows, then settles back.
//
// Detection reads raw deltas from /dev/input/event* rather than the protocol:
// river_seat_v1.pointer_position only arrives inside a manage sequence, and
// motion alone is explicitly forbidden from starting one, so shaking inside a
// single window would yield almost no samples. Needs no elevation — the devices
// are root:input 0660 and the user is normally in `input`.
//
// Detector is Hyprland's: over a trailing window of motion, compare distance
// travelled against the diagonal of the box it stayed inside. A shake piles up
// travel in a small box; a straight swipe has travel ≈ diagonal and never fires.

const std = @import("std");
const linux = std.os.linux;
const log = std.log.scoped(.shake);

const config = @import("config.zig");
const Context = @import("context.zig");

// This Zig's std.posix has no open/ioctl; the codebase already calls libc
// directly elsewhere (popen, fopen, setenv).
const C = struct {
    extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern fn read(fd: c_int, buf: [*]u8, nbyte: usize) isize;
    extern fn close(fd: c_int) c_int;
    extern fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

    const O_RDONLY: c_int = 0;
    const O_NONBLOCK: c_int = 0o4000;
    const O_CLOEXEC: c_int = 0o2000000;
};

const EV_SYN: u16 = 0x00;
const EV_REL: u16 = 0x02;
const REL_X: u16 = 0x00;
const REL_Y: u16 = 0x01;

const InputEvent = extern struct {
    sec: i64,
    usec: i64,
    type: u16,
    code: u16,
    value: i32,
};

/// _IOC(_IOC_READ, 'E', 0x20 + ev, len)
fn EVIOCGBIT(ev: u32, len: u32) c_ulong {
    return (@as(c_ulong, 2) << 30) | (@as(c_ulong, len) << 16) |
        (@as(c_ulong, 'E') << 8) | (0x20 + @as(c_ulong, ev));
}

const MAX_DEVICES = 8;
const MAX_SAMPLES = 256;

/// Motion is folded into history at most this often, so a 1 kHz mouse and a
/// 125 Hz one give comparable history. Deltas in between are accumulated, not
/// dropped.
const SAMPLE_INTERVAL_US = 2000;

const Sample = struct {
    t_us: u64,
    x: f64,
    y: f64,
    /// Distance from the previous sample, so path length stays incremental.
    seg: f64,
};

pub var device_fds: [MAX_DEVICES]i32 = [_]i32{-1} ** MAX_DEVICES;
pub var device_count: usize = 0;

/// Animation tick; armed only while the size is moving.
pub var timer_fd: ?i32 = null;

var samples: [MAX_SAMPLES]Sample = undefined;
var head: usize = 0;
var count: usize = 0;
var path_sum: f64 = 0; // sum of seg over every sample except the oldest

var vx: f64 = 0;
var vy: f64 = 0;
var acc_x: f64 = 0;
var acc_y: f64 = 0;
var last_sample_us: u64 = 0;

var cur_size: f32 = 0;
var sent_size: u32 = 0;
var pending_size: ?u32 = null;
var last_shake_us: u64 = 0;
var last_tick_us: u64 = 0;

fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// Relative pointing devices only — absolute ones (touchscreens, tablets) don't
/// shake meaningfully.
fn isPointer(fd: c_int) bool {
    var evbits = [_]u8{0} ** 4;
    if (C.ioctl(fd, EVIOCGBIT(0, evbits.len), &evbits) < 0) return false;
    if (evbits[EV_REL >> 3] & (@as(u8, 1) << @intCast(EV_REL & 7)) == 0) return false;

    var relbits = [_]u8{0} ** 2;
    if (C.ioctl(fd, EVIOCGBIT(EV_REL, relbits.len), &relbits) < 0) return false;
    const need: u8 = (1 << REL_X) | (1 << REL_Y);
    return relbits[0] & need == need;
}

pub fn start() void {
    cur_size = @floatFromInt(config.cursor.size);
    sent_size = config.cursor.size;
    pending_size = config.cursor.size;

    if (!config.cursor.shake.enabled) return;

    // Probing by number avoids a directory walk (no opendir in this std.posix).
    var name_buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < 64 and device_count < MAX_DEVICES) : (i += 1) {
        const path = std.fmt.bufPrintZ(&name_buf, "/dev/input/event{d}", .{i}) catch continue;
        const fd = C.open(path.ptr, C.O_RDONLY | C.O_NONBLOCK | C.O_CLOEXEC);
        if (fd < 0) continue;
        if (!isPointer(fd)) {
            _ = C.close(fd);
            continue;
        }
        device_fds[device_count] = fd;
        device_count += 1;
    }

    if (device_count == 0) {
        log.warn("no readable pointer device in /dev/input — is this user in the `input` group?", .{});
        return;
    }

    const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
    if (linux.errno(tfd) != .SUCCESS) {
        log.warn("timerfd_create failed: errno {} — shake disabled", .{linux.errno(tfd)});
        return;
    }
    timer_fd = @intCast(tfd);
    log.info("shake to find: watching {d} pointer device(s)", .{device_count});
}

fn armTimer(on: bool) void {
    const fd = timer_fd orelse return;
    const ns: isize = if (on) 16_000_000 else 0; // ~60 Hz
    const spec = linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = ns },
        .it_value = .{ .sec = 0, .nsec = ns },
    };
    _ = linux.timerfd_settime(fd, .{}, &spec, null);
}

/// Drain one device. Returns true if river needs a manage cycle.
pub fn onMotion(index: usize) bool {
    if (index >= device_count) return false;
    const fd = device_fds[index];

    var buf: [@sizeOf(InputEvent) * 32]u8 align(@alignOf(InputEvent)) = undefined;
    var moved = false;

    while (true) {
        const n = C.read(fd, &buf, buf.len);
        if (n <= 0) break;
        const events = std.mem.bytesAsSlice(InputEvent, buf[0..@intCast(n)]);
        for (events) |ev| {
            switch (ev.type) {
                EV_REL => switch (ev.code) {
                    REL_X => acc_x += @floatFromInt(ev.value),
                    REL_Y => acc_y += @floatFromInt(ev.value),
                    else => {},
                },
                EV_SYN => moved = true,
                else => {},
            }
        }
        if (@as(usize, @intCast(n)) < buf.len) break;
    }

    if (!moved) return false;
    sampleMotion();
    return false;
}

fn sampleMotion() void {
    const now = nowUs();
    if (now - last_sample_us < SAMPLE_INTERVAL_US) return;
    last_sample_us = now;

    const dx = acc_x;
    const dy = acc_y;
    acc_x = 0;
    acc_y = 0;
    vx += dx;
    vy += dy;

    push(.{ .t_us = now, .x = vx, .y = vy, .seg = @sqrt(dx * dx + dy * dy) });
    prune(now);

    if (isShaking(now)) {
        last_shake_us = now;
        if (timer_fd != null and last_tick_us == 0) {
            last_tick_us = now;
            armTimer(true);
        }
    }
}

fn push(s: Sample) void {
    if (count == MAX_SAMPLES) dropOldest();
    samples[(head + count) % MAX_SAMPLES] = s;
    if (count > 0) path_sum += s.seg;
    count += 1;
}

fn dropOldest() void {
    if (count == 0) return;
    head = (head + 1) % MAX_SAMPLES;
    count -= 1;
    if (count > 0) path_sum -= samples[head].seg;
}

fn prune(now: u64) void {
    const window_us = @as(u64, config.cursor.shake.window_ms) * 1000;
    while (count > 1 and now - samples[head].t_us > window_us) dropOldest();
}

fn isShaking(now: u64) bool {
    const sh = config.cursor.shake;
    if (count < 8) return false;
    const span_us = now - samples[head].t_us;
    if (span_us < 50_000) return false;

    var min_x = samples[head].x;
    var max_x = min_x;
    var min_y = samples[head].y;
    var max_y = min_y;
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const s = samples[(head + i) % MAX_SAMPLES];
        min_x = @min(min_x, s.x);
        max_x = @max(max_x, s.x);
        min_y = @min(min_y, s.y);
        max_y = @max(max_y, s.y);
    }

    const w = max_x - min_x;
    const h = max_y - min_y;
    const diag = @sqrt(w * w + h * h);
    if (diag < 1.0) return false;

    const speed = path_sum / (@as(f64, @floatFromInt(span_us)) / 1_000_000.0);
    if (speed < sh.min_speed) return false;

    return path_sum / diag >= sh.threshold;
}

/// Returns true if the quantised size changed.
pub fn onTimer() bool {
    var buf: [8]u8 = undefined;
    _ = C.read(timer_fd.?, &buf, buf.len);

    const sh = config.cursor.shake;
    const now = nowUs();
    const dt = @as(f32, @floatFromInt(now - last_tick_us)) / 1_000_000.0;
    last_tick_us = now;

    const base: f32 = @floatFromInt(config.cursor.size);
    const max: f32 = @floatFromInt(sh.max_size);
    const since_shake = now - last_shake_us;
    const hold_us = @as(u64, sh.hold_ms) * 1000;

    if (since_shake < 100_000) {
        cur_size = @min(max, cur_size + sh.grow_rate * dt);
    } else if (since_shake < hold_us) {
        // hold — keeps the size from flickering as the ratio dips between reversals
    } else {
        cur_size = @max(base, cur_size - sh.shrink_rate * dt);
    }

    if (cur_size <= base and since_shake >= hold_us) {
        cur_size = base;
        armTimer(false);
        last_tick_us = 0;
        head = 0;
        count = 0;
        path_sum = 0;
    }

    const q = quantise(cur_size);
    if (q != sent_size) {
        pending_size = q;
        return true;
    }
    return false;
}

/// Every distinct size costs the compositor an xcursor load plus a texture
/// upload, and themes only hold a handful of real sizes.
fn quantise(v: f32) u32 {
    const base: f32 = @floatFromInt(config.cursor.size);
    const max: f32 = @floatFromInt(config.cursor.shake.max_size);
    const step: f32 = @floatFromInt(@max(1, config.cursor.shake.size_step));
    const snapped = base + @round((v - base) / step) * step;
    return @intFromFloat(@max(base, @min(max, snapped)));
}

/// Called from the manage cycle. set_xcursor_theme isn't marked manage-only, but
/// issuing it inside a sequence is valid either way.
pub fn applyPending() void {
    const size = pending_size orelse return;
    const ctx = Context.get();
    const seat = ctx.primary_seat orelse return; // no seat yet; retry next cycle
    pending_size = null;
    seat.rwm.setXcursorTheme(config.cursor.theme.ptr, size);
    sent_size = size;
}
