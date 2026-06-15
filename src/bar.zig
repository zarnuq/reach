// bar.zig — the baked-in status bar (one per output).
//
// Layout, left → right:
//   [layout symbol]  [ focused window title .......... ]  [ status text ]
//
// THE FOCUS BEHAVIOR the user asked about (dwlb's per-monitor highlight): the
// bar on the *focused* output draws its title region in the `select` scheme
// (mauve), every other output uses `normal` (dark). dwlb gets the "this monitor
// is active" signal from dwl's IPC `active` event; Confluence is the WM, so it
// just compares each output against the focused one (`currentOutput`).
//
// Rendering is software: pixman fills the background rectangles and composites
// fcft-rasterized glyphs into a wl_shm buffer (see render/). Each bar owns a
// river shell-surface + node so the compositor places it in the scene; the
// layout (layout.zig) reserves `height()` pixels at the top so windows never sit
// under it.
//
// Status text is the dwlb/dwm-blocks format and may contain `^fg(RRGGBB)` color
// escapes, parsed here so the user's existing someblocks scripts work unchanged.

const std = @import("std");
const log = std.log.scoped(.bar);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const pixman = @import("pixman");
const fcft = @import("fcft");

const config = @import("config.zig");
const Context = @import("context.zig");
const status = @import("status.zig");
const Output = @import("output.zig").Output;
const Window = @import("window.zig").Window;

const Font = @import("render/font.zig");
const Buffer = @import("render/buffer.zig");
const utils = @import("render/utils.zig");

// Process-wide font, loaded once in main via `initFont`. Shared by every bar.
pub var font: Font = undefined;
// Whether the bar subsystem is usable (font loaded + wl_shm present).
pub var enabled: bool = false;

/// Load the font and enable the bar. Call once at startup, after `Font.initLibrary`.
pub fn initFont(gpa: std.mem.Allocator) void {
    if (Context.get().wl_shm == null) {
        log.warn("no wl_shm — bar disabled", .{});
        return;
    }
    font.init(gpa, config.bar.font) catch |err| {
        log.err("load bar font failed: {} — bar disabled", .{err});
        return;
    };
    enabled = true;
}

/// Bar height in pixels (what the layout reserves). 0 when the bar is disabled.
pub fn height() i32 {
    return if (enabled) font.height() else 0;
}

pub const Bar = struct {
    output: *Output,
    wl_surface: *wl.Surface,
    shell: *river.ShellSurfaceV1,
    node: *river.NodeV1,
    buffers: [2]Buffer = .{ .{}, .{} },

    pub fn create(output: *Output) !*Bar {
        const ctx = Context.get();
        const wl_surface = try ctx.wl_compositor.?.createSurface();
        errdefer wl_surface.destroy();
        const shell = try ctx.rwm.getShellSurface(wl_surface);
        errdefer shell.destroy();
        const node = try shell.getNode();

        const self = try ctx.gpa.create(Bar);
        self.* = .{ .output = output, .wl_surface = wl_surface, .shell = shell, .node = node };
        return self;
    }

    pub fn destroy(self: *Bar) void {
        const ctx = Context.get();
        self.buffers[0].deinit();
        self.buffers[1].deinit();
        self.node.destroy();
        self.shell.destroy();
        self.wl_surface.destroy();
        ctx.gpa.destroy(self);
    }

    /// Pick a buffer the compositor isn't currently reading, mark it in use.
    fn nextBuffer(self: *Bar) ?*Buffer {
        for (&self.buffers) |*b| {
            if (!b.busy) {
                b.occupy();
                return b;
            }
        }
        return null;
    }

    /// Draw and commit the bar. Called from the render cycle (after windows).
    pub fn render(self: *Bar) void {
        if (!enabled) return;
        const ctx = Context.get();
        const gpa = ctx.gpa;
        const out = self.output;

        const w = out.width;
        const h = font.height();
        if (w <= 0 or h <= 0) return;

        const buffer = self.nextBuffer() orelse return; // both busy this frame
        buffer.init(w, h) catch |err| {
            log.err("bar buffer init failed: {}", .{err});
            return;
        };

        const normal_fg = utils.color(config.bar.normal_fg);
        const normal_bg = utils.color(config.bar.normal_bg);
        const select_fg = utils.color(config.bar.select_fg);
        const select_bg = utils.color(config.bar.select_bg);
        const status_bg = utils.color(config.bar.status_bg);

        const is_current = currentOutput() == out;
        const pad: i32 = @max(2, @divFloor(h, 2));

        // Background.
        fillRect(buffer, 0, 0, w, h, &normal_bg);

        // 1. Tag area (workspaces) on the far left.
        var x: i32 = renderTags(buffer, out, h, pad);

        // 2. Layout symbol (always normal scheme).
        x += @divFloor(pad, 2);
        x += font.renderStr(gpa, buffer, config.bar.layout_symbol, &normal_fg, x, 0);
        x += pad;

        // 3. Title region — fills the rest; status (drawn next) overwrites its
        //    right edge. The focused output gets the `select` highlight here.
        const title_start = x;
        const title_fg = if (is_current) &select_fg else &normal_fg;
        const title_bg = if (is_current) &select_bg else &normal_bg;
        fillRect(buffer, title_start, 0, w - title_start, h, title_bg);
        if (topWindowOn(out)) |win| {
            if (win.title) |t| {
                _ = font.renderStr(gpa, buffer, t, title_fg, title_start + @divFloor(pad, 2), 0);
            }
        }

        // 4. Status text, right-aligned, with `^fg(...)` color parsing.
        renderStatus(buffer, title_start, w, pad, &status_bg);

        // Commit. syncNextCommit aligns this with river's render sequence.
        self.wl_surface.attach(buffer.wl_buffer, 0, 0);
        self.wl_surface.damageBuffer(0, 0, w, h);
        self.shell.syncNextCommit();
        self.wl_surface.commit();

        const y = out.y + if (config.bar.top) 0 else out.height - h;
        self.node.setPosition(out.x, y);
        self.node.placeTop();
    }

};

/// Parse and draw the someblocks status text into the right end of the bar.
/// `min_x` is the title start (status never overlaps the title's left edge).
fn renderStatus(buffer: *Buffer, min_x: i32, w: i32, pad: i32, bg: *const pixman.Color) void {
    const ctx = Context.get();
        const gpa = ctx.gpa;
        const text = status.text();
        if (text.len == 0) return;

        const default_fg = config.bar.status_fg;

        // Cleaned text (escapes stripped) + the color runs over it.
        var cleaned: std.ArrayList(u8) = .empty;
        defer cleaned.deinit(gpa);
        const Seg = struct { color: u32, start: usize, len: usize };
        var segs: std.ArrayList(Seg) = .empty;
        defer segs.deinit(gpa);

        var cur_color = default_fg;
        var seg_start: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '^') {
                // `^^` → a literal caret.
                if (i + 1 < text.len and text[i + 1] == '^') {
                    cleaned.append(gpa, '^') catch return;
                    i += 2;
                    continue;
                }
                // `^name(arg)` command. Close the current run at this boundary.
                if (cleaned.items.len > seg_start) {
                    segs.append(gpa, .{ .color = cur_color, .start = seg_start, .len = cleaned.items.len - seg_start }) catch return;
                }
                const name_start = i + 1;
                const open = std.mem.indexOfScalarPos(u8, text, name_start, '(') orelse break;
                const close = std.mem.indexOfScalarPos(u8, text, open + 1, ')') orelse break;
                const name = text[name_start..open];
                const arg = text[open + 1 .. close];
                if (std.mem.eql(u8, name, "fg")) {
                    cur_color = parseColor(arg) orelse default_fg;
                }
                // ^bg(...), ^lm(...), ^mm, ^rm, … : not handled yet, just skipped.
                seg_start = cleaned.items.len;
                i = close + 1;
            } else {
                cleaned.append(gpa, text[i]) catch return;
                i += 1;
            }
        }
        if (cleaned.items.len > seg_start) {
            segs.append(gpa, .{ .color = cur_color, .start = seg_start, .len = cleaned.items.len - seg_start }) catch return;
        }
        if (segs.items.len == 0) return;

        // Rasterize each run and measure the total width.
        const Run = struct { color: pixman.Color, run: *const fcft.TextRun };
        var runs: std.ArrayList(Run) = .empty;
        defer {
            for (runs.items) |r| r.run.destroy();
            runs.deinit(gpa);
        }
        var total: i32 = 0;
        for (segs.items) |s| {
            const slice = cleaned.items[s.start .. s.start + s.len];
            const run = font.rasterize(gpa, slice) orelse continue;
            total += @intCast(utils.textWidth(run));
            runs.append(gpa, .{ .color = utils.color((s.color << 8) | 0xff), .run = run }) catch {
                run.destroy();
                continue;
            };
        }
        if (runs.items.len == 0) return;

        // Right-align, but never left of the title start.
        var x = @max(min_x, w - total - pad);
        fillRect(buffer, x, 0, w - x, font.height(), bg);
        x += @divFloor(pad, 2);
        for (runs.items) |r| {
            x += font.renderRun(buffer, r.run, &r.color, x, 0);
        }
}

/// Draw the tag (workspace) cells on the left of `out`'s bar and return the x
/// where the next region (layout symbol) should start. dwlb's `hide_vacant`
/// behavior: a tag is shown only if it's currently viewed or has a window. The
/// viewed tag(s) use the `select` scheme; occupied tags get a small corner box.
fn renderTags(buffer: *Buffer, out: *Output, h: i32, pad: i32) i32 {
    const ctx = Context.get();
    const gpa = ctx.gpa;

    const normal_fg = utils.color(config.bar.normal_fg);
    const normal_bg = utils.color(config.bar.normal_bg);
    const select_fg = utils.color(config.bar.select_fg);
    const select_bg = utils.color(config.bar.select_bg);

    // Which tags hold at least one (mapped) window on this output.
    var occupied: u32 = 0;
    for (ctx.windows.items) |w| {
        if (w.output == out and w.mapped) occupied |= w.tags;
    }

    var x: i32 = 0;
    for (0..config.tags.count) |i| {
        const bit = @as(u32, 1) << @intCast(i);
        const active = (out.tagset & bit) != 0;
        const occ = (occupied & bit) != 0;
        if (!active and !occ) continue; // hide vacant tags

        const name = config.tags.names[i];
        const fg = if (active) &select_fg else &normal_fg;
        const bg = if (active) &select_bg else &normal_bg;

        const cell_w = font.strWidth(gpa, name) + pad;
        fillRect(buffer, x, 0, cell_w, h, bg);

        // Occupied indicator: a small filled box in the top-left corner.
        if (occ) {
            const box = @max(2, @divFloor(h, 6));
            fillRect(buffer, x + 2, 2, box, box, fg);
        }

        _ = font.renderStr(gpa, buffer, name, fg, x + @divFloor(pad, 2), 0);
        x += cell_w;
    }
    return x;
}

/// Parse a hex color from a `^fg(...)` argument: "RRGGBB" or "RRGGBBAA". Returns
/// the value as 0xRRGGBB (alpha applied by the caller) or null on a bad string.
fn parseColor(arg: []const u8) ?u32 {
    if (arg.len == 0) return null;
    const v = std.fmt.parseInt(u32, arg, 16) catch return null;
    return switch (arg.len) {
        8 => v >> 8, // RRGGBBAA → drop alpha; caller re-adds opaque alpha
        6 => v, // RRGGBB
        else => v,
    };
}

/// Fill a rectangle (output-local) with a solid color.
fn fillRect(buffer: *Buffer, x: i32, y: i32, w: i32, h: i32, c: *const pixman.Color) void {
    if (w <= 0 or h <= 0) return;
    const rects = [_]pixman.Rectangle16{.{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(w),
        .height = @intCast(h),
    }};
    _ = pixman.Image.fillRectangles(.src, buffer.image, c, 1, &rects);
}

/// The selected output (whose bar gets the highlight). This is the same value the
/// tag/layout keybindings act on (see binding.focusedOutput), so the highlighted
/// monitor is always the one the keyboard drives. Falls back to the focused
/// window's output, then the sole output, before any selection has happened.
fn currentOutput() ?*Output {
    const ctx = Context.get();
    if (ctx.current_output) |o| return o;
    if (ctx.focused) |f| return f.output;
    if (ctx.outputs.items.len == 1) return ctx.outputs.items[0];
    return null;
}

/// The window whose title the bar shows for `out`: the most-recently-focused
/// window that's actually visible there (windows are kept in focus/stack order).
fn topWindowOn(out: *Output) ?*Window {
    const ctx = Context.get();
    for (ctx.windows.items) |w| {
        if (w.output == out and w.visible()) return w;
    }
    return null;
}
