// outputconfig.zig — apply the config.monitors table via wlr-output-management.
//
// In river's non-monolithic split, the window-management protocol only *reports*
// output geometry to us; it can't set modes/positions/transforms. That belongs to
// the standard wlroots `zwlr_output_manager_v1` protocol (which river implements).
// This module is reach's equivalent of dwl's `createmon`/monrules: it learns the
// available heads + modes, then applies our desired configuration once at startup
// (and again on hotplug).
//
// Protocol flow:
//   manager.head        -> a head (output) appeared; collect its modes
//   head.mode           -> one supported mode (size + refresh)
//   manager.done(serial)-> a complete, consistent snapshot; now we may configure
//   create_configuration(serial) -> per-head enable + set mode/pos/transform/scale
//   apply -> succeeded | failed | cancelled (cancelled = serial stale, retry)

const std = @import("std");
const log = std.log.scoped(.outputcfg);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const config = @import("config.zig");
const Context = @import("context.zig");

const Mode = struct {
    rwm: *zwlr.OutputModeV1,
    width: i32 = 0,
    height: i32 = 0,
    refresh: i32 = 0, // mHz
    preferred: bool = false,
};

const Head = struct {
    rwm: *zwlr.OutputHeadV1,
    name: ?[:0]u8 = null,
    modes: std.ArrayList(*Mode) = .empty,
    finished: bool = false,
};

var manager: ?*zwlr.OutputManagerV1 = null;
var heads: std.ArrayList(*Head) = .empty;
/// (Re)apply on the next `done`. Set when a head appears (startup / hotplug);
/// cleared once we've issued an apply for the current snapshot.
var need_apply: bool = true;

/// Store the manager and start listening. Called from main once the global binds.
pub fn init(mgr: *zwlr.OutputManagerV1) void {
    manager = mgr;
    mgr.setListener(?*anyopaque, managerListener, null);
}

fn managerListener(_: *zwlr.OutputManagerV1, event: zwlr.OutputManagerV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .head => |ev| addHead(ev.head),
        .done => |ev| onDone(ev.serial),
        // Compositor is done with us; the object is destroyed by the library.
        .finished => manager = null,
    }
}

fn addHead(rwm: *zwlr.OutputHeadV1) void {
    const ctx = Context.get();
    const h = ctx.gpa.create(Head) catch return;
    h.* = .{ .rwm = rwm };
    rwm.setListener(*Head, headListener, h);
    heads.append(ctx.gpa, h) catch {};
    need_apply = true; // a new head (startup batch or hotplug) → (re)apply
}

fn headListener(_: *zwlr.OutputHeadV1, event: zwlr.OutputHeadV1.Event, self: *Head) void {
    const ctx = Context.get();
    switch (event) {
        .name => |ev| {
            if (self.name) |n| ctx.gpa.free(n);
            self.name = ctx.gpa.dupeZ(u8, std.mem.span(ev.name)) catch null;
        },
        .mode => |ev| addMode(self, ev.mode),
        // Head unplugged → mark inert; we just skip it when configuring. (We
        // bound v1, so there's no `release` request to call.)
        .finished => self.finished = true,
        else => {}, // enabled/current_mode/position/transform/scale/etc — unused
    }
}

fn addMode(h: *Head, rwm: *zwlr.OutputModeV1) void {
    const ctx = Context.get();
    const m = ctx.gpa.create(Mode) catch return;
    m.* = .{ .rwm = rwm };
    rwm.setListener(*Mode, modeListener, m);
    h.modes.append(ctx.gpa, m) catch {};
}

fn modeListener(_: *zwlr.OutputModeV1, event: zwlr.OutputModeV1.Event, self: *Mode) void {
    switch (event) {
        .size => |ev| {
            self.width = ev.width;
            self.height = ev.height;
        },
        .refresh => |ev| self.refresh = ev.refresh,
        .preferred => self.preferred = true,
        .finished => {},
    }
}

fn onDone(serial: u32) void {
    if (!need_apply) return;
    // Clear first; a failed/cancelled apply re-sets it so the next `done` retries.
    need_apply = false;
    buildAndApply(serial);
}

fn buildAndApply(serial: u32) void {
    const mgr = manager orelse return;
    const conf = mgr.createConfiguration(serial) catch |err| {
        log.err("create_configuration failed: {}", .{err});
        return;
    };
    conf.setListener(?*anyopaque, configListener, null);

    for (heads.items) |h| {
        if (h.finished) continue;
        // Enable every present head; only matched ones get explicit settings.
        const ch = conf.enableHead(h.rwm) catch continue;
        const mon = matchMonitor(h.name) orelse continue;

        if (mon.w > 0 and mon.h > 0) {
            if (pickMode(h, mon)) |m| {
                ch.setMode(m.rwm);
            } else {
                // No advertised mode at that resolution — ask for it directly.
                ch.setCustomMode(mon.w, mon.h, mon.refresh);
            }
        }
        if (!(mon.x == -1 and mon.y == -1)) ch.setPosition(mon.x, mon.y);
        if (mon.transform != .normal) ch.setTransform(toWlTransform(mon.transform));
        if (mon.scale != 1.0) ch.setScale(wl.Fixed.fromDouble(mon.scale));
    }

    conf.apply();
}

fn configListener(conf: *zwlr.OutputConfigurationV1, event: zwlr.OutputConfigurationV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .succeeded => {
            log.info("monitor configuration applied", .{});
            conf.destroy();
        },
        .failed => {
            // Bad config (e.g. an unsupported mode). Don't retry — that would spin.
            log.err("monitor configuration rejected by compositor", .{});
            conf.destroy();
        },
        .cancelled => {
            // Output state changed under us (serial stale). Retry on the next done.
            need_apply = true;
            conf.destroy();
        },
    }
}

/// The config.monitors entry whose name equals `name`, or null.
fn matchMonitor(name: ?[:0]const u8) ?*const config.Monitor {
    const n = name orelse return null;
    for (&config.monitors) |*mon| {
        if (std.mem.eql(u8, mon.name, n)) return mon;
    }
    return null;
}

/// Best mode on `h` matching the requested resolution: exact refresh if asked for,
/// else the highest refresh available at that size. Null if no size match.
fn pickMode(h: *Head, mon: *const config.Monitor) ?*Mode {
    var best: ?*Mode = null;
    for (h.modes.items) |m| {
        if (m.width != mon.w or m.height != mon.h) continue;
        if (mon.refresh > 0 and m.refresh == mon.refresh) return m;
        if (best == null or m.refresh > best.?.refresh) best = m;
    }
    return best;
}

fn toWlTransform(t: config.Transform) wl.Output.Transform {
    return switch (t) {
        .normal => .normal,
        .rotate_90 => .@"90",
        .rotate_180 => .@"180",
        .rotate_270 => .@"270",
        .flipped => .flipped,
        .flipped_90 => .flipped_90,
        .flipped_180 => .flipped_180,
        .flipped_270 => .flipped_270,
    };
}
