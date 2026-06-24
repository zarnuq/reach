// status.zig — the baked-in status engine (someblocks, in-process).
//
// Instead of an external someblocks process piping text to us, reach runs
// the configured blocks itself (config.bar.blocks). The semantics match suckless
// someblocks exactly:
//   * each block is `icon ++ first line of <command> stdout`;
//   * blocks are joined by `config.bar.delim`, empty blocks omitted;
//   * a block re-runs every `interval` seconds (driven by a 1s timerfd), and/or
//     when we receive SIGRTMIN+`signal` (driven by a signalfd) — so the user's
//     existing `kill -35 $(pidof reach)` style refresh still works.
//
// Commands run through libc `popen`, i.e. `/bin/sh -c <command>`, so `$HOME`,
// pipes and globs behave just like in the someblocks blocks.h.
//
// The composed text lives in `text_buf`; bar.zig reads it via `text()`. The
// event loop (wm.zig) polls `timer_fd` and `signal_fd` and calls onTimer/onSignal.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.status);

const config = @import("config.zig");

// libc command runner (someblocks uses popen too). libc is linked.
const FILE = opaque {};
extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn pclose(stream: *FILE) c_int;
extern fn fgets(buf: [*]u8, n: c_int, stream: *FILE) ?[*]u8;

// glibc real-time signal range. The user's volume keybinds send raw 35/36, i.e.
// SIGRTMIN+1 / SIGRTMIN+2, so the base must be 34 to match someblocks.
const SIGRTMIN = 34;
const SIGRTMAX = 64;

// Blocks come from `config.bar.blocks`, which is now a runtime slice (it can be
// overlaid from config.zon), so the per-block caches are sized to a compile-time
// MAX_BLOCKS ceiling and we iterate over the live count. A config with more than
// MAX_BLOCKS blocks simply has the surplus ignored.
const MAX_BLOCKS = 32;
const CMDLEN = 256; // max bytes kept per block (icon + line)

/// Number of active blocks this run (clamped to the cache capacity).
inline fn nblocks() usize {
    return @min(config.bar.blocks.len, MAX_BLOCKS);
}

/// Composed status line; bar.zig reads this.
pub var text_buf: [4096]u8 = undefined;
pub var text_len: usize = 0;

/// 1-second tick timer and real-time-signal fd (null = setup failed).
pub var timer_fd: ?i32 = null;
pub var signal_fd: ?i32 = null;

// Per-block cached output (icon + first line, no delimiter) and its length.
var out_buf: [MAX_BLOCKS][CMDLEN]u8 = undefined;
var out_len: [MAX_BLOCKS]usize = [_]usize{0} ** MAX_BLOCKS;
var clock: u64 = 0;

pub fn text() []const u8 {
    return text_buf[0..text_len];
}

/// Run every block once, then arm the 1s timer and the RT-signal fd.
pub fn start() void {
    for (0..nblocks()) |i| runBlock(i);
    compose();

    // 1-second repeating timer.
    const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true });
    if (linux.errno(tfd) == .SUCCESS) {
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 1, .nsec = 0 },
            .it_value = .{ .sec = 1, .nsec = 0 },
        };
        _ = linux.timerfd_settime(@intCast(tfd), .{}, &spec, null);
        timer_fd = @intCast(tfd);
    } else {
        log.warn("timerfd_create failed: errno {}", .{linux.errno(tfd)});
    }

    // Block SIGRTMIN..SIGRTMAX and deliver them via a signalfd instead, so a
    // `kill -SIGRTMIN+n` refreshes the matching blocks.
    var mask = linux.sigemptyset();
    var sig: u32 = SIGRTMIN;
    while (sig <= SIGRTMAX) : (sig += 1) {
        linux.sigaddset(&mask, @enumFromInt(sig));
    }
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sfd = linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
    if (linux.errno(sfd) == .SUCCESS) {
        signal_fd = @intCast(sfd);
    } else {
        log.warn("signalfd failed: errno {}", .{linux.errno(sfd)});
    }
}

/// Timer fired: advance the clock and re-run blocks whose interval is due.
/// Returns true if the composed text changed.
pub fn onTimer() bool {
    const fd = timer_fd orelse return false;
    var buf: [8]u8 = undefined;
    _ = posix.read(fd, &buf) catch return false; // drain the expiration count
    clock += 1;

    var ran = false;
    for (0..nblocks()) |i| {
        const b = config.bar.blocks[i];
        if (b.interval != 0 and clock % b.interval == 0) {
            runBlock(i);
            ran = true;
        }
    }
    if (!ran) return false;
    return recompose();
}

/// A real-time signal arrived: re-run blocks registered for it. Returns true if
/// the composed text changed.
pub fn onSignal() bool {
    const fd = signal_fd orelse return false;
    var ran = false;
    // Drain all queued siginfo records.
    while (true) {
        var info: linux.signalfd_siginfo = undefined;
        const bytes: [*]u8 = @ptrCast(&info);
        const n = posix.read(fd, bytes[0..@sizeOf(linux.signalfd_siginfo)]) catch break;
        if (n != @sizeOf(linux.signalfd_siginfo)) break;
        if (info.signo < SIGRTMIN) continue;
        const want: u8 = @intCast(info.signo - SIGRTMIN);
        for (0..nblocks()) |i| {
            if (config.bar.blocks[i].signal == want) {
                runBlock(i);
                ran = true;
            }
        }
    }
    if (!ran) return false;
    return recompose();
}

/// Recompose and report whether the text differs from what's on screen.
fn recompose() bool {
    const old_len = text_len;
    var old: [text_buf.len]u8 = undefined;
    @memcpy(old[0..old_len], text_buf[0..old_len]);
    compose();
    if (text_len != old_len) return true;
    return !std.mem.eql(u8, text_buf[0..text_len], old[0..old_len]);
}

/// Run one block's command and cache `icon ++ first-line-of-stdout`.
fn runBlock(i: usize) void {
    const b = config.bar.blocks[i];

    // Start with the icon.
    var n: usize = 0;
    for (b.icon) |c| {
        if (n < CMDLEN) {
            out_buf[i][n] = c;
            n += 1;
        }
    }

    // Run the command and take its first line.
    var cmdz: [1024]u8 = undefined;
    if (b.command.len < cmdz.len) {
        @memcpy(cmdz[0..b.command.len], b.command);
        cmdz[b.command.len] = 0;
        if (popen(@ptrCast(&cmdz), "r")) |f| {
            var line: [CMDLEN]u8 = undefined;
            const got = fgets(@ptrCast(&line), CMDLEN, f);
            _ = pclose(f);
            if (got != null) {
                var l = std.mem.indexOfScalar(u8, &line, 0) orelse CMDLEN;
                if (l > 0 and line[l - 1] == '\n') l -= 1;
                for (line[0..l]) |c| {
                    if (n < CMDLEN) {
                        out_buf[i][n] = c;
                        n += 1;
                    }
                }
            }
        }
    }
    out_len[i] = n;
}

/// Join all non-empty block outputs with the delimiter into `text_buf`.
fn compose() void {
    var n: usize = 0;
    var first = true;
    for (0..nblocks()) |i| {
        if (out_len[i] == 0) continue;
        if (!first) {
            for (config.bar.delim) |c| {
                if (n < text_buf.len) {
                    text_buf[n] = c;
                    n += 1;
                }
            }
        }
        first = false;
        for (out_buf[i][0..out_len[i]]) |c| {
            if (n < text_buf.len) {
                text_buf[n] = c;
                n += 1;
            }
        }
    }
    text_len = n;
}
