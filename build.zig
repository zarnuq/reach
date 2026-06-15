// build.zig — Confluence build script.
//
// This file does NOT compile the program directly; it builds the *build graph*
// (`b`) that Zig's build runner then executes. The big jobs here are:
//
//   1. Run the zig-wayland "scanner" over the Wayland protocol XML files. The
//      scanner turns each protocol into type-safe Zig code (objects, requests,
//      event unions). That generated code becomes the `wayland` module we import
//      from src/.
//   2. Define the `confluence` executable, give it the `wayland` module, and
//      link the C libraries the bindings call into (`libwayland-client`, libc).
//
// Milestone 1 keeps this minimal: only the globals we actually touch are
// generated, and there is no font baker / xkbcommon yet (those arrive in later
// milestones and are marked with TODO below).

const std = @import("std");
const wayland = @import("wayland");

pub fn build(b: *std.Build) void {
    // `-Dtarget=...` and `-Doptimize=...` come from these. We don't constrain
    // them: native target by default, and the user picks Debug / ReleaseSafe /
    // ReleaseFast / ReleaseSmall. For a tiny resident WM, `ReleaseSafe` is a good
    // daily driver and `ReleaseSmall` squeezes the binary.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----------------------------------------------------------------------
    // 1. Wayland protocol code generation
    // ----------------------------------------------------------------------
    //
    // The scanner needs:
    //   * the core Wayland protocol (wl_compositor, wl_shm, wl_seat, …), which it
    //     finds in the system wayland-protocols data dir, and
    //   * our vendored river protocols in protocol/.
    const scanner = wayland.Scanner.create(b, .{});

    // Stable/staging Wayland protocols from the system wayland-protocols package
    // (provided by the Nix dev shell). viewporter scales a buffer to any size;
    // single-pixel-buffer makes a 1x1 solid-color buffer — together they draw
    // solid-color rectangles (the tmux borders) with no shm at all.
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");

    // Our custom protocols (copied from river/kwm into protocol/).
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));

    // `generate(interface, version)` emits Zig for exactly the interfaces we use,
    // at the version we request. We only list what milestone 1 needs plus the
    // core globals we'll reuse soon (compositor/subcompositor/shm for surfaces &
    // buffers, seat/output because the river protocols reference wl_seat/wl_output
    // in their events).
    scanner.generate("wl_compositor", 4); // wl_surface / wl_region factory
    scanner.generate("wl_subcompositor", 1); // wl_subsurface (border/bar pieces later)
    scanner.generate("wl_shm", 1); // shared-memory buffers (borders + bar later)
    scanner.generate("wl_seat", 7); // referenced by river_seat_v1.wl_seat event
    scanner.generate("wl_output", 4); // referenced by river_output_v1.wl_output event
    scanner.generate("wp_viewporter", 1); // scale the 1x1 color buffer to border size
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1); // solid-color buffers
    scanner.generate("river_window_manager_v1", 4); // THE protocol that drives us
    scanner.generate("river_xkb_bindings_v1", 2); // keybinds (wired up in M5)
    scanner.generate("river_layer_shell_v1", 1); // border/bar surfaces (M3/M4)

    // Wrap the generated source as an importable module named "wayland".
    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });

    // M4 bar dependencies (see build.zig.zon). pixman/fcft are `lazy` so we ask
    // for them via lazyDependency; mvzr (the regex for status color escapes) is a
    // normal dependency.
    const pixman_mod = b.dependency("pixman", .{}).module("pixman");
    const fcft_mod = b.dependency("fcft", .{}).module("fcft");

    // ----------------------------------------------------------------------
    // 2. The executable
    // ----------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "confluence",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // libc is required because the Wayland bindings call into the C
            // `libwayland-client` library.
            .link_libc = true,
            // Modules importable from src/ via `@import("wayland")`.
            .imports = &.{
                .{ .name = "wayland", .module = wayland_mod },
                .{ .name = "pixman", .module = pixman_mod },
                .{ .name = "fcft", .module = fcft_mod },
            },
        }),
    });

    // The actual C libraries behind the generated bindings.
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    // M4 bar: pixman (compositing) + fcft (font rasterization). Both are found
    // via pkg-config inside the Nix dev shell.
    exe.root_module.linkSystemLibrary("pixman-1", .{});
    exe.root_module.linkSystemLibrary("fcft", .{});
    // TODO(M5 keychords): exe.root_module.linkSystemLibrary("xkbcommon", .{});

    // `zig build` installs this into zig-out/bin/confluence.
    b.installArtifact(exe);

    // `zig build run` — handy for launching inside a nested river session.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and run confluence");
    run_step.dependOn(&run_cmd.step);
}
