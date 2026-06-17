# reach

A minimal, dwl-spirited tiling window manager for the
[river](https://codeberg.org/river/river) Wayland compositor, written in Zig.

river is non-monolithic: it is *only* the compositor. reach is a client that
speaks `river-window-management-v1` and decides policy — layout, focus, tmux-style
shared borders, and a built-in dwlb-style status bar fed by `someblocks`. See
`../reach-zig-plan.md` for the full design.

## Status: Milestone 1 — skeleton

Implemented:

- Connects to river, binds the globals (`river_window_manager_v1`, plus
  compositor/shm/layer-shell/xkb-bindings for later milestones).
- Runs the poll() event loop.
- Handles river's **manage** and **render** sequences correctly (always closes
  them so the compositor never stalls).
- Logs windows / outputs / seats appearing and disappearing.

Not yet: layout, floating, borders, bar, keychords (M2–M5). Search the source for
`TODO(M…)` markers — each points at where the next milestone plugs in.

## Build

Requires **Zig 0.16.x** (same as kwm/river) and `libwayland-client`. The first
build fetches `zig-wayland` from the network and caches it.

```sh
zig build                       # -> zig-out/bin/reach
zig build -Doptimize=ReleaseSafe
zig build run                   # build + run
```

## Run

river only advertises the window-management protocol to the process it launches
itself, so start reach via river's `-c`:

```sh
nix develop
zig build
WLR_RENDERER=pixman river -c "$PWD/zig-out/bin/reach"
```

`WLR_RENDERER=pixman` forces wlroots' software renderer, which sidesteps EGL/
Vulkan init. On this machine (Nix wlroots + host NVIDIA driver) the GPU renderer
fails with `RendererCreateFailed`, so pixman is required for now — it works both
from a bare TTY (DRM backend) and nested inside another Wayland session. It is CPU
rendering (slow) but fine for development.

You should see log lines for the compositor connection and each output/seat/window
river reports.
