// layout.zig — the master-stack tiling layout.
//
// Classic dwm/dwl arrangement: `nmaster` windows fill a master column on the
// left (taking `mfact` of the width when a stack exists); the remaining windows
// share a stack column on the right. Gaps: `outer_gap` around the whole tiled
// area, `inner_gap` between adjacent windows (these gutters are where the
// tmux-style borders in border.zig are drawn).
//
// arrange() only sets each window's x/y/width/height (output-relative). The
// actual protocol calls happen later: manage() proposes the size, render()
// positions the node.

const std = @import("std");

const config = @import("config.zig");
const Context = @import("context.zig");
const Output = @import("output.zig").Output;
const Window = @import("window.zig").Window;
const bar = @import("bar.zig");

/// Lay out the tiled (non-floating) windows that live on `out`.
pub fn arrange(out: *Output) void {
    const ctx = Context.get();

    // Gather this output's tiled windows on the currently-viewed desktop, in stack
    // order (head = master). We compare desktops directly rather than going through
    // visible(): visible() requires `mapped`, but arrange is precisely what first
    // lays a window out and sets `mapped = true` (below). Gating on visible() here
    // would deadlock — a freshly-created tiled window (mapped == false) would never
    // be included, so it would never get mapped, and would never appear.
    var tiled: std.ArrayList(*Window) = .empty;
    defer tiled.deinit(ctx.gpa);
    for (ctx.windows.items) |w| {
        if (w.output == out and !w.floating and !w.fullscreen and w.desktop == out.desktop) {
            tiled.append(ctx.gpa, w) catch return; // OOM: skip this frame
        }
    }

    const n: i32 = @intCast(tiled.items.len);
    if (n == 0) return;

    // The bar reserves a strip at the top (or bottom) of the output; tiled
    // windows live in what's left. `oy` is the top edge of the usable area.
    const bar_h = bar.height();
    const top_reserve: i32 = if (config.bar.top) bar_h else 0;
    const oy = config.outer_gap + top_reserve;

    // Usable area inside the outer gap, minus the bar strip.
    const usable_w = out.width - 2 * config.outer_gap;
    const usable_h = out.height - 2 * config.outer_gap - bar_h;
    if (usable_w <= 0 or usable_h <= 0) return;

    const nmaster = @min(n, out.nmaster);
    const nstack = n - nmaster;

    // Master column width: full width if there is no stack, else mfact of it
    // (leaving an inner gap before the stack).
    const master_w: i32 = if (nstack > 0)
        @intFromFloat(out.mfact * @as(f32, @floatFromInt(usable_w)))
    else
        usable_w;
    const stack_w: i32 = if (nstack > 0) usable_w - master_w - config.inner_gap else 0;

    for (tiled.items, 0..) |w, idx| {
        const i: i32 = @intCast(idx);
        if (i < nmaster) {
            // Master column, split vertically into nmaster rows. The division
            // leaves up to nmaster-1 px over, so the LAST row runs to the bottom
            // edge instead of taking a cell: handing the remainder to nobody leaves
            // a sliver of background under the column whose height changes with the
            // window count.
            const cell_h = @divFloor(usable_h - (nmaster - 1) * config.inner_gap, nmaster);
            w.x = config.outer_gap;
            w.y = oy + i * (cell_h + config.inner_gap);
            w.width = master_w;
            w.height = if (i == nmaster - 1) oy + usable_h - w.y else cell_h;
        } else {
            // Stack column, split vertically into nstack rows — same remainder
            // rule as the master column above.
            const si = i - nmaster;
            const cell_h = @divFloor(usable_h - (nstack - 1) * config.inner_gap, nstack);
            w.x = config.outer_gap + master_w + config.inner_gap;
            w.y = oy + si * (cell_h + config.inner_gap);
            w.width = stack_w;
            w.height = if (si == nstack - 1) oy + usable_h - w.y else cell_h;
        }
        w.width = @max(1, w.width);
        w.height = @max(1, w.height);
        w.mapped = true;
    }
}
