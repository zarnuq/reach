// config.zig — configuration: compiled-in DEFAULTS, optionally overlaid at startup.
//
// dwl-style values live here, but most are now `pub var` rather than `pub const`:
// they hold the compiled-in DEFAULT, and `confparse.zig` overlays any field the
// user set in `config.zon` (see confparse.load, called once at startup before the
// seat/bar/outputs are configured). With no config file, these defaults are used
// verbatim — so the binary works out of the box and nothing user-specific is baked
// into the ELF (important for packaging). Desktops and the type definitions below stay
// `const`: the desktop count feeds comptime sizing and the types are, well, types.
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
/// window focuses it and selects its monitor — so the bar highlight and desktop keys
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
// Cursor
// ---------------------------------------------------------------------------
//
// river renders the cursor; the WM picks its theme/size via
// river_seat_v1.set_xcursor_theme. reach also exports XCURSOR_THEME/XCURSOR_SIZE
// to children (the protocol suggests this) — without them libXcursor derives a
// size from the X screen height, which on a multi-monitor Xwayland root is huge,
// giving X11 windows a wildly oversized pointer.

pub const cursor = struct {
    /// Theme name under ~/.local/share/icons or /usr/share/icons. "default"
    /// follows that theme's `Inherits` chain, i.e. whatever dconf/nwg-look set.
    pub var theme: [:0]const u8 = "default";

    /// Resting size in px; also the exported XCURSOR_SIZE.
    pub var size: u32 = 24;

    /// Export XCURSOR_THEME/XCURSOR_SIZE to spawned processes. Only affects
    /// what reach starts — shells predating the session keep their old env.
    pub var export_env: bool = true;

    /// Shake to find: scrub the mouse, the cursor grows. Two knobs — how long
    /// you must shake, and how fast it grows. Everything else (the detector
    /// itself, max size, shrink and hold timing) is derived in shake.zig.
    pub const shake = struct {
        /// When false, /dev/input is never opened and this costs nothing.
        pub var enabled: bool = false;

        /// How long (ms) you have to keep shaking before the cursor starts
        /// growing. This is the knob for how easy it is to set off: it is what
        /// separates a real shake from an ordinary overshoot-and-correct, which
        /// only looks like one for a moment. Lower = twitchier; 0 = grow the
        /// instant the motion qualifies.
        pub var delay: u32 = 150;

        /// How fast it grows, in cursor px per second. It shrinks back at about
        /// a third of this. 600 goes from `size` to full in roughly 120 ms.
        pub var speed: f32 = 600.0;
    };
};

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
// floating, move it to a desktop, switch the output to view that desktop, send it to
// a specific monitor, and give a floating geometry as fractions of the output.
//
// Matching mirrors dwl's POSIX-regex feel without a regex dep:
//   pattern "^foo"  → app_id/title must START WITH "foo"  (anchored)
//   pattern "foo"   → app_id/title CONTAINS "foo"         (substring)
// Leave `app_id`/`title` null to not constrain on that field.

pub const Rule = struct {
    app_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// Desktop to put the window on, 1-based (0 = leave it on the current one).
    desktop: u32 = 0,
    /// Also switch the target output to view `desktop` (dwl switchtotag).
    switchto: bool = false,
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
/// `desktop` is a 1-based desktop number).
pub var rules: []const Rule = &[_]Rule{};

/// tmux border highlight color, 0xRRGGBB (alpha is forced opaque). Each face the
/// focused window shares with a neighbour carries one line, laid just outside that
/// window's own edge; this is the color of the stretch running alongside it.
pub var border_active: u32 = 0x89b4fa;

/// Color of the REST of that same line — the stretch beyond the focused window,
/// collinear with the active part and the same thickness (0xRRGGBB, alpha forced
/// opaque). In the two-pane cases the cut lands at the midpoint, so the divider
/// reads half active / half inactive. Catppuccin surface1: muted enough to read as
/// the quieter half.
pub var border_inactive: u32 = 0x45475a;

/// Thickness (px) of the seam line. The line sits entirely OUTSIDE the focused
/// window, flush against its edge, so no pixel of the window is ever covered — at
/// any `inner_gap`. Set `inner_gap` to at least this value to keep the line inside
/// the gutter; below that it reaches over the neighbour, the way a tmux pane border
/// occupies its own column between two panes.
pub var border_thickness: i32 = 2;

// ---------------------------------------------------------------------------
// Virtual desktops
// ---------------------------------------------------------------------------
//
// Each output views exactly ONE desktop (`output.desktop`); each window lives on
// exactly ONE desktop (`window.desktop`). A window is visible on its output when
// `window.desktop == output.desktop`.
//
// Desktop numbers are 1-BASED throughout — in the config, in the keybinds, and
// internally — so `.desktop = 3` is the desktop you reach with MOD+3 and the one
// the bar labels "3". 0 is never a valid desktop; it is the "unset" sentinel for
// `Rule.desktop`. The only place the offset shows up is indexing `names`, which
// is `names[desktop - 1]`.
//
// This replaces the dwm/dwl bitmask tag model. A window can no longer be in two
// places at once, and an output can no longer view two desktops at once — which
// is what makes an empty view unrepresentable rather than something the toggle
// actions had to guard against.

pub const desktops = struct {
    /// Number of desktops. Bound above by 9, since the binds are MOD+1..9.
    pub const count = 9;

    /// Labels shown in the bar. `names[d - 1]` is the label for desktop `d`.
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
