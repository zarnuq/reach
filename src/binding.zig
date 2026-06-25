// binding.zig — xkb keybindings, and the tag (workspace) actions they drive.
//
// river hands keybindings to the WM via river_xkb_bindings_v1: we create a
// binding for (seat, keysym, modifiers), `enable()` it during a manage sequence,
// and then receive a `pressed` event when it fires. Per the protocol, a `pressed`
// event is always followed by a manage_start, so mutating state in the handler is
// enough — the layout/render re-runs automatically (no manageDirty needed).
//
// The full dwl keybind set is wired up in registerForSeat (mirroring the user's
// config.h). The tag binds are:
//   MOD+1..9            view tag n
//   MOD+Ctrl+1..9       toggle tag n in the view
//   MOD+Shift+sym       move focused window to tag n
//   MOD+Ctrl+Shift+sym  toggle tag n on the focused window
//   MOD+0               view all tags
//   MOD+Shift+0sym      put focused window on all tags
// where MOD is Super (mod4); the rest (spawn, focus, layout, chords, media, …)
// follow in the same function.

const std = @import("std");
const log = std.log.scoped(.binding);

const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const confparse = @import("confparse.zig");
const Context = @import("context.zig");
const Seat = @import("seat.zig").Seat;
const Output = @import("output.zig").Output;
const Window = @import("window.zig").Window;

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
const MOD_CTRL = Mods{ .mod4 = true, .ctrl = true };
const MOD_CTRL_SHIFT = Mods{ .mod4 = true, .ctrl = true, .shift = true };
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

/// A signed step on each axis, in pixels — for floating move/resize.
pub const Delta = struct { x: i32 = 0, y: i32 = 0 };

/// What a keybinding does when pressed.
pub const Action = union(enum) {
    // Tag actions
    view: u32,
    toggleview: u32,
    tag: u32,
    toggletag: u32,
    // Spawn - single shell command string
    spawn: [:0]const u8,
    // Enter a two-key chord submap (dwl SPAWN2): the leader arms `chord`, whose
    // sub-bindings become live until the next key resolves them. See the submap
    // machinery near the bottom of this file.
    enter_submap: *Chord,
    // Window management
    quit,
    killclient,
    zoom,
    togglefloating,
    togglefullscreen,
    // Floating geometry (keyboard). Both only act on the focused window while it
    // is floating; no-ops otherwise.
    move: Delta,
    resize: Delta,
    // Focus/layout
    focusstack: i32,
    setmfact: f32,
    incnmaster: i32,
    focusmon: i32,
    tagmon: i32,
};

/// One live keybinding: the river object plus the action to run on press.
pub const Binding = struct {
    rwm: *river.XkbBindingV1,
    action: Action,

    /// Listener for top-level bindings (always-enabled).
    fn listener(_: *river.XkbBindingV1, event: river.XkbBindingV1.Event, self: *Binding) void {
        switch (event) {
            .pressed => execute(self.action),
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
                    execute(self.action);
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

    // Tag management
    var i: usize = 0;
    while (i < config.tags.count and i < 9) : (i += 1) {
        const bit = @as(u32, 1) << @intCast(i);
        add(xkb, seat, digit_keysym[i], MOD, .{ .view = bit });
        add(xkb, seat, digit_keysym[i], MOD_CTRL, .{ .toggleview = bit });
        // NOTE: river matches Shift bindings in `no_translate` mode using the
        // BASE-level keysym (e.g. '1', not '!') while KEEPING Shift in the mod
        // mask. So Shift bindings must register the unshifted keysym + MOD_SHIFT,
        // never the shifted glyph. (See Seat.matchXkbBinding / XkbBinding.match.)
        add(xkb, seat, digit_keysym[i], MOD_SHIFT, .{ .tag = bit });
        add(xkb, seat, digit_keysym[i], MOD_CTRL_SHIFT, .{ .toggletag = bit });
    }
    add(xkb, seat, '0', MOD, .{ .view = ~@as(u32, 0) });
    add(xkb, seat, '0', MOD_SHIFT, .{ .tag = ~@as(u32, 0) });

    // The action/spawn/chord binds: if config.zon supplied a `binds` array it FULLY
    // replaces the compiled-in keymap (dwl-style — your config is the config); the
    // tag binds above are always generated. With no file binds, the built-in
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
        add(xkb, seat, kc.keysym, kc.mods, toAction(a));
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
        addSub(chord, xkb, seat, kc.keysym, kc.mods, toAction(a));
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

/// confparse.ActionSpec → the real Action union (chords excluded; they come in
/// structurally via KeySpec.chord, not as an action).
fn toAction(a: confparse.ActionSpec) Action {
    return switch (a) {
        .view => |v| .{ .view = v },
        .toggleview => |v| .{ .toggleview = v },
        .tag => |v| .{ .tag = v },
        .toggletag => |v| .{ .toggletag = v },
        .spawn => |v| .{ .spawn = v },
        .quit => .quit,
        .killclient => .killclient,
        .zoom => .zoom,
        .togglefloating => .togglefloating,
        .togglefullscreen => .togglefullscreen,
        .move => |d| .{ .move = .{ .x = d.x, .y = d.y } },
        .resize => |d| .{ .resize = .{ .x = d.x, .y = d.y } },
        .focusstack => |v| .{ .focusstack = v },
        .setmfact => |v| .{ .setmfact = v },
        .incnmaster => |v| .{ .incnmaster = v },
        .focusmon => |v| .{ .focusmon = v },
        .tagmon => |v| .{ .tagmon = v },
    };
}

/// The compiled-in fallback keymap, used only when config.zon supplies no `binds`.
/// Deliberately MINIMAL and generic — a terminal plus core window management, with
/// no references to specific apps — so a bare install (or zero-config run from the
/// repo) is usable out of the box. The full personal keymap lives in
/// `config.example.zon`, not here. Tag binds are generated separately in
/// registerForSeat and are always present.
fn registerDefaultBinds(xkb: *river.XkbBindingsV1, seat: *Seat) void {
    // Terminal: dwl's Super+Shift+Return. Respect $TERMINAL, fall back to foot (a
    // light Wayland-native terminal); harmless no-op if neither is installed.
    add(xkb, seat, XKB_KEY_Return, MOD_SHIFT, .{ .spawn = "${TERMINAL:-foot}" });

    // Window management
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
    add(xkb, seat, ',', MOD_SHIFT, .{ .tagmon = -1 });
    add(xkb, seat, '.', MOD_SHIFT, .{ .tagmon = 1 });
}

/// Enable any newly-created bindings. Must be called from a manage sequence.
pub fn enablePending() void {
    if (enable_from >= list.items.len) return;
    for (list.items[enable_from..]) |b| b.rwm.enable();
    enable_from = list.items.len;
}

fn add(xkb: *river.XkbBindingsV1, seat: *Seat, keysym: u32, mods: Mods, action: Action) void {
    const ctx = Context.get();
    const rwm = xkb.getXkbBinding(seat.rwm, keysym, mods) catch |err| {
        log.err("getXkbBinding failed: {}", .{err});
        return;
    };
    const b = ctx.gpa.create(Binding) catch {
        rwm.destroy();
        return;
    };
    b.* = .{ .rwm = rwm, .action = action };
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
fn addSub(chord: *Chord, xkb: *river.XkbBindingsV1, seat: *Seat, keysym: u32, mods: Mods, action: Action) void {
    const ctx = Context.get();
    const rwm = xkb.getXkbBinding(seat.rwm, keysym, mods) catch |err| {
        log.err("getXkbBinding (sub) failed: {}", .{err});
        return;
    };
    const b = ctx.gpa.create(Binding) catch {
        rwm.destroy();
        return;
    };
    b.* = .{ .rwm = rwm, .action = action };
    rwm.setListener(*Binding, Binding.subListener, b);
    chord.subs.append(ctx.gpa, b) catch {};
}

/// Ask to arm `chord`'s submap on the next manage cycle. Called from a leader's
/// `pressed` handler — which the protocol guarantees is followed by a manage
/// sequence, so no manageDirty is needed.
fn requestSubmapEnter(chord: *Chord) void {
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

// ---------------------------------------------------------------------------
// Cursor warp (dwl warpcursor)
// ---------------------------------------------------------------------------

/// Ask to warp the pointer onto the focused window on the next manage cycle.
/// Runs inside a guaranteed manage sequence (binding press → manage_start).
fn requestWarp() void {
    Context.get().warp_pending = true;
}

/// Warp the pointer to the center of the focused window (or the selected output
/// if nothing is focused). MUST be called from a manage sequence — pointer_warp
/// is a manage-only request — and AFTER arrange() so window geometry is current.
pub fn applyWarp() void {
    const ctx = Context.get();
    if (!ctx.warp_pending) return;
    ctx.warp_pending = false;

    const seat = ctx.primary_seat orelse return;
    var x: i32 = undefined;
    var y: i32 = undefined;
    if (ctx.focused) |f| {
        const o = f.output orelse return;
        x = o.x + f.x + @divFloor(f.width, 2);
        y = o.y + f.y + @divFloor(f.height, 2);
    } else if (ctx.current_output) |o| {
        x = o.x + @divFloor(o.width, 2);
        y = o.y + @divFloor(o.height, 2);
    } else return;

    seat.rwm.pointerWarp(x, y);
}

/// river_xkb_bindings_seat_v1 events. `ate_unbound_key` means the armed submap
/// got a key that matched no sub-binding → abort the submap.
fn seatListener(_: *river.XkbBindingsSeatV1, event: river.XkbBindingsSeatV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .ate_unbound_key => requestSubmapExit(),
    }
}

/// Run the configured startup commands (dwl's `autostart[]`). Each goes through
/// `/bin/sh -c`. Spawned children inherit our environment, including the
/// WAYLAND_DISPLAY river set for us, so GUI clients connect to the session.
pub fn runAutostart() void {
    for (config.autostart) |cmd| spawn(cmd);
}

/// Double-fork + setsid a `/bin/sh -c <cmd>`, reaping the first child so no
/// zombie is left and the grandchild is reparented to init.
pub fn spawn(cmd: [:0]const u8) void {
    const pid1 = std.c.fork();
    if (pid1 < 0) return;
    if (pid1 == 0) {
        // Child 1: new session, reset signal mask, fork again.
        _ = std.c.setsid();
        _ = std.c.sigprocmask(std.c.SIG.SETMASK, &std.posix.sigemptyset(), null);

        const pid2 = std.c.fork();
        if (pid2 < 0) std.c._exit(1);
        if (pid2 == 0) {
            const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd.ptr, null };
            _ = std.c.execve("/bin/sh", &child_args, std.c.environ);
            std.c._exit(1);
        }
        std.c._exit(0);
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid1, &status, 0);
}

// ---------------------------------------------------------------------------
// Action execution
// ---------------------------------------------------------------------------

fn execute(action: Action) void {
    const ctx = Context.get();
    switch (action) {
        // Tag actions. No warp here: switching/ moving tags on the same monitor
        // shouldn't yank the pointer (user preference). focusmon still warps
        // because it moves the keyboard selection across monitors; tagmon does
        // not (it moves a window, not the selection — see its case below).
        .view => |t| {
            if (t == 0) return;
            const out = focusedOutput() orelse return;
            out.tagset = t;
            refocus(out);
        },
        .toggleview => |t| {
            const out = focusedOutput() orelse return;
            const next = out.tagset ^ t;
            if (next == 0) return;
            out.tagset = next;
            refocus(out);
        },
        .tag => |t| {
            if (t == 0) return;
            const out = focusedOutput() orelse return;
            if (ctx.focused) |f| {
                f.tags = t;
                refocus(out);
            }
        },
        .toggletag => |t| {
            const out = focusedOutput() orelse return;
            if (ctx.focused) |f| {
                const next = f.tags ^ t;
                if (next != 0) f.tags = next;
                refocus(out);
            }
        },
        // Spawn a shell command (double-fork; see spawn()).
        .spawn => |cmd| spawn(cmd),
        // Arm a two-key chord submap.
        .enter_submap => |chord| requestSubmapEnter(chord),
        // Window management
        .quit => {
            ctx.running = false;
            // reach is launched as river's `-c` startup command, so river is
            // our parent process. Stopping the poll loop only exits reach (the
            // WM client) and would leave river running with no window manager —
            // an "orphaned" compositor. Signal the parent so river quits too,
            // matching dwl's monolithic quit where compositor and WM are one.
            _ = std.os.linux.kill(std.os.linux.getppid(), std.os.linux.SIG.TERM);
        },
        .killclient => if (ctx.focused) |f| f.rwm.close(),
        .zoom => {
            if (ctx.focused) |f| promoteToMaster(f);
            requestWarp();
        },
        .togglefloating => {
            if (ctx.focused) |f| {
                f.floating = !f.floating;
                // Re-establish geometry next cycle: when floating, placeFloating
                // recenters at the (now larger) default; when tiling, arrange
                // retiles. Without this the old float geometry would persist.
                f.float_placed = false;
            }
        },
        .togglefullscreen => {
            if (ctx.focused) |f| f.fullscreen = !f.fullscreen;
        },
        // Floating move/resize. The press is followed by a manage cycle, and
        // float_placed stays set, so the change sticks (placeFloating won't reset).
        .move => |d| moveFloating(d.x, d.y),
        .resize => |d| resizeFloating(d.x, d.y),
        // Focus/layout — all reposition the focused window and/or move the
        // selection, so warp the pointer to follow (dwl warpcursor).
        .focusstack => |dir| {
            focusStack(dir);
            requestWarp();
        },
        .setmfact => |delta| {
            adjustMfact(delta);
            requestWarp();
        },
        .incnmaster => |delta| {
            adjustNmaster(delta);
            requestWarp();
        },
        .focusmon => |dir| {
            focusMonitor(dir);
            requestWarp();
        },
        // Moves the focused WINDOW to the adjacent monitor. Unlike focusmon, the
        // selection (and pointer) stay put — moving a window shouldn't yank the
        // cursor — so no warp here.
        .tagmon => |dir| tagMonitor(dir),
    }
}

/// The output the tag/layout actions affect: the selected output (`selmon`). This
/// is the same value the bar highlights, so a keybinding always acts on the
/// monitor that visibly has focus. Falls back to the first output before any
/// selection has been made.
fn focusedOutput() ?*Output {
    const ctx = Context.get();
    if (ctx.current_output) |o| return o;
    return if (ctx.outputs.items.len > 0) ctx.outputs.items[0] else null;
}

/// Ensure focus lands on a window that's actually visible on `out` after a view
/// or tag change; clears focus if the output is now empty.
fn refocus(out: *Output) void {
    const ctx = Context.get();
    if (ctx.focused) |f| {
        if (f.output == out and f.visible()) return; // still valid
    }
    for (ctx.windows.items) |w| {
        if (w.output == out and w.visible()) {
            ctx.focused = w;
            return;
        }
    }
    ctx.focused = null;
}

fn promoteToMaster(w: *Window) void {
    const ctx = Context.get();
    for (ctx.windows.items, 0..) |win, i| {
        if (win == w and i > 0) {
            _ = ctx.windows.orderedRemove(i);
            ctx.windows.insert(ctx.gpa, 0, w) catch {};
            break;
        }
    }
}

fn focusStack(dir: i32) void {
    const ctx = Context.get();
    const out = focusedOutput() orelse return;
    const cur = ctx.focused orelse return;
    if (cur.output != out) return;

    var visible: std.ArrayList(*Window) = .empty;
    defer visible.deinit(ctx.gpa);
    for (ctx.windows.items) |w| {
        if (w.output == out and w.visible() and !w.floating) {
            visible.append(ctx.gpa, w) catch return;
        }
    }
    if (visible.items.len < 2) return;

    for (visible.items, 0..) |w, i| {
        if (w == cur) {
            const next_idx = if (dir > 0)
                (i + 1) % visible.items.len
            else
                (i + visible.items.len - 1) % visible.items.len;
            ctx.focused = visible.items[next_idx];
            return;
        }
    }
}

fn adjustMfact(delta: f32) void {
    const out = focusedOutput() orelse return;
    const new = @max(0.1, @min(0.9, out.mfact + delta));
    out.mfact = new;
}

fn adjustNmaster(delta: i32) void {
    const out = focusedOutput() orelse return;
    out.nmaster = @max(0, out.nmaster + delta);
}

/// Move the focused floating window by (dx,dy), keeping it on its output. No-op for
/// tiled/fullscreen windows. float_placed is already set, so placeFloating leaves
/// the new position alone.
fn moveFloating(dx: i32, dy: i32) void {
    const ctx = Context.get();
    const f = ctx.focused orelse return;
    if (!f.floating or f.fullscreen) return;
    const o = f.output orelse return;
    f.x = std.math.clamp(f.x + dx, 0, @max(0, o.width - f.width));
    f.y = std.math.clamp(f.y + dy, 0, @max(0, o.height - f.height));
}

/// Grow/shrink the focused floating window by (dw,dh), respecting its min-size hint
/// (and a small floor) and the output bounds, then nudge it back on-screen if it
/// grew past an edge.
fn resizeFloating(dw: i32, dh: i32) void {
    const ctx = Context.get();
    const f = ctx.focused orelse return;
    if (!f.floating or f.fullscreen) return;
    const o = f.output orelse return;
    const min_w = @max(@as(i32, 40), f.min_width);
    const min_h = @max(@as(i32, 40), f.min_height);
    f.width = std.math.clamp(f.width + dw, min_w, o.width);
    f.height = std.math.clamp(f.height + dh, min_h, o.height);
    f.x = @min(f.x, @max(0, o.width - f.width));
    f.y = @min(f.y, @max(0, o.height - f.height));
}

/// Index of `out` in the output list, or null if not present.
fn outputIndex(out: *Output) ?usize {
    const ctx = Context.get();
    for (ctx.outputs.items, 0..) |o, i| {
        if (o == out) return i;
    }
    return null;
}

/// The output `dir` steps away from `out` (wrapping). Null if there's only one.
fn adjacentOutput(out: *Output, dir: i32) ?*Output {
    const ctx = Context.get();
    const n = ctx.outputs.items.len;
    if (n < 2) return null;
    const i = outputIndex(out) orelse return null;
    const next = if (dir > 0) (i + 1) % n else (i + n - 1) % n;
    return ctx.outputs.items[next];
}

/// Move the selection to the adjacent monitor and pull keyboard focus there.
/// Works even when the target monitor is empty (selection still moves, focus
/// clears) so you can switch to a bare monitor and spawn onto it.
fn focusMonitor(dir: i32) void {
    const ctx = Context.get();
    const cur = focusedOutput() orelse return;
    const next_out = adjacentOutput(cur, dir) orelse return;

    ctx.current_output = next_out;
    ctx.pointer_output = next_out;
    ctx.focused = topVisibleOn(next_out);
}

/// Send the focused window to the adjacent monitor, keeping it on the SAME tag
/// (desktop) number it was already on rather than retagging it to the
/// destination's viewed tags. So a window on tag 3 stays on tag 3 over there —
/// it only shows immediately if that monitor is already viewing tag 3, otherwise
/// it waits on that desktop. The selection stays put; focus falls to whatever's
/// left on the current monitor.
fn tagMonitor(dir: i32) void {
    const ctx = Context.get();
    const cur = focusedOutput() orelse return;
    const next_out = adjacentOutput(cur, dir) orelse return;
    const w = ctx.focused orelse return;

    w.output = next_out;
    refocus(cur);
}

/// The most-recently-focused visible window on `out`, or null if it's empty.
fn topVisibleOn(out: *Output) ?*Window {
    const ctx = Context.get();
    for (ctx.windows.items) |w| {
        if (w.output == out and w.visible()) return w;
    }
    return null;
}
