// wm.zig — the window-manager core: setup, event loop, and the manage/render
// cycles that drive layout.
//
// river's driving model (the two sequences) — recap:
//   MANAGE: river sends new state (window/output/seat events, hints) then emits
//           `manage_start`. We run the layout, propose sizes, set focus, and call
//           `manage_finish`.
//   RENDER: river emits `render_start` when it wants the visual result committed.
//           We position nodes and show windows, then call `render_finish`.
// Both sequences MUST be closed or the compositor blocks.

const std = @import("std");
const log = std.log.scoped(.wm);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Context = @import("context.zig");
const layout = @import("layout.zig");
const border = @import("border.zig");
const stack = @import("stack.zig");
const binding = @import("binding.zig");
const action = @import("action.zig");
const status = @import("status.zig");
const shake = @import("shake.zig");
const reload = @import("reload.zig");
const ipc = @import("ipc.zig");
const Window = @import("window.zig").Window;
const Output = @import("output.zig").Output;
const Seat = @import("seat.zig").Seat;

/// Initialise the global context and attach the window-manager listener.
pub fn init(gpa: std.mem.Allocator, registry: *wl.Registry, globals: Context.Globals) void {
    Context.init(gpa, registry, globals);
    globals.rwm.setListener(?*anyopaque, wmListener, null);
    log.info("window manager initialised; waiting for river events", .{});
}

pub fn deinit() void {
    // Process exit reclaims everything; explicit teardown of tracked objects can
    // come later if we ever need a graceful in-process restart.
}

/// The event loop: poll() over the Wayland fd plus the status engine's 1s timerfd
/// and real-time-signal fd, shake-to-find's pointer devices and animation tick,
/// and the state socket's listener plus its connected clients (all optional;
/// added to the set only when present).
pub fn run(display: *wl.Display) !void {
    const ctx = Context.get();
    const wl_fd = display.getFd();

    while (ctx.running) {
        _ = display.flush();

        // Slot 0 is always Wayland; the rest are added when their subsystem is
        // live. Sized for wayland + status timer/signal + shake timer + devices
        // + the ipc listener and its clients.
        var fds: [5 + shake.device_fds.len + ipc.max_clients]std.posix.pollfd = undefined;
        var n: usize = 1;
        fds[0] = .{ .fd = wl_fd, .events = std.posix.POLL.IN, .revents = 0 };
        const timer_slot = addFd(&fds, &n, status.timer_fd);
        const signal_slot = addFd(&fds, &n, status.signal_fd);
        const shake_timer_slot = addFd(&fds, &n, shake.timer_fd);
        const shake_first = n;
        for (shake.device_fds[0..shake.device_count]) |fd| _ = addFd(&fds, &n, fd);
        const ipc_slot = addFd(&fds, &n, ipc.listen_fd);
        const ipc_first = n;
        const ipc_polled = ipc.client_count;
        for (ipc.client_fds[0..ipc_polled]) |fd| _ = addFd(&fds, &n, fd);

        _ = std.posix.poll(fds[0..n], -1) catch |err| {
            log.err("poll failed: {}", .{err});
            return err;
        };

        if (fds[0].revents & std.posix.POLL.IN != 0) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }

        // A block re-ran (timer tick or refresh signal) and the text changed →
        // ask river for a fresh manage/render cycle so the bars redraw.
        var dirty = false;
        if (timer_slot) |s| if (fds[s].revents & std.posix.POLL.IN != 0) {
            if (status.onTimer()) dirty = true;
        };
        if (signal_slot) |s| if (fds[s].revents & std.posix.POLL.IN != 0) {
            if (status.onSignal()) dirty = true;
            // SIGHUP arrived on the same fd: `kill -HUP $(pidof reach)` reloads
            // config.zon. Like every other reload trigger it only sets the
            // request; manageDirty gets us the manage cycle that applies it.
            if (status.hup_received) {
                status.hup_received = false;
                reload.request();
                dirty = true;
            }
        };

        // Pointer motion feeds the shake detector; its tick animates the size.
        for (0..shake.device_count) |i| {
            if (fds[shake_first + i].revents & std.posix.POLL.IN != 0) {
                if (shake.onMotion(i)) dirty = true;
            }
        }
        if (shake_timer_slot) |s| if (fds[s].revents & std.posix.POLL.IN != 0) {
            if (shake.onTimer()) dirty = true;
        };

        // State socket. Clients BEFORE the listener, and descending: onClient may
        // drop a client (compacting the array), and accepting one appends to it —
        // either would invalidate the slot indices this loop reads. Neither can
        // make the window manager dirty; the socket is write-only (see ipc.zig).
        var client = ipc_polled;
        while (client > 0) {
            client -= 1;
            const revents = fds[ipc_first + client].revents;
            if (revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                ipc.onClient(client);
            }
        }
        if (ipc_slot) |s| if (fds[s].revents & std.posix.POLL.IN != 0) ipc.onAccept();

        if (dirty) ctx.rwm.manageDirty();
    }
}

/// Append `maybe_fd` to the poll set if present, returning its slot index.
fn addFd(fds: []std.posix.pollfd, n: *usize, maybe_fd: ?i32) ?usize {
    const fd = maybe_fd orelse return null;
    const slot = n.*;
    fds[slot] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
    n.* += 1;
    return slot;
}

// ---------------------------------------------------------------------------
// The manage and render cycles
// ---------------------------------------------------------------------------

/// MANAGE: arrange tiled windows, place floats, propose sizes, set focus.
fn manageCycle() void {
    const ctx = Context.get();

    // Apply a requested config reload. Runs FIRST so the rest of this cycle — and
    // enablePending() immediately below, which activates the rebuilt bindings —
    // already sees the new config. Deferring to here is what makes it safe to
    // request a reload from a keybinding's own handler.
    reload.apply();

    // Activate any keybindings created since the last cycle (the protocol only
    // allows enable() inside a manage sequence).
    binding.enablePending();

    // Open/close a pending chord submap (enable/disable of its sub-bindings and
    // ensure_next_key_eaten are likewise manage-only requests).
    binding.applySubmap();

    // Mark the selected monitor as the default for new layer surfaces (rofi,
    // etc.) so they open on the focused output. set_default may only be issued
    // inside a manage sequence, and only when the selection has moved.
    if (ctx.current_output) |o| {
        if (ctx.layer_default != o) {
            if (o.layer_output) |lo| {
                lo.setDefault();
                ctx.layer_default = o;
            }
        }
    }

    // Tile each output.
    for (ctx.outputs.items) |o| layout.arrange(o);

    // Place floating windows (centered on their output).
    for (ctx.windows.items) |w| {
        if (w.floating) w.placeFloating();
    }

    // Tell river each window's tiled state and proposed size.
    for (ctx.windows.items) |w| w.manage();

    // Keyboard focus follows the focused window.
    if (ctx.focused) |f| {
        if (ctx.primary_seat) |s| s.rwm.focusWindow(f.rwm);
    }

    // Warp the pointer to the focused window if a focus/layout keybind asked for
    // it (dwl warpcursor). Done last, so window geometry from arrange() is final.
    action.applyWarp();

    // Push the cursor theme/size (resting value at startup, or a shake step).
    shake.applyPending();
}

/// RENDER: position and show every window, draw the tmux borders and the bars,
/// then order the scene.
///
/// Content first, z-order last, and deliberately separate: what a thing looks like
/// and what it sits in front of are independent questions, and folding the second
/// into the first is what made layering fall out of the order these calls happen to
/// run in. stack.apply() is the only thing here with an opinion about depth.
fn renderCycle() void {
    const ctx = Context.get();
    for (ctx.windows.items) |w| w.render();
    border.update();
    for (ctx.outputs.items) |o| {
        if (o.bar) |b| b.render();
    }
    stack.apply();

    // Publish the same state the bar just drew, for an external one. Here rather
    // than anywhere else so both bars update on the same beat; a no-op when the
    // state is unchanged or nothing is listening.
    ipc.publish();
}

// ---------------------------------------------------------------------------
// Window manager event handler
// ---------------------------------------------------------------------------

fn wmListener(_: *river.WindowManagerV1, event: river.WindowManagerV1.Event, _: ?*anyopaque) void {
    const ctx = Context.get();
    switch (event) {
        .unavailable => {
            log.err("window management unavailable (another WM connected?)", .{});
            ctx.running = false;
        },
        .finished => {
            log.info("river sent `finished`; shutting down", .{});
            ctx.running = false;
        },

        .manage_start => {
            manageCycle();
            ctx.rwm.manageFinish();
        },
        .render_start => {
            renderCycle();
            ctx.rwm.renderFinish();
        },

        .session_locked => log.info("session locked", .{}),
        .session_unlocked => log.info("session unlocked", .{}),

        // A new window. Create its wrapper, assign it to an output, make it the
        // new master (head of the stack) and the focus.
        .window => |ev| {
            const w = Window.create(ev.id) catch |err| {
                log.err("failed to create window: {}", .{err});
                return;
            };

            // Place the window on the selected monitor (dwl spawns on `selmon`),
            // so apps launched by a keybind appear where the keyboard focus is —
            // not on whatever output happens to be first (DP-1). Fall back to the
            // pointer's output, then the focused window's output, then the first.
            var out: ?*Output = ctx.current_output;
            if (out == null) out = ctx.pointer_output;
            if (out == null) {
                if (ctx.focused) |f| out = f.output;
            }
            if (out == null and ctx.outputs.items.len > 0) out = ctx.outputs.items[0];
            w.output = out;

            // New windows land on the desktop the output is currently viewing
            // (dwl behavior), so they appear on the active workspace.
            if (out) |o| w.desktop = o.desktop;

            // Insert at the head so a new window becomes master (dwm-like).
            ctx.windows.insert(ctx.gpa, 0, w) catch |err| {
                log.err("failed to track window: {}", .{err});
                w.node.destroy();
                w.rwm.destroy();
                ctx.gpa.destroy(w);
                return;
            };
            ctx.focused = w;
            // The new window is focused, so its monitor becomes the selected one
            // (keeps the bar highlight and desktop keys on the window you just opened).
            if (out) |o| ctx.current_output = o;
            log.info("window created (total {d})", .{ctx.windows.items.len});
        },

        .output => |ev| {
            const o = Output.create(ev.id) catch |err| {
                log.err("failed to create output: {}", .{err});
                return;
            };
            ctx.outputs.append(ctx.gpa, o) catch |err| {
                log.err("failed to track output: {}", .{err});
                o.rwm.destroy();
                ctx.gpa.destroy(o);
                return;
            };
            // First monitor to appear is selected by default.
            if (ctx.current_output == null) ctx.current_output = o;
            // Re-home any windows orphaned by a total output blackout (e.g. all
            // outputs were removed during a VT switch and are now reappearing).
            for (ctx.windows.items) |w| {
                if (w.output == null) w.output = o;
            }
            log.info("output created (total {d})", .{ctx.outputs.items.len});
        },

        .seat => |ev| {
            const s = Seat.create(ev.id) catch |err| {
                log.err("failed to create seat: {}", .{err});
                return;
            };
            ctx.seats.append(ctx.gpa, s) catch |err| {
                log.err("failed to track seat: {}", .{err});
                s.rwm.destroy();
                ctx.gpa.destroy(s);
                return;
            };
            if (ctx.primary_seat == null) ctx.primary_seat = s;
            log.info("seat created (total {d})", .{ctx.seats.items.len});
        },
    }
}
