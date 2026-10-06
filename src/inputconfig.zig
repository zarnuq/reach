// inputconfig.zig — apply keyboard repeat via the river-input-management protocol.
//
// dwl sets `repeat_rate`/`repeat_delay` on the keyboard directly because dwl is
// the compositor. river's non-monolithic split puts input under the compositor,
// exposed to clients through `river_input_manager_v1` — a sibling protocol to
// river-window-management (just like wlr-output-management is for outputs). reach
// binds it and, for every input device the compositor announces, sets the repeat
// info from config. `set_repeat_info` is a no-op on non-keyboard devices, so we
// don't need to wait for the device's `type` event before applying it.
//
// Protocol flow:
//   manager.input_device -> a device appeared; apply repeat info immediately
//   device.removed       -> device unplugged; destroy our proxy
//
// Live devices are tracked so a config reload can push new repeat info to them.

const std = @import("std");
const log = std.log.scoped(.inputcfg);

const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");
const Context = @import("context.zig");

var devices: std.ArrayList(*river.InputDeviceV1) = .empty;

/// Start listening on the manager. Called from main once the global binds.
pub fn init(mgr: *river.InputManagerV1) void {
    mgr.setListener(?*anyopaque, managerListener, null);
}

/// Push the current repeat config to every live device. Called on reload.
pub fn reapply() void {
    for (devices.items) |dev| dev.setRepeatInfo(config.repeat_rate, config.repeat_delay);
}

fn managerListener(mgr: *river.InputManagerV1, event: river.InputManagerV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .input_device => |ev| {
            // Apply to every device unconditionally — the compositor ignores
            // set_repeat_info for non-keyboards. Re-fires on hotplug, so newly
            // plugged keyboards pick up the config too.
            ev.id.setRepeatInfo(config.repeat_rate, config.repeat_delay);
            ev.id.setListener(?*anyopaque, deviceListener, null);
            devices.append(Context.get().gpa, ev.id) catch
                log.warn("out of memory; device won't follow repeat changes on reload", .{});
        },
        // No more events on the manager; the protocol leaves destroying it, and
        // the devices it announced, to us.
        .finished => {
            for (devices.items) |dev| dev.destroy();
            devices.clearRetainingCapacity();
            mgr.destroy();
        },
    }
}

fn deviceListener(dev: *river.InputDeviceV1, event: river.InputDeviceV1.Event, _: ?*anyopaque) void {
    switch (event) {
        // Device unplugged → release the proxy. (We don't act on type/name.)
        .removed => {
            if (std.mem.indexOfScalar(*river.InputDeviceV1, devices.items, dev)) |i|
                _ = devices.swapRemove(i);
            dev.destroy();
        },
        else => {},
    }
}
