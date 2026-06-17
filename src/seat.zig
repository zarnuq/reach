// seat.zig — an input seat (keyboard + pointer group).
//
// M2 only needs the seat object so we can drive keyboard focus
// (`focus_window`). Keybindings/keychords and pointer ops arrive in M5, which is
// why most events are ignored for now.

const std = @import("std");
const log = std.log.scoped(.seat);

const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const Context = @import("context.zig");
const binding = @import("binding.zig");

pub const Seat = struct {
    rwm: *river.SeatV1,

    pub fn create(rwm: *river.SeatV1) !*Seat {
        const ctx = Context.get();
        const self = try ctx.gpa.create(Seat);
        self.* = .{ .rwm = rwm };
        rwm.setListener(*Seat, listener, self);

        // Hook up the keybindings (tags etc.) for this seat.
        binding.registerForSeat(self);
        return self;
    }

    fn listener(_: *river.SeatV1, event: river.SeatV1.Event, self: *Seat) void {
        const ctx = Context.get();
        switch (event) {
            // Pointer moved onto a window. Always track its output (spawn target);
            // with sloppy focus, also focus the window and select its monitor so
            // the bar highlight and tag keys follow the mouse.
            .pointer_enter => |ev| {
                for (ctx.windows.items) |w| {
                    if (w.rwm == ev.window) {
                        ctx.pointer_output = w.output;
                        if (config.sloppy_focus and ctx.focused != w) {
                            ctx.focused = w;
                            ctx.current_output = w.output;
                            // Diagnostic: confirms river delivers hover events and
                            // that focus-follows-mouse is firing. Fires only on an
                            // actual focus change, so it's not per-motion noise.
                            log.info("sloppy focus -> {s}", .{if (w.title) |t| t else "(window)"});
                            // Focus is applied in the manage cycle; ask for one.
                            ctx.rwm.manageDirty();
                        }
                        break;
                    }
                }
            },
            .pointer_leave => {},

            // Click-to-focus and pointer tracking
            .window_interaction => |ev| {
                for (ctx.windows.items) |w| {
                    if (w.rwm == ev.window) {
                        ctx.focused = w;
                        ctx.pointer_output = w.output;
                        // Clicking a window also selects its monitor (selmon).
                        ctx.current_output = w.output;
                        break;
                    }
                }
            },

            .removed => {
                for (ctx.seats.items, 0..) |s, i| {
                    if (s == self) {
                        _ = ctx.seats.orderedRemove(i);
                        break;
                    }
                }
                if (ctx.primary_seat == self) {
                    ctx.primary_seat = if (ctx.seats.items.len > 0) ctx.seats.items[0] else null;
                }
                self.rwm.destroy();
                ctx.gpa.destroy(self);
            },
            else => {},
        }
    }
};
