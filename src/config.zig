// config.zig — configuration: compiled-in DEFAULTS, optionally overlaid at startup.
//
// dwl-style values live here, but most are now `pub var` rather than `pub const`:
// they hold the compiled-in DEFAULT, and `confparse.zig` overlays any field the
// user set in `config.zon` (see confparse.load, called once at startup before the
// seat/bar/outputs are configured). With no config file, these defaults are used
// verbatim — so the binary works out of the box and nothing user-specific is baked
// into the ELF (important for packaging). Tags and the type definitions below stay
// `const`: tag count feeds comptime sizing and the types are, well, types.
// Keybindings live in binding.zig; their defaults are likewise overridable via the
// `binds` array in config.zon.

/// Gap (px) between the tiled area and the output edge. 0 = windows extend all
/// the way to the screen edge (dwl/tmux style — no outer border).
pub var outer_gap: i32 = 0;

/// Gap (px) between adjacent tiled windows — the seam the tmux border line fills.
/// Keep this equal to `border_thickness` so the border fills the seam and the
/// vertical/horizontal lines abut at junctions (no cut-off corners). Making it
/// larger than the line would reopen corner gaps until line-extension is added.
pub var inner_gap: i32 = 2;

/// Focus follows the mouse (dwl's `sloppyfocus`): moving the pointer onto a
/// window focuses it and selects its monitor — so the bar highlight and tag keys
/// track the monitor the mouse is over. false = focus changes only on click.
pub var sloppy_focus: bool = true;

/// Keyboard auto-repeat (dwl's `repeat_rate` / `repeat_delay`). In river's
/// non-monolithic split the compositor owns input, so reach applies these to every
/// keyboard via the river-input-management protocol (see inputconfig.zig) rather
/// than configuring the keyboard directly like dwl does.
///   repeat_rate  — repeats per second once repeating starts (0 disables repeat).
///   repeat_delay — ms held before repeating begins.
pub var repeat_rate: i32 = 50;
pub var repeat_delay: i32 = 300;

// ---------------------------------------------------------------------------
// Environment (dwl `setenv` / setupenv)
// ---------------------------------------------------------------------------
//
// Each entry is applied with setenv(key, val, overwrite=1) right after reach
// connects to the Wayland display, before autostart. Processes spawned by
// reach (autostart, keybinds, runsvdir) all inherit these, fixing services
// that need WAYLAND_DISPLAY, QT/GTK hints, etc.

// Minimal generic default: just identify the session as river/wayland. Anything
// machine-specific (PATH, toolkit themes, service dirs, …) belongs in config.zon's
// `env`. Never set WAYLAND_DISPLAY here — river exports the correct socket name to
// reach, and hardcoding it breaks children if river chose a name other than
// wayland-0.
pub var env: []const [2][:0]const u8 = &[_][2][:0]const u8{
    .{ "XDG_CURRENT_DESKTOP", "river" },
    .{ "XDG_SESSION_TYPE", "wayland" },
};

/// Commands run once at startup (dwl's `autostart[]`). Each is passed to
/// `/bin/sh -c`, so `$HOME`, pipes, and `&` all work. Empty by default — set your
/// session bringup (services, notification daemon, wallpaper, …) in config.zon's
/// `autostart`, conventionally a single `$HOME/.config/reach/autostart.sh`.
pub var autostart: []const [:0]const u8 = &[_][:0]const u8{};

// ---------------------------------------------------------------------------
// Monitor configuration (dwl `monrules`)
// ---------------------------------------------------------------------------
//
// Applied once at startup via the wlr-output-management protocol (see
// outputconfig.zig) — river itself doesn't let the WM set modes through the
// window-management protocol. Matched by output name; unmatched outputs are left
// at their compositor defaults. Adaptive sync is intentionally NOT handled.

/// Output transform (rotation/reflection), mirroring wl_output.transform.
pub const Transform = enum {
    normal,
    rotate_90,
    rotate_180,
    rotate_270,
    flipped,
    flipped_90,
    flipped_180,
    flipped_270,
};

pub const Monitor = struct {
    /// Output name to match (e.g. "DP-1", "eDP-1"), exactly as the compositor
    /// reports it.
    name: []const u8,
    /// Desired mode resolution. 0×0 = leave the compositor's preferred mode.
    w: i32 = 0,
    h: i32 = 0,
    /// Refresh in mHz (e.g. 144000 for 144 Hz). 0 = pick the highest refresh
    /// available at w×h (or the preferred mode).
    refresh: i32 = 0,
    /// Position in the global layout. (-1, -1) = let the compositor auto-place
    /// (matches dwl's `-1` sentinel).
    x: i32 = -1,
    y: i32 = -1,
    /// Output scale (1.0 = unscaled). Only sent when != 1.0.
    scale: f64 = 1.0,
    transform: Transform = .normal,
};

/// Empty by default: every output keeps the compositor's preferred mode and is
/// auto-placed. Declare your displays in config.zon's `monitors` (matched by
/// connector name). NOTE: there, array ORDER defines monitor numbering / focusmon
/// (Super+,/.) navigation — reach sorts live outputs into that order (output.zig
/// reorder).
pub var monitors: []const Monitor = &[_]Monitor{};

/// Number of windows in the master stack.
pub var nmaster: i32 = 1;

/// Fraction of the usable width given to the master column when a stack exists.
pub var mfact: f32 = 0.55;

/// Default size for a floating window with no size preference of its own, as a
/// fraction of its output (centered). Fixed-size dialogs keep their own size; this
/// only applies when the window has no max-size hint. Replaces the old fixed
/// 640x480, which felt cramped on large monitors.
pub var float_default_frac_w: f32 = 0.6;
pub var float_default_frac_h: f32 = 0.65;

/// Step (px) for keyboard move/resize of a floating window: MOD+arrows move it,
/// MOD+Shift+arrows grow/shrink it.
pub var float_step: i32 = 40;

// ---------------------------------------------------------------------------
// Window rules (dwl `rules[]`)
// ---------------------------------------------------------------------------
//
// When a window's app_id (or title) becomes known, the first... actually ALL
// matching rules are applied (dwl accumulates). A rule can force the window
// floating, move it to a tag set, switch the output to view that tag, send it to
// a specific monitor, and give a floating geometry as fractions of the output.
//
// Matching mirrors dwl's POSIX-regex feel without a regex dep:
//   pattern "^foo"  → app_id/title must START WITH "foo"  (anchored)
//   pattern "foo"   → app_id/title CONTAINS "foo"         (substring)
// Leave `app_id`/`title` null to not constrain on that field.

pub const Rule = struct {
    app_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// Tag bitmask to put the window on (0 = leave on the default/current tags).
    tags: u32 = 0,
    /// Also switch the target output to view `tags` (dwl switchtotag).
    switchtotag: bool = false,
    /// Force the window floating (never forces *non*-floating).
    floating: bool = false,
    /// Send the window to this output index (−1 = leave where it spawned).
    monitor: i32 = -1,
    /// Floating geometry as fractions of the output (all 0 = center at default
    /// size). Only used when the window ends up floating.
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// Empty by default. Define your own in config.zon's `rules` (app_id/title based;
/// tags use `1 << n` indices).
pub var rules: []const Rule = &[_]Rule{};

/// tmux border highlight color, 0xRRGGBB (alpha is forced opaque). Drawn in the
/// gutters along the focused window's interior (shared) edges.
pub var border_active: u32 = 0x89b4fa;

/// Solid fill color for every *inactive* gutter (0xRRGGBB, forced opaque). The
/// inner gaps between tiled windows would otherwise show the wallpaper through
/// the seam; filling them gives inactive windows a solid border. The focused
/// window's `border_active` highlight is drawn on top of this. Catppuccin mantle.
pub var border_inactive: u32 = 0x181825;

/// Thickness (px) of the highlight line. The line is centered within the gutter,
/// so this is independent of `inner_gap` (keep it <= inner_gap).
pub var border_thickness: i32 = 2;

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
// The baked-in status bar (dwlb-style)
// ---------------------------------------------------------------------------
//
// One bar is drawn at the top of every output. Layout left→right:
//   [layout symbol] [ window title .......... ] [ status text ]
// Colors below mirror the user's dwlb defaults (Catppuccin Mocha). The KEY
// behavior: the bar on the *focused* monitor uses the `select` scheme for its
// title region (mauve), every other monitor uses `normal` (dark) — exactly how
// dwlb reacts to dwl's per-output `active` IPC event, except here reach is
// the WM and knows the focused output directly (no IPC needed).

pub const bar = struct {
    /// fontconfig name. fcft resolves this; a generic monospace is the default so
    /// the bar renders without assuming a specific (e.g. Nerd) font is installed.
    pub var font: [:0]const u8 = "monospace:size=12";

    /// Draw the bar at the top of the output (false = bottom).
    pub var top: bool = true;

    /// Colors as 0xRRGGBBAA.
    ///   normal_* — unfocused monitors / default text.
    ///   select_* — the focused monitor's title region (the "this monitor is
    ///              active" highlight).
    ///   status_* — the someblocks status text on the right.
    pub var normal_fg: u32 = 0x7f849cff;
    pub var normal_bg: u32 = 0x1e1e2eff;
    pub var select_fg: u32 = 0xffffffff;
    pub var select_bg: u32 = 0xcba6f7ff;
    pub var status_fg: u32 = 0x7f849cff;
    pub var status_bg: u32 = 0x1e1e2eff;

    // -----------------------------------------------------------------------
    // Status blocks (someblocks baked in)
    // -----------------------------------------------------------------------
    //
    // reach runs these itself — no external someblocks process or fifo.
    // Each block is `icon ++ first line of <command> stdout`, and the blocks are
    // joined left→right by `delim`. Semantics match suckless someblocks:
    //   interval — re-run every N seconds (0 = never on a timer).
    //   signal   — also re-run when reach receives SIGRTMIN+<signal>
    //              (e.g. `kill -35 $(pidof reach)` refreshes signal 1).
    // Commands run via `/bin/sh -c`, so `$HOME`, pipes, etc. all work.

    pub const Block = struct {
        icon: []const u8,
        command: []const u8,
        interval: u32,
        signal: u8,
    };

    /// Separator drawn between adjacent blocks.
    pub var delim: []const u8 = "|";

    /// Ported from the user's ~/.local/src/someblocks/blocks.h.
    /// Minimal default: just a clock. Add your own blocks in config.zon's
    /// `bar.blocks` (each is icon ++ first line of the command's stdout).
    pub var blocks: []const Block = &[_]Block{
        .{ .icon = "", .command = "date '+%a %m/%d %I:%M %p'", .interval = 1, .signal = 0 },
    };
};
