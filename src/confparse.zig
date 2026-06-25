// confparse.zig — load an optional runtime config file (ZON) and overlay it onto
// the compiled-in defaults in config.zig.
//
// WHY a file at all: reach is dwl-style (config in code), but to ship as a real
// package the per-user, per-machine bits (monitors, env, window rules, keybinds,
// status blocks) must NOT be baked into the ELF — `/home/<you>/…` paths and your
// monitor layout don't belong in a distro binary. So at startup we look for a
// `config.zon` and overlay whatever it sets on top of config.zig's defaults. No
// file → defaults are used verbatim (the binary works out of the box). This is
// read ONCE at startup, not watched/reloaded (you said you don't need Hyprland-
// style live reload), which keeps it simple and the steady-state zero-overhead.
//
// FORMAT: ZON (Zig Object Notation) — the same syntax config.zig already uses for
// its literals, parsed straight into the same types via std.zon. Every field is
// optional; a file only needs to mention what it overrides. Example:
//
//   .{
//       .mfact = 0.6,
//       .monitors = .{
//           .{ .name = "DP-1", .w = 2560, .h = 1440, .x = 0, .y = 0 },
//       },
//       .binds = .{
//           .{ .mods = .{ .mod4 = true }, .keysym = "Return", .action = .{ .spawn = "kitty" } },
//       },
//   }
//
// LOOKUP ORDER (first that exists wins, dwl/river-style XDG with a system default
// for packaging):
//   $XDG_CONFIG_HOME/reach/config.zon
//   $HOME/.config/reach/config.zon
//   /etc/reach/config.zon          (shipped by the ebuild)

const std = @import("std");
const log = std.log.scoped(.config);

const config = @import("config.zig");

// libc file IO + getenv. This Zig's std.posix is gutted (no open/getenv), and the
// rest of the codebase already calls libc directly (popen in status.zig, setenv in
// main.zig), so we do the same here rather than fight std.fs.
const C = struct {
    const FILE = opaque {};
    extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
    extern fn fclose(stream: *FILE) c_int;
    extern fn fseek(stream: *FILE, off: c_long, whence: c_int) c_int;
    extern fn ftell(stream: *FILE) c_long;
    extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    const SEEK_SET: c_int = 0;
    const SEEK_END: c_int = 2;
};

// ---------------------------------------------------------------------------
// The file schema. Every field is optional (null = "not set, keep the default").
// These mirror config.zig's types so std.zon parses straight into them.
// ---------------------------------------------------------------------------

/// A pixel delta for floating move/resize actions.
pub const DeltaSpec = struct { x: i32 = 0, y: i32 = 0 };

/// What a bind does. Mirrors binding.Action MINUS `enter_submap` (chords are
/// expressed structurally via KeySpec.chord, not as an opaque pointer). binding.zig
/// maps this onto its real Action union.
pub const ActionSpec = union(enum) {
    view: u32,
    toggleview: u32,
    tag: u32,
    toggletag: u32,
    spawn: [:0]const u8,
    quit,
    killclient,
    zoom,
    togglefloating,
    togglefullscreen,
    move: DeltaSpec,
    resize: DeltaSpec,
    focusstack: i32,
    setmfact: f32,
    incnmaster: i32,
    focusmon: i32,
    tagmon: i32,
};

/// One keybinding. `key` is a combo string: zero or more modifiers and the xkb
/// keysym NAME, joined by '+' — e.g. "Super+Shift+q", "Alt+Up", "XF86AudioPlay".
/// Sub-keys of a chord normally carry no modifier, so just "d". Modifier aliases
/// (case-insensitive): Super/Mod/Mod4/Logo/Win/Meta, Alt/Mod1, Ctrl/Control,
/// Shift, Mod3, Mod5. The keysym is the xkb name ("Return", "space", "comma",
/// "bracketleft"; letters/digits are themselves), resolved via
/// xkb_keysym_from_name (binding.zig). A leaf bind sets `action`; a chord leader
/// leaves `action` null and lists its sub-keys in `chord`, which nests to any
/// depth (dwl-style multi-key chords).
pub const KeySpec = struct {
    key: []const u8,
    action: ?ActionSpec = null,
    chord: []const KeySpec = &.{},
};

/// nested `bar` table.
pub const BarSpec = struct {
    font: ?[:0]const u8 = null,
    top: ?bool = null,
    normal_fg: ?u32 = null,
    normal_bg: ?u32 = null,
    select_fg: ?u32 = null,
    select_bg: ?u32 = null,
    status_fg: ?u32 = null,
    status_bg: ?u32 = null,
    delim: ?[]const u8 = null,
    blocks: ?[]const config.bar.Block = null,
};

/// The top-level config.zon document.
pub const FileConfig = struct {
    outer_gap: ?i32 = null,
    inner_gap: ?i32 = null,
    sloppy_focus: ?bool = null,
    repeat_rate: ?i32 = null,
    repeat_delay: ?i32 = null,
    nmaster: ?i32 = null,
    mfact: ?f32 = null,
    float_default_frac_w: ?f32 = null,
    float_default_frac_h: ?f32 = null,
    float_step: ?i32 = null,
    border_active: ?u32 = null,
    border_inactive: ?u32 = null,
    border_thickness: ?i32 = null,
    env: ?[]const [2][:0]const u8 = null,
    autostart: ?[]const [:0]const u8 = null,
    monitors: ?[]const config.Monitor = null,
    rules: ?[]const config.Rule = null,
    bar: ?BarSpec = null,
    binds: ?[]const KeySpec = null,
};

/// Binds parsed from the file, if any. binding.registerForSeat reads this: null
/// means "no file binds, use the compiled-in default keymap"; non-null fully
/// REPLACES the default action/spawn/chord binds (the tag binds are always
/// generated). Lives for the whole process (never freed).
pub var binds: ?[]const KeySpec = null;

/// Locate, read and apply the config file. Call once at startup, before the seat,
/// bar and outputs are configured (so the overlaid values are the ones used). On
/// any problem (no file, parse error) the compiled defaults are left in place and
/// reach keeps running — a bad config never bricks the session.
pub fn load(gpa: std.mem.Allocator) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = locate(&path_buf) orelse {
        log.info("no config.zon found; using built-in defaults", .{});
        return;
    };

    const source = readFileZ(gpa, path) catch |err| {
        log.warn("could not read {s}: {} — using defaults", .{ path, err });
        return;
    };
    // source is never freed: parsed strings/slices below borrow from the ZON AST
    // which we also keep, and the config lives for the whole process anyway.

    // The ZON parser inline-unrolls over every FileConfig field at comptime;
    // each new field costs branches, so lift the quota above the default 1000.
    @setEvalBranchQuota(4000);
    var diag: std.zon.parse.Diagnostics = .{};
    const fc = std.zon.parse.fromSliceAlloc(FileConfig, gpa, source, &diag, .{}) catch |err| {
        log.err("config.zon parse failed ({}):\n{f}", .{ err, diag });
        log.warn("using built-in defaults", .{});
        return;
    };

    overlay(fc);
    log.info("loaded config from {s}", .{path});
}

/// First existing candidate path, written into `buf`. Returns null if none exist.
fn locate(buf: []u8) ?[:0]const u8 {
    if (C.getenv("XDG_CONFIG_HOME")) |x| {
        if (std.mem.span(x).len != 0) {
            if (candidate(buf, &.{ std.mem.span(x), "/reach/config.zon" })) |p| return p;
        }
    }
    if (C.getenv("HOME")) |h| {
        if (candidate(buf, &.{ std.mem.span(h), "/.config/reach/config.zon" })) |p| return p;
    }
    if (candidate(buf, &.{"/etc/reach/config.zon"})) |p| return p;
    return null;
}

/// Join `parts` into `buf` (null-terminated) and return it if that file exists.
fn candidate(buf: []u8, parts: []const []const u8) ?[:0]const u8 {
    var n: usize = 0;
    for (parts) |part| {
        if (n + part.len >= buf.len) return null;
        @memcpy(buf[n .. n + part.len], part);
        n += part.len;
    }
    buf[n] = 0;
    const path = buf[0..n :0];
    const f = C.fopen(path.ptr, "rb") orelse return null;
    _ = C.fclose(f);
    return path;
}

/// Read an entire file into a freshly allocated, null-terminated buffer (the shape
/// std.zon.parse wants).
fn readFileZ(gpa: std.mem.Allocator, path: [:0]const u8) ![:0]const u8 {
    const f = C.fopen(path.ptr, "rb") orelse return error.OpenFailed;
    defer _ = C.fclose(f);

    if (C.fseek(f, 0, C.SEEK_END) != 0) return error.SeekFailed;
    const len = C.ftell(f);
    if (len < 0) return error.TellFailed;
    if (C.fseek(f, 0, C.SEEK_SET) != 0) return error.SeekFailed;

    const size: usize = @intCast(len);
    const buf = try gpa.allocSentinel(u8, size, 0);
    errdefer gpa.free(buf);
    const got = C.fread(buf.ptr, 1, size, f);
    if (got != size) return error.ShortRead;
    return buf;
}

/// Copy every field the file set over the corresponding config.zig default.
fn overlay(fc: FileConfig) void {
    if (fc.outer_gap) |v| config.outer_gap = v;
    if (fc.inner_gap) |v| config.inner_gap = v;
    if (fc.sloppy_focus) |v| config.sloppy_focus = v;
    if (fc.repeat_rate) |v| config.repeat_rate = v;
    if (fc.repeat_delay) |v| config.repeat_delay = v;
    if (fc.nmaster) |v| config.nmaster = v;
    if (fc.mfact) |v| config.mfact = v;
    if (fc.float_default_frac_w) |v| config.float_default_frac_w = v;
    if (fc.float_default_frac_h) |v| config.float_default_frac_h = v;
    if (fc.float_step) |v| config.float_step = v;
    if (fc.border_active) |v| config.border_active = v;
    if (fc.border_inactive) |v| config.border_inactive = v;
    if (fc.border_thickness) |v| config.border_thickness = v;
    if (fc.env) |v| config.env = v;
    if (fc.autostart) |v| config.autostart = v;
    if (fc.monitors) |v| config.monitors = v;
    if (fc.rules) |v| config.rules = v;
    if (fc.binds) |v| binds = v;
    if (fc.bar) |b| {
        if (b.font) |v| config.bar.font = v;
        if (b.top) |v| config.bar.top = v;
        if (b.normal_fg) |v| config.bar.normal_fg = v;
        if (b.normal_bg) |v| config.bar.normal_bg = v;
        if (b.select_fg) |v| config.bar.select_fg = v;
        if (b.select_bg) |v| config.bar.select_bg = v;
        if (b.status_fg) |v| config.bar.status_fg = v;
        if (b.status_bg) |v| config.bar.status_bg = v;
        if (b.delim) |v| config.bar.delim = v;
        if (b.blocks) |v| config.bar.blocks = v;
    }
}
