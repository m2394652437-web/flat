// SPDX-FileCopyrightText: © 2026 CQZY
// SPDX-License-Identifier: GPL-3.0-only

//! A copy of the last frame of a closed window, see river_window_ghost_v1.

const WindowGhost = @This();

const std = @import("std");
const math = std.math;
const wayland = @import("wayland");
const wl = wayland.server.wl;
const river = wayland.server.river;
const wlr = @import("wlroots");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Window = @import("Window.zig");

const log = std.log.scoped(.wm);

/// A copied node and its geometry at scale 1
const Piece = struct {
    node: *wlr.SceneNode,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    /// color of a rect, opacity of a buffer in [0]
    color: [4]f32,
};

const State = struct {
    /// layout coordinates, null: where the window was
    x: ?i32 = null,
    y: ?i32 = null,
    scale: f64 = 1,
    opacity: f32 = 1,
};

object: *river.WindowGhostV1,
link: wl.list.Link,
/// The window to copy once it closes, null once copied or destroyed
window: ?*Window,
/// null until the window closes
tree: ?*wlr.SceneTree = null,
pieces: std.ArrayList(Piece) = .empty,
requested: State = .{},
applied: State = .{},

pub fn create(client: *wl.Client, version: u32, id: u32, window: ?*Window) void {
    const ghost = util.gpa.create(WindowGhost) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    const object = river.WindowGhostV1.create(client, version, id) catch {
        util.gpa.destroy(ghost);
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    ghost.* = .{ .object = object, .link = undefined, .window = window };
    server.window_scale.ghosts.append(ghost);
    object.setHandler(*WindowGhost, handleRequest, handleDestroy, ghost);

    if (window) |w| {
        if (w.ghost) |old| old.window = null;
        w.ghost = ghost;
    }
}

fn handleDestroy(_: *river.WindowGhostV1, ghost: *WindowGhost) void {
    if (ghost.window) |window| window.ghost = null;
    if (ghost.tree) |tree| tree.node.destroy();
    ghost.pieces.deinit(util.gpa);
    ghost.link.remove();
    util.gpa.destroy(ghost);
}

fn handleRequest(
    object: *river.WindowGhostV1,
    request: river.WindowGhostV1.Request,
    ghost: *WindowGhost,
) void {
    switch (request) {
        .destroy => object.destroy(),
        .set_position => |args| {
            ghost.requested.x = args.x;
            ghost.requested.y = args.y;
        },
        .set_scale => |args| {
            if (args.numerator == 0 or args.denominator == 0) {
                object.postError(.invalid_scale, "numerator and denominator must not be 0");
                return;
            }
            ghost.requested.scale = @as(f64, @floatFromInt(args.numerator)) / @as(f64, @floatFromInt(args.denominator));
        },
        .set_opacity => |args| {
            if (args.denominator == 0 or args.numerator > args.denominator) {
                object.postError(.invalid_opacity, "denominator must not be 0 or less than numerator");
                return;
            }
            ghost.requested.opacity = @floatCast(@as(f64, @floatFromInt(args.numerator)) / @as(f64, @floatFromInt(args.denominator)));
        },
    }
}

/// Copy what `window` shows now, called right before the closed event is sent.
pub fn snapshot(ghost: *WindowGhost, window: *Window) void {
    std.debug.assert(ghost.window == window);
    ghost.window = null;
    window.ghost = null;

    if (!window.tree.node.enabled) return;
    const parent = window.tree.node.parent orelse return;
    const tree = parent.createSceneTree() catch {
        log.err("out of memory", .{});
        return;
    };
    tree.node.setPosition(window.tree.node.x, window.tree.node.y);
    tree.node.placeAbove(&window.tree.node);
    ghost.tree = tree;
    ghost.copyTree(window.tree, 0, 0);
}

fn copyTree(ghost: *WindowGhost, tree: *wlr.SceneTree, dx: c_int, dy: c_int) void {
    var it = tree.children.iterator(.forward);
    while (it.next()) |node| {
        if (!node.enabled) continue;
        const x = dx + node.x;
        const y = dy + node.y;
        ghost.copyNode(node, x, y) catch {
            log.err("out of memory", .{});
            return;
        };
    }
}

fn copyNode(ghost: *WindowGhost, node: *wlr.SceneNode, x: c_int, y: c_int) !void {
    const tree = ghost.tree.?;
    switch (node.type) {
        .tree => ghost.copyTree(wlr.SceneTree.fromNode(node), x, y),
        .rect => {
            const rect = wlr.SceneRect.fromNode(node);
            if (rect.width <= 0 or rect.height <= 0) return;
            const copy = try tree.createSceneRect(rect.width, rect.height, &rect.color);
            copy.node.setPosition(x, y);
            try ghost.pieces.append(util.gpa, .{
                .node = &copy.node,
                .x = x,
                .y = y,
                .width = rect.width,
                .height = rect.height,
                .color = rect.color,
            });
        },
        .buffer => {
            const buffer = wlr.SceneBuffer.fromNode(node);
            const wlr_buffer = buffer.buffer orelse return;
            const width, const height = if (buffer.dst_width == 0 and buffer.dst_height == 0)
                .{ wlr_buffer.width, wlr_buffer.height }
            else
                .{ buffer.dst_width, buffer.dst_height };
            if (width <= 0 or height <= 0) return;
            const copy = try tree.createSceneBuffer(wlr_buffer);
            copy.node.setPosition(x, y);
            copy.setDestSize(width, height);
            copy.setSourceBox(&buffer.src_box);
            copy.setTransform(buffer.transform);
            copy.setOpacity(buffer.opacity);
            copy.setFilterMode(buffer.filter_mode);
            try ghost.pieces.append(util.gpa, .{
                .node = &copy.node,
                .x = x,
                .y = y,
                .width = width,
                .height = height,
                .color = .{ buffer.opacity, 0, 0, 0 },
            });
        },
    }
}

/// Apply the requested state, called at the end of every render sequence.
pub fn renderFinish(ghost: *WindowGhost) void {
    const tree = ghost.tree orelse return;
    const requested = ghost.requested;

    if (requested.x != null and requested.y != null and
        (requested.x != ghost.applied.x or requested.y != ghost.applied.y))
    {
        // the parent of the ghost may not be at the layout origin
        var px: c_int = 0;
        var py: c_int = 0;
        if (tree.node.parent) |parent| _ = parent.node.coords(&px, &py);
        tree.node.setPosition(requested.x.? - px, requested.y.? - py);
    }

    if (requested.scale != ghost.applied.scale or requested.opacity != ghost.applied.opacity) {
        const scale = requested.scale;
        const opacity = requested.opacity;
        for (ghost.pieces.items) |piece| {
            piece.node.setPosition(scaleCoord(piece.x, scale), scaleCoord(piece.y, scale));
            const width = @max(1, scaleCoord(piece.width, scale));
            const height = @max(1, scaleCoord(piece.height, scale));
            switch (piece.node.type) {
                .rect => {
                    const rect = wlr.SceneRect.fromNode(piece.node);
                    rect.setSize(width, height);
                    // the color is premultiplied
                    const color: [4]f32 = .{
                        piece.color[0] * opacity,
                        piece.color[1] * opacity,
                        piece.color[2] * opacity,
                        piece.color[3] * opacity,
                    };
                    rect.setColor(&color);
                },
                .buffer => {
                    const buffer = wlr.SceneBuffer.fromNode(piece.node);
                    buffer.setDestSize(width, height);
                    buffer.setOpacity(piece.color[0] * opacity);
                },
                .tree => unreachable,
            }
        }
    }

    ghost.applied = requested;
}

fn scaleCoord(coord: c_int, scale: f64) c_int {
    if (scale == 1) return coord;
    return @intFromFloat(@round(@as(f64, @floatFromInt(coord)) * scale));
}
