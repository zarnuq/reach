// output.zig — a monitor.
//
// Wraps a river_output_v1 and tracks its position + size in the global
// coordinate space. The layout uses these dimensions; each output also owns its
// status bar (bar.zig) and the layer-shell handle used to steer new layer
// surfaces (rofi, notifications) onto the focused monitor.

const std = @import("std");
const log = std.log.scoped(.output);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Context = @import("context.zig");
const config = @import("config.zig");
const bar = @import("bar.zig");

/// An output-local rectangle.
pub const Rect = struct { x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0 };

pub const Output = struct {
    rwm: *river.OutputV1,

    // The underlying wl_output and its connector name ("DP-1", "eDP-1", …). river
    // only gives us the numeric global name in `wl_output`; we bind it ourselves
    // to read the string name, which is what `config.monitors` is keyed on and
    // what determines this output's position in `ctx.outputs` (monitor ordering).
    wl_output: ?*wl.Output = null,
    name: ?[:0]u8 = null,

    // Global-space geometry, filled in by the `position` / `dimensions` events.
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    // river's `non_exclusive_area`: what's left of the output after subtracting
    // every layer surface's exclusive zone. Stored EXACTLY as received — raw, in
    // GLOBAL coordinates — and converted on demand by `nonExclusive()`.
    //
    // Kept raw on purpose. Converting here would need `x`/`y`/`width`/`height`,
    // and river makes no promise that `position`/`dimensions` arrive before this
    // event on a fresh output; converting eagerly against a still-zero geometry
    // would silently discard the hint, and river has no reason to resend it.
    //
    // null = never received one, so the whole output is ours.
    usable_hint: ?Rect = null,

    // The virtual desktop this output is currently showing (1-based; see
    // config.desktops). Exactly one, always — there is no empty view.
    desktop: u32 = 1,

    // Per-output layout state
    mfact: f32 = 0.55,
    nmaster: i32 = 1,

    // This output's status bar. null when the bar subsystem is disabled
    // (no wl_shm / font failed to load) or if its surfaces couldn't be created.
    bar: ?*bar.Bar = null,

    // river_layer_shell_output_v1 handle for this monitor. We use it to mark the
    // selected output as the default for new layer surfaces (rofi etc.) so they
    // open on the focused monitor rather than river's fallback (the first output).
    layer_output: ?*river.LayerShellOutputV1 = null,

    /// The part of this output no layer surface has claimed, output-local: the
    /// raw `non_exclusive_area` hint translated out of global coordinates and
    /// clipped to our own bounds. The whole output when no hint has arrived, so a
    /// compositor that never sends one behaves exactly as it did before.
    ///
    /// This does NOT subtract reach's own bar — the bar spans this area, so it
    /// needs the value before its own strip is taken out. For laying windows out,
    /// use `usableArea()`.
    pub fn nonExclusive(self: *const Output) Rect {
        const hint = self.usable_hint orelse
            return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };

        // Global → output-local, then clipped. The clip is what makes a stale hint
        // (one describing a resolution we've since left) safe rather than a way to
        // put windows off-screen.
        var x = hint.x - self.x;
        var y = hint.y - self.y;
        var w = hint.width;
        var h = hint.height;
        if (x < 0) {
            w += x;
            x = 0;
        }
        if (y < 0) {
            h += y;
            y = 0;
        }
        if (x + w > self.width) w = self.width - x;
        if (y + h > self.height) h = self.height - y;

        return .{ .x = x, .y = y, .width = @max(0, w), .height = @max(0, h) };
    }

    /// The part of this output available to the window layout, output-local:
    /// `nonExclusive()` minus the strip reach's own bar sits in.
    ///
    /// The bar is subtracted HERE rather than by river because it is a
    /// river_shell_surface_v1, not a layer surface — river's hint only accounts for
    /// layer surfaces' exclusive zones, so it has no idea the bar is there. Both
    /// layout.zig and border.zig go through this so the two can't drift.
    pub fn usableArea(self: *const Output) Rect {
        const bar_h = bar.height();
        var r = self.nonExclusive();
        if (config.bar.top) r.y += bar_h;
        r.height -= bar_h;
        return r;
    }

    pub fn create(rwm: *river.OutputV1) !*Output {
        const ctx = Context.get();
        const self = try ctx.gpa.create(Output);
        self.* = .{ .rwm = rwm };
        rwm.setListener(*Output, listener, self);

        if (ctx.layer_shell) |ls| {
            self.layer_output = ls.getOutput(rwm) catch |err| blk: {
                log.warn("get layer_shell output failed: {}", .{err});
                break :blk null;
            };
            // Its `non_exclusive_area` event is how a layer surface's exclusive
            // zone reaches the layout — river can't honor a zone itself, since it
            // doesn't place windows. See layerOutputListener.
            if (self.layer_output) |lo| lo.setListener(*Output, layerOutputListener, self);
        }

        if (bar.enabled) {
            self.bar = bar.Bar.create(self) catch |err| blk: {
                log.warn("create bar failed: {}", .{err});
                break :blk null;
            };
        }
        return self;
    }

    fn listener(_: *river.OutputV1, event: river.OutputV1.Event, self: *Output) void {
        const ctx = Context.get();
        switch (event) {
            // Position in the global layout (multi-monitor).
            .position => |ev| {
                self.x = ev.x;
                self.y = ev.y;
            },
            // Resolution. The `mode` arg is ignored for now.
            .dimensions => |ev| {
                self.width = ev.width;
                self.height = ev.height;
                // The hint we hold describes the OLD resolution, so drop it and use
                // the whole output until river sends a fresh one. Falling back this
                // way can briefly let a window sit under a panel; the opposite error
                // — keeping a rect measured against a bigger screen — strands
                // windows in a sliver of the new one.
                self.usable_hint = null;
                log.info("output geometry: {d}x{d} @ ({d},{d})", .{ self.width, self.height, self.x, self.y });
            },
            // The numeric name of the wl_output global backing this output. Bind
            // it and listen for its connector-name event so we can order monitors
            // by config.monitors (and so window rules' `monitor` index is stable).
            .wl_output => |ev| {
                if (self.wl_output != null) return; // sent exactly once, but be safe
                const wo = ctx.registry.bind(ev.name, wl.Output, 4) catch |err| {
                    log.warn("bind wl_output failed: {}", .{err});
                    return;
                };
                self.wl_output = wo;
                wo.setListener(*Output, wlOutputListener, self);
            },
            // The monitor went away. Move its windows to a surviving output (so
            // they stay visible), drop ourselves from the list, and release the
            // proxy. If this is the last output, windows get null and will be
            // re-homed when an output reappears (wm.zig output event handler).
            .removed => {
                // Find a surviving output BEFORE removing ourselves so windows
                // on this output don't go dark when another monitor still exists.
                var fallback: ?*Output = null;
                for (ctx.outputs.items) |o| {
                    if (o != self) { fallback = o; break; }
                }
                for (ctx.windows.items) |w| {
                    if (w.output == self) w.output = fallback;
                }
                for (ctx.outputs.items, 0..) |o, i| {
                    if (o == self) {
                        _ = ctx.outputs.orderedRemove(i);
                        break;
                    }
                }
                // Don't leave the selection (or pointer target) dangling at a
                // freed output; fall back to whatever monitor remains.
                if (ctx.current_output == self) ctx.current_output = fallback;
                if (ctx.pointer_output == self) ctx.pointer_output = fallback;
                // Force the manage cycle to re-apply set_default to the fallback
                // (the protocol leaves the default undefined once ours is gone).
                if (ctx.layer_default == self) ctx.layer_default = null;
                if (self.layer_output) |lo| lo.destroy();
                if (self.bar) |b| b.destroy();
                if (self.wl_output) |wo| wo.destroy();
                if (self.name) |n| ctx.gpa.free(n);
                self.rwm.destroy();
                ctx.gpa.destroy(self);
            },
        }
    }
};

/// wl_output listener — we only care about the connector name. Once it arrives
/// (or changes) we re-sort `ctx.outputs` so monitor numbering follows config.
fn wlOutputListener(_: *wl.Output, event: wl.Output.Event, self: *Output) void {
    const ctx = Context.get();
    switch (event) {
        .name => |ev| {
            if (self.name) |n| ctx.gpa.free(n);
            self.name = ctx.gpa.dupeZ(u8, std.mem.span(ev.name)) catch null;
            log.info("output connector: {s}", .{std.mem.span(ev.name)});
            // NOTE: no transform is mirrored onto the Output. outputconfig.zig
            // hands `config.monitors`' transform to the compositor, and river
            // then reports `position`/`dimensions` — and takes our node
            // positions — in the LOGICAL coordinate space that transform
            // produces. So the WM never sees physical pixels and has nothing to
            // compensate for. A `transform` field lived here for a while, set
            // from the config and read by nothing, above a comment claiming the
            // bar and layout needed it; it made rotation look handled where in
            // fact there was nothing to handle.
            reorder();
        },
        else => {}, // geometry/mode/scale/description/done — unused
    }
}

/// This output's rank for ordering: its index in `config.monitors` (by name), or
/// a large value (kept after configured monitors, in arrival order) if its name
/// is unknown or absent from the config.
fn configRank(o: *const Output) usize {
    const name = o.name orelse return std.math.maxInt(usize);
    for (config.monitors, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, name)) return i;
    }
    return std.math.maxInt(usize);
}

fn rankLessThan(_: void, a: *Output, b: *Output) bool {
    return configRank(a) < configRank(b);
}

/// Order `ctx.outputs` by `config.monitors` so that monitor numbering — which
/// drives focusmon/sendmon navigation (MOD+,/.) and the window-rule `monitor`
/// index — is deterministic and user-controlled, instead of following river's
/// arbitrary output-event order. Stable, so unconfigured outputs keep their
/// relative arrival order. Pointers into the list (current_output, …) are
/// unaffected; only the ordering changes.
pub fn reorder() void {
    const ctx = Context.get();
    std.sort.insertion(*Output, ctx.outputs.items, {}, rankLessThan);
}

/// river_layer_shell_output_v1 listener — the exclusive-zone hint.
///
/// A layer-shell client (a quickshell panel, waybar, an on-screen keyboard) asks
/// for space with `exclusive_zone`. river places the surface itself, but it cannot
/// keep the space clear, because in river's non-monolithic split the WM is what
/// lays windows out. So river subtracts every layer surface's zone from the output
/// and hands us the remainder here. Ignoring this event is what makes exclusive
/// zones silently non-functional — the panel draws, and windows tile underneath it.
///
/// The protocol sends this in GLOBAL coordinates and guarantees a manage_start
/// follows, so storing the rect is enough; the layout re-runs on its own.
fn layerOutputListener(
    _: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    self: *Output,
) void {
    switch (event) {
        // Stashed raw; `nonExclusive()` does the global→local conversion, so this
        // does not care whether our own geometry has arrived yet.
        .non_exclusive_area => |ev| self.usable_hint = .{
            .x = ev.x,
            .y = ev.y,
            .width = ev.width,
            .height = ev.height,
        },
    }
}
