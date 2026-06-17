# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

# Tell zig.eclass which Zig slot to build with. This pulls dev-lang/zig:0.16
# into BDEPEND for us (and virtual/pkgconfig).
ZIG_SLOT="0.16"

inherit git-r3 zig

DESCRIPTION="A minimal tiling window manager for the river compositor"
HOMEPAGE="https://github.com/YOURUSER/reach"

# Live ebuild: build straight from the GitHub repo. git-r3 clones over https,
# so no local-path permission concerns. Replace YOURUSER with your handle.
EGIT_REPO_URI="https://github.com/YOURUSER/reach.git"
# EGIT_BRANCH="main"   # set if your default branch isn't the repo default

# FIXME: set to reach's actual license once you add a LICENSE file. kwm (the
# reference it cribs from) is GPL-3.0; pick what matches your source headers.
LICENSE="GPL-3.0-or-later"
SLOT="0"
# Live ebuilds carry no KEYWORDS on purpose -- accepted via package.accept_keywords.

# System libraries the build links through pkg-config (build.zig
# linkSystemLibrary calls):
#   wayland-client -> dev-libs/wayland
#   pixman-1       -> x11-libs/pixman
#   fcft           -> gui-libs/fcft  (drags in freetype + fontconfig at runtime)
RDEPEND="
	dev-libs/wayland
	x11-libs/pixman
	gui-libs/fcft
"
DEPEND="${RDEPEND}"

# Build-time only:
#   wayland-scanner   -> zig-wayland's Scanner shells out to it
#   wayland-protocols -> the stable/staging XML the scanner reads at build time
# (dev-lang/zig:0.16 and virtual/pkgconfig come from zig.eclass.)
BDEPEND="
	dev-util/wayland-scanner
	dev-libs/wayland-protocols
"
# NOTE: add x11-libs/libxkbcommon to {R,}DEPEND once M5 keychords link it
# (build.zig:113 is still TODO -- the current tree doesn't link xkbcommon).

src_unpack() {
	# 1. Clone reach into ${S} (network allowed: this is a live ebuild).
	git-r3_src_unpack
	# 2. Fetch the build.zig.zon deps (zig-wayland / zig-pixman / zig-fcft)
	#    over the network now, exactly like `nix develop` does. src_prepare
	#    then switches the build to offline --system mode.
	zig_live_src_unpack
}

# src_prepare / src_configure / src_compile / src_install are all exported by
# zig.eclass. The default src_install runs `zig build install` with the right
# prefix, so b.installArtifact(exe) lands reach in /usr/bin. Nothing to add
# unless reach grows extra install steps (assets, man pages, etc.).
