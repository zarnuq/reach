// output.zig — a monitor.
//
// Wraps a river_output_v1 and tracks its position + size in the global
// coordinate space. The layout uses these dimensions; M3 will hang the per-output
// border surfaces here and M4 the status bar.

const std = @import("std");
const log = std.log.scoped(.output);

const wayland = @import("wayland");
const river = wayland.client.river;

const Context = @import("context.zig");
const bar = @import("bar.zig");

pub const Output = struct {
    rwm: *river.OutputV1,

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

    // This output's status bar (M4). null when the bar subsystem is disabled
    // (no wl_shm / font failed to load) or if its surfaces couldn't be created.
    bar: ?*bar.Bar = null,

    pub fn create(rwm: *river.OutputV1) !*Output {
        const ctx = Context.get();
        const self = try ctx.gpa.create(Output);
        self.* = .{ .rwm = rwm };
        rwm.setListener(*Output, listener, self);

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
                if (self.bar) |b| b.destroy();
                self.rwm.destroy();
                ctx.gpa.destroy(self);
            },
            // wl_output (the underlying core object) is handled when M3/M4 need it.
            else => {},
        }
    }
};
