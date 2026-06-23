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

    // Currently-viewed tags (workspace bitmask). Default: tag 1 (bit 0).
    tagset: u32 = 1,

    // Per-output layout state
    mfact: f32 = 0.55,
    nmaster: i32 = 1,

    // Transform applied by outputconfig. Needed so the bar and layout can place
    // themselves at the correct physical edge: rotate_180 flips the y-axis, so
    // "logical top" (y=0) is physically the bottom of the panel.
    transform: config.Transform = .normal,

    // This output's status bar. null when the bar subsystem is disabled
    // (no wl_shm / font failed to load) or if its surfaces couldn't be created.
    bar: ?*bar.Bar = null,

    // river_layer_shell_output_v1 handle for this monitor. We use it to mark the
    // selected output as the default for new layer surfaces (rofi etc.) so they
    // open on the focused monitor rather than river's fallback (the first output).
    layer_output: ?*river.LayerShellOutputV1 = null,

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
            // We don't act on its events (non_exclusive_area); the bar reserves a
            // fixed strip. A no-op listener keeps the dispatcher happy.
            if (self.layer_output) |lo| lo.setListener(?*anyopaque, layerOutputListener, null);
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
            // The monitor went away. Orphan any windows that lived here (they'll be
            // re-homed on the next manage cycle once another output exists), drop
            // ourselves from the list, and release the proxy.
            .removed => {
                for (ctx.windows.items) |w| {
                    if (w.output == self) w.output = null;
                }
                for (ctx.outputs.items, 0..) |o, i| {
                    if (o == self) {
                        _ = ctx.outputs.orderedRemove(i);
                        break;
                    }
                }
                // Don't leave the selection (or pointer target) dangling at a
                // freed output; fall back to whatever monitor remains.
                const fallback: ?*Output = if (ctx.outputs.items.len > 0) ctx.outputs.items[0] else null;
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
            // Inherit the transform from config.monitors so bar.zig and
            // layout.zig can account for outputs where the y-axis is flipped
            // (rotate_180: logical top = physical bottom).
            for (config.monitors) |m| {
                if (std.mem.eql(u8, m.name, std.mem.span(ev.name))) {
                    self.transform = m.transform;
                    break;
                }
            }
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
/// drives focusmon/tagmon navigation (MOD+,/.) and the window-rule `monitor`
/// index — is deterministic and user-controlled, instead of following river's
/// arbitrary output-event order. Stable, so unconfigured outputs keep their
/// relative arrival order. Pointers into the list (current_output, …) are
/// unaffected; only the ordering changes.
pub fn reorder() void {
    const ctx = Context.get();
    std.sort.insertion(*Output, ctx.outputs.items, {}, rankLessThan);
}

/// We ignore river_layer_shell_output_v1 events (non_exclusive_area); the bar
/// reserves a fixed strip rather than honoring the exclusive zone.
fn layerOutputListener(
    _: *river.LayerShellOutputV1,
    _: river.LayerShellOutputV1.Event,
    _: ?*anyopaque,
) void {}
