// query.zig — shared read-only predicates over the Context, defined once so callers can't disagree.

const wayland = @import("wayland");
const river = wayland.client.river;

const Context = @import("context.zig");
const Output = @import("output.zig").Output;
const Window = @import("window.zig").Window;

/// Does `w` take part in `out`'s tiling right now?
///
/// This is THE definition — layout.arrange builds its sequence from it, and
/// border.zig walks that same sequence to find the focused window's index. Any
/// difference between the two shows up as border lines drawn on the wrong seam.
///
/// Deliberately does NOT require `mapped`. arrange() is what first lays a window
/// out and sets that flag, so gating on it here would be circular: a fresh window
/// would never be included, so never mapped, so never shown. By the time borders
/// are drawn arrange() has already run, so the flag adds nothing there either.
pub fn tiledOn(w: *const Window, out: *const Output) bool {
    return w.output == out and !w.floating and !w.fullscreen and w.desktop == out.desktop;
}

/// The managed Window wrapping river's `rwm`, or null if it is not one of ours
/// (already closed, or an event naming a window we never tracked). Takes the
/// optional that seat events deliver, so callers need not unwrap it first.
pub fn windowFor(rwm: ?*river.WindowV1) ?*Window {
    const ctx = Context.get();
    const r = rwm orelse return null;
    for (ctx.windows.items) |w| {
        if (w.rwm == r) return w;
    }
    return null;
}

/// The most-recently-focused visible window on `out`, or null if it is empty.
/// `ctx.windows` is kept in stack order, so the first match is the top one.
pub fn topVisibleOn(out: *Output) ?*Window {
    const ctx = Context.get();
    for (ctx.windows.items) |w| {
        if (w.output == out and w.visible()) return w;
    }
    return null;
}

/// Is a fullscreen window showing on `out`? Published on the state socket so a
/// panel can hide itself, since a fullscreen window owns the whole output.
pub fn fullscreenOn(out: *Output) bool {
    const ctx = Context.get();
    for (ctx.windows.items) |w| {
        if (w.output == out and w.fullscreen and w.visible()) return true;
    }
    return false;
}

/// The output whose geometry contains a global point, or null when none does —
/// which is a real case, not a defensive one: a layout may leave a gap between
/// heads, and a head that has just been unplugged still has a pointer somewhere.
pub fn outputAt(x: i32, y: i32) ?*Output {
    const ctx = Context.get();
    for (ctx.outputs.items) |o| {
        if (x >= o.x and x < o.x + o.width and y >= o.y and y < o.y + o.height) return o;
    }
    return null;
}

/// The output the user is driving — dwl's `selmon`. The desktop and layout actions
/// act on it and the state socket reports it as focused, and it must be ONE
/// answer: those two reading it differently is precisely what made a panel's
/// highlight point at a different monitor than the keys.
///
/// `current_output` is the real answer and is set as soon as any output appears;
/// the rest is fallback for the window between startup and that first event.
pub fn selectedOutput() ?*Output {
    const ctx = Context.get();
    if (ctx.current_output) |o| return o;
    if (ctx.focused) |f| {
        if (f.output) |o| return o;
    }
    return if (ctx.outputs.items.len > 0) ctx.outputs.items[0] else null;
}
