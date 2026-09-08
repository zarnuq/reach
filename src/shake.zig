// shake.zig — shake the mouse, and `cursor.shake.command` runs.
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
//
// That test only answers "is this shaking right now". What makes it feel right
// is requiring it to stay true for `shake.delay` — an overshoot-and-correct
// looks like a shake for a moment, a real shake keeps looking like one. So the
// ratio tuning below stays fixed and permissive, and `delay` is the whole
// user-facing surface.
//
// A shake used to grow the cursor from here. It no longer does anything itself:
// it spawns `cursor.shake.command`. Growing was possible because a cursor size
// is just a number handed to set_xcursor_theme — but the deltas above are the
// ONLY pointer information reach has, and you cannot draw at a cursor whose
// position you don't know. The base cursor theme/size is still applied from
// this file (applyPending), which is why the pending_size plumbing stays.

const std = @import("std");
const linux = std.os.linux;
const log = std.log.scoped(.shake);

const config = @import("config.zig");
const Context = @import("context.zig");
const action = @import("action.zig");

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
const EV_KEY: u16 = 0x01;
const EV_REL: u16 = 0x02;
const EV_ABS: u16 = 0x03;
const REL_X: u16 = 0x00;
const REL_Y: u16 = 0x01;
const ABS_X: u16 = 0x00;
const ABS_Y: u16 = 0x01;
/// Finger down/up on a touch device. Releasing invalidates the last position, so
/// lifting and re-placing doesn't read as one enormous jump across the pad.
const BTN_TOUCH: u16 = 0x14a;

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

/// Motion is folded into history at most this often, so a 1 kHz mouse and a
/// 125 Hz one give comparable history. Deltas in between are accumulated, not
/// dropped.
const SAMPLE_INTERVAL_US = 4000;

/// Covers WINDOW_US at SAMPLE_INTERVAL_US with room to spare (512 * 4 ms ≈ 2 s).
const MAX_SAMPLES = 512;

// Detector tuning. Deliberately not exposed: `shake.delay` is the knob that
// governs how easy this is to set off, and it does so far more predictably than
// a ratio threshold. These are set permissive on purpose — the instantaneous
// test just answers "does this look like shaking right now", and sustaining it
// for `delay` is what separates a real shake from an overshoot-and-correct.

/// Travel-to-diagonal ratio. Works out to about "sweeps per WINDOW_US", so 2.0
/// over 500 ms is a lazy 2 Hz shake.
const THRESHOLD: f64 = 2.0;

/// Floor in raw device counts/sec — unaccelerated, so independent of pointer
/// speed settings. Rejects slow scribbling that would otherwise score well.
const MIN_SPEED: f64 = 250.0;

/// Trailing motion history. Longer makes a sustained shake score higher: the
/// bounding box stops growing once you oscillate in place, while travel keeps
/// piling up.
const WINDOW_US: u64 = 500_000;

/// Gap tolerated between qualifying samples before the shake counts as broken,
/// so the ratio dipping between reversals doesn't reset progress.
const GAP_US: u64 = 100_000;

/// Headroom the sustained-shake accumulator may bank past `delay`: enough that
/// a momentary dip doesn't drop back under the threshold, not so much that a
/// long shake banks seconds it would then take just as long to bleed off.
const OVERSHOOT_US: u64 = 500_000;

const Sample = struct {
    t_us: u64,
    x: f64,
    y: f64,
    /// Distance from the previous sample, so path length stays incremental.
    seg: f64,
};

pub var device_fds: [MAX_DEVICES]i32 = [_]i32{-1} ** MAX_DEVICES;
pub var device_count: usize = 0;

// Absolute devices report a POSITION, not a delta, so each one needs its own
// previous position to subtract — unlike the relative path, where every device
// can pour straight into the shared accumulator.
//
// `have` is per AXIS, and is set by the sample that stores the coordinate rather
// than by the finger-down event: a touchpad sends BTN_TOUCH before the position,
// so trusting the press would difference the first sample of a touch against
// wherever the LAST touch ended — one jump the width of the pad, every time a
// finger lands.
var device_abs: [MAX_DEVICES]bool = [_]bool{false} ** MAX_DEVICES;
var abs_x: [MAX_DEVICES]i32 = undefined;
var abs_y: [MAX_DEVICES]i32 = undefined;
var abs_have_x: [MAX_DEVICES]bool = [_]bool{false} ** MAX_DEVICES;
var abs_have_y: [MAX_DEVICES]bool = [_]bool{false} ** MAX_DEVICES;

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

var sent_size: u32 = 0;
var pending_size: ?u32 = null;
var last_shake_us: u64 = 0; // last time the ratio test passed
var shake_us: u64 = 0; // how long the shake has been sustained
var fired: bool = false; // command already run for this shake
var last_tick_us: u64 = 0;

fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// How a pointing device reports motion, or null if it doesn't point.
///
/// Both kinds are taken. A mouse or TrackPoint is relative; a TOUCHPAD is
/// absolute, and taking only the relative kind is what made shake-to-find work
/// on the TrackPoint but not the trackpad of the same laptop. An I2C touchpad
/// does also expose a REL mouse-emulation node that passes the relative test —
/// but it stays silent while hid-multitouch drives the real ABS node, so it is
/// opened and never heard from.
const Kind = enum { relative, absolute };

fn pointerKind(fd: c_int) ?Kind {
    var evbits = [_]u8{0} ** 4;
    if (C.ioctl(fd, EVIOCGBIT(0, evbits.len), &evbits) < 0) return null;

    if (evbits[EV_REL >> 3] & (@as(u8, 1) << @intCast(EV_REL & 7)) != 0) {
        var relbits = [_]u8{0} ** 2;
        if (C.ioctl(fd, EVIOCGBIT(EV_REL, relbits.len), &relbits) >= 0) {
            const need: u8 = (1 << REL_X) | (1 << REL_Y);
            if (relbits[0] & need == need) return .relative;
        }
    }

    if (evbits[EV_ABS >> 3] & (@as(u8, 1) << @intCast(EV_ABS & 7)) != 0) {
        var absbits = [_]u8{0} ** 8;
        if (C.ioctl(fd, EVIOCGBIT(EV_ABS, absbits.len), &absbits) >= 0) {
            const need: u8 = (1 << ABS_X) | (1 << ABS_Y);
            if (absbits[0] & need == need) return .absolute;
        }
    }

    return null;
}

pub fn start() void {
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
        const kind = pointerKind(fd) orelse {
            _ = C.close(fd);
            continue;
        };
        device_fds[device_count] = fd;
        device_abs[device_count] = kind == .absolute;
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

/// Close every watched device and disarm the animation timer, so `start` can be
/// re-run against a changed `config.cursor`. The event loop rebuilds its pollfd set
/// from `device_fds`/`device_count` each iteration, so clearing them here is enough
/// — but this must not run mid-poll, hence reload's manage-cycle deferral.
pub fn stop() void {
    for (device_fds[0..device_count]) |fd| _ = C.close(fd);
    device_fds = [_]i32{-1} ** MAX_DEVICES;
    device_count = 0;

    if (timer_fd) |fd| {
        _ = C.close(fd);
        timer_fd = null;
    }

    // Drop the detector's history; the samples describe a gesture that is no
    // longer in progress on devices that no longer exist.
    head = 0;
    count = 0;
    path_sum = 0;
    vx = 0;
    vy = 0;
    acc_x = 0;
    acc_y = 0;
    shake_us = 0;
    fired = false;
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
                // A position, differenced against this device's last one to give
                // the accumulator the same kind of delta the relative branch
                // hands it. The first sample of a touch only sets the origin.
                // Guarded on `device_abs` so a hybrid device classified relative
                // can't feed the same motion in twice.
                EV_ABS => if (device_abs[index]) switch (ev.code) {
                    ABS_X => {
                        if (abs_have_x[index]) acc_x += @floatFromInt(ev.value - abs_x[index]);
                        abs_x[index] = ev.value;
                        abs_have_x[index] = true;
                    },
                    ABS_Y => {
                        if (abs_have_y[index]) acc_y += @floatFromInt(ev.value - abs_y[index]);
                        abs_y[index] = ev.value;
                        abs_have_y[index] = true;
                    },
                    else => {},
                },
                // Finger up: forget the origin, so the next touch landing
                // elsewhere on the pad isn't counted as travel between the two.
                EV_KEY => if (ev.code == BTN_TOUCH and ev.value == 0) {
                    abs_have_x[index] = false;
                    abs_have_y[index] = false;
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
    while (count > 1 and now - samples[head].t_us > WINDOW_US) dropOldest();
}

fn isShaking(now: u64) bool {
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
    if (speed < MIN_SPEED) return false;

    return path_sum / diag >= THRESHOLD;
}

/// Drives the sustained-shake accumulator. Returns true if river needs a manage
/// cycle — nothing here changes the cursor any more, so always false.
pub fn onTimer() bool {
    var buf: [8]u8 = undefined;
    _ = C.read(timer_fd.?, &buf, buf.len);

    const sh = config.cursor.shake;
    const now = nowUs();
    const dt_us = now - last_tick_us;
    last_tick_us = now;

    const delay_us = @as(u64, sh.delay) * 1000;

    // Is the motion still qualifying? sampleMotion stamps last_shake_us on every
    // pass; GAP_US of slack keeps a dip between reversals from breaking it.
    const qualifying = now - last_shake_us < GAP_US;

    // Sustained-shake accumulator. Builds while shaking, and bleeds off at twice
    // the rate when not, so a stray flick never banks progress toward `delay`.
    if (qualifying) {
        shake_us = @min(shake_us + dt_us, delay_us + OVERSHOOT_US);
    } else {
        shake_us -= @min(shake_us, dt_us * 2);
    }

    // Must be shaking now AND have been for long enough. The `qualifying` term
    // is what keeps delay = 0 from meaning "always armed".
    const armed = qualifying and shake_us >= delay_us;

    // Once per shake. `fired` clears only when the accumulator has bled all the
    // way off, so keeping the shake going doesn't re-run the command every tick
    // and a dip mid-shake doesn't count as a second gesture.
    if (armed and !fired) {
        fired = true;
        if (sh.command.len != 0) action.spawn(sh.command);
    }

    // Fully settled: stop ticking and forget the history so the next shake
    // starts from a clean window.
    if (!qualifying and shake_us == 0) {
        fired = false;
        armTimer(false);
        last_tick_us = 0;
        head = 0;
        count = 0;
        path_sum = 0;
    }

    return false;
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
