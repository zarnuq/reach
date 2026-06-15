// window.zig — a managed window.
//
// Wraps a river_window_v1 plus its river_node_v1 (the scene-graph node we
// position). Carries the geometry the layout assigns and the float state we
// derive from river's hints.
//
// The two-phase dance with river (see wm.zig) shows up here as two methods:
//   manage() — runs in the MANAGE sequence: tell river the window's tiled state
//              and propose its size.
//   render() — runs in the RENDER sequence: position the node and show/hide it.

const std = @import("std");
const log = std.log.scoped(.window);

const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const Context = @import("context.zig");
const Output = @import("output.zig").Output;

pub const Window = struct {
    rwm: *river.WindowV1,
    node: *river.NodeV1,

    // Which output this window currently lives on (null = none yet / orphaned).
    output: ?*Output = null,

    // Last title river reported, owned/duped by us (null = never set / cleared).
    // The bar shows this for the focused window on each output.
    title: ?[:0]u8 = null,

    // Tags (workspace bitmask) this window belongs to. Set from the output's
    // current tagset when the window appears. Visible when it intersects the
    // output's tagset.
    tags: u32 = 1,

    // Output-relative content geometry, assigned by the layout (tiled) or the
    // float placement. Meaningful once `mapped` is true.
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    mapped: bool = false,

    // Float state and the inputs we derive it from.
    floating: bool = false,
    has_parent: bool = false,
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,

    // Last tiled-edges state we sent, so manage() can avoid redundant set_tiled
    // calls. null = never sent.
    tiled_applied: ?bool = null,

    pub fn create(rwm: *river.WindowV1) !*Window {
        const ctx = Context.get();
        const self = try ctx.gpa.create(Window);
        errdefer ctx.gpa.destroy(self);

        // Each window owns one scene node; grab it once here. The window event
        // that brings us here fires inside a manage sequence, so this is fine.
        const node = try rwm.getNode();

        self.* = .{ .rwm = rwm, .node = node };
        rwm.setListener(*Window, listener, self);
        return self;
    }

    /// Whether this window should be shown right now: mapped, homed to an output,
    /// and on one of that output's currently-viewed tags.
    pub fn visible(self: *Window) bool {
        const o = self.output orelse return false;
        return self.mapped and (self.tags & o.tagset) != 0;
    }

    /// Recompute float state from the current hints. A window floats if it is a
    /// transient (has a parent — dialogs/menus) or is fixed-size (min == max).
    fn recomputeFloating(self: *Window) void {
        const fixed = self.min_width > 0 and self.min_width == self.max_width and
            self.min_height > 0 and self.min_height == self.max_height;
        self.floating = self.has_parent or fixed;
    }

    /// MANAGE phase: set tiled edges and propose a size.
    pub fn manage(self: *Window) void {
        // Tell river whether this window is tiled (snapped on all edges, no client
        // shadows) or floating. Only send when it changes.
        const want_tiled = !self.floating;
        if (self.tiled_applied == null or self.tiled_applied.? != want_tiled) {
            if (want_tiled) {
                self.rwm.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
            } else {
                self.rwm.setTiled(.{});
            }
            self.tiled_applied = want_tiled;
        }

        // No geometry yet (no output, or never laid out) → propose 0,0, which
        // lets the client pick its own size until we can place it.
        if (!self.mapped or self.output == null) {
            self.rwm.proposeDimensions(0, 0);
            return;
        }
        self.rwm.proposeDimensions(self.width, self.height);
    }

    /// Compute a centered position+size for a floating window on its output.
    pub fn placeFloating(self: *Window) void {
        const out = self.output orelse return;
        // Prefer the window's own max size; otherwise a sensible default.
        const w = if (self.max_width > 0) self.max_width else config.float_default_width;
        const h = if (self.max_height > 0) self.max_height else config.float_default_height;
        self.width = @max(1, @min(w, out.width));
        self.height = @max(1, @min(h, out.height));
        self.x = @divFloor(out.width - self.width, 2);
        self.y = @divFloor(out.height - self.height, 2);
        self.mapped = true;
    }

    /// RENDER phase: place the node in global coordinates and show it.
    pub fn render(self: *Window) void {
        // Hidden when unmapped, orphaned, or on a tag the output isn't viewing.
        if (!self.visible()) {
            self.rwm.hide();
            return;
        }
        const out = self.output.?;
        self.node.setPosition(out.x + self.x, out.y + self.y);
        // Keep floats stacked above the tiled windows.
        if (self.floating) self.node.placeTop();
        self.rwm.show();
    }

    fn listener(_: *river.WindowV1, event: river.WindowV1.Event, self: *Window) void {
        const ctx = Context.get();
        switch (event) {
            // Preferred min/max size. Drives fixed-size float detection.
            .dimensions_hint => |ev| {
                self.min_width = ev.min_width;
                self.min_height = ev.min_height;
                self.max_width = ev.max_width;
                self.max_height = ev.max_height;
                self.recomputeFloating();
            },

            // A parent makes this a transient (dialog/menu) → float.
            .parent => |ev| {
                self.has_parent = ev.parent != null;
                self.recomputeFloating();
            },

            // Useful for logs/rules; M2 just logs.
            .app_id => |ev| {
                if (ev.app_id) |id| log.info("app_id: {s}", .{id});
            },

            // The window's title changed. Dup it for the bar, and ask river for a
            // fresh cycle so the bar redraws (a title change alone wouldn't
            // otherwise trigger one).
            .title => |ev| {
                if (self.title) |t| ctx.gpa.free(t);
                self.title = if (ev.title) |s|
                    ctx.gpa.dupeZ(u8, std.mem.span(s)) catch null
                else
                    null;
                ctx.rwm.manageDirty();
            },

            // The window is gone. Unlink, fix up focus, and release proxies.
            .closed => {
                const closing_output = self.output;
                for (ctx.windows.items, 0..) |w, i| {
                    if (w == self) {
                        _ = ctx.windows.orderedRemove(i);
                        break;
                    }
                }
                if (ctx.focused == self) {
                    // Prefer a visible window on the same output, then any visible window.
                    ctx.focused = blk: {
                        for (ctx.windows.items) |w| {
                            if (w.output == closing_output and w.visible()) break :blk w;
                        }
                        for (ctx.windows.items) |w| {
                            if (w.visible()) break :blk w;
                        }
                        break :blk if (ctx.windows.items.len > 0) ctx.windows.items[0] else null;
                    };
                    ctx.rwm.manageDirty();
                }
                if (self.title) |t| ctx.gpa.free(t);
                self.node.destroy();
                self.rwm.destroy();
                ctx.gpa.destroy(self);
            },

            // title, dimensions (actual size), decoration_hint, fullscreen/maximize
            // requests, pointer move/resize, … → later milestones.
            else => {},
        }
    }
};
