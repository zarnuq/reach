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

    // Last app_id river reported (owned/duped). Used for window rules.
    app_id: ?[:0]u8 = null,

    // Window rules (config.rules) are applied once, when identity first becomes
    // known. `rules_done` guards against re-applying on later app_id/title events.
    rules_done: bool = false,

    // Floating geometry as fractions of the output, set by a matching rule
    // (w == 0 means "no rule geometry; use the default centered placement").
    float_frac_x: f32 = 0,
    float_frac_y: f32 = 0,
    float_frac_w: f32 = 0,
    float_frac_h: f32 = 0,

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

    // Fullscreen state. `fullscreen` is what we want; `fs_applied` is what we've
    // already told river, so manage() only issues the request on a real change.
    // While fullscreen, river owns the window's size/position and stacks it above
    // shell surfaces (the bar) — see river_window_v1.fullscreen.
    fullscreen: bool = false,
    fs_applied: bool = false,

    // Whether the floating geometry has been established. placeFloating computes
    // position/size ONCE (default-centered, or from a rule); after that the stored
    // x/y/width/height are preserved, so keyboard move/resize stick instead of
    // being recentered every manage cycle. Reset whenever the window (re)enters
    // floating so it re-centers at the default size.
    float_placed: bool = false,

    // Float state and the inputs we derive it from.
    floating: bool = false,
    // A window rule forced this window floating (config.rules `.floating`). Sticky:
    // recomputeFloating() must keep honoring it, otherwise a later size-hint event
    // would recompute `floating` purely from min/max and re-tile a rule-floated
    // window (e.g. pavucontrol, which isn't fixed-size) a frame after it appears.
    rule_floating: bool = false,
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
        self.floating = self.rule_floating or self.has_parent or fixed;
    }

    /// MANAGE phase: set tiled edges and propose a size.
    pub fn manage(self: *Window) void {
        // Fullscreen overrides everything else. Issue the protocol request only on
        // a state change; while fullscreen, river drives the geometry, so we don't
        // set_tiled or propose_dimensions (those are ignored anyway).
        if (self.fullscreen != self.fs_applied) {
            if (self.fullscreen) {
                if (self.output) |o| {
                    self.rwm.fullscreen(o.rwm);
                    self.rwm.informFullscreen(); // tell the client app (e.g. mpv) too
                    self.fs_applied = true;
                }
            } else {
                self.rwm.exitFullscreen();
                self.rwm.informNotFullscreen();
                self.fs_applied = false;
                // Force tiled state to be re-sent now that we're back to normal.
                self.tiled_applied = null;
            }
        }
        if (self.fullscreen) return;

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

    /// Resolve a customfloat axis value (dwl semantics): 0 → `fallback` px,
    /// 0<v≤1 → fraction of `output_dim`, v>1 → absolute pixels.
    fn floatAxis(v: f32, output_dim: i32, fallback: i32) i32 {
        if (v == 0) return fallback;
        if (v <= 1) return @intFromFloat(v * @as(f32, @floatFromInt(output_dim)));
        return @intFromFloat(v);
    }

    /// A fraction of an output dimension, in pixels.
    fn fracPx(frac: f32, dim: i32) i32 {
        return @intFromFloat(frac * @as(f32, @floatFromInt(dim)));
    }

    /// Compute a floating window's position+size on its output. Size first (so the
    /// centered fallback can use it), then position. A matching rule's geometry
    /// (float_frac_*) overrides per-axis; an unset axis falls back to the window's
    /// own size hint or a fraction-of-output default, centered (dwl centerfloating).
    ///
    /// Runs ONCE per float: after the first placement `float_placed` is set, and we
    /// keep the stored geometry so the user's move/resize aren't reset each cycle.
    pub fn placeFloating(self: *Window) void {
        const out = self.output orelse return;
        if (out.width <= 0 or out.height <= 0) return; // geometry not known yet
        if (self.float_placed) return; // keep current (initial / moved / resized)

        // Default size: a fixed-size window keeps its own (max == min) size; anything
        // else gets a comfortable fraction of the output rather than a cramped fixed
        // pixel size.
        const def_w = if (self.max_width > 0) self.max_width else fracPx(config.float_default_frac_w, out.width);
        const def_h = if (self.max_height > 0) self.max_height else fracPx(config.float_default_frac_h, out.height);
        self.width = @max(1, @min(floatAxis(self.float_frac_w, out.width, def_w), out.width));
        self.height = @max(1, @min(floatAxis(self.float_frac_h, out.height, def_h), out.height));

        const cx = @divFloor(out.width - self.width, 2);
        const cy = @divFloor(out.height - self.height, 2);
        self.x = floatAxis(self.float_frac_x, out.width, cx);
        self.y = floatAxis(self.float_frac_y, out.height, cy);
        self.mapped = true;
        self.float_placed = true;
    }

    /// Match `pattern` against `value` dwl-style: "^foo" anchors a prefix, "foo"
    /// matches as a substring. Null/empty inputs never match.
    fn patternMatch(pattern: []const u8, value: ?[:0]const u8) bool {
        const v = value orelse return false;
        if (pattern.len == 0) return false;
        if (pattern[0] == '^') return std.mem.startsWith(u8, v, pattern[1..]);
        return std.mem.indexOf(u8, v, pattern) != null;
    }

    /// Apply window rules (config.rules) once, after identity (app_id/title) is
    /// known. ALL matching rules are applied in order (dwl accumulates): force
    /// floating, set tags, switch the output's view, reassign monitor, and stash
    /// a floating geometry. No-op until at least app_id or title exists.
    pub fn applyRules(self: *Window) void {
        if (self.rules_done) return;
        if (self.app_id == null and self.title == null) return;
        const ctx = Context.get();

        var matched = false;
        for (config.rules) |r| {
            // A rule with both app_id and title set requires BOTH to match.
            if (r.app_id) |p| {
                if (!patternMatch(p, self.app_id)) continue;
            }
            if (r.title) |p| {
                if (!patternMatch(p, self.title)) continue;
            }
            if (r.app_id == null and r.title == null) continue; // empty rule
            matched = true;

            if (r.monitor >= 0 and r.monitor < ctx.outputs.items.len) {
                self.output = ctx.outputs.items[@intCast(r.monitor)];
            }
            if (r.tags != 0) {
                self.tags = r.tags;
                if (r.switchtotag) {
                    if (self.output) |o| o.tagset = r.tags;
                }
            }
            if (r.floating) {
                self.floating = true;
                self.rule_floating = true; // sticky: survive later recomputeFloating()
            }
            // Stash any custom-float geometry (dwl customfloat). It applies
            // whenever the window ends up floating — by rule, transient, or
            // fixed-size. Per-axis, in placeFloating: 0 = default/centered,
            // ≤1 = fraction of the output, >1 = absolute pixels.
            if (r.x != 0) self.float_frac_x = r.x;
            if (r.y != 0) self.float_frac_y = r.y;
            if (r.w != 0) self.float_frac_w = r.w;
            if (r.h != 0) self.float_frac_h = r.h;
        }

        // Only commit (and stop re-checking) once a rule actually matched, so a
        // window that gets its app_id before its title can still match a
        // title-only rule later.
        if (matched) {
            self.rules_done = true;
            ctx.rwm.manageDirty();
        }
    }

    /// RENDER phase: place the node in global coordinates and show it.
    pub fn render(self: *Window) void {
        // Hidden when unmapped, orphaned, or on a tag the output isn't viewing.
        if (!self.visible()) {
            self.rwm.hide();
            return;
        }
        // Fullscreen: river positions/sizes the window to the output; we just keep
        // it on top of the stack and show it.
        if (self.fullscreen) {
            self.node.placeTop();
            self.rwm.show();
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

            // The app_id is the primary key for window rules. Dup it, then apply
            // rules (once) now that identity is known, and ask for a fresh cycle
            // so any float/tag/monitor change takes effect.
            .app_id => |ev| {
                if (self.app_id) |a| ctx.gpa.free(a);
                self.app_id = if (ev.app_id) |s|
                    ctx.gpa.dupeZ(u8, std.mem.span(s)) catch null
                else
                    null;
                if (ev.app_id) |id| log.info("app_id: {s}", .{id});
                self.applyRules();
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
                // A title-based rule may only become matchable now.
                self.applyRules();
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
                if (self.app_id) |a| ctx.gpa.free(a);
                self.node.destroy();
                self.rwm.destroy();
                ctx.gpa.destroy(self);
            },

            // The client asked to go fullscreen (e.g. a video player, browser F11).
            // Honor it; the manage cycle applies the actual river request. river
            // gives an output hint, but we just fullscreen on the window's output.
            .fullscreen_requested => {
                self.fullscreen = true;
                // A window can request fullscreen before arrange() ever maps it
                // (e.g. a Proton game that launches straight into fullscreen).
                // arrange() skips fullscreen windows, so it's the only mapper that
                // would never run for this window — map it here or render() hides it
                // forever (visible() requires `mapped`).
                self.mapped = true;
                ctx.rwm.manageDirty();
            },
            .exit_fullscreen_requested => {
                self.fullscreen = false;
                ctx.rwm.manageDirty();
            },

            // dimensions (actual size), decoration_hint, maximize requests,
            // pointer move/resize, … → not handled (move/resize is keyboard-driven).
            else => {},
        }
    }
};
