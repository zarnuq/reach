// ipc.zig — the state socket: what a bar needs, for a bar that isn't ours.
//
// reach draws no bar. A panel inside the window manager could read its state
// directly — query.selectedOutput(), out.desktop, query.topVisibleOn() are plain
// reads of the Context — but an external one (a layer-shell client such as
// quickshell) has no such access: river is non-monolithic, so reach IS the window
// manager and there is no compositor-side workspace protocol for a bar to bind.
// Nothing about desktops, focus or titles leaves this process unless we send it,
// which is what makes this socket the whole interface rather than a convenience.
//
// So: a SOCK_STREAM unix socket at $XDG_RUNTIME_DIR/reach.sock. On connect a
// client gets one JSON line describing every output; after that it gets a new
// line whenever that description CHANGES. One line, one complete snapshot — no
// deltas to apply and no ordering to get wrong, so a client that reconnects is
// immediately correct with no resync step.
//
// Publishing is driven from the render cycle (wm.zig) — a render is exactly when
// this state can have changed, so a panel is as live as the windows themselves.
// It costs nothing when unused: with no client connected, publish() returns
// before composing anything.
//
// DELIBERATELY WRITE-ONLY. Client fds are polled and read only to notice a
// disconnect (a closed socket reads EOF); bytes sent to us are discarded. A
// command like "view 3" for a clickable desktop cell would have to name the
// output too — action.view acts on query.selectedOutput(), so a click on an
// unfocused monitor's bar would switch the focused one — and moving the
// selection is a focus-semantics decision, not something a status socket should
// make on its own. A panel that wants to act on the WM has keybinds and `spawn`.

const std = @import("std");
const linux = std.os.linux;
const log = std.log.scoped(.ipc);

const config = @import("config.zig");
const Context = @import("context.zig");
const query = @import("query.zig");

// libc socket calls. Zig 0.16's std.posix no longer wraps the socket API, and we
// link libc anyway — same approach shake.zig takes for its evdev handles. The
// constants and `sockaddr.un` still come from std.os.linux.
const C = struct {
    extern fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    extern fn bind(fd: c_int, addr: *const linux.sockaddr.un, len: c_uint) c_int;
    extern fn listen(fd: c_int, backlog: c_int) c_int;
    extern fn accept4(fd: c_int, addr: ?*anyopaque, len: ?*c_uint, flags: c_int) c_int;
    extern fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
    extern fn read(fd: c_int, buf: [*]u8, len: usize) isize;
    extern fn close(fd: c_int) c_int;
    extern fn unlink(path: [*:0]const u8) c_int;
    extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
};

/// Concurrent listeners. A bar per session is the case; the ceiling exists so a
/// client stuck in a reconnect loop can't exhaust our fds.
pub const max_clients = 4;

/// Longest title/app_id we publish. A bar elides long titles anyway, and the cap
/// is what keeps one pathological window from overflowing the snapshot buffer.
const max_string = 256;

/// Listening socket, and the connected clients. wm.zig's poll loop reads both
/// (null / count 0 = nothing to add to the poll set).
pub var listen_fd: ?i32 = null;
pub var client_fds: [max_clients]i32 = undefined;
pub var client_count: usize = 0;

// The last line we sent, and the buffer the next one is composed into. Keeping
// the previous snapshot is what makes publish() a no-op on an unchanged frame —
// river runs a render cycle for reasons the bar doesn't care about.
var snapshot: [8192]u8 = undefined;
var snapshot_len: usize = 0;
var scratch: [8192]u8 = undefined;

/// Bind and listen. Failure disables the socket and leaves everything else
/// running — an external bar not starting is not a reason to lose the session.
pub fn start() void {
    var path_buf: [108]u8 = undefined;
    const path = socketPath(&path_buf) orelse {
        log.warn("socket path too long — ipc disabled", .{});
        return;
    };

    // A previous run's socket file outlives the process and would make bind()
    // fail with EADDRINUSE. Nothing else owns this name, so removing it is safe.
    _ = C.unlink(path.ptr);

    const fd = C.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
        0,
    );
    if (fd < 0) {
        log.warn("socket failed — ipc disabled", .{});
        return;
    }

    var addr = linux.sockaddr.un{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);

    if (C.bind(fd, &addr, @sizeOf(linux.sockaddr.un)) < 0) {
        log.warn("bind {s} failed — ipc disabled", .{path});
        _ = C.close(fd);
        return;
    }
    if (C.listen(fd, max_clients) < 0) {
        log.warn("listen failed — ipc disabled", .{});
        _ = C.close(fd);
        return;
    }

    listen_fd = fd;
    log.info("ipc listening on {s}", .{path});
}

/// Close the socket and remove its file, so the next run's bind() doesn't have to.
pub fn stop() void {
    for (client_fds[0..client_count]) |fd| _ = C.close(fd);
    client_count = 0;
    const fd = listen_fd orelse return;
    _ = C.close(fd);
    listen_fd = null;
    var path_buf: [108]u8 = undefined;
    if (socketPath(&path_buf)) |path| _ = C.unlink(path.ptr);
}

/// The listening socket is readable: take every pending connection. Each new
/// client is sent the current state immediately, so it renders a correct bar
/// without waiting for the next change.
pub fn onAccept() void {
    const fd = listen_fd orelse return;
    while (true) {
        // EAGAIN once the backlog is drained; any other failure is equally a
        // reason to stop taking connections this pass.
        const client = C.accept4(fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        if (client < 0) return;
        if (client_count == max_clients) {
            log.warn("ipc client limit reached; refusing connection", .{});
            _ = C.close(client);
            continue;
        }
        client_fds[client_count] = client;
        client_count += 1;
        // Compose unconditionally: the dedup snapshot may be stale (we skip
        // composing while nobody is connected) or empty (first client).
        _ = compose();
        if (!sendTo(client, snapshot[0..snapshot_len])) drop(client_count - 1);
    }
}

/// A client fd is readable. We have nothing to receive, so this only ever means
/// "closed" (read of 0) or a client talking to itself (discarded).
pub fn onClient(i: usize) void {
    var buf: [256]u8 = undefined;
    const n = C.read(client_fds[i], &buf, buf.len);
    // 0 = the peer closed. Negative is EAGAIN (a spurious wakeup, keep it) or a
    // real error (drop it); either way the next publish would reap a dead fd.
    if (n == 0) drop(i);
}

/// Send the current state to every client, if it differs from what they have.
/// Called once per render cycle.
pub fn publish() void {
    if (client_count == 0) return;
    if (!compose()) return;

    // Descending, so dropping a client (which shifts the tail down) can't skip
    // the next one or read past the new count.
    var i = client_count;
    while (i > 0) {
        i -= 1;
        if (!sendTo(client_fds[i], snapshot[0..snapshot_len])) drop(i);
    }
}

/// Forget client `i`, closing its fd. Order among clients doesn't matter, but
/// the array has to stay dense for the poll loop, so the last one fills the hole.
fn drop(i: usize) void {
    _ = C.close(client_fds[i]);
    client_count -= 1;
    client_fds[i] = client_fds[client_count];
}

/// One write, MSG_NOSIGNAL so a client that vanished mid-send gives us EPIPE
/// instead of killing the window manager with SIGPIPE. A short write is treated
/// as a lost client: the next snapshot supersedes this one anyway, and a partial
/// line would corrupt the client's parse.
fn sendTo(fd: i32, bytes: []const u8) bool {
    const n = C.send(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL);
    return n == @as(isize, @intCast(bytes.len));
}

/// $XDG_RUNTIME_DIR/reach.sock, or /tmp/reach.sock without one. NUL-terminated:
/// it is passed to bind() and unlink() as a C string.
fn socketPath(buf: []u8) ?[:0]const u8 {
    const dir = if (C.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
    return std.fmt.bufPrintZ(buf, "{s}/reach.sock", .{dir}) catch null;
}

// ---------------------------------------------------------------------------
// The snapshot
// ---------------------------------------------------------------------------

/// Build the state line into `scratch` and, if it differs from the last one,
/// promote it to `snapshot`. Returns whether it changed.
fn compose() bool {
    const ctx = Context.get();
    const selected = query.selectedOutput();
    var out = Writer{ .buf = &scratch };

    out.print("{{\"desktops\":{d},\"outputs\":[", .{config.desktops.count});
    for (ctx.outputs.items, 0..) |o, i| {
        if (i != 0) out.raw(",");
        out.raw("{\"name\":");
        out.string(if (o.name) |n| n else "");
        out.print(",\"desktop\":{d},\"focused\":{s},\"fullscreen\":{s},\"occupied\":[", .{
            o.desktop,
            if (selected == o) "true" else "false",
            if (query.fullscreenOn(o)) "true" else "false",
        });

        // Which desktops hold a window on this output — the bar's occupied dots.
        // Same rule as renderDesktops(): any managed window homed here counts,
        // mapped or not, so a rule that opens an app on an unviewed desktop
        // lights its cell up.
        var occupied = [_]bool{false} ** config.desktops.count;
        for (ctx.windows.items) |w| {
            if (w.output == o and w.desktop >= 1 and w.desktop <= config.desktops.count) {
                occupied[w.desktop - 1] = true;
            }
        }
        var first = true;
        for (occupied, 1..) |occ, d| {
            if (!occ) continue;
            if (!first) out.raw(",");
            first = false;
            out.print("{d}", .{d});
        }

        const top = query.topVisibleOn(o);
        out.raw("],\"title\":");
        out.string(if (top) |w| (w.title orelse "") else "");
        out.raw(",\"appId\":");
        out.string(if (top) |w| (w.app_id orelse "") else "");
        out.raw("}");
    }
    out.raw("]}\n");

    // An overflowed buffer is a truncated line, i.e. invalid JSON. Keep the
    // previous snapshot rather than publishing something a client can't parse.
    if (!out.ok) {
        log.warn("state snapshot exceeded {d} bytes; not published", .{scratch.len});
        return false;
    }
    if (out.len == snapshot_len and std.mem.eql(u8, snapshot[0..snapshot_len], scratch[0..out.len])) {
        return false;
    }
    @memcpy(snapshot[0..out.len], scratch[0..out.len]);
    snapshot_len = out.len;
    return true;
}

/// Append-only cursor over a fixed buffer. `ok` goes false on the first overflow
/// and every later write is dropped, so the caller checks once at the end rather
/// than after every field.
const Writer = struct {
    buf: []u8,
    len: usize = 0,
    ok: bool = true,

    fn raw(self: *Writer, bytes: []const u8) void {
        if (!self.ok) return;
        if (self.len + bytes.len > self.buf.len) {
            self.ok = false;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        if (!self.ok) return;
        const written = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch {
            self.ok = false;
            return;
        };
        self.len += written.len;
    }

    /// A JSON string literal: quoted, escaped, and capped at `max_string`.
    fn string(self: *Writer, s: []const u8) void {
        self.raw("\"");
        for (s[0..truncate(s)]) |c| {
            switch (c) {
                '"' => self.raw("\\\""),
                '\\' => self.raw("\\\\"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                '\t' => self.raw("\\t"),
                // Any other control character has no short escape and is illegal
                // raw inside a JSON string.
                0...0x08, 0x0b, 0x0c, 0x0e...0x1f => self.print("\\u{x:0>4}", .{c}),
                else => self.raw(&[_]u8{c}),
            }
        }
        self.raw("\"");
    }
};

/// Length to cut `s` at: `max_string`, backed off to a UTF-8 boundary. Cutting
/// mid-codepoint would emit a lone continuation byte, which is not valid UTF-8
/// and so not valid JSON — the client's parse would fail on the whole line, not
/// just the title.
fn truncate(s: []const u8) usize {
    if (s.len <= max_string) return s.len;
    var n: usize = max_string;
    while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
    return n;
}
