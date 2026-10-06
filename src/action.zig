// action.zig — what the window manager can be asked to do (Action), and the doing of it.
//
// Actions mutate state directly: river follows every `pressed` with a manage_start,
// so layout/render re-run on their own. Only a config reload and a cursor warp
// (warp_pending) are deferred to the manage cycle.

const std = @import("std");

const config = @import("config.zig");
const gamma = @import("gamma.zig");
const reload = @import("reload.zig");
const Context = @import("context.zig");
const output = @import("output.zig");
const Output = output.Output;
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
    // Screen brightness, as a signed percentage step applied to every output at
    // once (gamma.zig). Clamped to a floor so a bind can't black the screen out.
    brightness: i32,
    // Re-read config.zon (deferred; see reload.zig).
    reload,
};

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
            if (!config.validDesktop(d)) return;
            const out = ctx.current_output orelse return;
            out.desktop = d;
            refocus(out);
        },
        .send => |d| {
            if (!config.validDesktop(d)) return;
            const out = ctx.current_output orelse return;
            if (ctx.focused) |f| {
                f.desktop = d;
                refocus(out);
            }
        },
        // Spawn a shell command (double-fork; see spawn()).
        .spawn => |cmd| spawn(cmd),
        // Dim/undim every output.
        .brightness => |d| gamma.step(d),
        // Deferred; see reload.zig.
        .reload => reload.request(),
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
            warp_pending = true;
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
            warp_pending = true;
        },
        .setmfact => |delta| {
            if (ctx.current_output) |out| out.mfact = output.clampMfact(out.mfact + delta);
            warp_pending = true;
        },
        .incnmaster => |delta| {
            if (ctx.current_output) |out| out.nmaster = output.clampNmaster(out.nmaster + delta);
            warp_pending = true;
        },
        .focusmon => |dir| {
            focusMonitor(dir);
            warp_pending = true;
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

/// Ensure focus lands on a window that's actually visible on `out` after a view
/// or desktop change; clears focus if the output is now empty.
fn refocus(out: *Output) void {
    const ctx = Context.get();
    if (ctx.focused) |f| {
        if (f.output == out and f.visible()) return; // still valid
    }
    ctx.focused = query.topVisibleOn(out);
}

/// Move `w` to the head of the stack (master), shifting the windows above it
/// down one place. In place, so it cannot fail.
fn promoteToMaster(w: *Window) void {
    const ctx = Context.get();
    const i = std.mem.indexOfScalar(*Window, ctx.windows.items, w) orelse return;
    std.mem.rotate(*Window, ctx.windows.items[0 .. i + 1], i);
}

fn focusStack(dir: i32) void {
    const ctx = Context.get();
    const out = ctx.current_output orelse return;
    const cur = ctx.focused orelse return;

    ctx.focused = nextFocusable(ctx.windows.items, out, cur, dir) orelse return;
}

/// Find the next visible window on `out` in stack order. Tiled and floating
/// windows deliberately share one cycle: focus is independent of layout mode,
/// and stack.apply() raises a floating window when it becomes focused.
fn nextFocusable(windows: []const *Window, out: *Output, cur: *Window, dir: i32) ?*Window {
    if (cur.output != out or !cur.visible()) return null;
    const n = windows.len;
    var i = std.mem.indexOfScalar(*Window, windows, cur) orelse return null;
    for (1..n) |_| {
        i = if (dir > 0) (i + 1) % n else (i + n - 1) % n;
        if (windows[i].output == out and windows[i].visible()) return windows[i];
    }
    return null;
}

test "focus cycling includes floating windows in both directions" {
    var out = Output{ .rwm = undefined };
    var tiled_a = Window{ .rwm = undefined, .node = undefined, .output = &out, .mapped = true };
    var floating = Window{ .rwm = undefined, .node = undefined, .output = &out, .mapped = true, .floating = true };
    var tiled_b = Window{ .rwm = undefined, .node = undefined, .output = &out, .mapped = true };
    const windows = [_]*Window{ &tiled_a, &floating, &tiled_b };

    try std.testing.expectEqual(&floating, nextFocusable(&windows, &out, &tiled_a, 1).?);
    try std.testing.expectEqual(&tiled_b, nextFocusable(&windows, &out, &floating, 1).?);
    try std.testing.expectEqual(&tiled_a, nextFocusable(&windows, &out, &tiled_b, 1).?);
    try std.testing.expectEqual(&floating, nextFocusable(&windows, &out, &tiled_b, -1).?);
    try std.testing.expectEqual(&tiled_b, nextFocusable(&windows, &out, &tiled_a, -1).?);
}

test "focus cycling skips windows that are not visible on the selected output" {
    var out = Output{ .rwm = undefined };
    var other_out = Output{ .rwm = undefined };
    var current = Window{ .rwm = undefined, .node = undefined, .output = &out, .mapped = true };
    var unmapped = Window{ .rwm = undefined, .node = undefined, .output = &out, .floating = true };
    var other_desktop = Window{ .rwm = undefined, .node = undefined, .output = &out, .mapped = true, .desktop = 2, .floating = true };
    var other_output = Window{ .rwm = undefined, .node = undefined, .output = &other_out, .mapped = true, .floating = true };
    var target = Window{ .rwm = undefined, .node = undefined, .output = &out, .mapped = true, .floating = true };
    const windows = [_]*Window{ &current, &unmapped, &other_desktop, &other_output, &target };

    try std.testing.expectEqual(&target, nextFocusable(&windows, &out, &current, 1).?);
    try std.testing.expectEqual(&target, nextFocusable(&windows, &out, &current, -1).?);
}

/// The focused window if it is floating, not fullscreen, and on an output.
fn focusedFloating() ?*Window {
    const f = Context.get().focused orelse return null;
    if (!f.floating or f.fullscreen or f.output == null) return null;
    return f;
}

/// Move the focused floating window by (dx,dy), keeping it on its output. No-op for
/// tiled/fullscreen windows. float_placed is already set, so placeFloating leaves
/// the new position alone.
fn moveFloating(dx: i32, dy: i32) void {
    const f = focusedFloating() orelse return;
    const o = f.output.?;
    f.x = std.math.clamp(f.x + dx, 0, @max(0, o.width - f.width));
    f.y = std.math.clamp(f.y + dy, 0, @max(0, o.height - f.height));
}

/// Grow/shrink the focused floating window by (dw,dh), respecting its min-size hint
/// (and a small floor) and the output bounds, then nudge it back on-screen if it
/// grew past an edge.
fn resizeFloating(dw: i32, dh: i32) void {
    const f = focusedFloating() orelse return;
    const o = f.output.?;
    const min_w = @max(@as(i32, 40), f.min_width);
    const min_h = @max(@as(i32, 40), f.min_height);
    f.width = std.math.clamp(f.width + dw, min_w, o.width);
    f.height = std.math.clamp(f.height + dh, min_h, o.height);
    f.x = @min(f.x, @max(0, o.width - f.width));
    f.y = @min(f.y, @max(0, o.height - f.height));
}

/// The output `dir` steps away from `out` (wrapping). Null if there's only one.
fn adjacentOutput(out: *Output, dir: i32) ?*Output {
    const ctx = Context.get();
    const n = ctx.outputs.items.len;
    if (n < 2) return null;
    const i = std.mem.indexOfScalar(*Output, ctx.outputs.items, out) orelse return null;
    const next = if (dir > 0) (i + 1) % n else (i + n - 1) % n;
    return ctx.outputs.items[next];
}

/// Move the selection to the adjacent monitor and pull keyboard focus there.
/// Works even when the target monitor is empty (selection still moves, focus
/// clears) so you can switch to a bare monitor and spawn onto it.
fn focusMonitor(dir: i32) void {
    const ctx = Context.get();
    const cur = ctx.current_output orelse return;
    const next_out = adjacentOutput(cur, dir) orelse return;

    ctx.current_output = next_out;
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
    const cur = ctx.current_output orelse return;
    const next_out = adjacentOutput(cur, dir) orelse return;
    const w = ctx.focused orelse return;

    w.output = next_out;
    refocus(cur);
}

// ---------------------------------------------------------------------------
// Cursor warp (dwl warpcursor)
// ---------------------------------------------------------------------------

/// Set by keyboard focus/layout actions to warp the pointer onto the newly focused
/// window (dwl `warpcursor`) on the next manage cycle. Keeps the cursor with the
/// keyboard focus, which also stops sloppy_focus from snapping focus back on the
/// next stray pointer motion.
var warp_pending = false;

/// Warp the pointer to the center of the focused window (or the selected output
/// if nothing is focused). MUST be called from a manage sequence — pointer_warp
/// is a manage-only request — and AFTER arrange() so window geometry is current.
pub fn applyWarp() void {
    const ctx = Context.get();
    if (!warp_pending) return;
    warp_pending = false;

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
