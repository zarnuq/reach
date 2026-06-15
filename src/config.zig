// config.zig — compile-time configuration.
//
// dwl-style: edit these values and rebuild. A runtime config format can come
// later; for now constants keep things simple and zero-overhead. M3 will add the
// border colors/width here; M4 the bar; M5 the keybindings.

/// Gap (px) between the tiled area and the output edge. 0 = windows extend all
/// the way to the screen edge (dwl/tmux style — no outer border).
pub const outer_gap: i32 = 0;

/// Gap (px) between adjacent tiled windows — the seam the tmux border line fills.
/// Keep this equal to `border_thickness` so the border fills the seam and the
/// vertical/horizontal lines abut at junctions (no cut-off corners). Making it
/// larger than the line would reopen corner gaps until line-extension is added.
pub const inner_gap: i32 = 2;

/// Number of windows in the master stack.
pub const nmaster: i32 = 1;

/// Fraction of the usable width given to the master column when a stack exists.
pub const mfact: f32 = 0.55;

/// Default size (px) for a floating window with no size preference of its own.
pub const float_default_width: i32 = 640;
pub const float_default_height: i32 = 480;

/// tmux border highlight color, 0xRRGGBB (alpha is forced opaque). Drawn in the
/// gutters along the focused window's interior (shared) edges.
pub const border_active: u32 = 0x89b4fa;

/// Thickness (px) of the highlight line. The line is centered within the gutter,
/// so this is independent of `inner_gap` (keep it <= inner_gap).
pub const border_thickness: i32 = 2;

// ---------------------------------------------------------------------------
// Tags (dwl-style workspaces)
// ---------------------------------------------------------------------------
//
// Tags are a bitmask workspace model (like dwl/dwm). Each output views a set of
// tags (`tagset`); each window belongs to a set of tags. A window is visible on
// its output when `window.tags & output.tagset != 0`. The keybinds that drive
// them (MOD+1..9 view, MOD+Shift+1..9 move, MOD+Ctrl+1..9 toggleview, MOD+0 view
// all) are defined in binding.zig, mirroring the user's dwl config.h.

pub const tags = struct {
    /// Number of tags (dwl uses 9).
    pub const count = 9;

    /// Labels shown in the bar's tag area.
    pub const names = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };
};

// ---------------------------------------------------------------------------
// M4 — the baked-in status bar (dwlb-style)
// ---------------------------------------------------------------------------
//
// One bar is drawn at the top of every output. Layout left→right:
//   [layout symbol] [ window title .......... ] [ status text ]
// Colors below mirror the user's dwlb defaults (Catppuccin Mocha). The KEY
// behavior: the bar on the *focused* monitor uses the `select` scheme for its
// title region (mauve), every other monitor uses `normal` (dark) — exactly how
// dwlb reacts to dwl's per-output `active` IPC event, except here Confluence is
// the WM and knows the focused output directly (no IPC needed).

pub const bar = struct {
    /// fontconfig name. fcft resolves this; Nerd Font glyphs work out of the box.
    pub const font = "JetBrainsMono Nerd Font:size=16";

    /// Draw the bar at the top of the output (false = bottom).
    pub const top = true;

    /// Symbol shown for the current layout. Confluence has one layout for now
    /// (master-stack tile), matching dwl's "[]=".
    pub const layout_symbol = "[]=";

    /// Colors as 0xRRGGBBAA.
    ///   normal_* — unfocused monitors / default text.
    ///   select_* — the focused monitor's title region (the "this monitor is
    ///              active" highlight).
    ///   status_* — the someblocks status text on the right.
    pub const normal_fg: u32 = 0x7f849cff;
    pub const normal_bg: u32 = 0x1e1e2eff;
    pub const select_fg: u32 = 0xffffffff;
    pub const select_bg: u32 = 0xcba6f7ff;
    pub const status_fg: u32 = 0x7f849cff;
    pub const status_bg: u32 = 0x1e1e2eff;

    // -----------------------------------------------------------------------
    // Status blocks (someblocks baked in)
    // -----------------------------------------------------------------------
    //
    // Confluence runs these itself — no external someblocks process or fifo.
    // Each block is `icon ++ first line of <command> stdout`, and the blocks are
    // joined left→right by `delim`. Semantics match suckless someblocks:
    //   interval — re-run every N seconds (0 = never on a timer).
    //   signal   — also re-run when Confluence receives SIGRTMIN+<signal>
    //              (e.g. `kill -35 $(pidof confluence)` refreshes signal 1).
    // Commands run via `/bin/sh -c`, so `$HOME`, pipes, etc. all work.

    pub const Block = struct {
        icon: []const u8,
        command: []const u8,
        interval: u32,
        signal: u8,
    };

    /// Separator drawn between adjacent blocks.
    pub const delim = "|";

    /// Ported from the user's ~/.local/src/someblocks/blocks.h.
    pub const blocks = [_]Block{
        .{ .icon = "", .command = "~/.local/src/someblocks/blocks/ip.sh", .interval = 30, .signal = 0 },
        .{ .icon = "", .command = "$HOME/.local/src/someblocks/blocks/audio.sh", .interval = 60, .signal = 1 },
        .{ .icon = "", .command = "pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -o '[0-9]\\+%' | head -1", .interval = 1, .signal = 1 },
        .{ .icon = "", .command = "$HOME/.local/src/someblocks/blocks/mic.sh", .interval = 1, .signal = 2 },
        .{ .icon = "", .command = "date '+%a %m/%d %I:%M %p'", .interval = 1, .signal = 0 },
        .{ .icon = "", .command = "$HOME/.local/src/someblocks/blocks/battery.sh", .interval = 30, .signal = 0 },
    };
};
