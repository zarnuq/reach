// signals.zig — SIGHUP on the poll loop.
//
// `kill -HUP $(pidof reach)` re-reads config.zon. It arrives on a signalfd rather
// than through a handler so that it is delivered at a point in the event loop
// where mutating window-manager state is safe; a handler could land in the middle
// of a manage sequence.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.signals);

/// The signalfd, or null if it could not be created — reload-by-signal is then
/// unavailable and the `.reload` keybind is the only way in.
pub var fd: ?i32 = null;

/// Block SIGHUP process-wide and route it to `fd` instead.
pub fn start() void {
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.HUP);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, null);
    const sfd = linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC);
    if (linux.errno(sfd) == .SUCCESS) {
        fd = @intCast(sfd);
    } else {
        log.warn("signalfd failed: errno {} — SIGHUP reload unavailable", .{linux.errno(sfd)});
    }
}

/// Drain every queued signal. True if a SIGHUP was among them.
pub fn onSignal() bool {
    const f = fd orelse return false;
    var hup = false;
    while (true) {
        var info: linux.signalfd_siginfo = undefined;
        const n = posix.read(f, std.mem.asBytes(&info)) catch break;
        if (n != @sizeOf(linux.signalfd_siginfo)) break;
        if (info.signo == @intFromEnum(linux.SIG.HUP)) hup = true;
    }
    return hup;
}
