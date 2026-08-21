// border.zig — tmux-style shared-gutter borders.
//
// The look (per the user's spec): highlight only the gutters that *touch the
// focused window* — its interior edges (the ones shared with a neighbor across a
// gap), never the edges facing the screen, and never a full box around the
// window.
//
// EVERY tiled window draws the same shape — a line in each of its interior-edge
// gutters, applying dwl's half-line-at-junction rule (a line extends only halfway
// into a crossing gutter) — see windowRects() for the geometry. The only thing
// focus changes is the COLOR: `border_active` for the focused window,
// `border_inactive` for all the others.
//
// The line HUGS its own window: it sits in the gutter flush against that window's
// edge, not centred in the gutter. So `border_thickness` is all that is ever
// painted, and `inner_gap` only controls how much wallpaper is left beyond it —
// the two knobs stay independent however wide the gap gets. A gutter between two
// windows therefore carries TWO lines, one hugging each side, with the wallpaper
// visible between them.
//
// Drawing mechanism — no shm needed for solid colors:
//   * a 1x1 wp_single_pixel_buffer holds the color,
//   * a wp_viewport scales that one pixel up to the rectangle size,
//   * a river shell-surface + node place the rectangle in the scene.
// Surfaces are pooled and reused frame to frame; spares are hidden, not freed.

const std = @import("std");
const log = std.log.scoped(.border);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const config = @import("config.zig");
const Context = @import("context.zig");
const Window = @import("window.zig").Window;
const bar = @import("bar.zig");

/// One reusable solid-color rectangle in the scene.
pub const BorderSurface = struct {
    surface: *wl.Surface,
    viewport: *wp.Viewport,
    shell: *river.ShellSurfaceV1,
    node: *river.NodeV1,
    visible: bool = false,

    fn create() !*BorderSurface {
        const ctx = Context.get();
        const surface = try ctx.wl_compositor.?.createSurface();
        errdefer surface.destroy();
        const viewport = try ctx.wp_viewporter.?.getViewport(surface);
        errdefer viewport.destroy();
        const shell = try ctx.rwm.getShellSurface(surface);
        errdefer shell.destroy();
        const node = try shell.getNode();

        const self = try ctx.gpa.create(BorderSurface);
        self.* = .{ .surface = surface, .viewport = viewport, .shell = shell, .node = node };
        return self;
    }

    /// Show this border at global (gx, gy) with size (w, h) in `color` (0xRRGGBB).
    /// Placed above the windows. Must be called inside a render sequence.
    fn show(self: *BorderSurface, gx: i32, gy: i32, w: i32, h: i32, color: u32) void {
        const ctx = Context.get();
        if (w <= 0 or h <= 0) {
            self.hide();
            return;
        }

        // A fresh 1x1 buffer of the color (cheap; released after commit).
        const c = components(color);
        const buffer = ctx.wp_single_pixel_buffer_manager.?.createU32RgbaBuffer(c.r, c.g, c.b, c.a) catch |err| {
            log.err("create color buffer failed: {}", .{err});
            return;
        };
        defer buffer.destroy();

        self.surface.attach(buffer, 0, 0);
        self.surface.damage(0, 0, w, h);
        self.viewport.setDestination(w, h); // scale the 1px up to w x h
        self.shell.syncNextCommit(); // align this commit with the render sequence
        self.surface.commit();

        self.node.setPosition(gx, gy);
        self.node.placeTop();
        self.visible = true;
    }

    /// Hide by detaching the buffer (an unmapped surface draws nothing).
    fn hide(self: *BorderSurface) void {
        if (!self.visible) return;
        self.surface.attach(null, 0, 0);
        self.shell.syncNextCommit();
        self.surface.commit();
        self.visible = false;
    }
};

/// A highlight rectangle in output-local coordinates.
const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Recompute and draw the focused window's border highlights. Called from the
/// render cycle, after windows are positioned.
pub fn update() void {
    const ctx = Context.get();

    // Borders need the viewporter + single-pixel-buffer globals; if either is
    // missing we simply draw nothing.
    if (ctx.wp_viewporter == null or ctx.wp_single_pixel_buffer_manager == null) return;

    var used: usize = 0;

    // Unfocused windows first, focused last: both sides of a shared gutter draw a
    // line hugging their own edge, and drawing the focused one last means its
    // colour wins wherever the two would overlap (they only can when the gutter is
    // narrower than 2 * border_thickness).
    for (ctx.windows.items) |w| {
        if (w == ctx.focused) continue;
        used = draw(w, config.border_inactive, used);
    }
    if (ctx.focused) |f| used = draw(f, config.border_active, used);

    // Hide any pooled surfaces we didn't use this frame.
    for (ctx.borders.items[used..]) |bs| bs.hide();
}

/// Draw one window's border lines in `color`, continuing the frame's surface
/// allocation at `used` and returning the new count.
fn draw(w: *Window, color: u32, used: usize) usize {
    var n = used;
    const wr = windowRects(w) orelse return n;
    for (wr.rects[0..wr.n]) |r| {
        const bs = ensure(n) orelse return n;
        n += 1;
        bs.show(wr.out_x + r.x, wr.out_y + r.y, r.w, r.h, color);
    }
    return n;
}

/// Compute one window's highlight rectangles, porting dwl's `drawclientborders`
/// half-line geometry into reach's gapped layout, with each line hugging `f`'s own
/// edge rather than centred in the gutter. `f`'s index `cidx` among the tiled
/// windows and the total `total` drive which shared edges get a line and where the
/// half-lines fall. Returns null when there is nothing to highlight.
///
/// Focus does not appear here at all — the caller picks the colour. Both windows
/// either side of a gutter run this independently and each gets its own line.
fn windowRects(f: *Window) ?struct { rects: [4]Rect, n: usize, out_x: i32, out_y: i32 } {
    const ctx = Context.get();
    if (f.fullscreen or !f.visible()) return null;
    const out = f.output orelse return null;

    // Floating window: it has no shared gutters with tiled neighbors (it stacks
    // above them), so the tmux half-line model doesn't apply. Draw a full box
    // outline instead — a ring inset along the window's own edges (inset, so it
    // can't spill off-screen when the window is flush against an output edge).
    if (f.floating) {
        const t = config.border_thickness;
        const w = f.width;
        const h = f.height;
        if (w <= 0 or h <= 0) return null;
        var box: [4]Rect = undefined;
        box[0] = .{ .x = f.x, .y = f.y, .w = w, .h = t }; // top
        box[1] = .{ .x = f.x, .y = f.y + h - t, .w = w, .h = t }; // bottom
        box[2] = .{ .x = f.x, .y = f.y, .w = t, .h = h }; // left
        box[3] = .{ .x = f.x + w - t, .y = f.y, .w = t, .h = h }; // right
        return .{ .rects = box, .n = 4, .out_x = out.x, .out_y = out.y };
    }

    // Find the focused window's index among the tiled, visible windows on its
    // output, in the same order layout.arrange used (master first).
    var total: i32 = 0;
    var cidx: i32 = -1;
    for (ctx.windows.items) |w| {
        if (w.output == out and !w.floating and w.visible()) {
            if (w == f) cidx = total;
            total += 1;
        }
    }
    if (cidx < 0 or total <= 1) return null; // single tiled window → no shared edge

    const og = config.outer_gap;
    const t = config.border_thickness;
    const nmaster = out.nmaster;

    // Usable area (output-local), matching layout.zig — including the strip the
    // bar reserves at the top/bottom. Only the two-pane cases need it, to halve
    // the line's length.
    const bar_h = bar.height();
    const top_reserve: i32 = if (config.bar.top) bar_h else 0;
    const ux = og;
    const uy = og + top_reserve;
    const uw = out.width - 2 * og;
    const uh = out.height - 2 * og - bar_h;

    // Every line HUGS the focused window — it goes in the gutter flush against
    // that window's own edge, so its position derives from `f` alone and the
    // gutter's width never enters into it. `f.x + f.width` is the first column
    // outside the right edge; `f.x - t` is the last column before the left edge.
    const in_master = cidx < nmaster;

    var rects: [4]Rect = undefined;
    var n: usize = 0;

    if (nmaster == 1 and total == 2) {
        // Two panes side by side: half-height vertical line hugging the focused
        // pane — TOP half when it is the master (left, cidx 0), BOTTOM half when
        // it is the stack (right, cidx 1).
        const y0 = uy + (if (cidx == 1) @divFloor(uh, 2) else 0);
        const h = @divFloor(uh, 2);
        const x = if (cidx == 1) f.x - t else f.x + f.width;
        rects[n] = .{ .x = x, .y = y0, .w = t, .h = h };
        n += 1;
    } else if (nmaster != 1 and total == 2) {
        // Two panes stacked: half-width horizontal line hugging the focused pane —
        // its bottom edge when it is the upper pane, its top edge when it is the
        // lower one. LEFT or RIGHT half depending on which pane is focused.
        const x0 = ux + (if (cidx == 1) @divFloor(uw, 2) else 0);
        const w = @divFloor(uw, 2);
        const y = if (cidx == 1) f.y - t else f.y + f.height;
        rects[n] = .{ .x = x0, .y = y, .w = w, .h = t };
        n += 1;
    } else {
        // General case.
        // Vertical line on the side facing the other column: the focused window's
        // right edge when it sits in the master column, its left edge when it sits
        // in the stack.
        if (nmaster > 0 and total > nmaster) {
            const x = if (in_master) f.x + f.width else f.x - t;
            rects[n] = .{ .x = x, .y = f.y, .w = t, .h = f.height };
            n += 1;
        }
        // Horizontal line ABOVE, only when the focused window has a neighbor above
        // in its own column. Spans just the focused window's column (its width).
        if ((cidx > 0 and cidx < nmaster) or (cidx > nmaster)) {
            rects[n] = .{ .x = f.x, .y = f.y - t, .w = f.width, .h = t };
            n += 1;
        }
        // Horizontal line BELOW, only when there is a neighbor below in its column.
        if ((cidx < nmaster - 1) or (cidx >= nmaster and cidx < total - 1)) {
            rects[n] = .{ .x = f.x, .y = f.y + f.height, .w = f.width, .h = t };
            n += 1;
        }
    }

    if (n == 0) return null;
    return .{ .rects = rects, .n = n, .out_x = out.x, .out_y = out.y };
}

/// Get pooled border surface `i`, growing the pool if needed.
fn ensure(i: usize) ?*BorderSurface {
    const ctx = Context.get();
    while (ctx.borders.items.len <= i) {
        const bs = BorderSurface.create() catch |err| {
            log.err("create border surface failed: {}", .{err});
            return null;
        };
        ctx.borders.append(ctx.gpa, bs) catch {
            bs.surface.destroy();
            return null;
        };
    }
    return ctx.borders.items[i];
}

/// Split a 0xRRGGBB color into the 32-bit-per-channel, opaque, premultiplied
/// components wp_single_pixel_buffer expects. (8-bit c → 32-bit by byte-repeat.)
fn components(color: u32) struct { r: u32, g: u32, b: u32, a: u32 } {
    return .{
        .r = chan(@truncate((color >> 16) & 0xff)),
        .g = chan(@truncate((color >> 8) & 0xff)),
        .b = chan(@truncate(color & 0xff)),
        .a = 0xffff_ffff,
    };
}

fn chan(c: u8) u32 {
    return @as(u32, c) * 0x0101_0101;
}
