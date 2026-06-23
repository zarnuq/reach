// border.zig — tmux-style shared-gutter borders.
//
// The look (per the user's spec): highlight only the gutters that *touch the
// focused window* — its interior edges (the ones shared with a neighbor across a
// gap), never the edges facing the screen, and never a full box around the
// window. Inactive gutters are left empty.
//
// We draw a highlight line in each interior-edge gutter of the focused window,
// applying dwl's half-line-at-junction rule (a line extends only halfway into a
// crossing gutter) — see focusedRects() for the geometry.
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
    /// Must be called inside a render sequence (it positions the node).
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
        self.node.placeTop(); // keep borders above the windows
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

    if (focusedRects()) |fr| {
        for (fr.rects[0..fr.n]) |r| {
            const bs = ensure(used) orelse break;
            used += 1;
            bs.show(fr.out_x + r.x, fr.out_y + r.y, r.w, r.h, config.border_active);
        }
    }

    // Hide any pooled surfaces we didn't use this frame.
    for (ctx.borders.items[used..]) |bs| bs.hide();
}

/// Compute the focused window's highlight rectangles, porting dwl's
/// `drawclientborders` half-line geometry into reach's gapped layout. The
/// focused window's index `cidx` among the tiled windows and the total `total`
/// drive which shared edges get a line and where the half-lines fall. Returns
/// null when there is nothing to highlight.
fn focusedRects() ?struct { rects: [4]Rect, n: usize, out_x: i32, out_y: i32 } {
    const ctx = Context.get();
    const f = ctx.focused orelse return null;
    if (f.fullscreen or !f.visible()) return null;
    const out = f.output orelse return null;

    // Floating window: it has no shared gutters with tiled neighbors (it stacks
    // above them), so the tmux half-line model doesn't apply. Draw a full box
    // outline instead — a focus ring inset along the window's own edges (inset, so
    // it can't spill off-screen when the window is flush against an output edge).
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
    const ig = config.inner_gap;
    const t = config.border_thickness;
    const half_t = @divFloor(t, 2);
    const half_g = @divFloor(ig, 2);
    const nmaster = out.nmaster;

    // Usable area (output-local) and the master column width, matching layout.zig
    // — including the strip the bar reserves at the top/bottom.
    const bar_h = bar.height();
    const top_reserve: i32 = if (config.bar.top) bar_h else 0;
    const ux = og;
    const uy = og + top_reserve;
    const uw = out.width - 2 * og;
    const uh = out.height - 2 * og - bar_h;
    const nstack = total - @min(total, nmaster);
    const master_w: i32 = if (nstack > 0)
        @intFromFloat(out.mfact * @as(f32, @floatFromInt(uw)))
    else
        uw;
    // Center of the vertical gutter dividing master and stack columns.
    const divider_cx = ux + master_w + half_g;

    var rects: [4]Rect = undefined;
    var n: usize = 0;

    if (nmaster == 1 and total == 2) {
        // Two panes side by side: half-height vertical line at the divider —
        // TOP half when the focused pane is the master (left, cidx 0), BOTTOM
        // half when it's the stack (right, cidx 1).
        const y0 = uy + (if (cidx == 1) @divFloor(uh, 2) else 0);
        const h = @divFloor(uh, 2);
        rects[n] = .{ .x = divider_cx - half_t, .y = y0, .w = t, .h = h };
        n += 1;
    } else if (nmaster != 1 and total == 2) {
        // Two panes stacked: half-width horizontal line at the vertical center —
        // LEFT or RIGHT half depending on which pane is focused.
        const x0 = ux + (if (cidx == 1) @divFloor(uw, 2) else 0);
        const w = @divFloor(uw, 2);
        const cy = uy + @divFloor(uh, 2);
        rects[n] = .{ .x = x0, .y = cy - half_t, .w = w, .h = t };
        n += 1;
    } else {
        // General case.
        // Vertical divider segment, spanning the focused window's height.
        if (nmaster > 0 and total > nmaster) {
            rects[n] = .{ .x = divider_cx - half_t, .y = f.y, .w = t, .h = f.height };
            n += 1;
        }
        // Horizontal line ABOVE, only when the focused window has a neighbor above
        // in its own column. Spans just the focused window's column (its width).
        if ((cidx > 0 and cidx < nmaster) or (cidx > nmaster)) {
            const cy = f.y - half_g;
            rects[n] = .{ .x = f.x, .y = cy - half_t, .w = f.width, .h = t };
            n += 1;
        }
        // Horizontal line BELOW, only when there is a neighbor below in its column.
        if ((cidx < nmaster - 1) or (cidx >= nmaster and cidx < total - 1)) {
            const cy = f.y + f.height + half_g;
            rects[n] = .{ .x = f.x, .y = cy - half_t, .w = f.width, .h = t };
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
