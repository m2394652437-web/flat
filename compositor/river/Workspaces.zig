// SPDX-FileCopyrightText: © 2026 CQZY
// SPDX-License-Identifier: GPL-3.0-only

//! The workspaces of the window manager, see river-workspace-v1. They are
//! shown to other clients through ext-workspace-v1.

const Workspaces = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;
const wlr = @import("wlroots");

const server = &@import("main.zig").server;

const Output = @import("Output.zig");
const Workspace = @import("Workspace.zig");

const log = std.log.scoped(.wm);

global: *wl.Global,
ext_manager: *wlr.ExtWorkspaceManagerV1,

commit: wl.Listener(*wlr.ExtWorkspaceManagerV1.event.Commit) = .init(handleCommit),

pub fn init(workspaces: *Workspaces) !void {
    workspaces.* = .{
        .global = try wl.Global.create(server.wl_server, river.WorkspaceManagerV1, 1, *Workspaces, workspaces, bind),
        .ext_manager = try wlr.ExtWorkspaceManagerV1.create(server.wl_server, 1),
    };
    workspaces.ext_manager.events.commit.add(&workspaces.commit);
}

pub fn deinit(workspaces: *Workspaces) void {
    workspaces.commit.link.remove();
    workspaces.global.destroy();
}

/// The ext-workspace group of the output, created on first use.
/// Null if the wlr_output is gone or out of memory.
pub fn group(workspaces: *Workspaces, output: *Output) ?*wlr.ExtWorkspaceGroupHandleV1 {
    if (output.workspace_group) |g| return g;
    const wlr_output = output.wlr_output orelse return null;
    const g = workspaces.ext_manager.createGroup(.{}) catch {
        log.err("out of memory", .{});
        return null;
    };
    g.outputEnter(wlr_output);
    output.workspace_group = g;
    return g;
}

pub fn destroyGroup(output: *Output) void {
    if (output.workspace_group) |g| {
        // wlroots unsets the group of its workspaces
        g.destroy();
        output.workspace_group = null;
    }
}

fn bind(client: *wl.Client, _: *Workspaces, version: u32, id: u32) void {
    const object = river.WorkspaceManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    object.setHandler(?*anyopaque, handleRequest, null, null);
}

fn handleRequest(
    object: *river.WorkspaceManagerV1,
    request: river.WorkspaceManagerV1.Request,
    _: ?*anyopaque,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .get_workspace => |args| {
            // inert river_output_v1 objects have no user data, the workspace stays inert
            const output: ?*Output = if (args.output.getUserData()) |data| @ptrCast(@alignCast(data)) else null;
            Workspace.create(object.getClient(), object.getVersion(), args.id, output);
        },
    }
}

/// Pass requests of ext-workspace-v1 clients on to the window manager
fn handleCommit(
    _: *wl.Listener(*wlr.ExtWorkspaceManagerV1.event.Commit),
    event: *wlr.ExtWorkspaceManagerV1.event.Commit,
) void {
    var it = event.requests.iterator(.forward);
    while (it.next()) |request| {
        switch (request.type) {
            .activate => {
                const handle = request.data.activate.workspace orelse continue;
                const data = handle.data orelse continue;
                const workspace: *Workspace = @ptrCast(@alignCast(data));
                workspace.object.sendActivate();
            },
            // not advertised in the capabilities
            .create_workspace, .deactivate, .assign, .remove => {},
        }
    }
}
