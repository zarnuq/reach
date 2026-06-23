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
const zwlr = wayland.client.zwlr;

const Window = @import("window.zig").Window;
const Output = @import("output.zig").Output;
const Seat = @import("seat.zig").Seat;
const BorderSurface = @import("border.zig").BorderSurface;

/// Every global reach binds from the registry, gathered in one place (see
/// main.zig's registryListener). `rwm` is the only hard requirement; the rest are
/// optional because a minimal compositor could lack them (and we degrade: no
/// wl_shm → no bar, no viewporter/single-pixel-buffer → no borders, etc.).
/// Passed as a single value into `init`, replacing what used to be a dozen
/// positional parameters threaded through wm.init → Context.init.
pub const Globals = struct {
    rwm: *river.WindowManagerV1,
    xkb_bindings: ?*river.XkbBindingsV1 = null,
    layer_shell: ?*river.LayerShellV1 = null,
    wl_compositor: ?*wl.Compositor = null,
    wl_subcompositor: ?*wl.Subcompositor = null,
    wl_shm: ?*wl.Shm = null,
    wp_viewporter: ?*wp.Viewporter = null,
    wp_single_pixel_buffer_manager: ?*wp.SinglePixelBufferManagerV1 = null,
    // Sibling protocols applied once at startup (outputconfig/inputconfig) and not
    // needed afterwards, so they live here but aren't copied onto the Context.
    output_manager: ?*zwlr.OutputManagerV1 = null,
    input_manager: ?*river.InputManagerV1 = null,
};

pub const Context = struct {
    gpa: std.mem.Allocator,

    // The Wayland registry. Kept so outputs can bind their wl_output on demand
    // (river hands us only the numeric global name in river_output_v1.wl_output;
    // we bind it to read the connector name and order monitors by config).
    registry: *wl.Registry,

    // river + core globals (bound in main.zig). `rwm` is required; the optionals
    // gate optional subsystems (bar, borders) and a minimal compositor could lack
    // them. Copied from the `Globals` passed to init.
    rwm: *river.WindowManagerV1,
    xkb_bindings: ?*river.XkbBindingsV1,
    layer_shell: ?*river.LayerShellV1,
    wl_compositor: ?*wl.Compositor,
    wl_subcompositor: ?*wl.Subcompositor,
    wl_shm: ?*wl.Shm,
    wp_viewporter: ?*wp.Viewporter,
    wp_single_pixel_buffer_manager: ?*wp.SinglePixelBufferManagerV1,

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
    pointer_output: ?*Output = null, // output the pointer is over (spawn target)

    // The selected output — dwl's `selmon`. This is the single source of truth
    // for "which monitor is active": tag/layout keybindings act on it and the bar
    // draws its highlight there. Updated on click-to-focus, new windows, and
    // `focusmon`. Kept distinct from `pointer_output` so keyboard-driven focus and
    // mouse position can differ without the two disagreeing about the target.
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
};

// The one and only instance. Populated by `init` before the event loop starts.
var instance: Context = undefined;

pub fn get() *Context {
    return &instance;
}

/// Initialise the global. Called once from wm.init with the bound globals.
pub fn init(gpa: std.mem.Allocator, registry: *wl.Registry, g: Globals) void {
    instance = .{
        .gpa = gpa,
        .registry = registry,
        .rwm = g.rwm,
        .xkb_bindings = g.xkb_bindings,
        .layer_shell = g.layer_shell,
        .wl_compositor = g.wl_compositor,
        .wl_subcompositor = g.wl_subcompositor,
        .wl_shm = g.wl_shm,
        .wp_viewporter = g.wp_viewporter,
        .wp_single_pixel_buffer_manager = g.wp_single_pixel_buffer_manager,
        .windows = .empty,
        .outputs = .empty,
        .seats = .empty,
        .borders = .empty,
    };
}
