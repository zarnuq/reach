// action.zig — what the window manager can be asked to do, and the doing of it.
//
// An Action is a verb: view a desktop, send the focused window somewhere, adjust
// the layout, spawn a program. `execute` performs one, and the helpers below it are
// the window-manager operations those verbs are made of.
//
// SEPARATE FROM binding.zig on purpose. These operations are not about keyboards.
// They lived inside the keybinding module because keys were the only thing that
// triggered them, which made "what the WM can do" reachable only through "how a key
// is bound" — a 828-line file where the two were interleaved. Anything else that
// wants to drive the WM (a bar's desktop click, an IPC socket) needs exactly this
// half and none of the xkb plumbing.
//
// The split runs one way in spirit and both ways in code: binding.zig maps keys to
// an Action and calls `execute`; this file reaches back only for the chord submaps,
// since entering one IS a keybinding concept that happens to be spelled as an
// action (`Action.enter_submap`).
//
// TIMING, and why almost nothing here defers: river guarantees a `pressed` event is
// followed by a manage_start, so mutating state in an action is enough — the layout
// and render re-run on their own. The exceptions are the three things that must
// happen inside a specific sequence and so only get *requested* here: a config
// reload (reload.request), a submap change (binding.requestSubmapEnter) and a
// cursor warp (requestWarp).

const std = @import("std");

const config = @import("config.zig");
const confparse = @import("confparse.zig");
const reload = @import("reload.zig");
const binding = @import("binding.zig");
const Context = @import("context.zig");
const Output = @import("output.zig").Output;
const query = @import("query.zig");
const Window = @import("window.zig").Window;

/// A signed step on each axis, in pixels — for floating move/resize.
pub const Delta = struct { x: i32 = 0, y: i32 = 0 };

/// What a keybinding does when pressed.
pub const Action = union(enum) {
    // Desktop actions. Both carry a 1-based desktop number (see config.desktops).
    view: u32,
    send: u32,
    // Spawn - single shell command string
    spawn: [:0]const u8,
    // Enter a two-key chord submap (dwl SPAWN2): the leader arms `chord`, whose
    // sub-bindings become live until the next key resolves them. See the submap
    // machinery near the bottom of this file.
    enter_submap: *binding.Chord,
    // Window management
    quit,
    killclient,
    zoom,
    togglefloating,
    togglefullscreen,
    // Floating geometry (keyboard). Both only act on the focused window while it
    // is floating; no-ops otherwise.
    move: Delta,
    resize: Delta,
    // Focus/layout
    focusstack: i32,
    setmfact: f32,
    incnmaster: i32,
    focusmon: i32,
    sendmon: i32,
    // Re-read config.zon and rebuild everything it drives (reload.zig). Deferred
    // to the next manage cycle — running it here would free this very Binding
    // while its listener is still on the stack.
    reload,
};

/// confparse.ActionSpec → the real Action union (chords excluded; they come in
/// structurally via KeySpec.chord, not as an action).
pub fn toAction(a: confparse.ActionSpec) Action {
    return switch (a) {
        .view => |v| .{ .view = v },
        .send => |v| .{ .send = v },
        .spawn => |v| .{ .spawn = v },
        .quit => .quit,
        .killclient => .killclient,
        .zoom => .zoom,
        .togglefloating => .togglefloating,
        .togglefullscreen => .togglefullscreen,
        .move => |d| .{ .move = .{ .x = d.x, .y = d.y } },
        .resize => |d| .{ .resize = .{ .x = d.x, .y = d.y } },
        .focusstack => |v| .{ .focusstack = v },
        .setmfact => |v| .{ .setmfact = v },
        .incnmaster => |v| .{ .incnmaster = v },
        .focusmon => |v| .{ .focusmon = v },
        .sendmon => |v| .{ .sendmon = v },
        .reload => .reload,
    };
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

pub fn execute(action: Action) void {
    const ctx = Context.get();
    switch (action) {
        // Desktop actions. No warp here: switching desktops or moving a window
        // between them on the same monitor shouldn't yank the pointer (user
        // preference). focusmon still warps because it moves the keyboard
        // selection across monitors; sendmon does not (it moves a window, not the
        // selection — see its case below).
        //
        // Out-of-range numbers are dropped rather than clamped: a bind or IPC
        // message naming desktop 12 is a mistake, and silently landing on 9 hides
        // it. 0 is never a valid desktop (see config.desktops).
        .view => |d| {
            if (!validDesktop(d)) return;
            const out = query.selectedOutput() orelse return;
            out.desktop = d;
            refocus(out);
        },
        .send => |d| {
            if (!validDesktop(d)) return;
            const out = query.selectedOutput() orelse return;
            if (ctx.focused) |f| {
                f.desktop = d;
                refocus(out);
            }
        },
        // Spawn a shell command (double-fork; see spawn()).
        .spawn => |cmd| spawn(cmd),
        // Re-read config.zon. Only *requests* the reload; reload.apply() runs it
        // from the manage cycle that river guarantees follows this press, by
        // which point this Binding is no longer on the stack and can be freed.
        .reload => reload.request(),
        // Arm a two-key chord submap.
        .enter_submap => |chord| binding.requestSubmapEnter(chord),
        // Window management
        .quit => {
            ctx.running = false;
            // reach is launched as river's `-c` startup command, so river is
            // our parent process. Stopping the poll loop only exits reach (the
            // WM client) and would leave river running with no window manager —
            // an "orphaned" compositor. Signal the parent so river quits too,
            // matching dwl's monolithic quit where compositor and WM are one.
            _ = std.os.linux.kill(std.os.linux.getppid(), std.os.linux.SIG.TERM);
        },
        .killclient => if (ctx.focused) |f| f.rwm.close(),
        .zoom => {
            if (ctx.focused) |f| promoteToMaster(f);
            requestWarp();
        },
        .togglefloating => {
            if (ctx.focused) |f| {
                f.floating = !f.floating;
                // Re-establish geometry next cycle: when floating, placeFloating
                // recenters at the (now larger) default; when tiling, arrange
                // retiles. Without this the old float geometry would persist.
                f.float_placed = false;
            }
        },
        .togglefullscreen => {
            if (ctx.focused) |f| f.fullscreen = !f.fullscreen;
        },
        // Floating move/resize. The press is followed by a manage cycle, and
        // float_placed stays set, so the change sticks (placeFloating won't reset).
        .move => |d| moveFloating(d.x, d.y),
        .resize => |d| resizeFloating(d.x, d.y),
        // Focus/layout — all reposition the focused window and/or move the
        // selection, so warp the pointer to follow (dwl warpcursor).
        .focusstack => |dir| {
            focusStack(dir);
            requestWarp();
        },
        .setmfact => |delta| {
            adjustMfact(delta);
            requestWarp();
        },
        .incnmaster => |delta| {
            adjustNmaster(delta);
            requestWarp();
        },
        .focusmon => |dir| {
            focusMonitor(dir);
            requestWarp();
        },
        // Moves the focused WINDOW to the adjacent monitor. Unlike focusmon, the
        // selection (and pointer) stay put — moving a window shouldn't yank the
        // cursor — so no warp here.
        .sendmon => |dir| sendToMonitor(dir),
    }
}

// ---------------------------------------------------------------------------
// The window-manager operations the actions are built from
// ---------------------------------------------------------------------------

/// Whether `d` names a real desktop. Desktops are 1-based, so 0 is always
/// invalid; the upper bound is `config.desktops.count`.
fn validDesktop(d: u32) bool {
    return d >= 1 and d <= config.desktops.count;
}

/// Ensure focus lands on a window that's actually visible on `out` after a view
/// or desktop change; clears focus if the output is now empty.
fn refocus(out: *Output) void {
    const ctx = Context.get();
    if (ctx.focused) |f| {
        if (f.output == out and f.visible()) return; // still valid
    }
    for (ctx.windows.items) |w| {
        if (w.output == out and w.visible()) {
            ctx.focused = w;
            return;
        }
    }
    ctx.focused = null;
}

fn promoteToMaster(w: *Window) void {
    const ctx = Context.get();
    for (ctx.windows.items, 0..) |win, i| {
        if (win == w and i > 0) {
            _ = ctx.windows.orderedRemove(i);
            ctx.windows.insert(ctx.gpa, 0, w) catch {};
            break;
        }
    }
}

fn focusStack(dir: i32) void {
    const ctx = Context.get();
    const out = query.selectedOutput() orelse return;
    const cur = ctx.focused orelse return;
    if (cur.output != out) return;

    var visible: std.ArrayList(*Window) = .empty;
    defer visible.deinit(ctx.gpa);
    for (ctx.windows.items) |w| {
        if (w.output == out and w.visible() and !w.floating) {
            visible.append(ctx.gpa, w) catch return;
        }
    }
    if (visible.items.len < 2) return;

    for (visible.items, 0..) |w, i| {
        if (w == cur) {
            const next_idx = if (dir > 0)
                (i + 1) % visible.items.len
            else
                (i + visible.items.len - 1) % visible.items.len;
            ctx.focused = visible.items[next_idx];
            return;
        }
    }
}

fn adjustMfact(delta: f32) void {
    const out = query.selectedOutput() orelse return;
    const new = @max(0.1, @min(0.9, out.mfact + delta));
    out.mfact = new;
}

fn adjustNmaster(delta: i32) void {
    const out = query.selectedOutput() orelse return;
    out.nmaster = @max(0, out.nmaster + delta);
}

/// Move the focused floating window by (dx,dy), keeping it on its output. No-op for
/// tiled/fullscreen windows. float_placed is already set, so placeFloating leaves
/// the new position alone.
fn moveFloating(dx: i32, dy: i32) void {
    const ctx = Context.get();
    const f = ctx.focused orelse return;
    if (!f.floating or f.fullscreen) return;
    const o = f.output orelse return;
    f.x = std.math.clamp(f.x + dx, 0, @max(0, o.width - f.width));
    f.y = std.math.clamp(f.y + dy, 0, @max(0, o.height - f.height));
}

/// Grow/shrink the focused floating window by (dw,dh), respecting its min-size hint
/// (and a small floor) and the output bounds, then nudge it back on-screen if it
/// grew past an edge.
fn resizeFloating(dw: i32, dh: i32) void {
    const ctx = Context.get();
    const f = ctx.focused orelse return;
    if (!f.floating or f.fullscreen) return;
    const o = f.output orelse return;
    const min_w = @max(@as(i32, 40), f.min_width);
    const min_h = @max(@as(i32, 40), f.min_height);
    f.width = std.math.clamp(f.width + dw, min_w, o.width);
    f.height = std.math.clamp(f.height + dh, min_h, o.height);
    f.x = @min(f.x, @max(0, o.width - f.width));
    f.y = @min(f.y, @max(0, o.height - f.height));
}

/// Index of `out` in the output list, or null if not present.
fn outputIndex(out: *Output) ?usize {
    const ctx = Context.get();
    for (ctx.outputs.items, 0..) |o, i| {
        if (o == out) return i;
    }
    return null;
}

/// The output `dir` steps away from `out` (wrapping). Null if there's only one.
fn adjacentOutput(out: *Output, dir: i32) ?*Output {
    const ctx = Context.get();
    const n = ctx.outputs.items.len;
    if (n < 2) return null;
    const i = outputIndex(out) orelse return null;
    const next = if (dir > 0) (i + 1) % n else (i + n - 1) % n;
    return ctx.outputs.items[next];
}

/// Move the selection to the adjacent monitor and pull keyboard focus there.
/// Works even when the target monitor is empty (selection still moves, focus
/// clears) so you can switch to a bare monitor and spawn onto it.
fn focusMonitor(dir: i32) void {
    const ctx = Context.get();
    const cur = query.selectedOutput() orelse return;
    const next_out = adjacentOutput(cur, dir) orelse return;

    ctx.current_output = next_out;
    ctx.pointer_output = next_out;
    ctx.focused = query.topVisibleOn(next_out);
}

/// Send the focused window to the adjacent monitor, keeping it on the SAME
/// desktop number it was already on rather than moving it to the destination's
/// viewed desktop. So a window on desktop 3 stays on desktop 3 over there — it
/// only shows immediately if that monitor is already viewing desktop 3, otherwise
/// it waits there. The selection stays put; focus falls to whatever's left on the
/// current monitor.
fn sendToMonitor(dir: i32) void {
    const ctx = Context.get();
    const cur = query.selectedOutput() orelse return;
    const next_out = adjacentOutput(cur, dir) orelse return;
    const w = ctx.focused orelse return;

    w.output = next_out;
    refocus(cur);
}

// ---------------------------------------------------------------------------
// Cursor warp (dwl warpcursor)
// ---------------------------------------------------------------------------

/// Ask to warp the pointer onto the focused window on the next manage cycle.
/// Runs inside a guaranteed manage sequence (binding press → manage_start).
fn requestWarp() void {
    Context.get().warp_pending = true;
}

/// Warp the pointer to the center of the focused window (or the selected output
/// if nothing is focused). MUST be called from a manage sequence — pointer_warp
/// is a manage-only request — and AFTER arrange() so window geometry is current.
pub fn applyWarp() void {
    const ctx = Context.get();
    if (!ctx.warp_pending) return;
    ctx.warp_pending = false;

    const seat = ctx.primary_seat orelse return;
    var x: i32 = undefined;
    var y: i32 = undefined;
    if (ctx.focused) |f| {
        const o = f.output orelse return;
        x = o.x + f.x + @divFloor(f.width, 2);
        y = o.y + f.y + @divFloor(f.height, 2);
    } else if (ctx.current_output) |o| {
        x = o.x + @divFloor(o.width, 2);
        y = o.y + @divFloor(o.height, 2);
    } else return;

    seat.rwm.pointerWarp(x, y);
}

// ---------------------------------------------------------------------------
// Spawning
// ---------------------------------------------------------------------------

/// Run the configured startup commands (dwl's `autostart[]`). Each goes through
/// `/bin/sh -c`. Spawned children inherit our environment, including the
/// WAYLAND_DISPLAY river set for us, so GUI clients connect to the session.
pub fn runAutostart() void {
    for (config.autostart) |cmd| spawn(cmd);
}

/// Double-fork + setsid a `/bin/sh -c <cmd>`, reaping the first child so no
/// zombie is left and the grandchild is reparented to init.
pub fn spawn(cmd: [:0]const u8) void {
    const pid1 = std.c.fork();
    if (pid1 < 0) return;
    if (pid1 == 0) {
        // Child 1: new session, reset signal mask, fork again.
        _ = std.c.setsid();
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, &std.posix.sigemptyset(), null);

        const pid2 = std.c.fork();
        if (pid2 < 0) std.c._exit(1);
        if (pid2 == 0) {
            const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd.ptr, null };
            _ = std.c.execve("/bin/sh", &child_args, std.c.environ);
            std.c._exit(1);
        }
        std.c._exit(0);
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid1, &status, 0);
}

// ---------------------------------------------------------------------------
// Action execution
