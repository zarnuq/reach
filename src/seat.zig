// seat.zig — an input seat (keyboard + pointer group).
//
// The seat object lets us drive keyboard focus (`focus_window`) and observe the
// pointer for focus-follows-mouse / click-to-focus. Keybindings (and chords) are
// registered against the seat here via binding.registerForSeat; the events we
// don't act on are ignored.

const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const Context = @import("context.zig");
const binding = @import("binding.zig");
const query = @import("query.zig");

pub const Seat = struct {
    rwm: *river.SeatV1,

    pub fn create(rwm: *river.SeatV1) !*Seat {
        const ctx = Context.get();
        const self = try ctx.gpa.create(Seat);
        self.* = .{ .rwm = rwm };
        rwm.setListener(*Seat, listener, self);

        // Hook up the keybindings (desktops etc.) for this seat.
        binding.registerForSeat(self);
        return self;
    }

    fn listener(_: *river.SeatV1, event: river.SeatV1.Event, self: *Seat) void {
        const ctx = Context.get();
        switch (event) {
            // Pointer moved onto a window. Always track its output (spawn target);
            // with sloppy focus, also focus the window and select its monitor so
            // the bar highlight and desktop keys follow the mouse.
            .pointer_enter => |ev| {
                for (ctx.windows.items) |w| {
                    if (w.rwm == ev.window) {
                        ctx.pointer_output = w.output;
                        if (config.sloppy_focus and ctx.focused != w) {
                            ctx.focused = w;
                            ctx.current_output = w.output;
                            // Focus is applied in the manage cycle; ask for one.
                            ctx.rwm.manageDirty();
                        }
                        break;
                    }
                }
            },
            .pointer_leave => {},

            // Where the pointer IS, rather than which window it entered.
            //
            // `pointer_enter` above only fires for a window, so an output with
            // nothing under the cursor — bare desktop, or a monitor whose desktop
            // is empty — never became the selection. The bar then highlighted the
            // monitor you last touched a window on, and the desktop keys acted on
            // it, which is the half that actually bites: `Super+2` switched the
            // wrong screen while the mouse sat on this one.
            //
            // river sends this only inside a manage sequence (motion alone must
            // not start one), so it is as often as any window manager can know.
            // That makes the selection correct at the moment it is USED — a
            // keybind is a manage sequence — while the bar's highlight catches up
            // on the same beat rather than live under a motionless session.
            .pointer_position => |ev| {
                const out = query.outputAt(ev.x, ev.y) orelse return;
                ctx.pointer_output = out;
                // Only the OUTPUT selection, never `ctx.focused`: there is no
                // window under the pointer to focus, and stealing the keyboard
                // away from the one you were typing in is not what crossing a
                // screen edge should do.
                if (config.sloppy_focus) ctx.current_output = out;
            },

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
