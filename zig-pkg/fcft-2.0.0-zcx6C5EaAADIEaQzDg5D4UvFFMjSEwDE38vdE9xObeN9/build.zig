const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    const pixman = b.dependency("pixman", .{}).module("pixman");
    _ = b.addModule("fcft", .{
        .root_source_file = b.path("fcft.zig"),
        .imports = &.{
            .{ .name = "pixman", .module = pixman },
        },
    });
}
