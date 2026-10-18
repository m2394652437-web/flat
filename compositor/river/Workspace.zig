// SPDX-FileCopyrightText: © 2026 CQZY
// SPDX-License-Identifier: GPL-3.0-only

//! A workspace of the window manager, see river_workspace_v1.

const Workspace = @This();

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;
const wlr = @import("wlroots");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");

const log = std.log.scoped(.wm);

object: *river.WorkspaceV1,
/// Null for an inert workspace, whose output was already removed
handle: ?*wlr.ExtWorkspaceHandleV1,

pub fn create(client: *wl.Client, version: u32, id: u32, output: ?*Output) void {
    const workspace = util.gpa.create(Workspace) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    const object = river.WorkspaceV1.create(client, version, id) catch {
        util.gpa.destroy(workspace);
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    workspace.* = .{ .object = object, .handle = null };
    object.setHandler(*Workspace, handleRequest, handleDestroy, workspace);

    const group = server.workspaces.group(output orelse return) orelse return;
    const handle = server.workspaces.ext_manager.createWorkspace(null, .{ .activate = true }) catch {
        log.err("out of memory", .{});
        return;
    };
    handle.data = workspace;
    // wlroots sends everything at once when the event loop is idle, so the
    // name set right after this comes along with the new workspace
    handle.setGroup(group);
    workspace.handle = handle;
}

fn handleDestroy(_: *river.WorkspaceV1, workspace: *Workspace) void {
    if (workspace.handle) |handle| handle.destroy();
    util.gpa.destroy(workspace);
}

fn handleRequest(
    object: *river.WorkspaceV1,
    request: river.WorkspaceV1.Request,
    workspace: *Workspace,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .set_name => |args| {
            const handle = workspace.handle orelse return;
            handle.setName(args.name);
        },
        .set_position => |args| {
            const handle = workspace.handle orelse return;
            var coordinates = [_]u32{args.position};
            handle.setCoordinates(&coordinates);
        },
        .set_state => |args| {
            const handle = workspace.handle orelse return;
            handle.setActive(args.state.active);
            handle.setUrgent(args.state.urgent);
            handle.setHidden(args.state.hidden);
        },
    }
}
