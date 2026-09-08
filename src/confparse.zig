// confparse.zig — load an optional runtime config file (ZON) and overlay it onto
// the compiled-in defaults in config.zig.
//
// WHY a file at all: reach is dwl-style (config in code), but to ship as a real
// package the per-user, per-machine bits (monitors, env, window rules, keybinds,
// status blocks) must NOT be baked into the ELF — `/home/<you>/…` paths and your
// monitor layout don't belong in a distro binary. So at startup we look for a
// `config.zon` and overlay whatever it sets on top of config.zig's defaults. No
// file → defaults are used verbatim (the binary works out of the box).
//
// RELOAD: the file is re-read on demand (SIGHUP, or a `reload` keybind) — see
// reload.zig for the ordering. Each load parses into its OWN arena; the previous
// arena is freed only once every subsystem has rebound to the new one, because
// config slices (rules, blocks, spawn strings, monitors) borrow straight from the
// parsed AST. Reload is IDEMPOTENT: `defaults` is snapshotted before the first
// overlay, and re-applied ahead of every later one, so deleting a field from
// config.zon reverts it to the compiled-in value instead of stranding the old
// override.
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

/// What a bind does. Mirrors action.Action; chords are expressed structurally via
/// KeySpec.chord and remain an implementation detail of binding.zig.
pub const ActionSpec = union(enum) {
    view: u32,
    send: u32,
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
    sendmon: i32,
    reload,
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

/// nested `cursor.shake` table.
pub const ShakeSpec = struct {
    enabled: ?bool = null,
    delay: ?u32 = null,
    command: ?[:0]const u8 = null,
};

/// nested `cursor` table.
pub const CursorSpec = struct {
    theme: ?[:0]const u8 = null,
    size: ?u32 = null,
    export_env: ?bool = null,
    shake: ?ShakeSpec = null,
};

/// nested `bar` table.
pub const BarSpec = struct {
    enabled: ?bool = null,
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
    cursor: ?CursorSpec = null,
    bar: ?BarSpec = null,
    binds: ?[]const KeySpec = null,
};

/// Binds parsed from the file, if any. binding.registerForSeat reads this: null
/// means "no file binds, use the compiled-in default keymap"; non-null fully
/// REPLACES the default action/spawn/chord binds (the desktop binds are always
/// generated). Owned by the current generation's arena (see `arena`).
pub var binds: ?[]const KeySpec = null;

/// The arena owning the CURRENTLY LIVE parsed config — every string and slice in
/// config.zig points into it. Replaced wholesale on reload; the outgoing arena is
/// destroyed by `release`, never before the new one is committed.
var arena: ?*std.heap.ArenaAllocator = null;

/// config.zig's compiled-in values, captured before the first overlay. Re-applied
/// ahead of every reload so a field dropped from config.zon returns to its default
/// rather than keeping the previous run's override. Every field is non-null after
/// `snapshotDefaults`, so `overlay(defaults)` is a full reset.
var defaults: FileConfig = .{};
var defaults_taken = false;

/// A parsed-but-not-yet-applied config plus the arena backing it.
pub const Staged = struct {
    fc: FileConfig,
    arena: *std.heap.ArenaAllocator,
};

/// Locate, read and apply the config file. Call once at startup, before the seat,
/// bar and outputs are configured (so the overlaid values are the ones used). On
/// any problem (no file, parse error) the compiled defaults are left in place and
/// reach keeps running — a bad config never bricks the session.
pub fn load(gpa: std.mem.Allocator) void {
    const staged = stage(gpa) orelse return;
    // First load: there is no previous generation to displace.
    std.debug.assert(commit(staged) == null);
}

/// Read and parse config.zon into a FRESH arena, without touching any live state.
/// Returns null (having logged why) if there is no file or it doesn't parse — the
/// caller then keeps running on the config it already has, which is what makes a
/// typo in config.zon survivable during a reload.
pub fn stage(gpa: std.mem.Allocator) ?Staged {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = locate(&path_buf) orelse {
        // At startup this means "run on the compiled-in defaults". On a reload it
        // means the file went away, and we keep what is already loaded rather than
        // yanking the session back to defaults over a missing file.
        log.info("no config.zon found; keeping built-in defaults", .{});
        return null;
    };

    const ar = gpa.create(std.heap.ArenaAllocator) catch return null;
    ar.* = .init(gpa);
    // Everything below allocates from the arena, so one deinit reclaims the file
    // buffer and the whole parsed AST together.
    const aa = ar.allocator();

    const source = readFileZ(aa, path) catch |err| {
        log.warn("could not read {s}: {} — keeping current config", .{ path, err });
        ar.deinit();
        gpa.destroy(ar);
        return null;
    };

    // The ZON parser inline-unrolls over every FileConfig field at comptime;
    // each new field costs branches, so lift the quota above the default 1000.
    @setEvalBranchQuota(4000);
    var diag: std.zon.parse.Diagnostics = .{};
    const fc = std.zon.parse.fromSliceAlloc(FileConfig, aa, source, &diag, .{}) catch |err| {
        log.err("config.zon parse failed ({}):\n{f}", .{ err, diag });
        log.warn("keeping current config", .{});
        ar.deinit();
        gpa.destroy(ar);
        return null;
    };

    log.info("parsed config from {s}", .{path});
    return .{ .fc = fc, .arena = ar };
}

/// Point config.zig at `staged`, returning the arena it displaces (null on the
/// first load). The caller MUST keep the returned arena alive until every
/// subsystem holding borrowed slices — bindings above all — has been rebuilt, then
/// hand it to `release`.
pub fn commit(staged: Staged) ?*std.heap.ArenaAllocator {
    // Idempotent, and this is the only place an overlay can happen — so taking the
    // snapshot here means the defaults are always captured pristine, with no
    // ordering requirement on the caller.
    snapshotDefaults();

    const previous = arena;
    arena = staged.arena;

    // Reset first, so a field the file no longer mentions falls back to its
    // compiled-in default instead of keeping the outgoing generation's value.
    // `binds` needs doing by hand: overlay() skips nulls (that is how "the file
    // didn't mention this" is encoded), but null is precisely the reset value
    // here — it means "fall back to the compiled-in keymap".
    binds = null;
    if (defaults_taken) overlay(defaults);
    overlay(staged.fc);
    return previous;
}

/// Free a generation displaced by `commit`. Only safe once nothing points into it.
pub fn release(gpa: std.mem.Allocator, old: ?*std.heap.ArenaAllocator) void {
    const ar = old orelse return;
    ar.deinit();
    gpa.destroy(ar);
}

/// Capture config.zig's compiled-in values into `defaults` (once, on the first
/// commit, before anything overlays them). Field names in the *Spec structs mirror config.zig's namespaces
/// exactly, so the flat scalars copy across by reflection; the nested tables and
/// `binds` (which has no config.zig counterpart) are the handful of exceptions.
fn snapshotDefaults() void {
    if (defaults_taken) return;
    defaults_taken = true;
    defaults = mirror(FileConfig, config);
    defaults.bar = mirror(BarSpec, config.bar);
    defaults.cursor = mirror(CursorSpec, config.cursor);
    defaults.cursor.?.shake = mirror(ShakeSpec, config.cursor.shake);
    // `binds` is not a config.zig variable: null means "use the compiled-in
    // keymap", which is exactly the right reset value.
    defaults.binds = null;
}

/// Build an all-fields-populated `Spec` from the like-named declarations of the
/// namespace `src`. Fields with no counterpart in `src` (or whose counterpart is a
/// nested namespace rather than a value) are left null for the caller to fill.
fn mirror(comptime Spec: type, comptime src: anytype) Spec {
    var out: Spec = .{};
    inline for (@typeInfo(Spec).@"struct".fields) |f| {
        const Child = @typeInfo(f.type).optional.child;
        if (@hasDecl(src, f.name) and @TypeOf(@field(src, f.name)) == Child) {
            @field(out, f.name) = @field(src, f.name);
        }
    }
    return out;
}

/// First existing candidate path, written into `buf`. Returns null if none exist.
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
    if (fc.cursor) |c| {
        if (c.theme) |v| config.cursor.theme = v;
        if (c.size) |v| config.cursor.size = v;
        if (c.export_env) |v| config.cursor.export_env = v;
        if (c.shake) |s| {
            if (s.enabled) |v| config.cursor.shake.enabled = v;
            if (s.delay) |v| config.cursor.shake.delay = v;
            if (s.command) |v| config.cursor.shake.command = v;
        }
    }
    if (fc.bar) |b| {
        if (b.enabled) |v| config.bar.enabled = v;
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
