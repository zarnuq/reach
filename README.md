# reach

A custom tiling Wayland window manager written in Zig, for the
[**river**](https://codeberg.org/river/river) compositor's non-monolithic
architecture. ("reach" = a straight stretch of a river.)

river 0.4.x is a *non-monolithic* compositor: river is **only** the compositor
(it renders, handles input, talks to DRM/the GPU). The window manager is a
**separate client process** — this one — that speaks the
`river-window-management-v1` protocol and decides layout, focus, borders, and the
bar. (Contrast dwl, where compositor and WM are one binary.) reach is modeled
closely on the author's dwl `config.h`.

## Status

Feature-complete versus the author's dwl setup:

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

Not ported (optional): mouse move/resize/float (MOD+drag), cursor theme, bar tag
clicks.

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
run river with `WLR_RENDERER=pixman` (NVIDIA/EGL fails under the nix setup).

## Configuration

Configuration is **compile-time**, dwl-style: edit `src/config.zig` (and
`src/binding.zig` for keybindings) and rebuild. `config.zig` covers gaps, sloppy
focus, keyboard repeat, session env, autostart, monitor rules, master-stack
defaults (`nmaster`/`mfact`), float defaults, window rules, border color/width,
tags, and the bar (font, colors, status blocks).

### Keybindings

`MOD` = Super (mod4). Defined in `src/binding.zig`.

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
| `MOD+Shift+p` | quit reach |

**Spawn** (selection)

| Bind | Command |
|------|---------|
| `MOD+Tab` | kitty |
| `MOD+Space` | rofi (drun) |
| `MOD+d` | emacsclient |
| `MOD+t` | zen-browser |
| `MOD+p` | swaylock |
| `MOD+BackSpace` | floating kitty |
| `MOD+v` / `MOD+x` / `MOD+z` | clipfzf / killfzf / svfzf |

**Chords** (leader arms a submap; release Super, then press the sub-key)

- `MOD+r` → run/launch (`d` legcord, `b` brave, `a` pavucontrol, `s` steam, `w` runbar)
- `MOD+s` → screenshots (`s` quick, `d` section, `1`/`2`/`3` per-display)
- `MOD+q` → easyeffects presets (`1` EQ, `2` None)

Plus media keys, `MOD+Alt+arrows` for volume/mic, brightness, and redshift.

## Environment

Targets **Gentoo Linux + runit (no systemd)**. Session services come up via
`runsvdir ~/.local/sv` from the autostart script. This Zig 0.16 has a gutted
`std.posix`, so reach uses `std.os.linux.*` / `std.c.*` syscalls directly. reach
is launched through the system loader, so `main.zig` calls
`prctl(PR_SET_NAME, "reach")` to fix `/proc/self/comm` (and make `pidof reach`
work).
