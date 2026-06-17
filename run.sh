#!/bin/sh
# Launch reach under the NATIVE river on a real TTY.
#
# river 0.4.5 is built from source (~/.local/src/river) against system wlroots 0.20,
# but with nix-zig — so its baked ELF interpreter is the Nix glibc loader, which only
# searches /nix/store and can't find /usr/lib. patchelf can't rewrite it (it asserts
# on Zig's ELF layout), so we launch river through the SYSTEM loader directly. river's
# NEEDED libs are plain sonames and its max glibc symbol is 2.36 (Void has 2.41), so
# the system loader resolves everything from /usr/lib. Result: fully native — system
# glibc, system wlroots, system Mesa GBM + Vulkan + NVIDIA. No nixGL, no GBM hacks.
#
# IMPORTANT: build reach with plain `zig build` (NOT `nix develop --command zig
# build`). Outside the nix dev shell, reach links the SYSTEM wayland/pixman/fcft
# (no nix RUNPATH) — so, like river, it's a nix-zig binary with system sonames and is
# launched through the SYSTEM loader. (Inside nix develop it gets a nix RUNPATH and
# would instead need its own loader; we standardize on the system path for both.)
#
# WLR_NO_HARDWARE_CURSORS=1 works around NVIDIA's broken cursor planes.
# stdbuf + tee give live, line-buffered logs.
stdbuf -oL -eL env \
    WLR_RENDERER=vulkan \
    WLR_NO_HARDWARE_CURSORS=1 \
    /lib64/ld-linux-x86-64.so.2 "$HOME/.local/bin/river" \
        -c "/lib64/ld-linux-x86-64.so.2 $PWD/zig-out/bin/reach" 2>&1 \
    | stdbuf -oL tee /tmp/river-vulkan.log
