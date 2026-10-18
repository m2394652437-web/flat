// SPDX-FileCopyrightText: © 2026 CQZY
// SPDX-License-Identifier: GPL-3.0-only

const WindowScale = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;

const server = &@import("main.zig").server;

const Window = @import("Window.zig");
const WindowGhost = @import("WindowGhost.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,
ghosts: wl.list.Head(WindowGhost, .link),

pub fn init(window_scale: *WindowScale) !void {
    window_scale.* = .{
        .global = try wl.Global.create(server.wl_server, river.WindowScaleV1, 2, *WindowScale, window_scale, bind),
        .ghosts = undefined,
    };
    window_scale.ghosts.init();
}

/// Apply the requested state of the ghosts, called at the end of every render sequence.
pub fn renderFinish(window_scale: *WindowScale) void {
    var it = window_scale.ghosts.iterator(.forward);
    while (it.next()) |ghost| ghost.renderFinish();
}

pub fn deinit(window_scale: *WindowScale) void {
    window_scale.global.destroy();
}

fn bind(client: *wl.Client, _: *WindowScale, version: u32, id: u32) void {
    const object = river.WindowScaleV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    object.setHandler(?*anyopaque, handleRequest, null, null);
}

fn handleRequest(
    object: *river.WindowScaleV1,
    request: river.WindowScaleV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .set_scale => |args| {
            if (args.numerator == 0 or args.denominator == 0) {
                object.postError(.invalid_scale, "numerator and denominator must not be 0");
                return;
            }
            if (!server.wm.ensureRendering()) return;
            // inert river_window_v1 objects have no user data
            const data = args.window.getUserData() orelse return;
            const window: *Window = @ptrCast(@alignCast(data));
            window.rendering_requested.scale =
                @as(f64, @floatFromInt(args.numerator)) / @as(f64, @floatFromInt(args.denominator));
        },
        .get_ghost => |args| {
            // inert river_window_v1 objects have no user data, the ghost stays empty
            const window: ?*Window = if (args.window.getUserData()) |data| @ptrCast(@alignCast(data)) else null;
            WindowGhost.create(object.getClient(), object.getVersion(), args.id, window);
        },
    }
}
