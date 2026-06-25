# reach

A custom tiling Wayland window manager written in Zig, for the
[**river**](https://codeberg.org/river/river) compositor's non-monolithic
architecture. ("reach" = a straight stretch of a river.)

river 0.4.x is a *non-monolithic* compositor: river is **only** the compositor
(it renders, handles input, talks to DRM/the GPU). The window manager is a
**separate client process** — this one — that speaks the
`river-window-management-v1` protocol and decides layout, focus, borders, and the
bar. (Contrast dwl, where compositor and WM are one binary.) reach follows dwl's
design closely, including a dwl `config.h`-style configuration model.

## Features

- **Master-stack tiling** — the only layout (by design; no monocle/floating
  layout modes).
- **tmux-style shared borders** — the focused window's interior edges are
  highlighted in the gutter, dwl/tmux style, instead of per-window box borders.
- **Tags** (dwl/dwm bitmask workspaces) — view, toggle-view, move-to-tag,
  toggle-tag, view-all.
- **Built-in dwlb-style status bar** — drawn on every output; the someblocks
  blocks run *in-process* (no external `dwlb`/`someblocks`/fifo). Per-block
  intervals and `SIGRTMIN+n` signal refresh work like suckless someblocks.
- **Keybindings + multi-key chords** — arbitrary-depth chord tries built on
  river's submap primitive.
- **Floating windows** — toggle float, fullscreen, keyboard move/resize.
- **Window rules** — by `app_id`/`title`: force float, assign tags, switch tag,
  send to a monitor, set floating geometry.
- **Monitor configuration** — modes/positions/transforms/scale applied via
  `zwlr_output_manager_v1`, with deterministic config-ordered monitor numbering.
- **Input configuration** — keyboard repeat rate/delay via river-input-management.
- **Autostart**, **cursor warp**, **focus-follows-mouse** (sloppy focus), and
  **session env** (`setenv` before autostart).

Not implemented (optional): mouse move/resize/float (MOD+drag), cursor theme, bar
tag clicks.

See `CLAUDE.md` for the full architecture notes, gotchas, and the source map.

## Build

Requires **Zig 0.16** and the system `wayland-client`, `pixman`, and `fcft`
libraries. The first build fetches `zig-wayland`, `zig-pixman`, and `zig-fcft`
from the network and caches them.

```sh
zig build                 # → zig-out/bin/reach
```

Build with **plain `zig build`**. Do **NOT** use `nix develop --command zig
build`: outside the nix dev shell reach links the *system* wayland/pixman/fcft
(no nix RUNPATH), matching how river itself is built, so both are launched through
the system loader. See the header of `run.sh` for the full rationale.

## Run

river only advertises the window-management protocol to the process it launches
itself, so reach is started via river's `-c`:

```sh
./run.sh                  # launch native river on a real TTY, with reach as its WM
```

`run.sh` launches **both** river and reach via the system dynamic loader because
they are nix-zig binaries with system sonames. To test rendering without the GPU,
run river with `WLR_RENDERER=pixman` (useful where hardware EGL/GPU acceleration
is unavailable).

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
master-stack defaults (`nmaster`/`mfact`), float defaults, border color/width, the
bar (font, colors, status blocks), and the full keymap.

The config is read **once at startup** (no live reload, by design). A malformed
file is reported with a line/column error and the defaults are kept, so a bad edit
never breaks the running session.

> **Monitor numbering and external clients.** reach's config-ordered monitor
> numbering (used by `focusmon`/`tagmon` and window-rule `monitor` indices) is
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

`MOD` = Super (mod4). The tag and window-management binds below are intrinsic
defaults; the **complete keymap — including launcher/spawn binds and chords — is
defined in `binds` in `config.zon`** and, if present, fully replaces the default
action keymap (the tag binds are always generated). Each bind's `key` is a combo
string — modifiers then the xkb keysym name, joined by `+`, e.g. `"Super+Shift+q"`,
`"Alt+Up"`, `"XF86AudioPlay"`; a chord sub-key with no modifier is just `"d"`.
Modifier aliases (case-insensitive): `Super`/`Mod`/`Win`, `Alt`, `Ctrl`, `Shift`,
`Mod3`, `Mod5`. Keysyms are xkb names (`"Return"`, `"space"`, `"comma"`, `"plus"`;
letters/digits are themselves).

**Tags**

| Bind | Action |
|------|--------|
| `MOD+1..9` | view tag *n* |
| `MOD+Ctrl+1..9` | toggle tag *n* in the view |
| `MOD+Shift+1..9` | move focused window to tag *n* |
| `MOD+Ctrl+Shift+1..9` | toggle tag *n* on the focused window |
| `MOD+0` | view all tags |
| `MOD+Shift+0` | put focused window on all tags |

**Layout / windows**

| Bind | Action |
|------|--------|
| `MOD+j` / `MOD+k` | focus next / previous in stack |
| `MOD+h` / `MOD+l` | shrink / grow master area (`mfact`) |
| `MOD+m` / `MOD+n` | decrease / increase master count (`nmaster`) |
| `MOD+Return` | zoom (promote to master) |
| `MOD+f` | toggle floating |
| `MOD+Shift+f` | toggle fullscreen |
| `MOD+arrows` | move floating window |
| `MOD+Shift+arrows` | grow/shrink floating window |
| `MOD+,` / `MOD+.` | focus previous / next monitor |
| `MOD+Shift+,` / `MOD+Shift+.` | send window to previous / next monitor |
| `MOD+Shift+q` | kill focused client |
| `MOD+Shift+p` | quit reach (and the river session) |

**Spawn & chords.** Launcher bindings and multi-key chords are user-defined in
`config.zon`. A bind maps a keysym + modifiers to an action; a *chord* leader arms
a submap whose sub-keys (carrying no modifier) resolve on the next press, nesting
to arbitrary depth. The available actions are:

- `spawn` — run a shell command
- `view` / `toggleview` / `tag` / `toggletag` — tag (workspace) operations
- `zoom`, `killclient`, `quit`
- `togglefloating`, `togglefullscreen`
- `move` / `resize` — keyboard move/resize of a floating window
- `focusstack`, `setmfact`, `incnmaster`
- `focusmon`, `tagmon`

## Environment

reach makes no assumption about an init system or session/login manager: the
autostart command set in `config.zon` is where session services are brought up,
so it works with or without systemd. It links libc and, on Zig 0.16 whose
`std.posix` is gutted, calls `std.os.linux.*` / `std.c.*` syscalls directly.
Because it is launched through the system dynamic loader, `main.zig` calls
`prctl(PR_SET_NAME, "reach")` to fix `/proc/self/comm` (and make `pidof reach`
work).
