// binding.zig — xkb keybindings: turning key presses into actions.
//
// Strictly the KEY half. What an action then does lives in action.zig; this file
// only decides which action a given key means and hands it over. The two were one
// 828-line file, which made every window-manager operation reachable only through
// the keybinding machinery — see action.zig's header for why that mattered.
//
// river hands keybindings to the WM via river_xkb_bindings_v1: we create a
// binding for (seat, keysym, modifiers), `enable()` it during a manage sequence,
// and then receive a `pressed` event when it fires. Per the protocol, a `pressed`
// event is always followed by a manage_start, so an action mutating state is
// enough — the layout/render re-runs automatically (no manageDirty needed).
//
// The full dwl keybind set is wired up in registerForSeat (mirroring the user's
// config.h). The desktop binds are:
//   MOD+1..9            view desktop n
//   MOD+Shift+1..9      send the focused window to desktop n
// where MOD is Super (mod4); the rest (spawn, focus, layout, chords, media, …)
// follow in the same function.
//
// There is deliberately no toggle-view / toggle-desktop pair and no "all
// desktops" bind: an output views exactly one desktop and a window lives on
// exactly one, so those states do not exist to be toggled into.
//
// Chords (dwl's SPAWN2, generalised) are the one genuinely keyboard-shaped thing
// here beyond registration: a leader key arms a submap whose sub-bindings are
// enabled only while it is active, nesting to any depth.

const std = @import("std");
const log = std.log.scoped(.binding);

const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const confparse = @import("confparse.zig");
const Context = @import("context.zig");
const Seat = @import("seat.zig").Seat;
const action = @import("action.zig");

/// Resolve an xkb keysym NAME ("Return", "q", "XF86AudioPlay", "1") to its keysym
/// code, for binds loaded from config.zon. Case-sensitive (XKB_KEYSYM_NO_FLAGS),
/// matching xkbcommon's own naming: "Return" not "return", lowercase "q" for the Q
/// key (Shift binds register the BASE keysym + MOD_SHIFT — see the no_translate
/// note in registerForSeat). Returns null for an unknown name.
extern fn xkb_keysym_from_name(name: [*:0]const u8, flags: u32) u32;
fn resolveKeysym(name: []const u8) ?u32 {
    var buf: [64]u8 = undefined;
    if (name.len == 0 or name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ks = xkb_keysym_from_name(buf[0..name.len :0].ptr, 0);
    return if (ks == 0) null else ks; // 0 == XKB_KEY_NoSymbol
}

/// MOD is Super/logo (mod4), matching dwl's `#define MOD WLR_MODIFIER_LOGO`.
const Mods = river.SeatV1.Modifiers;
const MOD = Mods{ .mod4 = true };
const MOD_SHIFT = Mods{ .mod4 = true, .shift = true };
const MOD_ALT = Mods{ .mod1 = true };

/// xkbcommon keysyms - Latin-1 chars are direct codepoints, others from xkbcommon.h
const XKB_KEY_Tab = 0xff09;
const XKB_KEY_Return = 0xff0d;
const XKB_KEY_BackSpace = 0xff08;
const XKB_KEY_space = 0x0020;
const XKB_KEY_Up = 0xff52;
const XKB_KEY_Down = 0xff54;
const XKB_KEY_Left = 0xff51;
const XKB_KEY_Right = 0xff53;
const XKB_KEY_XF86AudioPlay = 0x1008ff14;
const XKB_KEY_XF86AudioPrev = 0x1008ff16;
const XKB_KEY_XF86AudioNext = 0x1008ff17;

const digit_keysym = [9]u32{ '1', '2', '3', '4', '5', '6', '7', '8', '9' };

/// One live keybinding: the river object plus the action to run on press.
pub const Binding = struct {
    rwm: *river.XkbBindingV1,
    action: action.Action,

    /// Listener for top-level bindings (always-enabled).
    fn listener(_: *river.XkbBindingV1, event: river.XkbBindingV1.Event, self: *Binding) void {
        switch (event) {
            .pressed => action.execute(self.action),
            else => {},
        }
    }

    /// Listener for a chord's sub-binding. A terminal key runs its action and
    /// closes the chord; a key that descends into a deeper submap
    /// (`.enter_submap`) transitions instead of closing — `applySubmap` swaps the
    /// active node, keeping us inside the chord. This is what makes chords of any
    /// depth work (dwl's `keys[5]`), not just two keys.
    fn subListener(_: *river.XkbBindingV1, event: river.XkbBindingV1.Event, self: *Binding) void {
        switch (event) {
            .pressed => switch (self.action) {
                .enter_submap => |child| requestSubmapEnter(child),
                else => {
                    action.execute(self.action);
                    requestSubmapExit();
                },
            },
            else => {},
        }
    }
};

/// A node in the chord trie (dwl `Keychord`). The node that owns it is entered by
/// a leader/parent key; `subs` are the next-level keys, each created DISABLED and
/// only enabled while THIS node is the active submap. A sub may be terminal (its
/// action runs and the chord closes) or itself descend into a deeper node (action
/// `.enter_submap`), so chords nest to arbitrary depth.
pub const Chord = struct {
    subs: std.ArrayList(*Binding) = .empty,
};

// Bindings are created when a seat appears, but can only be enabled inside a
// manage sequence — so we stash them and flip `pending_enable`, which the manage
// cycle drains via `enablePending`. (Chord sub-bindings are NOT in this list;
// they're enabled/disabled on the fly by `applySubmap`.)
var list: std.ArrayList(*Binding) = .empty;
var enable_from: usize = 0; // index of first not-yet-enabled binding

// Chord/submap state.
var chords: std.ArrayList(*Chord) = .empty;
/// Per-seat object used to request `ensure_next_key_eaten` and receive
/// `ate_unbound_key`. We assume a single (primary) seat for chords.
var bindings_seat: ?*river.XkbBindingsSeatV1 = null;
var active_chord: ?*Chord = null; // submap currently armed, if any
var pending_enter: ?*Chord = null; // submap to arm in the next manage cycle
var pending_exit: bool = false; // close the active submap in the next manage cycle

/// Create every configured binding for `seat`. No-op if the compositor didn't
/// advertise river_xkb_bindings_v1.
pub fn registerForSeat(seat: *Seat) void {
    const ctx = Context.get();
    const xkb = ctx.xkb_bindings orelse {
        log.warn("no river_xkb_bindings_v1 — keybindings disabled", .{});
        return;
    };

    // Per-seat bindings object — drives the chord submaps (ensure_next_key_eaten /
    // ate_unbound_key). Created once, for the first seat that registers.
    if (bindings_seat == null) {
        if (xkb.getSeat(seat.rwm)) |bs| {
            bs.setListener(?*anyopaque, seatListener, null);
            bindings_seat = bs;
        } else |err| {
            log.warn("xkb_bindings.get_seat failed: {} — chords disabled", .{err});
        }
    }

    // Desktop management. Desktop numbers are 1-based, so key '1' (digit_keysym[0])
    // is desktop 1 — the index and the number differ by exactly this `+ 1`.
    var i: usize = 0;
    while (i < config.desktops.count and i < 9) : (i += 1) {
        const d: u32 = @intCast(i + 1);
        add(xkb, seat, digit_keysym[i], MOD, .{ .view = d });
        // NOTE: river matches Shift bindings in `no_translate` mode using the
        // BASE-level keysym (e.g. '1', not '!') while KEEPING Shift in the mod
        // mask. So Shift bindings must register the unshifted keysym + MOD_SHIFT,
        // never the shifted glyph. (See Seat.matchXkbBinding / XkbBinding.match.)
        add(xkb, seat, digit_keysym[i], MOD_SHIFT, .{ .send = d });
    }

    // The action/spawn/chord binds: if config.zon supplied a `binds` array it FULLY
    // replaces the compiled-in keymap (dwl-style — your config is the config); the
    // desktop binds above are always generated. With no file binds, the built-in
    // defaults below are used verbatim.
    if (confparse.binds) |specs| {
        for (specs) |spec| registerSpecBind(xkb, seat, spec);
    } else {
        registerDefaultBinds(xkb, seat);
    }
}

/// Register one file-driven bind (and, recursively, its chord sub-tree).
fn registerSpecBind(xkb: *river.XkbBindingsV1, seat: *Seat, spec: confparse.KeySpec) void {
    const kc = parseKey(spec.key) orelse return; // parseKey logs the reason
    if (spec.chord.len != 0) {
        const chord = addChord(xkb, seat, kc.keysym, kc.mods);
        for (spec.chord) |sub| registerSpecSub(chord, xkb, seat, sub);
    } else if (spec.action) |a| {
        add(xkb, seat, kc.keysym, kc.mods, action.toAction(a));
    } else {
        log.warn("bind '{s}': neither action nor chord — skipped", .{spec.key});
    }
}

/// Register a sub-key of a chord from its spec (recurses for nested chords).
fn registerSpecSub(chord: *Chord, xkb: *river.XkbBindingsV1, seat: *Seat, spec: confparse.KeySpec) void {
    const kc = parseKey(spec.key) orelse return;
    if (spec.chord.len != 0) {
        const child = addSubChord(chord, xkb, seat, kc.keysym, kc.mods);
        for (spec.chord) |sub| registerSpecSub(child, xkb, seat, sub);
    } else if (spec.action) |a| {
        addSub(chord, xkb, seat, kc.keysym, kc.mods, action.toAction(a));
    }
}

/// A parsed key combo: the river modifier mask plus the resolved keysym code.
const KeyCombo = struct { mods: Mods, keysym: u32 };

/// Parse a config.zon `key` string ("Super+Shift+q", "Alt+Up", "XF86AudioPlay",
/// "d") into modifiers + keysym. Tokens are split on '+'; the LAST token is the
/// xkb keysym name, the rest are modifiers. Whitespace around tokens is ignored.
/// Returns null (and logs) on an unknown modifier or keysym — note '+' as the key
/// itself must be written by name ("plus"), since '+' is the separator.
fn parseKey(spec: []const u8) ?KeyCombo {
    const s = std.mem.trim(u8, spec, " \t");
    if (s.len == 0) {
        log.warn("bind: empty key string — skipped", .{});
        return null;
    }
    var mods: Mods = .{};
    const key_name = name: {
        // Last '+' separates the modifier list from the keysym name. No '+' at all
        // ⇒ the whole string is the keysym (a bare sub-key like "d").
        const cut = std.mem.lastIndexOfScalar(u8, s, '+') orelse break :name s;
        var it = std.mem.splitScalar(u8, s[0..cut], '+');
        while (it.next()) |tok| {
            const m = std.mem.trim(u8, tok, " \t");
            if (m.len == 0) continue;
            if (!applyMod(&mods, m)) {
                log.warn("bind '{s}': unknown modifier '{s}' — skipped", .{ spec, m });
                return null;
            }
        }
        break :name std.mem.trim(u8, s[cut + 1 ..], " \t");
    };
    const ks = resolveKeysym(key_name) orelse {
        log.warn("bind '{s}': unknown keysym '{s}' — skipped", .{ spec, key_name });
        return null;
    };
    return .{ .mods = mods, .keysym = ks };
}

/// Set the river modifier bit for a (case-insensitive) alias. false = unknown name.
fn applyMod(mods: *Mods, name: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "super") or eq(name, "mod") or eq(name, "mod4") or
        eq(name, "logo") or eq(name, "win") or eq(name, "meta"))
    {
        mods.mod4 = true;
    } else if (eq(name, "alt") or eq(name, "mod1")) {
        mods.mod1 = true;
    } else if (eq(name, "ctrl") or eq(name, "control")) {
        mods.ctrl = true;
    } else if (eq(name, "shift")) {
        mods.shift = true;
    } else if (eq(name, "mod3")) {
        mods.mod3 = true;
    } else if (eq(name, "mod5")) {
        mods.mod5 = true;
    } else return false;
    return true;
}

/// The compiled-in fallback keymap, used only when config.zon supplies no `binds`.
/// Deliberately MINIMAL and generic — a terminal plus core window management, with
/// no references to specific apps — so a bare install (or zero-config run from the
/// repo) is usable out of the box. The full personal keymap lives in
/// `config.example.zon`, not here. Desktop binds are generated separately in
/// registerForSeat and are always present.
fn registerDefaultBinds(xkb: *river.XkbBindingsV1, seat: *Seat) void {
    // Terminal: dwl's Super+Shift+Return. Respect $TERMINAL, fall back to foot (a
    // light Wayland-native terminal); harmless no-op if neither is installed.
    add(xkb, seat, XKB_KEY_Return, MOD_SHIFT, .{ .spawn = "${TERMINAL:-foot}" });

    // Window management
    add(xkb, seat, 'r', MOD_SHIFT, .reload);
    add(xkb, seat, 'p', MOD_SHIFT, .quit);
    add(xkb, seat, 'q', MOD_SHIFT, .killclient);
    add(xkb, seat, XKB_KEY_Return, MOD, .zoom);
    add(xkb, seat, 'f', MOD, .togglefloating);
    add(xkb, seat, 'f', MOD_SHIFT, .togglefullscreen);

    // Focus / layout
    add(xkb, seat, 'j', MOD, .{ .focusstack = 1 });
    add(xkb, seat, 'k', MOD, .{ .focusstack = -1 });
    add(xkb, seat, 'h', MOD, .{ .setmfact = -0.05 });
    add(xkb, seat, 'l', MOD, .{ .setmfact = 0.05 });
    add(xkb, seat, 'm', MOD, .{ .incnmaster = -1 });
    add(xkb, seat, 'n', MOD, .{ .incnmaster = 1 });
    add(xkb, seat, ',', MOD, .{ .focusmon = -1 });
    add(xkb, seat, '.', MOD, .{ .focusmon = 1 });
    add(xkb, seat, ',', MOD_SHIFT, .{ .sendmon = -1 });
    add(xkb, seat, '.', MOD_SHIFT, .{ .sendmon = 1 });
}

/// Destroy every binding and chord, returning the module to its pre-registration
/// state so `reregister` can rebuild from a freshly parsed config. MUST run inside
/// a manage sequence (disable() is manage-only) and MUST run before the config
/// arena those bindings borrow from is released — `Action.spawn` points straight
/// into the parsed AST.
///
/// `bindings_seat` deliberately survives: it is per-seat plumbing for the chord
/// protocol, not configuration, and registerForSeat only creates one when null.
pub fn teardown() void {
    const ctx = Context.get();

    // An armed submap has live, ENABLED sub-bindings and river has been told to
    // eat the next key. Close it before anything is destroyed so we don't strand
    // the compositor waiting on a submap whose bindings no longer exist.
    if (active_chord) |c| {
        for (c.subs.items) |b| b.rwm.disable();
    }
    active_chord = null;
    pending_enter = null;
    pending_exit = false;

    for (list.items) |b| {
        b.rwm.destroy();
        ctx.gpa.destroy(b);
    }
    list.clearRetainingCapacity();
    enable_from = 0;

    // Chord subs are not in `list` (they are owned by their node), so they are
    // destroyed here, node by node.
    for (chords.items) |c| {
        for (c.subs.items) |b| {
            b.rwm.destroy();
            ctx.gpa.destroy(b);
        }
        c.subs.deinit(ctx.gpa);
        ctx.gpa.destroy(c);
    }
    chords.clearRetainingCapacity();
}

/// Rebuild every binding from the current config, for every seat. Pairs with
/// `teardown`; the new bindings are created disabled and go live when the manage
/// cycle reaches `enablePending`.
pub fn reregister() void {
    for (Context.get().seats.items) |seat| registerForSeat(seat);
}

/// Enable any newly-created bindings. Must be called from a manage sequence.
pub fn enablePending() void {
    if (enable_from >= list.items.len) return;
    for (list.items[enable_from..]) |b| b.rwm.enable();
    enable_from = list.items.len;
}

fn add(xkb: *river.XkbBindingsV1, seat: *Seat, keysym: u32, mods: Mods, act: action.Action) void {
    const ctx = Context.get();
    const rwm = xkb.getXkbBinding(seat.rwm, keysym, mods) catch |err| {
        log.err("getXkbBinding failed: {}", .{err});
        return;
    };
    const b = ctx.gpa.create(Binding) catch {
        rwm.destroy();
        return;
    };
    b.* = .{ .rwm = rwm, .action = act };
    rwm.setListener(*Binding, Binding.listener, b);
    list.append(ctx.gpa, b) catch {};
}

// ---------------------------------------------------------------------------
// Chords (two-key submaps)
// ---------------------------------------------------------------------------

/// Allocate a chord node.
fn newChord() *Chord {
    const ctx = Context.get();
    const chord = ctx.gpa.create(Chord) catch @panic("OOM creating chord");
    chord.* = .{};
    chords.append(ctx.gpa, chord) catch {};
    return chord;
}

/// Create a top-level chord leader: a normal, always-enabled binding on
/// (keysym, mods) whose action arms the returned (initially empty) root submap.
/// Add keys to it with `addSub` (terminal) or `addSubChord` (deeper level).
fn addChord(xkb: *river.XkbBindingsV1, seat: *Seat, keysym: u32, mods: Mods) *Chord {
    const chord = newChord();
    add(xkb, seat, keysym, mods, .{ .enter_submap = chord });
    return chord;
}

/// Add a key to `chord` whose action runs the next-level submap, returning that
/// child node so you can keep adding to it. This is how chords go past two keys.
fn addSubChord(chord: *Chord, xkb: *river.XkbBindingsV1, seat: *Seat, keysym: u32, mods: Mods) *Chord {
    const child = newChord();
    addSub(chord, xkb, seat, keysym, mods, .{ .enter_submap = child });
    return child;
}

/// Add a key to a chord node. The binding is created DISABLED (never put in
/// `list`, never `enable()`d here); `applySubmap` toggles it as the node's submap
/// opens and closes, so it can't trigger except while that node is active.
fn addSub(chord: *Chord, xkb: *river.XkbBindingsV1, seat: *Seat, keysym: u32, mods: Mods, act: action.Action) void {
    const ctx = Context.get();
    const rwm = xkb.getXkbBinding(seat.rwm, keysym, mods) catch |err| {
        log.err("getXkbBinding (sub) failed: {}", .{err});
        return;
    };
    const b = ctx.gpa.create(Binding) catch {
        rwm.destroy();
        return;
    };
    b.* = .{ .rwm = rwm, .action = act };
    rwm.setListener(*Binding, Binding.subListener, b);
    chord.subs.append(ctx.gpa, b) catch {};
}

/// Ask to arm `chord`'s submap on the next manage cycle. Called from a leader's
/// `pressed` handler — which the protocol guarantees is followed by a manage
/// sequence, so no manageDirty is needed.
pub fn requestSubmapEnter(chord: *Chord) void {
    pending_enter = chord;
}

/// Ask to close the active submap on the next manage cycle (a sub fired, or an
/// unbound key aborted it). Also runs inside a guaranteed manage sequence.
fn requestSubmapExit() void {
    pending_exit = true;
}

/// Apply any pending submap open/close. MUST be called from a manage sequence
/// (enable/disable and ensure_next_key_eaten are manage-only requests).
pub fn applySubmap() void {
    if (pending_exit) {
        if (active_chord) |c| {
            for (c.subs.items) |b| b.rwm.disable();
        }
        active_chord = null;
        pending_exit = false;
    }
    if (pending_enter) |c| {
        // Defensive: if a different submap were somehow still armed, close it.
        if (active_chord) |old| {
            if (old != c) for (old.subs.items) |b| b.rwm.disable();
        }
        for (c.subs.items) |b| b.rwm.enable();
        // Eat the next key so a wrong second key aborts via ate_unbound_key
        // instead of leaking through to the focused surface.
        if (bindings_seat) |bs| bs.ensureNextKeyEaten();
        active_chord = c;
        pending_enter = null;
    }
}

/// river_xkb_bindings_seat_v1 events. `ate_unbound_key` means the armed submap
/// got a key that matched no sub-binding → abort the submap.
fn seatListener(_: *river.XkbBindingsSeatV1, event: river.XkbBindingsSeatV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .ate_unbound_key => requestSubmapExit(),
    }
}
