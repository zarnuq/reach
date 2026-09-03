// query.zig — the predicates over the managed world, defined once.
//
// These are the questions several subsystems ask about the same state: which
// windows take part in an output's tiling, which window is on top there, which
// output the user is driving. They live here because every one of them had drifted
// into two disagreeing copies:
//
//   * `tiledOn` existed in border.zig as "not floating and visible()" while
//     layout.zig gathered "not floating, not fullscreen, on this desktop". Border
//     geometry is computed by INDEXING into the layout's sequence, so the two sets
//     disagreeing meant a non-focused fullscreen window shifted every border line
//     onto the wrong gutter. border.zig's own comment insisted the two passes
//     "have to agree on this exactly" — which is exactly the kind of invariant a
//     comment cannot enforce and a shared function can.
//
//   * `selectedOutput` existed as bar.currentOutput (current → focused's output →
//     sole output) and binding.focusedOutput (current → outputs[0]). bar.zig's
//     comment claimed they were "the same value"; with `current_output` unset and
//     two monitors they named different ones, so the bar highlighted one monitor
//     while the desktop keys acted on another.
//
//   * `topVisibleOn` was byte-identical in binding.zig and bar.zig.
//
// Nothing here allocates or mutates; these are pure reads of the Context.

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

/// The most-recently-focused visible window on `out`, or null if it is empty.
/// `ctx.windows` is kept in stack order, so the first match is the top one.
pub fn topVisibleOn(out: *Output) ?*Window {
    const ctx = Context.get();
    for (ctx.windows.items) |w| {
        if (w.output == out and w.visible()) return w;
    }
    return null;
}

/// Is a fullscreen window showing on `out`? The bar hides itself when so, since a
/// fullscreen window owns the whole output.
pub fn fullscreenOn(out: *Output) bool {
    const ctx = Context.get();
    for (ctx.windows.items) |w| {
        if (w.output == out and w.fullscreen and w.visible()) return true;
    }
    return false;
}

/// The output the user is driving — dwl's `selmon`. The desktop and layout actions
/// act on it and the bar highlights it, and it must be ONE answer: those two
/// reading it differently is precisely what made the highlight point at a different
/// monitor than the keys.
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
