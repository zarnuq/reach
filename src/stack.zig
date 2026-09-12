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
//   1. tiled windows       — the layout keeps them from overlapping, but the list
//                            order still has to be defined rather than incidental.
//   2. tiled-focus border  — above every tile so zero-gap seams cannot be occluded.
//   3. floating windows    — above both the tiling and a tiled window's border.
//   4. floating-focus ring — above the focused float so its inset outline is seen.
//   5. fullscreen windows  — own the output outright, floats and borders included.
//
// The bar is not in this list: it is an ordinary layer surface belonging to
// another client, and the compositor stacks layer surfaces above everything the
// window manager places.

const Context = @import("context.zig");
const border = @import("border.zig");

/// Apply the z-order. Must be called inside a render sequence (place_* are
/// render-only requests), after every window has been positioned and every border
/// rectangle drawn — placement is independent of content, so it goes last.
pub fn apply() void {
    const ctx = Context.get();

    const focused_layer: ?Layer = focused: {
        const f = ctx.focused orelse break :focused null;
        if (!f.visible() or f.fullscreen) break :focused null;
        break :focused if (f.floating) .floating else .tiled;
    };

    // Window layers walk `ctx.windows` in REVERSE: the list is stack order with
    // the head newest, and place_top raises, so a forward pass would invert it and
    // leave the newest window at the bottom.
    //
    // Windows are re-placed every cycle rather than only when the order changes.
    // These are a handful of small wire messages against a render cycle that
    // already rasterizes the bar; tracking dirtiness would cost more than it saves.
    raiseEach(.tiled);

    // A tiled border must clear every tiled node. This matters when inner_gap is
    // zero: the outside-facing separator occupies pixels inside its neighbour.
    if (focused_layer == .tiled) border.raise();

    raiseEach(.floating);

    // Focusing does not move a window in `ctx.windows`, so explicitly raise a
    // focused float above its peers, followed by its inset border ring.
    if (focused_layer == .floating) {
        ctx.focused.?.node.placeTop();
        border.raise();
    }

    // Layer 5. A fullscreen window owns its output; it goes above the floats and
    // above any border (borders are skipped for it anyway — see focusedLines).
    for (ctx.windows.items) |w| {
        if (w.visible() and w.fullscreen) w.node.placeTop();
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
