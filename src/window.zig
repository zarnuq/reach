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
const query = @import("query.zig");

pub const Window = struct {
    rwm: *river.WindowV1,
    node: *river.NodeV1,

    // Which output this window currently lives on (null = none yet / orphaned).
    output: ?*Output = null,

    // Last title river reported, owned/duped by us (null = never set / cleared).
    // The state socket publishes this for the top window on each output.
    title: ?[:0]u8 = null,

    // Last app_id river reported (owned/duped). Used for window rules.
    app_id: ?[:0]u8 = null,

    // Window rules (config.rules) are applied once, when identity first becomes
    // known. `rules_done` guards against re-applying on later app_id/title events.
    rules_done: bool = false,

    // Floating geometry from a matching rule, per axis: 0 = default/centered,
    // ≤1 = fraction of the output, >1 = absolute pixels (see floatAxis).
    rule_x: f32 = 0,
    rule_y: f32 = 0,
    rule_w: f32 = 0,
    rule_h: f32 = 0,

    // The virtual desktop this window lives on (1-based; see config.desktops).
    // Set from the output's current desktop when the window appears. Visible
    // when it equals the output's desktop.
    desktop: u32 = 1,

    // Output-relative content geometry, assigned by the layout (tiled) or the
    // float placement. Meaningful once `mapped` is true.
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    mapped: bool = false,

    // Content size the client actually committed, from river's `dimensions` event
    // (0 = not reported yet). A client can refuse the size we propose — one whose
    // min_width is wider than its tile commits the min anyway and spills over its
    // neighbour — so this can disagree with width/height above. See drawnWidth.
    actual_width: i32 = 0,
    actual_height: i32 = 0,

    // Fullscreen state. `fullscreen` is what we want; `fs_applied` is what we've
    // already told river, so manage() only issues the request on a real change.
    // While fullscreen, river owns the window's size/position and stacks it above
    // shell surfaces (a panel) — see river_window_v1.fullscreen.
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

    /// Wrap a new river window, assign it to an output, make it the new master
    /// (head of the stack) and the focus.
    pub fn create(rwm: *river.WindowV1) !void {
        const ctx = Context.get();
        const self = try ctx.gpa.create(Window);

        // Each window owns one scene node; grab it once here. The window event
        // that brings us here fires inside a manage sequence, so this is fine.
        const node = rwm.getNode() catch |err| {
            rwm.destroy();
            ctx.gpa.destroy(self);
            return err;
        };
        self.* = .{ .rwm = rwm, .node = node };
        errdefer self.destroy();
        rwm.setListener(*Window, listener, self);

        // Place the window on the selected monitor (dwl spawns on `selmon`), so
        // apps launched by a keybind appear where the keyboard focus is — not on
        // whatever output happens to be first (DP-1). Null only while there are no
        // outputs; Output.create re-homes the window when one appears.
        const out = ctx.current_output;
        self.output = out;

        // New windows land on the desktop the output is currently viewing
        // (dwl behavior), so they appear on the active workspace.
        if (out) |o| self.desktop = o.desktop;

        // Insert at the head so a new window becomes master (dwm-like).
        try ctx.windows.insert(ctx.gpa, 0, self);
        // The new window is focused, so its monitor becomes the selected one
        // (keeps the desktop keys on the window you just opened).
        ctx.focus(self);
        log.info("window created (total {d})", .{ctx.windows.items.len});
    }

    /// Release the strings, proxies and memory. The caller has already untracked it.
    fn destroy(self: *Window) void {
        const gpa = Context.get().gpa;
        if (self.title) |t| gpa.free(t);
        if (self.app_id) |a| gpa.free(a);
        self.node.destroy();
        self.rwm.destroy();
        gpa.destroy(self);
    }

    /// Whether this window should be shown right now: mapped, homed to an output,
    /// and on that output's currently-viewed desktop.
    pub fn visible(self: *Window) bool {
        const o = self.output orelse return false;
        return self.mapped and self.desktop == o.desktop;
    }

    /// The width the window really covers: its tile, or more if the client
    /// committed something wider. Never less — a client that stops short of its
    /// tile (a terminal snapping to its cell grid) still owns the whole tile.
    pub fn drawnWidth(self: *const Window) i32 {
        return @max(self.width, self.actual_width);
    }

    /// Height counterpart of drawnWidth.
    pub fn drawnHeight(self: *const Window) i32 {
        return @max(self.height, self.actual_height);
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
        if (self.tiled_applied != want_tiled) {
            const t = want_tiled;
            self.rwm.setTiled(.{ .top = t, .bottom = t, .left = t, .right = t });
            self.tiled_applied = want_tiled;
        }

        // No geometry yet (no output, or never laid out) → propose 0,0, which
        // lets the client pick its own size until we can place it.
        const placed = self.mapped and self.output != null;
        self.rwm.proposeDimensions(if (placed) self.width else 0, if (placed) self.height else 0);
    }

    /// Resolve a customfloat axis value (dwl semantics): 0 → `fallback` px,
    /// 0<v≤1 → fraction of `output_dim`, v>1 → absolute pixels.
    fn floatAxis(v: f32, output_dim: i32, fallback: i32) i32 {
        if (v == 0) return fallback;
        if (v <= 1) return fracPx(v, output_dim);
        return @intFromFloat(v);
    }

    /// A fraction of an output dimension, in pixels.
    fn fracPx(frac: f32, dim: i32) i32 {
        return @intFromFloat(frac * @as(f32, @floatFromInt(dim)));
    }

    /// Compute a floating window's position+size on its output. Size first (so the
    /// centered fallback can use it), then position. A matching rule's geometry
    /// (rule_*) overrides per-axis; an unset axis falls back to the window's
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
        self.width = @max(1, @min(floatAxis(self.rule_w, out.width, def_w), out.width));
        self.height = @max(1, @min(floatAxis(self.rule_h, out.height, def_h), out.height));

        const cx = @divFloor(out.width - self.width, 2);
        const cy = @divFloor(out.height - self.height, 2);
        self.x = floatAxis(self.rule_x, out.width, cx);
        self.y = floatAxis(self.rule_y, out.height, cy);
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
    /// floating, set the desktop, switch the output's view, reassign monitor, stash
    /// a floating geometry. No-op until at least app_id or title exists.
    fn applyRules(self: *Window) void {
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
            // 0 = "no desktop in this rule"; anything past the configured count
            // is ignored rather than sending the window somewhere unreachable.
            if (config.validDesktop(r.desktop)) {
                self.desktop = r.desktop;
                if (r.switchto) {
                    if (self.output) |o| o.desktop = r.desktop;
                }
            }
            if (r.floating) self.rule_floating = true; // sticky: survive later recomputeFloating()
            // Stash any custom-float geometry (dwl customfloat). It applies
            // whenever the window ends up floating — by rule, transient, or
            // fixed-size. Per-axis, in placeFloating: 0 = default/centered,
            // ≤1 = fraction of the output, >1 = absolute pixels.
            if (r.x != 0) self.rule_x = r.x;
            if (r.y != 0) self.rule_y = r.y;
            if (r.w != 0) self.rule_w = r.w;
            if (r.h != 0) self.rule_h = r.h;
        }

        if (self.rule_floating) self.recomputeFloating();

        // Only commit (and stop re-checking) once a rule actually matched, so a
        // window that gets its app_id before its title can still match a
        // title-only rule later.
        if (matched) {
            self.rules_done = true;
            ctx.rwm.manageDirty();
        }
    }

    /// RENDER phase: place the node in global coordinates and show it.
    ///
    /// Z-order is NOT decided here — stack.apply() runs after every window has been
    /// through this and orders the whole scene at once. Raising a window from here
    /// is what made layering depend on the order unrelated files ran in.
    pub fn render(self: *Window) void {
        // Hidden when unmapped, orphaned, or on a desktop the output isn't viewing.
        if (!self.visible()) {
            self.rwm.hide();
            return;
        }
        // Fullscreen: river positions/sizes the window to the output, so there is
        // no geometry for us to set — just show it.
        if (!self.fullscreen) {
            const out = self.output.?;
            self.node.setPosition(out.x + self.x, out.y + self.y);
        }
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

            // The size the client actually committed (sent before render_start, so
            // border.update() sees it in the same render cycle).
            .dimensions => |ev| {
                self.actual_width = ev.width;
                self.actual_height = ev.height;
            },

            // A parent makes this a transient (dialog/menu) → float.
            .parent => |ev| {
                self.has_parent = ev.parent != null;
                self.recomputeFloating();
            },

            // The app_id is the primary key for window rules. Dup it, then apply
            // rules (once) now that identity is known, and ask for a fresh cycle
            // so any float/desktop/monitor change takes effect.
            .app_id => |ev| {
                replaceStr(&self.app_id, ev.app_id);
                if (ev.app_id) |id| log.info("app_id: {s}", .{id});
                self.applyRules();
            },

            // The window's title changed. Dup it for the state socket, and ask
            // river for a fresh cycle so it gets published (a title change alone
            // wouldn't otherwise trigger one).
            .title => |ev| {
                replaceStr(&self.title, ev.title);
                // A title-based rule may only become matchable now.
                self.applyRules();
                ctx.rwm.manageDirty();
            },

            // The window is gone. Unlink, fix up focus, and release proxies.
            .closed => {
                if (std.mem.indexOfScalar(*Window, ctx.windows.items, self)) |i| _ = ctx.windows.orderedRemove(i);
                if (ctx.focused == self) {
                    // The next visible window ON THIS OUTPUT, or nothing — never
                    // another monitor (same policy as `action.refocus`). No output
                    // (closed before river placed it) means nothing to stay on.
                    ctx.focused = if (self.output) |o| query.topVisibleOn(o) else null;
                    ctx.rwm.manageDirty();
                }
                self.destroy();
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

            // decoration_hint, maximize requests,
            // pointer move/resize, … → not handled (move/resize is keyboard-driven).
            else => {},
        }
    }
};

/// Replace an owned string with a dup of `s` (null clears it; so does OOM).
pub fn replaceStr(slot: *?[:0]u8, s: ?[*:0]const u8) void {
    const gpa = Context.get().gpa;
    if (slot.*) |old| gpa.free(old);
    slot.* = if (s) |p| gpa.dupeZ(u8, std.mem.span(p)) catch null else null;
}
