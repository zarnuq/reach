// border.zig — tmux-style shared-gutter borders.
//
// The look (per the user's spec): highlight only the gutters that *touch the
// focused window* — its interior edges (the ones shared with a neighbor across a
// gap), never the edges facing the screen, and never a full box around the
// window.
//
// ONLY the focused window is decorated, and only on the faces it actually shares
// with a neighbour — never a box around the window, never anything on the
// neighbour itself. Every other seam on the output stays bare.
//
// A shared face carries ONE line, tmux-style, sitting just OUTSIDE the FOCUSED
// window's own edge — flush against it, never over it, so no pixel of the window
// is covered. Its offset from the window is the same whatever `inner_gap` is; a
// gap of at least `border_thickness` keeps the line entirely in the gutter. The
// line is drawn at FULL length and cut collinearly — the stretch
// running alongside the focused window is `border_active`, the remainder of the
// same line is `border_inactive`. That split is the DIRECTION cue: the active
// stretch shows you where the focus is along the shared edge.
//
// dwl's half-line-at-junction rule survives in the two-pane cases, where the cut
// lands exactly at the midpoint — half active, half inactive.
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

    // Only the focused window is decorated. Its inactive twins go down first so
    // the active line wins if a narrow gutter makes the two overlap.
    if (focusedLines()) |l| {
        used = draw(l.inactive[0..l.n_inactive], l.out_x, l.out_y, config.border_inactive, used);
        used = draw(l.active[0..l.n_active], l.out_x, l.out_y, config.border_active, used);
    }

    // Hide any pooled surfaces we didn't use this frame.
    for (ctx.borders.items[used..]) |bs| bs.hide();
}

/// Draw `rects` (output-local) in `color`, continuing the frame's surface
/// allocation at `used` and returning the new count.
fn draw(rects: []const Rect, out_x: i32, out_y: i32, color: u32, used: usize) usize {
    var n = used;
    for (rects) |r| {
        const bs = ensure(n) orelse return n;
        n += 1;
        bs.show(out_x + r.x, out_y + r.y, r.w, r.h, color);
    }
    return n;
}

/// The lines to draw this frame, split by colour. There is ONE line per shared
/// face — the tmux single-divider look, laid just outside the focused window's own
/// edge so it never covers it, at any `inner_gap` — drawn at FULL length and cut
/// collinearly: the
/// stretch running alongside the focused window is `active`, the rest of that same
/// line is `inactive`. Nothing is drawn on any face the focused window doesn't
/// touch.
const Lines = struct {
    active: [4]Rect = undefined,
    n_active: usize = 0,
    inactive: [6]Rect = undefined,
    n_inactive: usize = 0,
    out_x: i32 = 0,
    out_y: i32 = 0,

    /// Empty rectangles are dropped rather than stored: a focused window flush
    /// against the end of a seam leaves no remainder on that side.
    fn addActive(self: *Lines, r: Rect) void {
        if (r.w <= 0 or r.h <= 0) return;
        self.active[self.n_active] = r;
        self.n_active += 1;
    }

    fn addInactive(self: *Lines, r: Rect) void {
        if (r.w <= 0 or r.h <= 0) return;
        self.inactive[self.n_inactive] = r;
        self.n_inactive += 1;
    }

    /// A vertical seam at `x`, spanning [y0, y1), whose [ay0, ay1) stretch is the
    /// active one. The two leftovers either side become the inactive halves.
    fn vline(self: *Lines, x: i32, t: i32, y0: i32, y1: i32, ay0: i32, ay1: i32) void {
        self.addActive(.{ .x = x, .y = ay0, .w = t, .h = ay1 - ay0 });
        self.addInactive(.{ .x = x, .y = y0, .w = t, .h = ay0 - y0 });
        self.addInactive(.{ .x = x, .y = ay1, .w = t, .h = y1 - ay1 });
    }

    /// A horizontal seam at `y`, spanning [x0, x1), whose [ax0, ax1) stretch is
    /// the active one.
    fn hline(self: *Lines, y: i32, t: i32, x0: i32, x1: i32, ax0: i32, ax1: i32) void {
        self.addActive(.{ .x = ax0, .y = y, .w = ax1 - ax0, .h = t });
        self.addInactive(.{ .x = x0, .y = y, .w = ax0 - x0, .h = t });
        self.addInactive(.{ .x = ax1, .y = y, .w = x1 - ax1, .h = t });
    }
};

/// Compute the focused window's seam lines, porting dwl's `drawclientborders`
/// half-line geometry into reach's gapped layout. `cidx` (the focused window's
/// index among the tiled windows) and `total` drive which seams exist and where the
/// active/inactive cut falls. Returns null when there is nothing to draw.
fn focusedLines() ?Lines {
    const ctx = Context.get();
    const f = ctx.focused orelse return null;
    if (f.fullscreen or !f.visible()) return null;
    const out = f.output orelse return null;

    var l: Lines = .{ .out_x = out.x, .out_y = out.y };

    // Floating window: it shares no seam with anything (it stacks above the tiled
    // windows), so there is no line to cut. Draw a full box outline instead — a
    // ring inset along its own edges, so it can't spill off-screen when the window
    // sits flush against an output edge.
    if (f.floating) {
        const t = config.border_thickness;
        const w = f.width;
        const h = f.height;
        if (w <= 0 or h <= 0) return null;
        l.addActive(.{ .x = f.x, .y = f.y, .w = w, .h = t }); // top
        l.addActive(.{ .x = f.x, .y = f.y + h - t, .w = w, .h = t }); // bottom
        l.addActive(.{ .x = f.x, .y = f.y, .w = t, .h = h }); // left
        l.addActive(.{ .x = f.x + w - t, .y = f.y, .w = t, .h = h }); // right
        return l;
    }

    // Where the focused window sits among the tiled, visible windows on its output,
    // in the same order layout.arrange used (master column first, then the stack).
    var total: i32 = 0;
    var cidx: i32 = -1;
    for (ctx.windows.items) |w| {
        if (w.output == out and !w.floating and w.visible()) {
            if (w == f) cidx = total;
            total += 1;
        }
    }
    if (cidx < 0 or total <= 1) return null; // single tiled window → no shared seam

    const og = config.outer_gap;
    const t = config.border_thickness;
    const nmaster = out.nmaster;

    // Usable area (output-local), matching layout.zig — including the strip the bar
    // reserves at the top/bottom. Only the full-line extents need it.
    const bar_h = bar.height();
    const top_reserve: i32 = if (config.bar.top) bar_h else 0;
    const ux = og;
    const uy = og + top_reserve;
    const uw = out.width - 2 * og;
    const uh = out.height - 2 * og - bar_h;

    // Every line is laid just OUTSIDE the focused window's own facing edge: it
    // starts at the first pixel past that edge and grows away from the window, so
    // it never covers any of it. A leading edge (left/top) therefore sits at
    // `edge - t`; a trailing edge (right/bottom) sits at `edge`. The gutter's width
    // never enters into it, so the offset from the window is the same whatever
    // `inner_gap` is — but only a gap of >= `border_thickness` has room to hold the
    // line without it reaching over the neighbour.
    const in_master = cidx < nmaster;

    if (nmaster == 1 and total == 2) {
        // Two panes side by side: one full-height divider on the focused pane's
        // facing edge, cut in half. The half alongside the focused pane is active —
        // TOP half when it is the master (left, cidx 0), BOTTOM when it is the
        // stack (right, cidx 1).
        const x = if (cidx == 1) f.x - t else f.x + f.width;
        const mid = uy + @divFloor(uh, 2);
        const ay0 = if (cidx == 1) mid else uy;
        const ay1 = if (cidx == 1) uy + uh else mid;
        l.vline(x, t, uy, uy + uh, ay0, ay1);
    } else if (nmaster != 1 and total == 2) {
        // Two panes stacked: one full-width divider on the focused pane's facing
        // edge, cut in half — LEFT or RIGHT half active depending on which pane is
        // focused.
        const y = if (cidx == 1) f.y - t else f.y + f.height;
        const mid = ux + @divFloor(uw, 2);
        const ax0 = if (cidx == 1) mid else ux;
        const ax1 = if (cidx == 1) ux + uw else mid;
        l.hline(y, t, ux, ux + uw, ax0, ax1);
    } else {
        // General case. The divider runs the whole usable height, just outside the
        // focused window's facing edge: past its right edge when it sits in the
        // master column, before its left edge when it sits in the stack. The stretch
        // beside the focused window is active and the rest is inactive.
        if (nmaster > 0 and total > nmaster) {
            const x = if (in_master) f.x + f.width else f.x - t;
            l.vline(x, t, uy, uy + uh, f.y, f.y + f.height);
        }
        // Horizontal seam ABOVE, only when the focused window has a neighbour above
        // in its own column. It spans exactly that column, which is the focused
        // window's own width, so the whole line is active.
        if ((cidx > 0 and cidx < nmaster) or (cidx > nmaster)) {
            l.hline(f.y - t, t, f.x, f.x + f.width, f.x, f.x + f.width);
        }
        // Horizontal seam BELOW, same reasoning.
        if ((cidx < nmaster - 1) or (cidx >= nmaster and cidx < total - 1)) {
            l.hline(f.y + f.height, t, f.x, f.x + f.width, f.x, f.x + f.width);
        }
    }

    if (l.n_active == 0 and l.n_inactive == 0) return null;
    return l;
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
