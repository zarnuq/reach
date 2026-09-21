// gamma.zig — screen dimming and colour temperature, via wlr-gamma-control.
//
// WHY THIS LIVES IN THE WINDOW MANAGER. `zwlr_gamma_control_v1` is not a
// fire-and-forget request: the client has to HOLD the control object for as long
// as the adjustment should last, the compositor restores the output's original
// ramp the moment it is destroyed, and only one client per output may hold one.
// So whatever owns gamma has to be the longest-lived process in the session —
// which is reach: if it exits, the session is over anyway. The alternative (and
// what this replaced) is a standalone daemon plus a D-Bus round trip per
// keypress, and a second subprocess in the panel to read the value back out.
//
// Like output modes (outputconfig.zig), gamma is NOT part of
// river-window-management: it goes through the standard wlroots protocol river
// implements, bound from the registry like any other global.
//
// THE SPLIT BETWEEN THE TWO KNOBS is deliberate. Brightness is runtime state,
// stepped by the `brightness` action — that is the whole keybind path, and it
// costs no process and no round trip. Temperature is config-only
// (`config.gamma.temperature`): editing config.zon and reloading is the entire
// night-light interface, so there is no action and no IPC for it.

const std = @import("std");
const log = std.log.scoped(.gamma);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const config = @import("config.zig");
const Context = @import("context.zig");

// libc for the memfd the protocol wants. Same reason the rest of the codebase
// calls libc directly (ipc.zig's sockets, confparse.zig's file IO): this Zig's
// std.posix doesn't wrap all of it, and we link libc regardless.
const C = struct {
    extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
    extern fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
    extern fn lseek(fd: c_int, off: c_long, whence: c_int) c_long;
    extern fn close(fd: c_int) c_int;
    const SEEK_SET: c_int = 0;
};

/// Largest ramp we will write. Hardware is 256 or 1024 entries; the cap is what
/// keeps this allocation-free on a fixed buffer.
const max_ramp = 4096;

/// A keybind must never be able to take the screen to black — you would have no
/// way to see the binding that brings it back.
const min_brightness = 10;

/// Neutral white. Ramps are normalised against this (see `whitepoint`), so a
/// config asking for 6500 K gets an identity table rather than a faint cast.
const neutral_kelvin = 6500.0;

/// Display transfer exponent. The ramp holds ENCODED values, so a multiplier
/// worked out in linear light cannot be applied to one directly — see
/// `whitepoint`.
const display_gamma = 2.2;

var manager: ?*zwlr.GammaControlManagerV1 = null;

/// Runtime brightness in percent. Starts at full; the `brightness` action steps
/// it. Deliberately not in config.zon — see the header.
var level: i32 = 100;

/// One output's gamma control, keyed by its wl_output. Keyed that way so
/// output.zig can hand us the pointer it already holds, and neither file has to
/// import the other.
const Control = struct {
    wl_output: *wl.Output,
    control: *zwlr.GammaControlV1,
    size: u32 = 0,
    dead: bool = false,
};

var controls: std.ArrayList(*Control) = .empty;

/// Composed here rather than on the stack: `apply` runs from an event callback,
/// and 24 KB of ramp has no business in that frame.
var ramp: [max_ramp * 3]u16 = undefined;

/// Store the manager. Called from main once the global binds; without it every
/// function here is a no-op and the session simply has no dimming.
pub fn init(mgr: *zwlr.GammaControlManagerV1) void {
    manager = mgr;
}

/// Current brightness, for the state socket.
pub fn brightness() i32 {
    return level;
}

/// Take gamma control of a newly bound wl_output. Called from output.zig at the
/// point river names the global behind an output — the first moment there is a
/// wl_output to ask about.
pub fn attach(wo: *wl.Output) void {
    const mgr = manager orelse return;
    const ctx = Context.get();

    const c = ctx.gpa.create(Control) catch return;
    const ctrl = mgr.getGammaControl(wo) catch |err| {
        log.warn("get_gamma_control failed: {}", .{err});
        ctx.gpa.destroy(c);
        return;
    };
    c.* = .{ .wl_output = wo, .control = ctrl };
    ctrl.setListener(*Control, listener, c);

    controls.append(ctx.gpa, c) catch {
        ctrl.destroy();
        ctx.gpa.destroy(c);
    };
}

/// Release the control for an output that went away. The object would be
/// destroyed with the connection anyway; doing it here keeps `controls` from
/// holding a pointer to a wl_output that output.zig is about to destroy.
pub fn detach(wo: *wl.Output) void {
    const ctx = Context.get();
    for (controls.items, 0..) |c, i| {
        if (c.wl_output != wo) continue;
        c.control.destroy();
        _ = controls.swapRemove(i);
        ctx.gpa.destroy(c);
        return;
    }
}

/// Step brightness by `delta` percent on every output. This is the whole
/// keybind path: no subprocess, no bus, no round trip.
pub fn step(delta: i32) void {
    const next = std.math.clamp(level + delta, min_brightness, 100);
    if (next == level) return;
    level = next;
    reapply();
}

/// Re-write every ramp. Called after a step, and after a reload that changed the
/// configured temperature.
pub fn reapply() void {
    for (controls.items) |c| apply(c);
}

fn listener(_: *zwlr.GammaControlV1, event: zwlr.GammaControlV1.Event, self: *Control) void {
    switch (event) {
        // Sent once, immediately after creation: how many entries each channel's
        // ramp holds. Nothing can be written before it arrives, so this is also
        // where the first apply happens.
        .gamma_size => |ev| {
            if (ev.size > max_ramp) {
                log.warn("gamma ramp of {d} entries exceeds the {d} cap; leaving this output alone", .{ ev.size, max_ramp });
                self.dead = true;
                return;
            }
            self.size = ev.size;
            apply(self);
        },
        // Inert from here on. Two causes, both worth naming: another client
        // already holds gamma for this output (the protocol gives one client
        // exclusive access, so a running wl-gammarelay-rs / wlsunset / gammastep
        // is exactly this), or the output has no gamma LUT to set at all — which
        // is every output of a NESTED session, since the wayland and headless
        // backends have no hardware ramp behind them. The second is why this
        // cannot be tested outside a real DRM session.
        .failed => {
            self.dead = true;
            log.warn("gamma control refused for an output — another gamma client holding it " ++
                "(wl-gammarelay-rs, wlsunset), or a backend with no gamma LUT (nested session)", .{});
        },
    }
}

fn apply(self: *Control) void {
    if (self.dead or self.size < 2) return;
    const size: usize = self.size;

    fillRamp(
        ramp[0 .. size * 3],
        size,
        whitepoint(config.gamma.temperature),
        @as(f64, @floatFromInt(level)) / 100.0,
    );

    const bytes = std.mem.sliceAsBytes(ramp[0 .. size * 3]);
    const fd = C.memfd_create("reach-gamma", 0);
    if (fd < 0) {
        log.warn("memfd_create failed; brightness not applied", .{});
        return;
    }
    // Closing ours is correct and not a double close: libwayland dups the fd
    // while marshalling the request (wl_closure_marshal), so what it later sends
    // and closes is its own copy.
    defer _ = C.close(fd);

    if (C.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) {
        log.warn("short write to the gamma table; not applied", .{});
        return;
    }
    // The compositor reads the table from the start of the file, and our write
    // left the offset at the end.
    _ = C.lseek(fd, 0, C.SEEK_SET);

    self.control.setGamma(fd);
}

/// The table set_gamma reads: three ramps back to back, red then green then
/// blue, each `size` entries of 0..65535 rising from black to the channel's
/// scaled maximum.
fn fillRamp(out: []u16, size: usize, w: [3]f64, bright: f64) void {
    const last: f64 = @floatFromInt(size - 1);
    for (0..size) |i| {
        const v = @as(f64, @floatFromInt(i)) / last * bright;
        for (0..3) |ch| {
            const scaled = std.math.clamp(v * w[ch], 0.0, 1.0) * 65535.0;
            out[ch * size + i] = @intFromFloat(@round(scaled));
        }
    }
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

/// Per-channel multipliers for a colour temperature, normalised so that
/// `neutral_kelvin` is exactly (1, 1, 1), and ENCODED for the ramp.
///
/// Two steps, and the second is the one that is easy to miss.
///
/// Normalising: taken raw, the Planckian locus at 6500 K is near but not equal
/// to the sRGB white point, so "neutral" would carry a permanent faint tint.
/// Dividing by the 6500 K result makes every temperature a relative shift away
/// from an untouched screen, and rescaling so the brightest channel is 1.0 keeps
/// the warm end from clipping.
///
/// Encoding: `planckianRgb` works in LINEAR light, but a gamma ramp maps encoded
/// values to encoded values. Attenuating an encoded `v` by a linear factor `f`
/// means encode(f · decode(v)) = (f · v^γ)^(1/γ) = f^(1/γ) · v — so the factor
/// that may be multiplied into the table is `f^(1/γ)`, not `f`. Applied raw, a
/// linear 0.38 blue lands as an effective 0.38^2.2 ≈ 0.11: the screen comes out
/// far redder AND much darker than the temperature asked for, since green (most
/// of perceived luminance) is over-attenuated the same way. Encoding first puts
/// 4000 K at ≈(1.000, 0.846, 0.644), which is redshift's own table to within a
/// few percent — the table wl-gammarelay-rs ships and this session was used to.
fn whitepoint(kelvin: u32) [3]f64 {
    const raw = planckianRgb(@floatFromInt(kelvin));
    const ref = planckianRgb(neutral_kelvin);

    var c: [3]f64 = undefined;
    var max: f64 = 0;
    for (0..3) |i| {
        c[i] = if (ref[i] > 0) raw[i] / ref[i] else 1.0;
        max = @max(max, c[i]);
    }
    for (0..3) |i| {
        if (max > 0) c[i] /= max;
        c[i] = std.math.pow(f64, c[i], 1.0 / display_gamma);
    }
    return c;
}

/// Linear sRGB for a black-body temperature: the Kim et al. cubic fit for the
/// Planckian locus in CIE 1931 xy, then the standard xyY → XYZ → sRGB matrix.
/// The same approximation redshift and wlsunset use; valid 1667–25000 K, which
/// is well outside anything a night light asks for.
fn planckianRgb(kelvin: f64) [3]f64 {
    const t = std.math.clamp(kelvin, 1667.0, 25000.0);
    const t2 = t * t;
    const t3 = t2 * t;

    const x = if (t < 4000.0)
        -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
    else
        -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390;

    const x2 = x * x;
    const x3 = x2 * x;
    const y = if (t < 2222.0)
        -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
    else if (t < 4000.0)
        -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
    else
        3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483;

    // y = 0 would divide by zero below; the fit never produces it in range, but
    // an untouched screen is the right answer if it ever did.
    if (y <= 0) return .{ 1.0, 1.0, 1.0 };

    // xyY with Y = 1.
    const big_x = x / y;
    const big_y = 1.0;
    const big_z = (1.0 - x - y) / y;

    return .{
        @max(0.0, 3.2404542 * big_x - 1.5371385 * big_y - 0.4985314 * big_z),
        @max(0.0, -0.9692660 * big_x + 1.8760108 * big_y + 0.0415560 * big_z),
        @max(0.0, 0.0556434 * big_x - 0.2040259 * big_y + 1.0572252 * big_z),
    };
}

test "neutral temperature is an identity whitepoint" {
    const w = whitepoint(@intFromFloat(neutral_kelvin));
    for (w) |c| try std.testing.expectApproxEqAbs(@as(f64, 1.0), c, 1e-9);
}

test "warmer than neutral keeps red and drops blue" {
    const w = whitepoint(4000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), w[0], 1e-9); // red is the max
    try std.testing.expect(w[1] < 1.0);
    try std.testing.expect(w[2] < w[1]); // blue falls fastest
}

test "the whitepoint is encoded, not linear light" {
    // Pinned against redshift's blackbody table (~1.000/0.815/0.619 at 4000 K),
    // which is what wl-gammarelay-rs and every other night light applies. Without
    // the gamma encoding this comes out at 0.692/0.380 — visibly red and dark,
    // which is exactly how the regression showed up.
    const w = whitepoint(4000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.846), w[1], 0.04);
    try std.testing.expectApproxEqAbs(@as(f64, 0.644), w[2], 0.04);
}

test "a neutral full-brightness ramp is the identity table" {
    var out: [3 * 256]u16 = undefined;
    fillRamp(&out, 256, .{ 1.0, 1.0, 1.0 }, 1.0);

    // Every channel runs black to full, and the three are laid out in order.
    for (0..3) |ch| {
        try std.testing.expectEqual(@as(u16, 0), out[ch * 256]);
        try std.testing.expectEqual(@as(u16, 65535), out[ch * 256 + 255]);
    }
    // Monotonic, which is the property a gamma ramp has to have.
    for (1..256) |i| try std.testing.expect(out[i] >= out[i - 1]);
}

test "dimming scales the ceiling, not the shape" {
    var out: [3 * 256]u16 = undefined;
    fillRamp(&out, 256, .{ 1.0, 1.0, 1.0 }, 0.5);
    try std.testing.expectEqual(@as(u16, 0), out[0]);
    // Half brightness = half the top value (rounded).
    try std.testing.expectApproxEqAbs(@as(f64, 32768.0), @as(f64, @floatFromInt(out[255])), 1.0);
}

test "a warm whitepoint pulls blue down and leaves red alone" {
    var out: [3 * 256]u16 = undefined;
    fillRamp(&out, 256, whitepoint(4000), 1.0);
    const red_top = out[255];
    const blue_top = out[2 * 256 + 255];
    try std.testing.expectEqual(@as(u16, 65535), red_top);
    try std.testing.expect(blue_top < red_top);
}

test "brightness steps clamp to the floor and the ceiling" {
    const saved = level;
    defer level = saved;

    level = 100;
    step(50);
    try std.testing.expectEqual(@as(i32, 100), level);

    step(-1000);
    try std.testing.expectEqual(@as(i32, min_brightness), level);
}
