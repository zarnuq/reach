# reach

A custom tiling Wayland window manager written in Zig, for the
[**river**](https://codeberg.org/river/river) compositor's non-monolithic
architecture. ("reach" = a straight stretch of a river.)

river 0.4.x is a *non-monolithic* compositor: river is **only** the compositor
(it renders, handles input, talks to DRM/the GPU). The window manager is a
**separate client process** — this one — that speaks the
`river-window-management-v1` protocol and decides layout, focus and borders.
reach is that window manager. It is configured through compiled-in defaults
plus an optional `config.zon` file (see [Configuration](#configuration)).

## Features

- **Master-stack tiling** — the only layout (by design; no monocle/floating
  layout modes).
- **tmux-style shared borders** — only the focused window is decorated, and only on
  the faces it shares with a neighbour: one line per face, sitting just outside that
  window's own edge — flush against it, never over it, at any `inner_gap`. The line is cut
  collinearly — `border_active` alongside the focused window, `border_inactive` for
  the rest of the same line.
- **Virtual desktops** — 9 of them; each output views exactly one, each window
  lives on exactly one. View a desktop, or send the focused window to one.
- **State socket** — desktops, focus, window titles and per-output occupancy
  published as JSON snapshots on a unix socket, for a panel to draw. reach has
  no bar of its own: drawing one is a job for a layer-shell client, and this is
  the state such a client cannot otherwise obtain.
- **Keybindings + multi-key chords** — arbitrary-depth chord tries built on
  river's submap primitive.
- **Floating windows** — toggle float, fullscreen, keyboard move/resize; stack
  focus cycling includes tiled and floating windows together.
- **Window rules** — by `app_id`/`title`: force float, assign a desktop, switch to
  it, send to a monitor, set floating geometry.
- **Monitor configuration** — modes/positions/transforms/scale applied via
  `zwlr_output_manager_v1`, with deterministic config-ordered monitor numbering.
- **Input configuration** — keyboard repeat rate/delay via river-input-management.
- **Autostart**, **cursor warp**, **focus-follows-mouse** (sloppy focus), and
  **session env** (`setenv` before autostart).
- **Cursor theme/size** — set on the seat and exported to spawned children — and
  **shake to find**: scrub the mouse and a command of your choosing runs.
- **Live config reload** — `SIGHUP` or a keybind re-reads `config.zon` and rebuilds
  keybinds, colors, rules and monitors in place; a config that doesn't parse is
  rejected without disturbing the running session.

Not implemented (optional): interactive mouse move/resize/float by `MOD`+drag
(floating itself works via keyboard, above).

## Build

[Gentoo overlay](https://github.com/zarnuq/gentoo-overlay)

Requires **Zig 0.16** and the system `wayland-client` and `xkbcommon` libraries.
At build time it also needs `wayland-scanner` and the `wayland-protocols` XML
data dir, from which the scanner reads `viewporter` and `single-pixel-buffer-v1`
(together those draw the solid-color border rectangles with no shm at all). The
first build fetches `zig-wayland` from the network and caches it; after that no
network is needed.

The vendored protocol definitions track river 0.4.8: window management v5, XKB
bindings v3, and input management v2. Bindings for river's libinput-config v2
and XKB-config v2 APIs are generated as the base for future device settings;
reach currently uses input management for keyboard repeat. At runtime, globals
are capped to the generated version; reach's current feature floor is window
management v3 and XKB bindings v2.

```sh
zig build                 # → zig-out/bin/reach
zig build run             # build and run (e.g. inside a nested river session)
zig build test            # run unit tests
```

Build with **plain `zig build`**: reach links the *system* `wayland-client` and
`xkbcommon`, matching how river itself is built. If your Zig comes from Nix,
build inside `nix develop` ([`flake.nix`](flake.nix)) instead — a Nix toolchain
linking the host distro's libwayland mixes two glibc worlds and segfaults on
connect.

## Run

river only advertises the window-management protocol to the process it launches
itself, so reach must be started by river via its `-c` flag — pointing at the
built binary:

```sh
river -c /path/to/reach/zig-out/bin/reach
```

reach then runs as river's window manager for that session. To test rendering
without GPU acceleration, start river with `WLR_RENDERER=pixman`.

## Configuration

reach has **compiled-in defaults** (`src/config.zig`) and reads an **optional
`config.zon`** at startup, overlaying any field it sets on top of those defaults.
With no config file the defaults are used — the binary runs out of the box and
nothing user- or machine-specific is baked into it.

Lookup order, first found wins:

```
$XDG_CONFIG_HOME/reach/config.zon
~/.config/reach/config.zon
/etc/reach/config.zon
```

The file is [ZON](https://ziglang.org/documentation/master/#Zon) (Zig Object
Notation), parsed straight into reach's config types via `std.zon`. **Every field
is optional** — a config only needs to mention what it overrides.
[`config.example.zon`](config.example.zon) documents the full schema and
reproduces the defaults, so it is a working starting point.

Configurable: gaps, sloppy focus, keyboard repeat, session env, autostart,
monitors (mode/position/transform/scale, matched by connector name), window rules,
master-stack defaults (`nmaster`/`mfact`), float defaults, border color/width,
cursor theme/size and shake-to-find, and the full keymap.

### Live reload

The config is re-read on demand — no restart, no lost windows:

```sh
kill -HUP $(pidof reach)     # or press Super+Shift+r
```

Reload rebuilds everything the file drives: colors, gaps, `nmaster`/`mfact`,
borders, window rules, the keymap (including chords), cursor theme/size and
shake-to-find, and monitor configuration. A malformed file is reported with a
line/column error and **is not applied at all** — the session keeps running on
the config it already had, so a bad edit costs you a log line rather than your
keybindings.

Two of those are re-applied only when they actually changed, because redoing
them is not free: the `monitors` table (re-setting a mode is a visible flicker)
and the `cursor` block (which reopens the `/dev/input` handles behind
shake-to-find). Everything else — colors, gaps, `mfact`/`nmaster`, border
thickness, window rules — needs no action at all, since the manage/render cycle
the reload runs inside reads each one fresh.

Two settings are startup-only, because they cannot be anything else:

| Setting | Why it can't reload |
| --- | --- |
| `env` | Already exported into a process tree that exists; re-exporting would not reach running children. |
| `autostart` | Already run; re-running would launch second copies. |

Deleting a field from `config.zon` reverts it to the compiled-in default, so the
file always describes the running state rather than accumulating overrides. Window
rules apply to windows opened from then on — reload does not retroactively move
or re-float windows that are already up. `desktops.count` and the desktop names
are compile-time constants and are not part of the file.

> **Monitor numbering and external clients.** reach's config-ordered monitor
> numbering (used by `focusmon`/`sendmon` and window-rule `monitor` indices) is
> **internal to reach** — it does *not* change the order river advertises
> `wl_output` globals to other clients. So an external bar/widget client (eww,
> waybar, …) that targets a monitor by **index** is at the mercy of river's
> advertisement order, not reach's. That order is also perturbed when reach
> applies the `monitors` config: changing an output's position/transform/mode via
> `zwlr_output_manager_v1` can re-advertise it, shifting every client's indices.
> **Target external widgets by connector name** (e.g. eww's `--screen DP-2`)
> rather than a numeric index, so placement is stable regardless of enumeration
> order.

### Keybindings

`MOD` = Super (mod4). The desktop and window-management binds below are intrinsic
defaults; the **complete keymap — including launcher/spawn binds and chords — is
defined in `binds` in `config.zon`** and, if present, fully replaces the default
action keymap (the desktop binds are always generated). Each bind's `key` is a combo
string — modifiers then the xkb keysym name, joined by `+`, e.g. `"Super+Shift+q"`,
`"Alt+Up"`, `"XF86AudioPlay"`; a chord sub-key with no modifier is just `"d"`.
Modifier aliases (case-insensitive): `Super`/`Mod`/`Win`, `Alt`, `Ctrl`, `Shift`,
`Mod3`, `Mod5`. Keysyms are xkb names (`"Return"`, `"space"`, `"comma"`, `"plus"`;
letters/digits are themselves).

**Desktops**

| Bind | Action |
|------|--------|
| `MOD+1..9` | view desktop *n* |
| `MOD+Shift+1..9` | send the focused window to desktop *n* |

There is no toggle-view or "all desktops" bind: an output views exactly one
desktop and a window lives on exactly one, so there is no such state to toggle
into — which is also why an empty view is unreachable.

**Layout / windows**

| Bind | Action |
|------|--------|
| `MOD+j` / `MOD+k` | focus next / previous in stack |
| `MOD+h` / `MOD+l` | shrink / grow master area (`mfact`) |
| `MOD+m` / `MOD+n` | decrease / increase master count (`nmaster`) |
| `MOD+Return` | zoom (promote to master) |
| `MOD+f` | toggle floating |
| `MOD+Shift+f` | toggle fullscreen |
| `MOD+,` / `MOD+.` | focus previous / next monitor |
| `MOD+Shift+,` / `MOD+Shift+.` | send window to previous / next monitor |
| `MOD+Shift+Return` | spawn `$TERMINAL` (falling back to `foot`) |
| `MOD+Shift+r` | reload `config.zon` |
| `MOD+Shift+q` | kill focused client |
| `MOD+Shift+p` | quit reach (and the river session) |

That table *is* the compiled-in keymap — the one you get with no `config.zon`,
or with one that sets no `binds`. Keyboard move/resize of a floating window has
no default bind; [`config.example.zon`](config.example.zon) puts it on
`MOD+arrows` / `MOD+Shift+arrows` (step `float_step`), which is the convention
the rest of this README assumes.

**Spawn & chords.** Launcher bindings and multi-key chords are user-defined in
`config.zon`. A bind maps a keysym + modifiers to an action; a *chord* leader arms
a submap whose sub-keys (carrying no modifier) resolve on the next press, nesting
to arbitrary depth. The available actions are:

- `spawn` — run a shell command
- `view` / `send` — desktop (workspace) operations; both take a 1-based number
- `zoom`, `killclient`, `quit`
- `togglefloating`, `togglefullscreen`
- `move` / `resize` — keyboard move/resize of a floating window
- `focusstack`, `setmfact`, `incnmaster`
- `focusmon`, `sendmon`
- `reload` — re-read `config.zon` (the same thing `SIGHUP` does)

### Cursor and shake to find

river renders the cursor, but the window manager picks its theme and size
(`river_seat_v1.set_xcursor_theme`). reach also exports `XCURSOR_THEME` /
`XCURSOR_SIZE` to the processes it spawns: without them libXcursor derives a size
from the Xwayland root's height, which across a multi-monitor layout gives X11
windows a wildly oversized pointer.

```zon
.cursor = .{
    .theme = "default",      // under ~/.local/share/icons or /usr/share/icons
    .size = 24,              // px; also the exported XCURSOR_SIZE
    .export_env = true,      // export the two vars to spawned children
    .shake = .{
        .enabled = false,
        .delay = 150,        // ms the motion must keep qualifying
        .command = "",       // empty = do nothing
    },
},
```

`theme = "default"` follows that theme's `Inherits` chain, i.e. whatever
dconf/nwg-look already set. `export_env` only affects what *reach* starts —
shells that predate the session keep their old environment.

**Shake to find** recognises a scrub of the mouse and runs `cursor.shake.command`
— once per shake, re-arming only after the motion stops. The detector is
Hyprland's: over a trailing window of motion, compare the distance travelled
against the diagonal of the box the pointer stayed inside, so a shake piles up
travel in a small box while a straight swipe never fires. `delay` is then the
whole tuning surface — that test answers "is this shaking *right now*", and
requiring it to hold for `delay` is what separates a real shake from an ordinary
overshoot-and-correct, which only looks like one for a moment. Lower is
twitchier; `0` fires the instant the motion qualifies.

Detection reads raw deltas from `/dev/input/event*` rather than from the
protocol, because `river_seat_v1.pointer_position` only arrives inside a manage
sequence and motion alone may not start one — shaking inside a single window
would yield almost no samples. That needs no elevation (the devices are
`root:input` 0660), but **the user must be in the `input` group**; with no
readable pointer device reach logs a warning and carries on. While
`enabled = false` — the default — `/dev/input` is never opened at all.

reach cannot *draw* anything at the cursor itself. It is river's
window-management client rather than the compositor, so it has no surface to
paint on, and those deltas are the only pointer information it has — it never
learns where the pointer actually is. So the gesture is recognised here and
handed to whatever can map a surface.

## State socket

reach draws no bar. Everything a panel would need to draw one — which desktop each
output is viewing, which desktops hold windows, which output is focused, and the
focused window's title and `app_id` — is published on a `SOCK_STREAM` unix socket
at `$XDG_RUNTIME_DIR/reach.sock` (falling back to `/tmp/reach.sock` when that
variable is unset):

```json
{"desktops":9,"outputs":[{"name":"DP-2","desktop":1,"focused":true,"fullscreen":false,"occupied":[1,3],"title":"nvim","appId":"kitty"}]}
```

One line per change, and each line is a **complete** snapshot rather than a delta:
a client that connects late or reconnects is immediately correct, with no resync
step and no ordering to get wrong. The first line arrives on connect. Publishing
is driven from the render cycle, so a panel is as live as the windows are, and
composing is skipped entirely when nothing is connected. Up to four clients may
be connected at once — a bar per session is the case, and the ceiling is what
stops a client stuck in a reconnect loop from exhausting reach's fds. Titles and
`app_id`s are truncated at 256 bytes. If the socket cannot be bound, reach logs
it and carries on: an external bar failing to start is not a reason to lose the
session.

The socket is **write-only**: client fds are read only to notice a disconnect, and
anything sent to reach is discarded. A `view <n>` command for clickable desktop
cells would have to name its output as well — desktop actions act on the *selected*
output, so a click on an unfocused monitor would switch the focused one — and that
is a focus-semantics decision, not one a status socket should make. A panel that
needs to drive the window manager has keybinds and `spawn`.

## Environment

reach makes no assumption about an init system or session/login manager: the
autostart command set in `config.zon` is where session services are brought up,
so it works with or without systemd. It links libc and, on Zig 0.16 whose
`std.posix` is gutted, calls `std.os.linux.*` / `std.c.*` syscalls directly.
Because it is launched through the system dynamic loader, `main.zig` calls
`prctl(PR_SET_NAME, "reach")` to fix `/proc/self/comm` (and make `pidof reach`
work).
