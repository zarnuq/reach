// reload.zig — re-read config.zon and rebuild everything it drives, without
// restarting the session.
//
// WHY THIS IS ITS OWN FILE: reloading is almost entirely a question of ORDERING.
// The individual "restart yourself" hooks are small and live with their
// subsystems (binding.teardown, shake.stop, outputconfig.reapply); what is easy
// to get wrong is the sequence they run in,
// and that sequence is what this file is.
//
// Two invariants drive the whole design:
//
//   1. NOTHING RUNS INLINE. A reload is *requested* (by a keybind or SIGHUP) and
//      applied later, from the manage cycle. A keybind handler that reloaded
//      inline would call binding.teardown() — freeing the very Binding whose
//      `pressed` listener is still on the stack. The request/apply split is the
//      same trick the chord submaps already use, for the same reason.
//
//   2. THE OLD ARENA OUTLIVES ITS READERS. Config slices are not copied: rules,
//      monitor lists and `Action.spawn` strings all point directly into
//      the parsed ZON AST (see confparse.zig). So the outgoing generation can
//      only be freed once every one of those readers has been rebuilt against
//      the new one. That is why teardown comes before commit, and release comes
//      after re-registration.
//
// A config that does not parse is not applied at all: `stage` fails, we log, and
// the session keeps running on the config it already had. That is the property
// that makes editing config.zon on a live session safe — a typo costs you a log
// line, not your keybindings.

const std = @import("std");
const log = std.log.scoped(.reload);

const config = @import("config.zig");
const confparse = @import("confparse.zig");
const Context = @import("context.zig");
const binding = @import("binding.zig");
const gamma = @import("gamma.zig");
const outputconfig = @import("outputconfig.zig");
const inputconfig = @import("inputconfig.zig");
const output = @import("output.zig");
const shake = @import("shake.zig");
const seat = @import("seat.zig");

/// A reload has been asked for and will be applied by the next manage cycle.
var pending: bool = false;

/// Ask for a reload. Safe to call from anywhere — a binding listener, the poll
/// loop — precisely because it does no work.
pub fn request() void {
    pending = true;
}

/// Apply a pending reload. MUST be called from a manage sequence, and before
/// `binding.enablePending()` so freshly registered bindings go live in the same
/// cycle. No-op when nothing was requested.
pub fn apply() void {
    if (!pending) return;
    pending = false;

    const ctx = Context.get();
    const gpa = ctx.gpa;

    // Parse FIRST, while the current config is still fully live. A bad file stops
    // here, having changed nothing.
    const staged = confparse.stage(gpa) orelse return;

    // What the old generation says, captured before it is displaced — these decide
    // which subsystems actually need rebuilding below. They BORROW the outgoing
    // arena, so every comparison against them has to happen before `release`.
    const old_cursor = cursorSettings();
    const old_monitors = config.monitors;
    const old_temperature = config.gamma.temperature;
    const old_mfact = config.mfact;
    const old_nmaster = config.nmaster;
    const old_repeat_rate = config.repeat_rate;
    const old_repeat_delay = config.repeat_delay;

    // Tear the bindings down while their `spawn` strings are still valid memory,
    // then swap the config in.
    binding.teardown();
    const previous = confparse.commit(staged);
    binding.reregister();

    // Diff the two generations while BOTH are still alive. Doing this after the
    // release below would be reading freed memory.
    const cursor_changed = !cursorEql(old_cursor, cursorSettings());
    const monitors_changed = !monitorsEql(old_monitors, config.monitors);

    // Nothing points into the outgoing generation any more.
    confparse.release(gpa, previous);

    // Cursor/shake: re-open pointer devices only if something it depends on moved.
    if (cursor_changed) {
        shake.stop();
        seat.cursor_dirty = true;
        shake.start();
    }

    // Monitors: cheap to skip, and re-applying a mode set is a visible flicker.
    if (monitors_changed) outputconfig.reapply();

    // Repeat info is only sent when a device appears, so existing keyboards keep
    // the old rate/delay unless it is pushed to them here.
    if (config.repeat_rate != old_repeat_rate or config.repeat_delay != old_repeat_delay) inputconfig.reapply();

    // Temperature is config-only, so a reload is the ONLY way it moves — this is
    // the night-light switch. Brightness is left alone on purpose: it is runtime
    // state owned by the keybinds, and a reload that reset it would undo every
    // adjustment made since the session started.
    if (config.gamma.temperature != old_temperature) gamma.reapply();

    // mfact/nmaster are per-output runtime state seeded from the config, and the
    // setmfact/incnmaster keybinds move them from there. Push a new default onto
    // every output only when the file actually changed it, so a reload for some
    // unrelated edit doesn't throw away the layout you have adjusted by hand.
    const mfact_changed = config.mfact != old_mfact;
    const nmaster_changed = config.nmaster != old_nmaster;
    for (ctx.outputs.items) |o| {
        if (mfact_changed) o.mfact = output.clampMfact(config.mfact);
        if (nmaster_changed) o.nmaster = output.clampNmaster(config.nmaster);
    }

    // `env` and `autostart` are deliberately one-shot: the variables were exported
    // into a process tree that already exists, and the programs have already run.
    // Re-doing either would not reach existing children and would duplicate the
    // latter, so say so rather than pretending the new values took effect.
    if (config.env.len != 0 or config.autostart.len != 0) {
        log.info("reload: `env` and `autostart` are startup-only and were not re-applied", .{});
    }

    // Colors, gaps, border thickness and the window rules need no
    // action at all: every one of them is read fresh by the manage/render cycle
    // this reload is running inside.
    log.info("config reloaded", .{});
}

/// The cursor settings shake.start() reads, as one comparable value.
const CursorSettings = struct { theme: [:0]const u8, size: u32, enabled: bool };

fn cursorSettings() CursorSettings {
    return .{
        .theme = config.cursor.theme,
        .size = config.cursor.size,
        .enabled = config.cursor.shake.enabled,
    };
}

/// Compare by VALUE. std.meta.eql would compare `theme` as a slice — pointer and
/// length — and the two generations never share an address, so identical themes
/// would read as changed and needlessly re-open every pointer device.
fn cursorEql(a: CursorSettings, b: CursorSettings) bool {
    return a.size == b.size and a.enabled == b.enabled and std.mem.eql(u8, a.theme, b.theme);
}

/// Same reasoning as cursorEql: `Monitor.name` is a slice, so compare it by
/// content, then alias it so std.meta.eql handles the value-only rest.
fn monitorsEql(a: []const config.Monitor, b: []const config.Monitor) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        var y2 = y;
        y2.name = x.name;
        if (!std.meta.eql(x, y2)) return false;
    }
    return true;
}

test "monitorsEql compares names by content and every other field" {
    var buf = "DP-1".*;
    const a = [_]config.Monitor{.{ .name = "DP-1", .w = 1920, .h = 1080 }};
    var b = [_]config.Monitor{.{ .name = &buf, .w = 1920, .h = 1080 }};
    try std.testing.expect(monitorsEql(&a, &b));
    b[0].scale = 2.0;
    try std.testing.expect(!monitorsEql(&a, &b));
}
