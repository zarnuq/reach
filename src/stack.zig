// stack.zig — the scene's z-order, decided in one place.
//
// river gives the WM a flat render list and three ways to move within it
// (place_top, place_bottom, place_above/below). Nothing about that list is
// implicit: per the protocol, "the initial position of a node in the render list
// is undefined", so whatever is not placed is wherever it happens to land.
//
// This used to be spread across window.zig, border.zig and bar.zig, each calling
// place_top on its own during the render cycle. The resulting order was whatever
// the *call order across those files* produced — which is how a focused tiled
// window's border ended up painted over a floating window that was stacked above
// it. Anything with an opinion about layering states it here instead, and the
// render cycle calls `apply()` once after everything has been drawn.
//
// Bottom → top:
//   1. tiled windows      — the layout keeps them from overlapping, but the list
//                           order still has to be defined rather than incidental.
//   2. floating windows   — above the tiling, with the focused float above its
//                           peers so that focusing one raises it.
//   3. focused borders    — anchored DIRECTLY above the window they decorate, not
//                           at the top of the scene. That single rule covers both
//                           shapes: a tiled window's gutter lines clear its tiled
//                           neighbours yet stay under any float, while a floating
//                           window's ring — inset over its own edge pixels — still
//                           lands above the float it outlines.
//   4. fullscreen windows — own the output outright, floats and borders included.
//   5. bars               — always on top, save where a fullscreen window hid them.

const std = @import("std");

const Context = @import("context.zig");
const border = @import("border.zig");

/// Apply the z-order. Must be called inside a render sequence (place_* are
/// render-only requests), after every window has been positioned and every border
/// rectangle drawn — placement is independent of content, so it goes last.
pub fn apply() void {
    const ctx = Context.get();

    // Layers 1 and 2. Both walk `ctx.windows` in REVERSE: the list is stack order
    // with the head newest, and place_top raises, so a forward pass would invert it
    // and leave the newest window at the bottom.
    //
    // Windows are re-placed every cycle rather than only when the order changes.
    // These are a handful of small wire messages against a render cycle that
    // already rasterizes the bar; tracking dirtiness would cost more than it saves.
    raiseEach(.tiled);
    raiseEach(.floating);

    // The focused float goes last so that focusing raises it above the other
    // floats. It needs saying explicitly: focusing a window does NOT move it in
    // `ctx.windows` (focusStack, click-to-focus and focusmon all just reassign
    // `ctx.focused`), so its list position says nothing about whether it is
    // focused, and the reverse pass above cannot pick it out.
    if (ctx.focused) |f| {
        if (f.visible() and f.floating and !f.fullscreen) f.node.placeTop();
    }

    // Layer 3. Anchored to the focused window, so it has to follow the windows and
    // precede anything that must cover it.
    border.restack();

    // Layer 4. A fullscreen window owns its output; it goes above the floats and
    // above any border (borders are skipped for it anyway — see focusedLines).
    for (ctx.windows.items) |w| {
        if (w.visible() and w.fullscreen) w.node.placeTop();
    }

    // Layer 5. `raise` is a no-op for a bar hidden by a fullscreen window.
    for (ctx.outputs.items) |o| {
        if (o.bar) |b| b.raise();
    }
}

const Layer = enum { tiled, floating };

/// Raise every visible, non-fullscreen window in `layer`, oldest first.
fn raiseEach(layer: Layer) void {
    const ctx = Context.get();
    var i = ctx.windows.items.len;
    while (i > 0) {
        i -= 1;
        const w = ctx.windows.items[i];
        if (!w.visible() or w.fullscreen) continue;
        if ((layer == .floating) != w.floating) continue;
        w.node.placeTop();
    }
}
