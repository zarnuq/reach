// binding.zig — xkb keybindings, and the tag (workspace) actions they drive.
//
// river hands keybindings to the WM via river_xkb_bindings_v1: we create a
// binding for (seat, keysym, modifiers), `enable()` it during a manage sequence,
// and then receive a `pressed` event when it fires. Per the protocol, a `pressed`
// event is always followed by a manage_start, so mutating state in the handler is
// enough — the layout/render re-runs automatically (no manageDirty needed).
//
// This milestone wires up the dwl tag keybinds (mirroring the user's config.h):
//   MOD+1..9            view tag n
//   MOD+Ctrl+1..9       toggle tag n in the view
//   MOD+Shift+sym       move focused window to tag n
//   MOD+Ctrl+Shift+sym  toggle tag n on the focused window
//   MOD+0               view all tags
//   MOD+Shift+0sym      put focused window on all tags
// where MOD is Super (mod4). The remaining dwl keybinds (spawn, focus, layout, …)
// arrive at M5 by adding more entries here.

const std = @import("std");
const log = std.log.scoped(.binding);

const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const Context = @import("context.zig");
const Seat = @import("seat.zig").Seat;
const Output = @import("output.zig").Output;
const Window = @import("window.zig").Window;

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
const shifted_keysym = [9]u32{ '!', '@', '#', '$', '%', '^', '&', '*', '(' };

/// What a keybinding does when pressed.
pub const Action = union(enum) {
    // Tag actions
    view: u32,
    toggleview: u32,
    tag: u32,
    toggletag: u32,
    // Spawn - single shell command string
    spawn: [:0]const u8,
    // Window management
    quit,
    killclient,
    zoom,
    togglefloating,
    togglefullscreen,
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

    fn listener(_: *river.XkbBindingV1, event: river.XkbBindingV1.Event, self: *Binding) void {
        switch (event) {
            .pressed => execute(self.action),
            else => {},
        }
    }
};

// Bindings are created when a seat appears, but can only be enabled inside a
// manage sequence — so we stash them and flip `pending_enable`, which the manage
// cycle drains via `enablePending`.
var list: std.ArrayList(*Binding) = .empty;
var pending_enable: bool = false;

/// Create every configured binding for `seat`. No-op if the compositor didn't
/// advertise river_xkb_bindings_v1.
pub fn registerForSeat(seat: *Seat) void {
    const ctx = Context.get();
    const xkb = ctx.xkb_bindings orelse {
        log.warn("no river_xkb_bindings_v1 — keybindings disabled", .{});
        return;
    };

    // Tag management
    var i: usize = 0;
    while (i < config.tags.count and i < 9) : (i += 1) {
        const bit = @as(u32, 1) << @intCast(i);
        add(xkb, seat, digit_keysym[i], MOD, .{ .view = bit });
        add(xkb, seat, digit_keysym[i], MOD_CTRL, .{ .toggleview = bit });
        add(xkb, seat, shifted_keysym[i], MOD_SHIFT, .{ .tag = bit });
        add(xkb, seat, shifted_keysym[i], MOD_CTRL_SHIFT, .{ .toggletag = bit });
    }
    add(xkb, seat, '0', MOD, .{ .view = ~@as(u32, 0) });
    add(xkb, seat, ')', MOD_SHIFT, .{ .tag = ~@as(u32, 0) });

    // Spawn - all with MOD to avoid conflicts
    add(xkb, seat, 'p', MOD, .{ .spawn = "swaylock" });
    add(xkb, seat, XKB_KEY_Tab, MOD, .{ .spawn = "kitty" });
    add(xkb, seat, 'd', MOD, .{ .spawn = "emacsclient -c" });
    add(xkb, seat, XKB_KEY_space, MOD, .{ .spawn = "rofi -show drun -show-icons" });
    add(xkb, seat, XKB_KEY_BackSpace, MOD, .{ .spawn = "kitty --class float" });
    add(xkb, seat, 'v', MOD, .{ .spawn = "kitty --class float -e $HOME/.local/bin/clipfzf" });
    add(xkb, seat, 'x', MOD, .{ .spawn = "kitty --class float -e $HOME/.local/bin/killfzf" });
    add(xkb, seat, 'z', MOD, .{ .spawn = "kitty --class float -e $HOME/.local/bin/svfzf" });
    add(xkb, seat, 'w', MOD, .{ .spawn = "kitty --class rmpc rmpc" });
    add(xkb, seat, 'W', MOD_SHIFT, .{ .spawn = "rmpc rescan" });
    add(xkb, seat, 't', MOD, .{ .spawn = "zen" });
    add(xkb, seat, 'B', MOD_SHIFT, .{ .spawn = "kitty -e yazi $HOME/Pictures/bgs" });
    add(xkb, seat, 'b', MOD, .{ .spawn = "awww img \"$(find $HOME/Pictures/bgs -type f \\( -iname '*.jpg' -o -iname '*.png' \\) | shuf -n1)\" --transition-fps 144 --transition-type top --transition-duration 1" });
    add(xkb, seat, 'e', MOD, .{ .spawn = "$HOME/.local/bin/eww.sh open" });
    add(xkb, seat, 'E', MOD_SHIFT, .{ .spawn = "$HOME/.local/bin/eww.sh close" });
    add(xkb, seat, 'r', MOD, .{ .spawn = "$HOME/.local/bin/runbar.sh" });

    // Apps (using Ctrl variants to avoid conflicts)
    add(xkb, seat, 'd', MOD_CTRL, .{ .spawn = "legcord" });
    add(xkb, seat, 'b', MOD_CTRL, .{ .spawn = "brave" });
    add(xkb, seat, 'a', MOD_CTRL, .{ .spawn = "pavucontrol" });
    add(xkb, seat, 's', MOD_CTRL, .{ .spawn = "exec steam </dev/null >/dev/null 2>&1" });

    // Screenshots
    add(xkb, seat, 's', MOD, .{ .spawn = "$HOME/.local/bin/screenshot.sh ss && notify-send Screenshot 'Quick capture saved!'" });
    add(xkb, seat, 'S', MOD_SHIFT, .{ .spawn = "$HOME/.local/bin/screenshot.sh section && notify-send Screenshot 'Section saved!'" });

    // Audio (using q prefix)
    add(xkb, seat, 'q', MOD, .{ .spawn = "easyeffects -l EQ" });
    add(xkb, seat, 'Q', MOD_SHIFT, .{ .spawn = "easyeffects -l None" });

    // Media controls
    add(xkb, seat, XKB_KEY_XF86AudioPlay, .{}, .{ .spawn = "playerctl -p mpd play-pause" });
    add(xkb, seat, XKB_KEY_XF86AudioPrev, .{}, .{ .spawn = "playerctl -p mpd previous" });
    add(xkb, seat, XKB_KEY_XF86AudioNext, .{}, .{ .spawn = "playerctl -p mpd next" });
    add(xkb, seat, XKB_KEY_Up, MOD_ALT, .{ .spawn = "pactl set-sink-volume @DEFAULT_SINK@ +5% && kill -35 $(pidof confluence)" });
    add(xkb, seat, XKB_KEY_Down, MOD_ALT, .{ .spawn = "pactl set-sink-volume @DEFAULT_SINK@ -5% && kill -35 $(pidof confluence)" });
    add(xkb, seat, XKB_KEY_Left, MOD_ALT, .{ .spawn = "pactl set-source-volume @DEFAULT_SOURCE@ -5% && kill -36 $(pidof confluence)" });
    add(xkb, seat, XKB_KEY_Right, MOD_ALT, .{ .spawn = "pactl set-source-volume @DEFAULT_SOURCE@ +5% && kill -36 $(pidof confluence)" });
    add(xkb, seat, 0xff57, MOD_ALT, .{ .spawn = "pactl set-source-mute @DEFAULT_SOURCE@ toggle && kill -36 $(pidof confluence)" }); // End
    add(xkb, seat, '[', MOD_ALT, .{ .spawn = "$HOME/.local/bin/flip.sh && touch /tmp/update_audio && kill -35 $(pidof confluence)" });

    // Brightness
    add(xkb, seat, XKB_KEY_Left, Mods{ .mod4 = true, .mod1 = true }, .{ .spawn = "$HOME/.local/bin/brightness.sh down" });
    add(xkb, seat, XKB_KEY_Right, Mods{ .mod4 = true, .mod1 = true }, .{ .spawn = "$HOME/.local/bin/brightness.sh up" });
    add(xkb, seat, XKB_KEY_Up, Mods{ .mod4 = true, .mod1 = true }, .{ .spawn = "$HOME/.local/bin/redshift.sh" });

    // Window management
    add(xkb, seat, 'P', MOD_SHIFT, .quit);
    add(xkb, seat, 'Q', MOD_SHIFT, .killclient);
    add(xkb, seat, XKB_KEY_Return, MOD, .zoom);
    add(xkb, seat, 'f', MOD, .togglefloating);
    add(xkb, seat, 'F', MOD_SHIFT, .togglefullscreen);

    // Focus/layout
    add(xkb, seat, 'j', MOD, .{ .focusstack = 1 });
    add(xkb, seat, 'k', MOD, .{ .focusstack = -1 });
    add(xkb, seat, 'h', MOD, .{ .setmfact = -0.05 });
    add(xkb, seat, 'l', MOD, .{ .setmfact = 0.05 });
    add(xkb, seat, 'm', MOD, .{ .incnmaster = -1 });
    add(xkb, seat, 'n', MOD, .{ .incnmaster = 1 });
    add(xkb, seat, ',', MOD, .{ .focusmon = -1 });
    add(xkb, seat, '.', MOD, .{ .focusmon = 1 });
    add(xkb, seat, '<', MOD_SHIFT, .{ .tagmon = -1 });
    add(xkb, seat, '>', MOD_SHIFT, .{ .tagmon = 1 });

    pending_enable = true;
}

/// Enable any newly-created bindings. Must be called from a manage sequence.
pub fn enablePending() void {
    if (!pending_enable) return;
    for (list.items) |b| b.rwm.enable();
    pending_enable = false;
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
// Action execution
// ---------------------------------------------------------------------------

fn execute(action: Action) void {
    const ctx = Context.get();
    switch (action) {
        // Tag actions
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
        // Spawn - double fork to avoid zombies, reset signal mask
        .spawn => |cmd| {
            const pid1 = std.c.fork();
            if (pid1 < 0) return;
            if (pid1 == 0) {
                // Child 1: create new session and fork again
                _ = std.c.setsid();
                // Reset signal mask
                _ = std.c.sigprocmask(std.c.SIG.SETMASK, &std.posix.sigemptyset(), null);
                
                const pid2 = std.c.fork();
                if (pid2 < 0) std.c._exit(1);
                if (pid2 == 0) {
                    // Child 2: exec the command
                    const child_args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd.ptr, null };
                    _ = std.c.execve("/bin/sh", &child_args, std.c.environ);
                    std.c._exit(1);
                }
                std.c._exit(0);
            }
            // Parent: reap child 1
            var status: c_int = 0;
            _ = std.c.waitpid(pid1, &status, 0);
        },
        // Window management
        .quit => ctx.running = false,
        .killclient => if (ctx.focused) |f| f.rwm.close(),
        .zoom => if (ctx.focused) |f| promoteToMaster(f),
        .togglefloating => {
            if (ctx.focused) |f| f.floating = !f.floating;
        },
        .togglefullscreen => {}, // TODO: implement fullscreen support
        // Focus/layout
        .focusstack => |dir| focusStack(dir),
        .setmfact => |delta| adjustMfact(delta),
        .incnmaster => |delta| adjustNmaster(delta),
        .focusmon => |dir| focusMonitor(dir),
        .tagmon => |dir| tagMonitor(dir),
    }
}

/// The output whose view the tag actions affect — pointer's output first,
/// else the focused window's output, else the first output.
fn focusedOutput() ?*Output {
    const ctx = Context.get();
    if (ctx.pointer_output) |o| return o;
    if (ctx.focused) |f| {
        if (f.output) |o| return o;
    }
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

fn focusMonitor(dir: i32) void {
    const ctx = Context.get();
    if (ctx.outputs.items.len < 2) return;
    const cur = focusedOutput() orelse return;

    for (ctx.outputs.items, 0..) |o, i| {
        if (o == cur) {
            const next_idx = if (dir > 0)
                (i + 1) % ctx.outputs.items.len
            else
                (i + ctx.outputs.items.len - 1) % ctx.outputs.items.len;
            const next_out = ctx.outputs.items[next_idx];
            for (ctx.windows.items) |w| {
                if (w.output == next_out and w.visible()) {
                    ctx.focused = w;
                    return;
                }
            }
            return;
        }
    }
}

fn tagMonitor(dir: i32) void {
    const ctx = Context.get();
    if (ctx.outputs.items.len < 2) return;
    const cur = focusedOutput() orelse return;
    const w = ctx.focused orelse return;

    for (ctx.outputs.items, 0..) |o, i| {
        if (o == cur) {
            const next_idx = if (dir > 0)
                (i + 1) % ctx.outputs.items.len
            else
                (i + ctx.outputs.items.len - 1) % ctx.outputs.items.len;
            w.output = ctx.outputs.items[next_idx];
            w.tags = w.output.?.tagset;
            return;
        }
    }
}
