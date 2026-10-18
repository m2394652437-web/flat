const Self = @This();

const Overview = @import("overview.zig");
const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.window);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const config = @import("config");

const utils = @import("utils.zig");
const types = @import("types.zig");
const Seat = @import("seat.zig");
const Output = @import("output.zig");
const Context = @import("context.zig");
const CustomBorder = @import("custom_border.zig");
const Gesture = @import("gesture.zig");

pub const Decoration = enum {
    csd,
    ssd,
};

pub const Edge = enum {
    top,
    bottom,
    left,
    right,
};
pub const ResizeDirection = struct {
    horizontal: ?types.Direction,
    vertical: ?types.Direction,
};

const MoveState = union(enum) {
    const Data = struct {
        seat: *Seat,
    };

    start: Data,
    stop,
};
const ResizeState = union(enum) {
    const Data = struct {
        seat: *Seat,
        direction: ResizeDirection,
    };

    start: Data,
    stop,
};
const Event = union(enum) {
    init,
    fullscreen: ?*Output,
    unfullscreen,
    maximize: bool,
    move: MoveState,
    resize: ResizeState,
};

const ctx = Context.get();

// river_window_scale_v1 takes the scale as a fraction
const scale_denominator = 1 << 16;

link: wl.list.Link = undefined,
flink: wl.list.Link = undefined,

rwm_window: *river.WindowV1,
rwm_window_node: *river.NodeV1,

output: ?*Output = null,
former_output: ?[]const u8 = null,

unhandled_events: std.ArrayList(Event) = undefined,

layer_managed: bool = false,
floating_changed: bool = true,
fullscreen: union(enum) {
    none,
    window,
    output: *Output,
} = .none,
maximize: bool = false,
floating: bool = false,
sticky: bool = false,
hidden: bool = false,
clip_state: enum {
    unknow,
    normal,
    cliped,
} = .unknow,
geometry_undefined: bool = false,
// set on the first `dimensions` event, i.e. once the window is displayed
mapped: bool = false,

tag: u32 = 1,
// workspace of its output the window belongs to, `tag` picks the rows in it
workspace: u8 = 0,
pid: i32 = 0,
app_id: ?[]const u8 = null,
title: ?[]const u8 = null,
parent: ?*Self = null,
decoration: ?Decoration = null,
decoration_hint: river.WindowV1.DecorationHint = .no_preference,

is_terminal: bool = false,
swallowing: ?*Self = null,
swallowed_by: ?*Self = null,
disable_swallow: bool = false,
swallowing_border: ?CustomBorder = null,

x: i32 = 0,
y: i32 = 0,
width: i32 = 0,
height: i32 = 0,
min_width: i32 = 1,
min_height: i32 = 1,
scroller_mfact: f32 = undefined,
// scroller_mfact to restore on unmaximize
unmaximized_mfact: f32 = undefined,
scroller_x: ?union(enum) {
    x: i32,
    center,
} = null,
// on-screen x before the window list was reordered, the next scroller arrange slides from it
move_from_x: ?i32 = null,
// horizontal offset of this window alone, settles back to 0 after a reorder
move_offset_x: i32 = 0,
move_anim_from: f64 = 0,
move_anim_start_ms: ?i64 = null,
// shown width before scroller_mfact changed, the next scroller arrange animates from it
width_from: ?i32 = null,
// added to the column width, settles back to 0 after a width change
width_offset: i32 = 0,
width_anim_from: f64 = 0,
width_anim_start_ms: ?i64 = null,
// width proposed to the client while the width animates, the larger of the two ends,
// so the client resizes once and the animation only changes the content clip box
width_hold: i32 = 0,
// clip the content to the shown width until the client has caught up after an animation
width_settling: bool = false,
// a new tiled window, its first arrange animates its width from a thin column
opening: bool = false,
// copy of the window river keeps once it closes, it shrinks away; null without river_window_scale_v1
ghost: ?*river.WindowGhostV1 = null,
// where the window was last shown, in layout coordinates and on screen size; null if hidden
shown_box: ?Gesture.Box = null,
content_clipped: bool = false,
// width the client actually took
client_width: i32 = 0,
// last proposed dimensions; proposing again makes river reconfigure the client and wait
// for it, which stalls every animation frame on slow clients like browsers
proposed: ?struct { width: i32, height: i32 } = null,
// scale last sent with river_window_scale_v1
sent_scale: f64 = 1,
overview_saved: ?struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    fullscreen: ?*Output,
} = null,
floating_geometry: ?struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
} = null,
operator: union(enum) {
    none,
    move: struct {
        start_x: i32,
        start_y: i32,
        seat: *Seat,
    },
    resize: struct {
        start_x: i32,
        start_y: i32,
        start_width: i32,
        start_height: i32,
        direction: ResizeDirection,
        seat: *Seat,
    },
} = .none,

pub fn create(rwm_window: *river.WindowV1, output: ?*Output) !*Self {
    const window = try ctx.gpa.create(Self);
    errdefer ctx.gpa.destroy(window);

    defer log.debug("<{*}> created", .{window});

    const rwm_window_node = try rwm_window.getNode();
    errdefer rwm_window_node.destroy();

    window.* = .{
        .rwm_window = rwm_window,
        .rwm_window_node = rwm_window_node,
        .unhandled_events = try .initCapacity(ctx.gpa, 2),
        .scroller_mfact = if (output) |o| o.scroller_mfact() else ctx.cfg.layout.scroller.mfact,
    };
    window.link.init();
    window.flink.init();
    // ghosts came with version 2
    if (ctx.rwm_window_scale) |window_scale| if (window_scale.getVersion() >= 2) {
        window.ghost = window_scale.getGhost(rwm_window) catch null;
    };
    if (output) |o| {
        window.workspace = o.workspace;
        window.set_tag(o.tag);
        window.set_output(o, false);
    }
    try window.unhandled_events.append(ctx.gpa, .init);

    rwm_window.setListener(*Self, rwm_window_listener, window);

    return window;
}

pub fn destroy(self: *Self) void {
    defer log.debug("<{*}> destroyed", .{self});

    {
        var it = ctx.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            switch (seat.previous_focused) {
                .window => |window| if (self == window) {
                    seat.previous_focused = if (self.output) |output| .{ .output = output } else .none;
                },
                else => {},
            }

            if (seat.window_below_pointer.window == self) {
                seat.window_below_pointer = .{};
            }
        }
    }

    if (ctx.overview.selected == self) ctx.overview.selected = null;
    if (ctx.overview.active) ctx.overview.check_empty = true;
    self.set_former_output(null);

    if (self.is_terminal) {
        ctx.unregister_terminal(self);
    }

    // before self.link.remove() below, unswallow moves our links
    if (self.swallowed_by) |swallower| {
        swallower.unswallow();
    }
    self.unswallow();

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| output.bar.damage(.tags);
    }

    if (self.ghost) |ghost| ghost.destroy();

    self.link.remove();
    self.flink.remove();
    self.rwm_window.destroy();
    self.rwm_window_node.destroy();
    self.set_appid(null);
    self.set_title(null);
    self.unhandled_events.deinit(ctx.gpa);

    ctx.gpa.destroy(self);
}

pub fn set_output(self: *Self, output: ?*Output, clear_former: bool) void {
    log.debug("<{*}> set output to {*}", .{ self, output });

    if (self.output != output) {
        if (comptime build_options.bar_enabled) {
            if (self.output) |o| o.bar.damage(.tags);
        }

        self.output = output;

        // reset floating_geometry
        // window's output had changed, restore its geometry may cause error
        self.floating_geometry = null;

        if (comptime build_options.bar_enabled) {
            if (self.output) |o| o.bar.damage(.tags);
        }
    }

    if (clear_former) self.set_former_output(null);
}

pub fn set_former_output(self: *Self, output: ?[]const u8) void {
    log.debug("<{*}> set former output to `{s}`", .{ self, output orelse "" });

    if (self.former_output) |name| {
        ctx.gpa.free(name);
        self.former_output = null;
    }

    if (output) |name| {
        self.former_output = ctx.gpa.dupe(u8, name) catch |err| {
            log.err("dupe {s} failed: {}", .{ name, err });
            return;
        };
    }
}

pub fn set_tag(self: *Self, tag: u32) void {
    if (tag == 0) return;

    log.debug("<{*}> set tag: {b}", .{ self, tag });

    self.tag = tag;

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| output.bar.damage(.tags);
    }
}

// move to `workspace` of `output`, onto the row shown there
pub fn set_workspace(self: *Self, output: *Output, workspace: u8) void {
    if (workspace >= Output.workspace_max or workspace == self.workspace) return;

    log.debug("<{*}> set workspace: {}", .{ self, workspace });

    self.workspace = workspace;
    self.tag = output.workspace_tag(workspace);

    if (comptime build_options.bar_enabled) output.bar.damage(.tags);
}

pub fn toggle_tag(self: *Self, mask: u32) void {
    if (self.tag ^ mask == 0) return;

    log.debug("<{*}> toggle tag: {b}", .{ self, mask });

    self.tag ^= mask;

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| output.bar.damage(.tags);
    }
}

pub fn place(self: *Self, pos: types.PlacePosition) void {
    switch (pos) {
        .top => self.rwm_window_node.placeTop(),
        .bottom => self.rwm_window_node.placeBottom(),
        .above => |node| self.rwm_window_node.placeAbove(node),
        .below => |node| self.rwm_window_node.placeBelow(node),
    }
}

pub fn move(self: *Self, x: ?i32, y: ?i32) void {
    defer log.debug("<{*}> move to (x: {}, y: {})", .{ self, self.x, self.y });

    self.x = @max(ctx.cfg.border.width, @min(x orelse self.x, self.output.?.exclusive_width() - self.width - ctx.cfg.border.width));
    self.y = @max(ctx.cfg.border.width, @min(y orelse self.y, self.output.?.exclusive_height() - self.height - ctx.cfg.border.width));
}

pub fn unbound_move(self: *Self, x: ?i32, y: ?i32) void {
    defer log.debug("<{*}> unbound move to (x: {}, y: {})", .{ self, self.x, self.y });

    if (x) |new_x| self.x = new_x;
    if (y) |new_y| self.y = new_y;
}

pub fn snap_to(self: *Self, edge: Edge) void {
    var new_x: ?i32 = null;
    var new_y: ?i32 = null;

    switch (edge) {
        .top => new_y = 0,
        .bottom => new_y = self.output.?.exclusive_height(),
        .left => new_x = 0,
        .right => new_x = self.output.?.exclusive_width(),
    }

    self.move(new_x, new_y);
}

pub fn resize(self: *Self, width: ?i32, height: ?i32) void {
    defer log.debug(
        "<{*}> set dimensions to (width: {}, height: {})",
        .{ self, self.width, self.height },
    );

    self.width = @min(self.output.?.exclusive_width() - self.x - ctx.cfg.border.width, @max(
        width orelse self.width,
        self.min_width,
    ));
    self.height = @min(self.output.?.exclusive_height() - self.y - ctx.cfg.border.width, @max(
        height orelse self.height,
        self.min_height,
    ));

    if (self.swallowing_border) |*border| {
        border.damage();
    }
}

pub fn unbound_resize(self: *Self, width: ?i32, height: ?i32) void {
    defer log.debug(
        "<{*}> unbound set dimensions to (width: {}, height: {})",
        .{ self, self.width, self.height },
    );

    if (width) |new_width| self.width = new_width;
    if (height) |new_height| self.height = new_height;

    if (self.swallowing_border) |*border| {
        border.damage();
    }
}

pub fn prepare_close(self: *Self) void {
    log.debug("<{*}> prepare to close", .{self});

    // the window may ask for confirmation first, it shrinks away once it is really closed
    self.rwm_window.close();
}

// the window was closed: hand its ghost to the shrink animation, the windows next to it slide into the gap
fn release_ghost(self: *Self) void {
    const ghost = self.ghost orelse return;
    self.ghost = null;
    const box = self.shown_box orelse return ghost.destroy();
    if (!ctx.cfg.gesture.animate_bindings) return ghost.destroy();
    if (self.output) |output| if (self.managed_by_layout()) ctx.prepare_slide(output);
    Gesture.start_ghost(ghost, box);
}

pub fn prepare_move(self: *Self, state: MoveState) void {
    switch (state) {
        .start => |data| log.debug("<{*}> prepare to start moving, seat: {*}", .{ self, data.seat }),
        .stop => log.debug("<{*}> prepare to stop moving", .{self}),
    }

    self.append_event(.{ .move = state });
}

pub fn prepare_resize(self: *Self, state: ResizeState) void {
    switch (state) {
        .start => |data| log.debug("<{*}> prepare to start resizing, seat: {*}", .{ self, data.seat }),
        .stop => log.debug("<{*}> prepare to stop resizing", .{self}),
    }

    self.append_event(.{ .resize = state });
}

pub fn prepare_fullscreen(self: *Self, output: ?*Output) void {
    if (output) |target_output| {
        log.debug("<{*}> prepare to fullscreen on {*}", .{ self, target_output });
    } else {
        log.debug("<{*}> prepare to fullscreen on window", .{self});
    }

    self.append_event(.{ .fullscreen = output });
}

pub fn prepare_unfullscreen(self: *Self) void {
    log.debug("<{*}> prepare unfullscreen", .{self});

    self.append_event(.unfullscreen);
}

pub fn set_border(self: *Self, width: i32, rgb: u32) void {
    log.debug("<{*}> set border: (width: {}, color: 0x{x})", .{ self, width, rgb });

    const color = utils.rgba(rgb);
    self.rwm_window.setBorders(
        .{
            .top = true,
            .bottom = true,
            .left = true,
            .right = true,
        },
        width,
        color.r,
        color.g,
        color.b,
        color.a,
    );
}

pub fn ensure_floating(self: *Self) void {
    self.toggle_floating(true);
}

pub fn toggle_floating(self: *Self, flag: ?bool) void {
    self.floating =
        if (flag) |floating| (if (self.floating != floating) floating else return) else !self.floating;
    self.layer_managed = false;
    self.floating_changed = true;

    log.debug("<{*}> toggle floating: {}", .{ self, self.floating });

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| {
            output.bar.damage(.title);
        }
    }

    if (!ctx.cfg.remember_floating_geometry) return;

    if (self.floating) {
        if (self.floating_geometry) |geometry| {
            self.unbound_move(geometry.x, geometry.y);
            self.unbound_resize(geometry.width, geometry.height);
        }
    } else {
        self.floating_geometry = .{
            .x = self.x,
            .y = self.y,
            .width = self.width,
            .height = self.height,
        };
    }
}

pub fn toggle_maximize(self: *Self, flag: ?bool) void {
    self.maximize =
        if (flag) |maximize| (if (self.maximize != maximize) maximize else return) else !self.maximize;

    log.debug("<{*}> toggle maximize: {}", .{ self, self.maximize });

    // a tiled window changes its column width: animate it, and slide the columns it pushes
    if (!self.floating) if (self.output) |output| {
        ctx.prepare_slide(output);
        ctx.prepare_resize(self);
    };

    // a maximized window is a full width column, so it slides like any other one
    if (self.maximize) {
        self.toggle_floating(false);
        self.unmaximized_mfact = self.scroller_mfact;
        self.scroller_mfact = 1;
    } else {
        self.scroller_mfact = self.unmaximized_mfact;
    }

    self.append_event(.{ .maximize = self.maximize });

    if (self.swallowing_border) |*border| {
        border.damage();
    }
}

pub fn toggle_sticky(self: *Self) void {
    log.debug("<{*}> toggle sticky: {}", .{ self, !self.sticky });

    self.sticky = !self.sticky;

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| output.bar.damage(.title);
    }
}

// if the window is arranged by the scroller
pub fn managed_by_layout(self: *const Self) bool {
    return self.output != null and !self.floating;
}

pub fn is_visible(self: *Self) bool {
    if (ctx.overview.active and !Overview.zoomed()) {
        return if (self.output) |output| Overview.is_candidate(self, output) else false;
    }

    if (self.output) |output| {
        if (self.swallowed_by != null) return false;
        if (self.sticky) return true;
        if (self.workspace == output.workspace) return self.on_shown_row(output, output.tag, output.gesture_peek_tag);
        // the workspace sliding out during a workspace switch
        if (output.peek_workspace) |peek| if (self.workspace == peek) {
            return self.on_shown_row(output, output.workspaces[peek].tag, 0);
        };
    }
    return false;
}

fn on_shown_row(self: *const Self, output: *Output, tag: u32, peek_tag: u32) bool {
    if (!self.floating) {
        if (output.shows_all_rows()) return true;
        // tiled windows of the row revealed by a vertical swipe
        if ((self.tag & peek_tag) != 0) return true;
    }
    return (self.tag & tag) != 0;
}

pub fn is_visible_in(self: *Self, output: *Output) bool {
    if (self.output == null) return false;

    if (self.output.? != output) return false;

    return (self.sticky or (self.workspace == output.workspace and (self.tag & output.tag) != 0)) and self.swallowed_by == null;
}

pub fn toggle_swallow(self: *Self) void {
    log.debug("<{*}> toggle swallow", .{self});

    if (self.swallowing != null) {
        self.unswallow();
    } else {
        self.try_swallow();
    }
}

pub fn handle_events(self: *Self) void {
    defer self.unhandled_events.clearRetainingCapacity();

    for (self.unhandled_events.items) |event| {
        log.debug("<{*}> handle event: {s}", .{ self, @tagName(event) });

        switch (event) {
            .init => {
                log.debug("<{*}> managing new window", .{self});

                self.rwm_window.setCapabilities(.{
                    .window_menu = false,
                    .maximize = true,
                    .fullscreen = true,
                    .minimize = false,
                });

                if (self.parent != null) {
                    self.toggle_floating(true);
                }

                self.apply_rules();

                switch (self.decoration_hint) {
                    .only_supports_csd => self.decoration = .csd,
                    .prefers_csd => self.decoration = self.decoration orelse .csd,
                    .prefers_ssd => self.decoration = self.decoration orelse .ssd,
                    else => {},
                }

                switch (self.decoration orelse ctx.cfg.default_window_decoration) {
                    .csd => self.rwm_window.useCsd(),
                    .ssd => self.rwm_window.useSsd(),
                }

                self.opening = !self.floating and ctx.cfg.gesture.animate_bindings and !ctx.overview.active;

                if (!self.managed_by_layout()) {
                    if (self.width > 0 and self.height > 0) {
                        self.center();
                    } else {
                        self.geometry_undefined = true;
                    }
                }

                if (self.is_terminal) {
                    ctx.register_terminal(self);
                }

                if (ctx.cfg.auto_swallow) {
                    self.try_swallow();
                }
            },
            .fullscreen => |data| {
                log.debug("<{*}> managing fullscreen: {*}", .{ self, data });
                self.proposed = null;

                var fullscreen_output: ?*Output = null;

                switch (self.fullscreen) {
                    .none => {
                        self.rwm_window.informFullscreen();
                        if (data) |output| {
                            fullscreen_output = output;
                        } else {
                            log.debug("<{*}> fullscreen on window", .{self});

                            self.fullscreen = .window;
                        }
                    },
                    .window => {
                        if (data) |output| {
                            fullscreen_output = output;
                        }
                    },
                    .output => |original_output| {
                        if (data) |output| {
                            if (output != original_output) {
                                log.debug("<{*}> fullscreen move from {*} to {*}", .{ self, original_output, output });

                                fullscreen_output = output;
                                self.rwm_window.exitFullscreen();
                            }
                        }
                    },
                }

                if (fullscreen_output) |output| {
                    log.debug("<{*}> fullscreen on {*}", .{ self, output });

                    self.rwm_window.fullscreen(output.rwm_output);
                    self.fullscreen = .{ .output = output };
                }
            },
            .unfullscreen => {
                log.debug("<{*}> managing unfullscreen", .{self});
                self.proposed = null;

                switch (self.fullscreen) {
                    .none => {
                        log.warn("<{*}> unfullscreen while window is not fullscreen", .{self});
                    },
                    .window => {
                        self.rwm_window.informNotFullscreen();
                    },
                    .output => {
                        self.rwm_window.informNotFullscreen();
                        self.rwm_window.exitFullscreen();
                    },
                }
                self.fullscreen = .none;
            },
            .maximize => |flag| {
                log.debug("<{*}> managing maximize: {}", .{ self, flag });

                if (flag) {
                    self.rwm_window.informMaximized();
                } else {
                    self.rwm_window.informUnmaximized();
                }
                self.maximize = flag;
            },
            .move => |state| {
                log.debug("<{*}> managing move, state: {s}", .{ self, @tagName(state) });

                switch (state) {
                    .start => |data| {
                        data.seat.op_start(.move);
                        self.operator = .{
                            .move = .{
                                .start_x = self.x,
                                .start_y = self.y,
                                .seat = data.seat,
                            },
                        };
                    },
                    .stop => {
                        switch (self.operator) {
                            .move => |op_data| {
                                op_data.seat.op_end();
                            },
                            else => unreachable,
                        }
                        self.operator = .none;
                    },
                }
            },
            .resize => |state| {
                log.debug("<{*}> managing resize, state: {s}", .{ self, @tagName(state) });

                switch (state) {
                    .start => |data| {
                        data.seat.op_start(.{ .resize = data.direction });
                        self.rwm_window.informResizeStart();
                        self.operator = .{
                            .resize = .{
                                .start_x = self.x,
                                .start_y = self.y,
                                .start_width = self.width,
                                .start_height = self.height,
                                .direction = data.direction,
                                .seat = data.seat,
                            },
                        };
                    },
                    .stop => {
                        switch (self.operator) {
                            .resize => |op_data| {
                                op_data.seat.op_end();
                                self.rwm_window.informResizeEnd();
                            },
                            else => unreachable,
                        }
                        self.operator = .none;
                    },
                }
            },
        }
    }

    if (self.floating_changed) {
        self.floating_changed = false;
        if (self.floating) {
            self.rwm_window.setTiled(.{});
        } else {
            self.rwm_window.setTiled(.{
                .top = true,
                .bottom = true,
                .left = true,
                .right = true,
            });
        }
    }
}

pub fn apply_rules(self: *Self) void {
    log.debug("<{*}> apply rules", .{self});

    for (ctx.cfg.window_rules) |rule| {
        if (rule.match(self.app_id, self.title)) {
            self.apply_rule(&rule);
            break;
        }
    }
}

pub fn manage(self: *Self) void {
    log.debug("<{*}> managing, propose dimensions: (width: {}, height: {})", .{ self, self.width, self.height });

    if (self.geometry_undefined) {
        self.rwm_window.proposeDimensions(0, 0);
        self.proposed = null;
        return;
    }

    const width, const height = blk: {
        var width = if (self.width_anim_start_ms != null) self.width_hold else self.width;
        var height = self.height;
        if (self.swallowing_border != null) {
            if (self.managed_by_layout()) {
                width = @max(width - 2 * ctx.cfg.border.width, self.min_width);
                height = @max(height - 2 * ctx.cfg.border.width, self.min_height);
            }
        }
        break :blk .{ width, height };
    };

    if (self.proposed) |p| if (p.width == width and p.height == height) return;
    self.rwm_window.proposeDimensions(width, height);
    self.proposed = .{ .width = width, .height = height };
}

pub fn render(self: *Self) void {
    defer self.hidden = false;

    const border_width = ctx.cfg.border.width;
    // self.x/y are coordinates on the plane of the workspace; the output shows the part of
    // the plane around the center of its exclusive area, zoomed by output.zoom
    const zoom = if (self.output) |output| output.zoom else 1;
    const center_x: f64 = if (self.output) |output| @as(f64, @floatFromInt(output.exclusive_width())) / 2 else 0;
    const center_y: f64 = if (self.output) |output| @as(f64, @floatFromInt(output.exclusive_height())) / 2 else 0;
    const view: struct { left: i32, right: i32, top: i32, bottom: i32 } = if (self.output) |output| .{
        .left = @as(i32, @intFromFloat(@floor(center_x - center_x / zoom))),
        .right = @as(i32, @intFromFloat(@ceil(center_x + (@as(f64, @floatFromInt(output.width)) - center_x) / zoom))),
        .top = @as(i32, @intFromFloat(@floor(center_y - center_y / zoom))),
        .bottom = @as(i32, @intFromFloat(@ceil(center_y + (@as(f64, @floatFromInt(output.height)) - center_y) / zoom))),
    } else .{ .left = 0, .right = 0, .top = 0, .bottom = 0 };
    // a workspace switch slides the whole workspace
    const x = if (self.output) |output| self.x + (if (self.sticky) 0 else output.workspace_shift(self.workspace)) else self.x;
    const y = self.y;

    if (self.hidden or self.output == null or self.geometry_undefined or x - border_width >= view.right or x + self.width + border_width <= view.left or y - border_width >= view.bottom or y + self.height + border_width <= view.top) {
        if (!self.hidden and !self.geometry_undefined)
            log.debug("<{*}> out of range, hide", .{self});
        if (self.geometry_undefined)
            log.debug("<{*}> geometry undefined, hidden", .{self});
        if (self.output == null)
            log.debug("<{*}> has no output, hide", .{self});
        self.rwm_window.hide();
        self.shown_box = null;
        return;
    }

    var offset_x: i32 = 0;
    var offset_y: i32 = 0;
    const output_x = self.output.?.exclusive_x();
    const output_y = self.output.?.exclusive_y();

    if (ctx.rwm_window_scale) |window_scale| if (zoom != self.sent_scale) {
        window_scale.setScale(self.rwm_window, @intFromFloat(@round(zoom * scale_denominator)), scale_denominator);
        self.sent_scale = zoom;
    };

    if (self.swallowing_border) |*border| {
        border.render(ctx.cfg.border.color.swallowing);
        if (self.managed_by_layout()) {
            offset_x += ctx.cfg.border.width;
            offset_y += ctx.cfg.border.width;
        }
    }

    log.debug("<{*}> rendering to (x: {}, y: {}, zoom: {d:.3})", .{ self, x, y, zoom });

    const screen_x = center_x + (@as(f64, @floatFromInt(x + offset_x)) - center_x) * zoom;
    const screen_y = center_y + (@as(f64, @floatFromInt(y + offset_y)) - center_y) * zoom;
    const node_x = output_x + @as(i32, @intFromFloat(@round(screen_x)));
    const node_y = output_y + @as(i32, @intFromFloat(@round(screen_y)));
    self.rwm_window_node.setPosition(node_x, node_y);
    self.shown_box = .{
        .x = node_x,
        .y = node_y,
        .width = @as(f64, @floatFromInt(self.width - 2 * offset_x)) * zoom,
        .height = @as(f64, @floatFromInt(self.height - 2 * offset_y)) * zoom,
    };

    var left = x - border_width;
    var right = x + self.width + border_width;
    var top = y - border_width;
    var bottom = y + self.height + border_width;
    if ((ctx.overview.active and !Overview.zoomed()) or left < view.left or top < view.top or right > view.right or bottom > view.bottom) {
        left = @max(left, view.left);
        right = @min(right, view.right);
        top = @max(top, view.top);
        bottom = @min(bottom, view.bottom);
        // the clip box is in unscaled window coordinates, river scales it with the window
        self.rwm_window.setClipBox(left - x - offset_x, top - y - offset_y, right - left, bottom - top);
        self.clip_state = .cliped;
    } else if (self.clip_state != .normal) {
        self.rwm_window.setClipBox(0, 0, 0, 0);
        self.clip_state = .normal;
    }

    // the client is wider than shown while a width change animates
    const content_width = self.width - (if (self.swallowing_border != null and self.managed_by_layout()) 2 * ctx.cfg.border.width else 0);
    if (self.width_settling and self.client_width > content_width) {
        // a 0 sized box would turn the clip off, keep 1 pixel for a thin column
        self.rwm_window.setContentClipBox(0, 0, @max(1, content_width), self.height);
        self.content_clipped = true;
    } else if (self.content_clipped) {
        self.rwm_window.setContentClipBox(0, 0, 0, 0);
        self.content_clipped = false;
    }

    self.rwm_window.show();
}

pub fn hide(self: *Self) void {
    log.debug("<{*}> hide", .{self});

    self.hidden = true;
}

fn set_appid(self: *Self, app_id: ?[]const u8) void {
    if (self.app_id) |appid| {
        ctx.gpa.free(appid);
        self.app_id = null;
    }
    if (app_id) |appid| {
        self.app_id = ctx.gpa.dupe(u8, appid) catch return;
    }
}

fn set_title(self: *Self, title: ?[]const u8) void {
    if (self.title) |tt| {
        ctx.gpa.free(tt);
        self.title = null;
    }
    if (title) |tt| {
        self.title = ctx.gpa.dupe(u8, tt) catch return;
    }
}

fn center(self: *Self) void {
    if (self.output) |output| {
        self.x = @divFloor(output.exclusive_width() - self.width, 2);
        self.y = @divFloor(output.exclusive_height() - self.height, 2);
    }
}

fn append_event(self: *Self, event: Event) void {
    log.debug("<{*}> append event: {s}", .{ self, @tagName(event) });

    self.unhandled_events.append(ctx.gpa, event) catch |err| {
        log.err("<{*}> append event {s} failed: {}", .{ self, @tagName(event), err });
        return;
    };
}

fn try_swallow(self: *Self) void {
    log.debug("<{*}> try swallow", .{self});

    if (!self.disable_swallow and self.pid != 0) {
        var pid = self.pid;
        var ppid: i32 = undefined;
        while (true) {
            ppid = utils.parent_pid(ctx.io, pid);
            if (ppid == 0 or ppid == 1) break;

            if (ctx.find_terminal(ppid)) |term| {
                self.swallow(term);
                break;
            }

            pid = ppid;
        }
    }
}

fn swallow(self: *Self, window: *Self) void {
    if (self == window) return;

    if (self.swallowing != null or window.swallowed_by != null) return;

    if (!window.is_visible()) return;

    log.debug("<{*}> swallowing {*}", .{ self, window });

    self.swallowing = window;

    self.tag = window.tag;
    self.workspace = window.workspace;
    self.scroller_x = window.scroller_x;
    if (self.floating == window.floating) {
        self.x = window.x;
        self.y = window.y;
        self.width = window.width;
        self.height = window.height;
        self.geometry_undefined = false;
    }

    self.link.remove();
    window.link.insert(&self.link);
    self.flink.remove();
    window.flink.insert(&self.flink);

    window.output = self.output;
    window.swallowed_by = self;
    switch (window.fullscreen) {
        .none, .window => {},
        .output => {
            window.prepare_unfullscreen();
        },
    }

    self.swallowing_border = undefined;
    self.swallowing_border.?.init(self) catch |err| {
        self.swallowing_border = null;
        log.err("<{*}> init custom decoration failed: {}", .{ self, err });
        return;
    };
}

fn unswallow(self: *Self) void {
    if (self.swallowing) |window| {
        defer self.swallowing = null;

        log.debug("<{*}> unswallowing {*}", .{ self, window });

        window.swallowed_by = null;
        window.output = self.output;
        window.tag = self.tag;
        window.workspace = self.workspace;

        window.link.remove();
        self.link.insert(&window.link);
        window.flink.remove();
        self.flink.insert(&window.flink);
    }

    if (self.swallowing_border) |*border| {
        border.deinit();
        self.swallowing_border = null;
    }
}

fn apply_rule(self: *Self, rule: *const config.WindowRule) void {
    if (rule.workspace) |workspace| if (self.output) |output| self.set_workspace(output, workspace -| 1);
    if (rule.tag) |tag| self.set_tag(tag);
    if (rule.output) |output_pattern| {
        {
            var it = ctx.outputs.safeIterator(.forward);
            while (it.next()) |output| {
                if (output_pattern.is_match(output.name)) {
                    self.set_output(output, true);
                    break;
                }
            }
        }
    }
    if (rule.floating) |floating| self.toggle_floating(floating);
    if (rule.dimension) |dimension| self.resize(dimension.width, dimension.height);
    if (rule.decoration) |decoration| self.decoration = decoration;
    if (rule.is_terminal) |is_terminal| self.is_terminal = is_terminal;
    if (rule.disable_swallow) |disable_swallow| self.disable_swallow = disable_swallow;
    if (rule.scroller_mfact) |scroller_mfact| self.scroller_mfact = scroller_mfact;
    if (rule.attach_mode) |mode| {
        self.link.remove();
        self.link.init();
        self.flink.remove();
        self.flink.init();
        ctx.attach_window(self, mode);
        ctx.focus(self, true);
    }
}

fn rwm_window_listener(rwm_window: *river.WindowV1, event: river.WindowV1.Event, window: *Self) void {
    std.debug.assert(rwm_window == window.rwm_window);

    switch (event) {
        .app_id => |data| {
            const app_id = data.app_id orelse return;

            log.debug("<{*}> app_id: {s}", .{ window, app_id });

            window.set_appid(mem.span(app_id));
        },
        .title => |data| {
            const title = data.title orelse return;

            log.debug("<{*}> title: {s}", .{ window, title });

            window.set_title(mem.span(title));
        },
        .closed => {
            log.debug("<{*}> closed", .{window});

            window.release_ghost();
            window.destroy();
        },
        .decoration_hint => |data| {
            log.debug("<{*}> decoration hint: {s}", .{ window, @tagName(data.hint) });

            window.decoration_hint = data.hint;
        },
        .dimensions => |data| {
            log.debug("<{*}> dimensions: ({}, {})", .{ window, data.width, data.height });

            window.mapped = true;
            window.client_width = data.width;
            // the client answered the final width proposed after the animation
            if (window.width_anim_start_ms == null) window.width_settling = false;

            if (window.geometry_undefined or (!window.managed_by_layout() and window.fullscreen != .output)) {
                if (window.output == null) {
                    window.unbound_resize(data.width, data.height);
                } else {
                    window.move(null, null);
                    window.resize(data.width, data.height);
                }
                if (window.geometry_undefined) {
                    window.geometry_undefined = false;
                    window.center();
                }
            }
        },
        .dimensions_hint => |data| {
            log.debug(
                "<{*}> dimensions hint: (-width/+width: {}/{}, -height/+height: {}/{})",
                .{ window, data.min_width, data.max_width, data.min_height, data.max_height },
            );

            window.min_width = @max(window.min_width, data.min_width);
            window.min_height = @max(window.min_height, data.min_height);

            // make small fixed-zise child windows to be floating, for
            // software doesn't use xdg_toplevel.set_parent
            const is_fixed = data.max_width > 0 and data.max_height > 0 and
                data.max_width == data.min_width and
                data.max_height == data.min_height;
            const is_small = data.max_width > 0 and data.max_height > 0 and
                data.max_width < 600 and data.max_height < 400;

            // only decide this for new windows, clients may change their
            // hints at any time (e.g. a transient fixed size while resizing)
            if (!window.mapped and (is_fixed or is_small) and !window.floating) {
                log.debug("<{*}> auto-floating fixed/small window ({}x{}-{}x{})", .{ window, data.min_width, data.min_height, data.max_width, data.max_height });

                window.toggle_floating(true);
                window.unbound_resize(0, 0);
                window.geometry_undefined = true;
            }
        },
        .fullscreen_requested => |data| {
            var output: ?*Output = undefined;
            if (data.output) |rwm_output| {
                output = @ptrCast(@alignCast(river.OutputV1.getUserData(rwm_output)));
            } else {
                output = window.output;
            }

            log.debug("<{*}> fullscreen requested: {*}", .{ window, output });

            window.prepare_fullscreen(output);
        },
        .exit_fullscreen_requested => {
            log.debug("<{*}> exit fullscreen requested", .{window});

            window.prepare_unfullscreen();
        },
        .maximize_requested => {
            log.debug("<{*}> maximize requested", .{window});

            window.toggle_maximize(true);
        },
        .unmaximize_requested => {
            log.debug("<{*}> unmaximize requested", .{window});

            window.toggle_maximize(false);
        },
        .minimize_requested => {
            log.debug("<{*}> minimize requested", .{window});
        },
        .parent => |data| {
            const parent_rwm_window = data.parent orelse return;
            const parent_window: *Self = @ptrCast(@alignCast(
                river.WindowV1.getUserData(parent_rwm_window),
            ));

            log.debug("<{*}> parent: {*} (of {*})", .{ window, parent_rwm_window, parent_window });

            window.parent = parent_window;
        },
        .pointer_move_requested => |data| {
            log.debug("<{*}> pointer move requested: {*}", .{ window, data.seat });

            if (window.managed_by_layout()) return;

            if (data.seat) |rwm_seat| {
                const seat: *Seat = @ptrCast(@alignCast(river.SeatV1.getUserData(rwm_seat)));
                window.prepare_move(.{ .start = .{ .seat = seat } });
            }
        },
        .pointer_resize_requested => |data| {
            log.debug("<{*}> pointer resize requested: {*}", .{ window, data.seat });

            if (window.managed_by_layout()) return;

            if (data.seat) |rwm_seat| {
                const seat: *Seat = @ptrCast(@alignCast(river.SeatV1.getUserData(rwm_seat)));
                window.prepare_resize(.{ .start = .{ .seat = seat, .direction = .{
                    .horizontal = if (data.edges.right) .forward else (if (data.edges.left) .reverse else null),
                    .vertical = if (data.edges.bottom) .forward else (if (data.edges.top) .reverse else null),
                } } });
            }
        },
        .show_window_menu_requested => |data| {
            log.debug("<{*}> show window menu requested: (x: {}, y: {})", .{ window, data.x, data.y });
        },
        .unreliable_pid => |data| {
            log.debug("<{*}> unreliable pid: {}", .{ window, data.unreliable_pid });

            window.pid = data.unreliable_pid;
        },
        .presentation_hint => |data| {
            log.debug("<{*}> presentation_hint: {s}", .{ window, @tagName(data.hint) });
        },
        .identifier => |data| {
            log.debug("<{*}> identifier: {s}", .{ window, data.identifier });
        },
    }
}
