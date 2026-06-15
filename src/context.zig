// context.zig — the global shared state.
//
// Rather than thread a `*Wm` pointer through every per-object event callback,
// Confluence keeps one process-global Context (the same approach kwm uses). Each
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

pub const Context = struct {
    gpa: std.mem.Allocator,

    // river + core globals (bound in main.zig). Optionals are globals we may use
    // later (M3/M4/M5) and that a minimal compositor could lack.
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

    // The currently focused window, and the seat we drive focus through. M2 uses
    // a single primary seat; per-seat focus is a later refinement.
    focused: ?*Window = null,
    primary_seat: ?*Seat = null,
    pointer_output: ?*Output = null, // output pointer is over

    running: bool = true,
};

// The one and only instance. Populated by `init` before the event loop starts.
var instance: Context = undefined;

pub fn get() *Context {
    return &instance;
}

/// Initialise the global. Called once from wm.init with the bound globals.
pub fn init(
    gpa: std.mem.Allocator,
    rwm: *river.WindowManagerV1,
    xkb_bindings: ?*river.XkbBindingsV1,
    layer_shell: ?*river.LayerShellV1,
    wl_compositor: ?*wl.Compositor,
    wl_subcompositor: ?*wl.Subcompositor,
    wl_shm: ?*wl.Shm,
    wp_viewporter: ?*wp.Viewporter,
    wp_single_pixel_buffer_manager: ?*wp.SinglePixelBufferManagerV1,
) void {
    instance = .{
        .gpa = gpa,
        .rwm = rwm,
        .xkb_bindings = xkb_bindings,
        .layer_shell = layer_shell,
        .wl_compositor = wl_compositor,
        .wl_subcompositor = wl_subcompositor,
        .wl_shm = wl_shm,
        .wp_viewporter = wp_viewporter,
        .wp_single_pixel_buffer_manager = wp_single_pixel_buffer_manager,
        .windows = .empty,
        .outputs = .empty,
        .seats = .empty,
        .borders = .empty,
    };
}
