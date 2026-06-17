// render/buffer.zig — a CPU-drawable shared-memory wl_buffer.
//
// The bar is drawn in software (pixman) into memory the compositor can read, so
// it needs a wl_shm buffer: an anonymous memfd shared with the compositor and
// mmap'd on our side, wrapped in a pixman image so we can fill rectangles and
// blit glyphs into it.
//
// A buffer is "busy" from when we attach+commit it until the compositor sends
// `release`. Drawing into a busy buffer would corrupt what's on screen, so the
// bar keeps two of these and ping-pongs between them (see bar.zig's pool).
//
// Adapted from kwm's render/buffer.zig (and the wayland-book shm example), using
// std.posix directly instead of a custom posix module.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const log = std.log.scoped(.buffer);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const pixman = @import("pixman");

const Context = @import("../context.zig");

wl_buffer: *wl.Buffer = undefined,
image: *pixman.Image = undefined,
data: []align(std.heap.page_size_min) u8 = undefined,

width: i32 = 0,
height: i32 = 0,
busy: bool = false,
configured: bool = false,

const Self = @This();

/// (Re)create the backing storage at `width` x `height`. If we already hold a
/// buffer of exactly that size, this is a no-op — the common case frame to frame.
pub fn init(self: *Self, width: i32, height: i32) !void {
    if (self.configured) {
        if (self.width == width and self.height == height) return;
        self.deinit();
    }

    const ctx = Context.get();
    const stride = width * 4; // ARGB8888: 4 bytes per pixel
    const size = stride * height;

    // Anonymous file in memory, shared with the compositor by passing its fd.
    const fd = try posix.memfd_create("reach-bar", linux.MFD.CLOEXEC);
    defer _ = linux.close(fd);
    // std.posix has no ftruncate wrapper; libc is linked, so call it directly.
    if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.TruncateFailed;

    const data = try posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer posix.munmap(data);

    // Hand the fd to the compositor as a pool, carve one buffer out of it.
    const pool = try ctx.wl_shm.?.createPool(fd, size);
    defer pool.destroy();
    const wl_buffer = try pool.createBuffer(0, width, height, stride, .argb8888);
    errdefer wl_buffer.destroy();
    wl_buffer.setListener(*Self, bufferListener, self);

    // A pixman image that writes straight into the shared memory. Note pixman's
    // a8r8g8b8 matches Wayland's little-endian argb8888.
    const image = pixman.Image.createBitsNoClear(.a8r8g8b8, width, height, @ptrCast(data.ptr), stride) orelse
        return error.CreateImageFailed;

    self.* = .{
        .wl_buffer = wl_buffer,
        .image = image,
        .data = data,
        .width = width,
        .height = height,
        .configured = true,
    };
}

pub fn deinit(self: *Self) void {
    if (!self.configured) return;
    self.wl_buffer.destroy();
    _ = self.image.unref();
    posix.munmap(self.data);
    self.configured = false;
}

/// Mark this buffer in-use; cleared again when the compositor releases it.
pub fn occupy(self: *Self) void {
    self.busy = true;
}

fn bufferListener(wl_buffer: *wl.Buffer, event: wl.Buffer.Event, self: *Self) void {
    std.debug.assert(wl_buffer == self.wl_buffer);
    switch (event) {
        .release => self.busy = false,
    }
}
