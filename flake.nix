{
  # Dev environment for reach.
  #
  # WHY THIS EXISTS: Zig itself comes from Nix (home-manager), so the compiler
  # links against Nix's glibc and uses Nix's dynamic loader. If the build then
  # links the *system* libwayland-client (/usr/lib, built against the host
  # distro's glibc), the resulting binary mixes two glibc worlds and segfaults
  # inside libwayland on connect. Building inside this shell makes pkg-config
  # point at Nix's wayland/xkbcommon, so everything lives in one coherent Nix
  # glibc universe.
  #
  # Usage:
  #   nix develop          # drop into the shell
  #   zig build            # build against the Nix libraries
  #   zig build run        # or run it
  #
  # (With direnv: `echo "use flake" > .envrc && direnv allow` to auto-enter.)

  description = "reach — a minimal tiling window manager for the river compositor";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        # Build inputs:
        packages = with pkgs; [
          zig_0_16 # the compiler (0.16.0, matches build.zig.zon)

          # Wayland toolchain. zig-wayland's Scanner shells out to wayland-scanner
          # and reads protocol XML from wayland-protocols' data dir; the runtime
          # links libwayland-client from `wayland`. pkg-config is how zig and the
          # scanner discover all of them.
          wayland # libwayland-client (runtime)
          wayland-scanner # the code generator zig-wayland drives
          wayland-protocols # core + stable/staging protocol XML
          pkg-config

          libxkbcommon # keysym constants for keybindings (wired up in M5)

          # M4 bar: software rendering + font stack. zig-pixman / zig-fcft link
          # `pixman-1` and `fcft` via pkg-config; fcft pulls in freetype/fontconfig
          # at runtime to find and rasterize "JetBrainsMono Nerd Font".
          pixman
          fcft
          freetype
          fontconfig

          river # the compositor — for `river -c ./zig-out/bin/reach` testing
        ];
      };
    };
}
