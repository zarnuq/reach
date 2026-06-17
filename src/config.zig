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

/// Focus follows the mouse (dwl's `sloppyfocus`): moving the pointer onto a
/// window focuses it and selects its monitor — so the bar highlight and tag keys
/// track the monitor the mouse is over. false = focus changes only on click.
pub const sloppy_focus = true;

/// Keyboard auto-repeat (dwl's `repeat_rate` / `repeat_delay`). In river's
/// non-monolithic split the compositor owns input, so reach applies these to every
/// keyboard via the river-input-management protocol (see inputconfig.zig) rather
/// than configuring the keyboard directly like dwl does.
///   repeat_rate  — repeats per second once repeating starts (0 disables repeat).
///   repeat_delay — ms held before repeating begins.
pub const repeat_rate: i32 = 50;
pub const repeat_delay: i32 = 300;

// ---------------------------------------------------------------------------
// Environment (dwl `setenv` / setupenv)
// ---------------------------------------------------------------------------
//
// Each entry is applied with setenv(key, val, overwrite=1) right after reach
// connects to the Wayland display, before autostart. Processes spawned by
// reach (autostart, keybinds, runsvdir) all inherit these, fixing services
// that need WAYLAND_DISPLAY, QT/GTK hints, etc.

pub const env = [_][2][:0]const u8{

    .{ "PATH",  "/usr/bin:/usr/sbin:/bin:/sbin:$HOME/.local/bin:/usr/local/bin:$HOME/.config/emacs/bin:/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin" },
    .{ "XDG_CURRENT_DESKTOP",  "river" },
    .{ "SVDIR",                "/home/miles/.local/sv" },
    .{ "XDG_SESSION_TYPE",     "wayland" },
    // WAYLAND_DISPLAY must NOT be set here — river exports the correct socket
    // name when it spawns reach; hardcoding it breaks children if river chose
    // a name other than wayland-0.
    .{ "DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/1000/bus" },

    .{ "QT_QPA_PLATFORMTHEME", "qt6ct" },
    .{ "QT_QPA_PLATFORM",      "wayland" },
    .{ "QT_STYLE_OVERRIDE",    "kvantum" },

    .{ "JAVA_HOME",            "/usr/lib/jvm/java-21-openjdk" },
    .{ "_JAVA_OPTIONS",        "-Djava.util.prefs.userRoot=/home/miles/.config/java" },

    .{ "XDG_DATA_DIRS",        "/home/miles/.nix-profile/share:/usr/local/share:/usr/share" },

    .{ "CUDA_CACHE_PATH",      "/home/miles/.cache/nv" },
    .{ "LIBVA_DRIVER_NAME",    "nvidia" },
    .{ "NVD_BACKEND",          "direct" },

    .{ "GTK2_RC_FILES",        "/home/miles/.config/gtk-2.0/gtkrc" },

    .{ "CARGO_HOME",           "/home/miles/.local/share/cargo" },
    .{ "RUSTUP_HOME",          "/home/miles/.local/share/rustup" },
    .{ "GOPATH",               "/home/miles/.local/share/go" },
    .{ "GNUPGHOME",            "/home/miles/.local/share/gnupg" },
    .{ "NPM_CONFIG_PREFIX",    "/home/miles/.local/share/npm" },
    .{ "NPM_CONFIG_CACHE",     "/home/miles/.cache/npm" },
    .{ "BUN_DIR",              "/home/miles/.local/share/bun" },
    .{ "WINEPREFIX",           "/home/miles/.local/share/wine" },
    .{ "MINECRAFT_HOME",       "/home/miles/.local/share/minecraft" },
    .{ "SQLITE_HISTORY",       "/home/miles/.local/state/sqlite_history" },
    .{ "CLAUDE_CONFIG_DIR",    "/home/miles/.cache/claude" },
    .{ "W3M_DIR",              "/home/miles/.local/share/w3m" },
};

/// Commands run once at startup (dwl's `autostart[]`). Each is passed to
/// `/bin/sh -c`, so `$HOME`, pipes, and `&` all work. The default mirrors the
/// user's dwl setup with a single session script that brings up the runit user
/// services (runsvdir → emacs daemon, mpd, pipewire, …), the notification daemon,
/// clipboard watchers, wallpaper, eww, etc. The reach script intentionally
/// OMITS dwlb/someblocks — the status bar is baked into reach itself.
pub const autostart = [_][:0]const u8{
    "$HOME/.config/reach/autostart.sh",
};

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

/// Ported from the user's dwl config.h `monrules` (positions/transforms as-is;
/// modes selected by resolution rather than dwl's mode index).
// NOTE: array ORDER defines monitor numbering / focusmon (MOD+,/.) navigation —
// reach sorts the live outputs into this order (see output.zig reorder). Desired
// cycle: DP-3 → DP-2 → DP-1, with the laptop panel last.
pub const monitors = [_]Monitor{
    .{ .name = "DP-3", .w = 3440, .h = 1440, .x = 0, .y = 0, .transform = .rotate_180 },
    .{ .name = "DP-2", .w = 3440, .h = 1440, .x = 0, .y = 1440 },
    .{ .name = "DP-1", .w = 1920, .h = 1080, .refresh = 165000, .x = 3440, .y = 1440, .transform = .rotate_270 },
    .{ .name = "eDP-1", .w = 1920, .h = 1200 }, // laptop panel, auto-placed
};

/// Number of windows in the master stack.
pub const nmaster: i32 = 1;

/// Fraction of the usable width given to the master column when a stack exists.
pub const mfact: f32 = 0.55;

/// Default size for a floating window with no size preference of its own, as a
/// fraction of its output (centered). Fixed-size dialogs keep their own size; this
/// only applies when the window has no max-size hint. Replaces the old fixed
/// 640x480, which felt cramped on large monitors.
pub const float_default_frac_w: f32 = 0.6;
pub const float_default_frac_h: f32 = 0.65;

/// Step (px) for keyboard move/resize of a floating window: MOD+arrows move it,
/// MOD+Shift+arrows grow/shrink it.
pub const float_step: i32 = 40;

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

/// Ported from the user's dwl config.h `rules[]` (all app_id-based; tags use the
/// same `1 << n` indices). `kitty --class float` → app_id "float", so the MOD+
/// BackSpace / clipfzf / killfzf floats match the `^float` rule.
pub const rules = [_]Rule{
    .{ .app_id = "rmpc", .monitor = 2 }, // DP-1 (index 2 in the monitors table above)
    .{ .app_id = "zen", .tags = 1 << 2, .switchtotag = true },
    .{ .app_id = "mpv", .tags = 1 << 0, .switchtotag = true },
    .{ .app_id = "^steam", .tags = 1 << 4 },
    .{ .app_id = "^float", .floating = true, .x = 0.25, .y = 0.25, .w = 0.5, .h = 0.5 },
    .{ .app_id = "pavucontrol", .floating = true, .x = 0.25, .y = 0.25, .w = 0.5, .h = 0.5 },
};

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
// dwlb reacts to dwl's per-output `active` IPC event, except here reach is
// the WM and knows the focused output directly (no IPC needed).

pub const bar = struct {
    /// fontconfig name. fcft resolves this; Nerd Font glyphs work out of the box.
    pub const font = "JetBrainsMono Nerd Font:size=15";

    /// Draw the bar at the top of the output (false = bottom).
    pub const top = true;

    /// Symbol shown for the current layout. reach has one layout for now
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
    pub const delim = "|";

    /// Ported from the user's ~/.local/src/someblocks/blocks.h.
    pub const blocks = [_]Block{
        .{ .icon = "", .command = "$XDG_CONFIG_HOME/reach/blocks/ip.sh", .interval = 30, .signal = 0 },
        .{ .icon = "", .command = "$XDG_CONFIG_HOME/reach/blocks/audio.sh", .interval = 60, .signal = 1 },
        .{ .icon = "", .command = "pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -o '[0-9]\\+%' | head -1", .interval = 1, .signal = 1 },
        .{ .icon = "", .command = "$XDG_CONFIG_HOME/reach/blocks/mic.sh", .interval = 1, .signal = 2 },
        .{ .icon = "", .command = "date '+%a %m/%d %I:%M %p'", .interval = 1, .signal = 0 },
        .{ .icon = "", .command = "$XDG_CONFIG_HOME/reach/blocks/battery.sh", .interval = 30, .signal = 0 },
    };
};
