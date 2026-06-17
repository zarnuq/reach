// inputconfig.zig — apply keyboard repeat (and future input settings) via the
// river-input-management protocol.
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

const std = @import("std");
const log = std.log.scoped(.inputcfg);

const wayland = @import("wayland");
const river = wayland.client.river;

const config = @import("config.zig");

var manager: ?*river.InputManagerV1 = null;

/// Store the manager and start listening. Called from main once the global binds.
pub fn init(mgr: *river.InputManagerV1) void {
    manager = mgr;
    mgr.setListener(?*anyopaque, managerListener, null);
}

fn managerListener(_: *river.InputManagerV1, event: river.InputManagerV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .input_device => |ev| {
            // Apply to every device unconditionally — the compositor ignores
            // set_repeat_info for non-keyboards. Re-fires on hotplug, so newly
            // plugged keyboards pick up the config too.
            ev.id.setRepeatInfo(config.repeat_rate, config.repeat_delay);
            ev.id.setListener(?*anyopaque, deviceListener, null);
        },
        // Compositor is done with us; the object is destroyed by the library.
        .finished => manager = null,
    }
}

fn deviceListener(dev: *river.InputDeviceV1, event: river.InputDeviceV1.Event, _: ?*anyopaque) void {
    switch (event) {
        // Device unplugged → release the proxy. (We don't act on type/name.)
        .removed => dev.destroy(),
        else => {},
    }
}
