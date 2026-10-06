// context.zig — the global shared state.
//
// Rather than thread a `*Wm` pointer through every per-object event callback,
// reach keeps one process-global Context (the same approach kwm uses). Each
// Window/Output/Seat listener gets a pointer to *its own* wrapper as callback
// data, and reaches everything else via `Context.get()`.
//
// There is exactly one compositor connection per process, so a single global is
// the natural fit and avoids a lot of plumbing.

const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;
const wp = wayland.client.wp;

const Window = @import("window.zig").Window;
const Output = @import("output.zig").Output;
const Seat = @import("seat.zig").Seat;
const BorderSurface = @import("border.zig").BorderSurface;

/// The registry globals the window-manager core keeps using after startup (see
/// main.zig's registryListener). `rwm` is the only hard requirement; the rest are
/// optional because a minimal compositor could lack them (and we degrade: no
/// viewporter/single-pixel-buffer → no borders, etc.). The sibling protocols
/// (output/input management, gamma) go straight from main.zig to their own
/// modules and never reach the Context.
pub const Globals = struct {
    rwm: *river.WindowManagerV1,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
    layer_shell: ?*river.LayerShellV1 = null,
    wl_compositor: ?*wl.Compositor = null,
    wp_viewporter: ?*wp.Viewporter = null,
    wp_single_pixel_buffer_manager: ?*wp.SinglePixelBufferManagerV1 = null,
};

pub const Context = struct {
    gpa: std.mem.Allocator,

    // The Wayland registry. Kept so outputs can bind their wl_output on demand
    // (river hands us only the numeric global name in river_output_v1.wl_output;
    // we bind it to read the connector name and order monitors by config).
    registry: *wl.Registry,

    // river + core globals (bound in main.zig). `rwm` is required; the optionals
    // gate optional subsystems (borders) and a minimal compositor could lack
    // them. Copied field-for-field from the `Globals` passed to init, so every
    // `Globals` field must have a same-named field here.
    rwm: *river.WindowManagerV1,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
    layer_shell: ?*river.LayerShellV1 = null,
    wl_compositor: ?*wl.Compositor = null,
    wp_viewporter: ?*wp.Viewporter = null,
    wp_single_pixel_buffer_manager: ?*wp.SinglePixelBufferManagerV1 = null,

    // The managed world.
    //   windows — stack order; index 0 is the head (newest / master / focused).
    //   outputs — monitors.
    //   seats   — input seats.
    windows: std.ArrayList(*Window),
    outputs: std.ArrayList(*Output),
    seats: std.ArrayList(*Seat),

    // Reusable pool of solid-color border surfaces (the tmux gutter highlights).
    // Grown on demand; unused ones are hidden rather than destroyed.
    borders: std.ArrayList(*BorderSurface),

    // The currently focused window, and the seat we drive focus through. reach
    // uses a single primary seat; per-seat focus is a possible future refinement.
    focused: ?*Window = null,
    primary_seat: ?*Seat = null,

    // The selected output — dwl's `selmon`. This is the single source of truth
    // for "which monitor is active": desktop/layout keybindings act on it and the
    // state socket reports it as the focused output. Updated on click-to-focus,
    // new windows, and `focusmon`. Invariant: null only while there are no
    // outputs — Output.create sets it if unset and removal moves it to a
    // surviving output — so callers need no fallback.
    current_output: ?*Output = null,

    // The output we last told river is the default for new layer surfaces (rofi,
    // notifications, …) via river_layer_shell_output_v1.set_default. Tracked so the
    // manage cycle only re-issues set_default when the selection actually moves.
    layer_default: ?*Output = null,

    // Set by keyboard focus/layout actions to warp the pointer onto the newly
    // focused window (dwl `warpcursor`) on the next manage cycle — applied after
    // arrange() so the geometry is current. Keeps the cursor with the keyboard
    // focus, which also stops sloppy_focus from snapping focus back on the next
    // stray pointer motion.
    warp_pending: bool = false,

    running: bool = true,

    /// Give `w` keyboard focus and select its monitor, so the desktop keys and the
    /// state socket follow the window you are in. A window not yet homed to an
    /// output leaves the selection where it was.
    pub fn focus(self: *Context, w: *Window) void {
        self.focused = w;
        if (w.output) |o| self.current_output = o;
    }
};

// The one and only instance. Populated by `init` before the event loop starts.
var instance: Context = undefined;

pub fn get() *Context {
    return &instance;
}

/// Replace a gpa-owned string with a dup of `s` (null clears it; so does OOM).
pub fn replaceStr(slot: *?[:0]u8, s: ?[*:0]const u8) void {
    if (slot.*) |old| instance.gpa.free(old);
    slot.* = if (s) |p| instance.gpa.dupeZ(u8, std.mem.span(p)) catch null else null;
}

/// Initialise the global. Called once from wm.init with the bound globals.
pub fn init(gpa: std.mem.Allocator, registry: *wl.Registry, g: Globals) void {
    instance = .{
        .gpa = gpa,
        .registry = registry,
        .rwm = g.rwm,
        .windows = .empty,
        .outputs = .empty,
        .seats = .empty,
        .borders = .empty,
    };
    inline for (std.meta.fields(Globals)) |f| @field(instance, f.name) = @field(g, f.name);
}
