const Self = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const log = std.log.scoped(.gesture);

const posix = @import("posix");
const config = @import("config");
const wayland = @import("wayland");
const river = wayland.client.river;

const binding = @import("binding.zig");
const Output = @import("output.zig");
const Overview = @import("overview.zig");
const Window = @import("window.zig");
const Context = @import("context.zig");

const ctx = Context.get();

const Udev = opaque {};
const Libinput = opaque {};
const Event = opaque {};
const GestureEvent = opaque {};

extern fn udev_new() ?*Udev;
extern fn udev_unref(*Udev) ?*Udev;
extern fn libinput_udev_create_context(*const Interface, ?*anyopaque, *Udev) ?*Libinput;
extern fn libinput_udev_assign_seat(*Libinput, [*:0]const u8) c_int;
extern fn libinput_unref(*Libinput) ?*Libinput;
extern fn libinput_get_fd(*Libinput) c_int;
extern fn libinput_dispatch(*Libinput) c_int;
extern fn libinput_get_event(*Libinput) ?*Event;
extern fn libinput_event_get_type(*Event) c_int;
extern fn libinput_event_destroy(*Event) void;
extern fn libinput_event_get_gesture_event(*Event) *GestureEvent;
extern fn libinput_event_gesture_get_finger_count(*GestureEvent) c_int;
extern fn libinput_event_gesture_get_dx_unaccelerated(*GestureEvent) f64;
extern fn libinput_event_gesture_get_dy_unaccelerated(*GestureEvent) f64;
extern fn libinput_event_gesture_get_cancelled(*GestureEvent) c_int;
extern fn libinput_event_gesture_get_time_usec(*GestureEvent) u64;

const Interface = extern struct {
    open_restricted: *const fn ([*:0]const u8, c_int, ?*anyopaque) callconv(.c) c_int,
    close_restricted: *const fn (c_int, ?*anyopaque) callconv(.c) void,
};

const interface: Interface = .{
    .open_restricted = open_restricted,
    .close_restricted = close_restricted,
};

// enum libinput_event_type in libinput.h
const SWIPE_BEGIN = 800;
const SWIPE_UPDATE = 801;
const SWIPE_END = 802;


// distance before the swipe axis is locked
const axis_lock_distance = 16;

// interval between animation frames
const frame_ms = 8;
// movement within this window before release decides the fling velocity
const velocity_window_us = 100 * std.time.us_per_ms;

const Axis = enum { undecided, horizontal, vertical };

// whether an animation tick is already scheduled
var ticking = false;
// time of the last render sequence, animations started after it have not been shown yet
var last_render_ms: i64 = 0;

// where a window was shown, in layout coordinates and on screen size
pub const Box = struct { x: i32, y: i32, width: f64, height: f64 };

// a closed window shrinking away around its center while it fades out
const Ghost = struct {
    object: *river.WindowGhostV1,
    box: Box,
    // set by the first render after the window closed
    start_ms: ?i64 = null,
};
var ghosts: std.ArrayList(Ghost) = .empty;


li: *Libinput,
fd: posix.fd_t,
dx: f64 = 0,
dy: f64 = 0,
axis: Axis = .undecided,
// output whose scroller follows the fingers, null if not tracking
tracking: ?*Output = null,
// output whose tags follow the fingers vertically, null if not tracking
tracking_y: ?*Output = null,
// the swipe has workspace_fingers fingers
workspace_swipe: bool = false,
// output whose workspaces follow the fingers, null if not tracking
tracking_workspace: ?*Output = null,
// recent updates, used to compute the velocity at release
samples: [16]Sample = undefined,
sample_count: usize = 0,

const Sample = struct { time_us: u64, dx: f64, dy: f64 };


pub fn init(self: *Self) !void {
    const udev = udev_new() orelse return error.UdevNewFailed;
    // libinput holds its own reference
    defer _ = udev_unref(udev);

    const li = libinput_udev_create_context(&interface, null, udev) orelse return error.LibinputCreateFailed;
    errdefer _ = libinput_unref(li);

    if (libinput_udev_assign_seat(li, "seat0") != 0) return error.LibinputAssignSeatFailed;

    self.* = .{ .li = li, .fd = libinput_get_fd(li) };
}


pub fn deinit(self: *Self) void {
    _ = libinput_unref(self.li);
}


pub fn dispatch(self: *Self) void {
    _ = libinput_dispatch(self.li);
    while (libinput_get_event(self.li)) |event| {
        defer libinput_event_destroy(event);
        self.handle_event(event);
    }
}


fn handle_event(self: *Self, event: *Event) void {
    const event_type = libinput_event_get_type(event);
    switch (event_type) {
        SWIPE_BEGIN, SWIPE_UPDATE, SWIPE_END => {},
        else => return,
    }
    const g = libinput_event_get_gesture_event(event);
    const fingers = libinput_event_gesture_get_finger_count(g);
    if (fingers != ctx.cfg.gesture.fingers and fingers != ctx.cfg.gesture.workspace_fingers) return;

    // libinput is read directly, so the lock screen has to be respected here
    if (!ctx.cfg.gesture.enabled or mem.eql(u8, ctx.mode, config.lock_mode)) {
        self.abort();
        return;
    }
    // the tracked output may have been unplugged since the last event
    if (self.tracking) |output| if (!alive(output)) {
        self.tracking = null;
    };
    if (self.tracking_y) |output| if (!alive(output)) {
        self.tracking_y = null;
    };
    if (self.tracking_workspace) |output| if (!alive(output)) {
        self.tracking_workspace = null;
    };

    switch (event_type) {
        SWIPE_BEGIN => {
            self.dx = 0;
            self.dy = 0;
            self.axis = .undecided;
            self.tracking = null;
            self.tracking_y = null;
            self.tracking_workspace = null;
            self.workspace_swipe = fingers == ctx.cfg.gesture.workspace_fingers;
            self.sample_count = 0;
        },
        SWIPE_UPDATE => {
            const dx = libinput_event_gesture_get_dx_unaccelerated(g);
            const dy = libinput_event_gesture_get_dy_unaccelerated(g);
            self.dx += dx;
            self.dy += dy;
            self.samples[self.sample_count % self.samples.len] = .{
                .time_us = libinput_event_gesture_get_time_usec(g),
                .dx = dx,
                .dy = dy,
            };
            self.sample_count += 1;

            if (self.axis == .undecided and @abs(self.dx) + @abs(self.dy) >= axis_lock_distance) {
                self.axis = if (@abs(self.dx) >= @abs(self.dy)) .horizontal else .vertical;
                if (self.workspace_swipe) {
                    if (self.axis == .horizontal) if (workspace_output()) |output| {
                        // grab the workspaces where they are, even if they are still settling
                        output.workspace_anim_start_ms = null;
                        output.gesture_base = output.workspace_offset_x;
                        self.tracking_workspace = output;
                    };
                } else if (self.axis == .horizontal) {
                    if (scroller_output()) |output| {
                        // grab the view where it is, even if it is still settling
                        output.gesture_anim_start_ms = null;
                        output.gesture_anchor = null;
                        output.gesture_base = output.gesture_offset_x;
                        self.tracking = output;
                    }
                } else if (tag_output()) |output| {
                    // grab the tags where they are, even if they are still settling
                    output.gesture_anim_y_start_ms = null;
                    output.gesture_base = output.gesture_offset_y;
                    self.tracking_y = output;
                }
            }

            if (self.tracking_y) |output| {
                const offset = output.gesture_base + @as(i32, @intFromFloat(@round(self.dy * ctx.cfg.gesture.tag_scroll_factor)));
                set_peek(output, offset);
                // nothing to reveal: resist instead of moving freely
                output.gesture_offset_y = if (output.gesture_peek_tag == 0) rubber(offset, 0) else offset;
                ctx.rwm.manageDirty();
            }

            if (self.tracking) |output| {
                const offset = output.gesture_base + @as(i32, @intFromFloat(@round(self.dx * ctx.cfg.gesture.scroll_factor)));
                output.gesture_offset_x = damp_x(output, offset);
                ctx.rwm.manageDirty();
            }

            if (self.tracking_workspace) |output| {
                const offset = output.gesture_base + @as(i32, @intFromFloat(@round(self.dx * ctx.cfg.gesture.scroll_factor)));
                set_peek_workspace(output, offset);
                // nothing to reveal: resist instead of moving freely
                const shown = if (output.peek_workspace == null) rubber(offset, 0) else offset;
                output.workspace_offset_x = shown;
                output.peek_workspace_offset_x = shown;
                output.peek_workspace_overhang_x = 0;
                ctx.rwm.manageDirty();
            }
        },
        SWIPE_END => {
            const cancelled = libinput_event_gesture_get_cancelled(g) != 0;
            // where the fingers would have ended up had they kept their release speed
            const vx, const vy = self.velocity(libinput_event_gesture_get_time_usec(g));
            const px = self.dx + vx * ctx.cfg.gesture.fling;
            const py = self.dy + vy * ctx.cfg.gesture.fling;
            log.debug("swipe end dx={d:.2} dy={d:.2} projected=({d:.2}, {d:.2}) cancelled={}", .{ self.dx, self.dy, px, py, cancelled });

            if (self.tracking_workspace) |output| {
                defer self.tracking_workspace = null;
                const offset = output.workspace_offset_x;
                // the fling has to point the same way as the revealed workspace
                const towards_peek = (px < 0) == (offset < 0);
                if (!cancelled and @abs(px) >= ctx.cfg.gesture.threshold and towards_peek and output.peek_workspace != null) {
                    // set_workspace starts the slide from where both workspaces are now
                    trigger(.{ .set_workspace = .{ .workspace = output.peek_workspace.? + 1 } });
                } else {
                    start_settle_workspace(output, offset);
                }
                ctx.rwm.manageDirty();
                return;
            }

            if (self.tracking) |output| {
                defer self.tracking = null;
                const steps = if (cancelled) 0 else scroll_steps(output, px);
                // remember where the current window is on screen, the next arrange
                // turns the jump to the new resting position into an animation
                if (ctx.focus_top_in(output, true)) |window| {
                    output.gesture_anchor = .{ .window = window, .x = window.x };
                }
                output.gesture_offset_x = 0;
                for (0..steps) |_| trigger(.{ .focus_iter = .{ .direction = if (px < 0) .forward else .reverse } });
                ctx.rwm.manageDirty();
                return;
            }

            if (self.tracking_y) |output| {
                defer self.tracking_y = null;
                const offset = output.gesture_offset_y;
                // the fling has to point the same way as the revealed tag
                const towards_peek = (py < 0) == (offset < 0);
                if (!cancelled and @abs(py) >= ctx.cfg.gesture.threshold and towards_peek and output.gesture_peek_tag != 0) {
                    // switch to the revealed tag, it keeps its on-screen position and
                    // slides in while the old tag becomes the one sliding out
                    const old_tag = output.tag;
                    const side = output.gesture_peek_side;
                    // step instead of jumping to the tag, so dynamic tags can wrap around
                    trigger(.{ .set_output_tag = .{ .tag = .{ .direction = if (side == 1) .forward else .reverse } } });
                    // the switch is animated here, the next arrange must not animate it again
                    output.gesture_prev_tag = output.gesture_peek_tag;
                    output.gesture_peek_tag = old_tag;
                    output.gesture_peek_side = -side;
                    start_settle_y(output, offset + side * output.exclusive_height());
                } else if (!cancelled and @abs(py) >= ctx.cfg.gesture.threshold and output.gesture_peek_tag == 0 and peek_exists(output, py)) {
                    // nothing to preview (floating tag), switch without the slide
                    output.gesture_offset_y = 0;
                    trigger(.{ .set_output_tag = .{ .tag = .{ .direction = if (py < 0) .forward else .reverse } } });
                } else {
                    start_settle_y(output, offset);
                }
                ctx.rwm.manageDirty();
                return;
            }

            if (cancelled) return;
            if (self.resolve_action()) |action| trigger(action);
        },
        else => unreachable,
    }
}


// drop the gesture in progress and put everything back in place
fn abort(self: *Self) void {
    if (self.tracking) |output| if (alive(output)) start_settle(output, output.gesture_offset_x);
    if (self.tracking_y) |output| if (alive(output)) start_settle_y(output, output.gesture_offset_y);
    if (self.tracking_workspace) |output| if (alive(output)) start_settle_workspace(output, output.workspace_offset_x);
    self.tracking = null;
    self.tracking_y = null;
    self.tracking_workspace = null;
    self.axis = .undecided;
}


// compare by address only, `output` may already be destroyed
fn alive(output: *Output) bool {
    var it = ctx.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (o == output) return true;
    }
    return false;
}


// average velocity (units per second) of the updates within `velocity_window_us` before `end_us`
fn velocity(self: *const Self, end_us: u64) struct { f64, f64 } {
    const count = @min(self.sample_count, self.samples.len);
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var oldest: u64 = end_us;
    for (0..count) |i| {
        const sample = self.samples[(self.sample_count - 1 - i) % self.samples.len];
        if (sample.time_us + velocity_window_us < end_us) break;
        sum_x += sample.dx;
        sum_y += sample.dy;
        oldest = sample.time_us;
    }
    // the oldest sample's movement happened before its timestamp, count one more frame
    const span_us = end_us - oldest + 10 * std.time.us_per_ms;
    const span_s = @as(f64, @floatFromInt(span_us)) / std.time.us_per_s;
    return .{ sum_x / span_s, sum_y / span_s };
}


// past `limit`, movement is damped and approaches `limit + rubber_band`
fn rubber(offset: i32, limit: i32) i32 {
    const magnitude: i32 = @intCast(@abs(offset));
    if (magnitude <= limit) return offset;
    const over: f64 = @floatFromInt(magnitude - limit);
    const band: f64 = @floatFromInt(ctx.cfg.gesture.rubber_band);
    const stretched = limit + @as(i32, @intFromFloat(@round(band * over / (over + band))));
    return if (offset < 0) -stretched else stretched;
}


// horizontal offset limited to the columns that actually exist in that direction
fn damp_x(output: *Output, offset: i32) i32 {
    if (offset == 0) return 0;
    const focus_top = ctx.focus_top_in(output, true) orelse return offset;
    const column = focus_top.width + output.scroller().inner_gap;
    const beyond: i32 = @intCast(windows_beyond(output, focus_top, offset < 0));
    return rubber(offset, beyond * column);
}


// whether there is a tag to switch to in the direction of `dy`, even one that cannot be previewed
fn peek_exists(output: *Output, dy: f64) bool {
    const tag: binding.Tag = .{ .direction = if (dy < 0) .forward else .reverse };
    const peek = tag.of(.{ .output = output });
    return peek != 0 and peek != output.tag;
}


// start animating `output`'s offset from `from` back to 0
pub fn start_settle(output: *Output, from: i32) void {
    output.gesture_offset_x = from;
    if (from == 0) {
        output.gesture_anim_start_ms = null;
        return;
    }
    output.gesture_anim_from = @floatFromInt(from);
    output.gesture_anim_start_ms = now_ms();
    if (!ticking) {
        ticking = true;
        ctx.run_later(.fromMilliseconds(frame_ms), tick);
    }
}


// start animating `output`'s vertical offset from `from` back to 0, the peek tag goes away at the end
pub fn start_settle_y(output: *Output, from: i32) void {
    output.gesture_offset_y = from;
    if (from == 0) {
        output.gesture_anim_y_start_ms = null;
        output.gesture_peek_tag = 0;
        return;
    }
    output.gesture_anim_y_from = @floatFromInt(from);
    output.gesture_anim_y_start_ms = now_ms();
    if (!ticking) {
        ticking = true;
        ctx.run_later(.fromMilliseconds(frame_ms), tick);
    }
}


// start animating `output`'s workspace offset from `from` back to 0, the peek workspace goes away at the end
pub fn start_settle_workspace(output: *Output, from: i32) void {
    output.workspace_offset_x = from;
    output.peek_workspace_offset_x = from;
    output.peek_workspace_overhang = if (from == 0) 0 else output.peek_overhang();
    output.peek_workspace_overhang_x = 0;
    if (from == 0) {
        output.workspace_anim_start_ms = null;
        output.peek_workspace = null;
        output.peek_workspace_offset_x = 0;
        return;
    }
    output.workspace_anim_from = @floatFromInt(from);
    output.workspace_anim_start_ms = now_ms();
    start_ticking();
}


// start animating `output`'s zoom from where it is now to `to`
pub fn start_zoom(output: *Output, to: f64) void {
    if (!ctx.cfg.gesture.animate_bindings or output.zoom == to) {
        output.zoom = to;
        output.zoom_anim_start_ms = null;
        return;
    }
    output.zoom_anim_from = output.zoom;
    output.zoom_anim_to = to;
    output.zoom_anim_start_ms = now_ms();
    start_ticking();
}


// shrink the ghost of a closed window that was shown at `box`, destroys it at the end
pub fn start_ghost(object: *river.WindowGhostV1, box: Box) void {
    ghosts.append(ctx.gpa, .{ .object = object, .box = box }) catch {
        object.destroy();
        return;
    };
    start_ticking();
}

// called at render start, the ghosts only accept changes in a render sequence
pub fn render_ghosts() void {
    const now = now_ms();
    const denominator = 1 << 16;
    var i: usize = 0;
    while (i < ghosts.items.len) {
        const ghost = &ghosts.items[i];
        const start = ghost.start_ms orelse now;
        ghost.start_ms = start;
        const p = progress(now, start) orelse {
            ghost.object.destroy();
            _ = ghosts.swapRemove(i);
            continue;
        };
        const scale = @max(p, 1.0 / 64.0);
        const x = ghost.box.x + @as(i32, @intFromFloat(@round(ghost.box.width * (1 - scale) / 2)));
        const y = ghost.box.y + @as(i32, @intFromFloat(@round(ghost.box.height * (1 - scale) / 2)));
        ghost.object.setPosition(x, y);
        ghost.object.setScale(@intFromFloat(@round(scale * denominator)), denominator);
        ghost.object.setOpacity(@intFromFloat(@round(p * denominator)), denominator);
        i += 1;
    }
}

fn start_ticking() void {
    if (!ticking) {
        ticking = true;
        ctx.run_later(.fromMilliseconds(frame_ms), tick);
    }
}


// start animating `window`'s own offset from `from` back to 0
pub fn start_settle_window(window: *Window, from: i32) void {
    window.move_offset_x = from;
    if (from == 0) {
        window.move_anim_start_ms = null;
        return;
    }
    window.move_anim_from = @floatFromInt(from);
    window.move_anim_start_ms = now_ms();
    if (!ticking) {
        ticking = true;
        ctx.run_later(.fromMilliseconds(frame_ms), tick);
    }
}


// start animating `window`'s width offset from `from` back to 0
pub fn start_settle_width(window: *Window, from: i32) void {
    window.width_offset = from;
    if (from == 0) {
        window.width_anim_start_ms = null;
        return;
    }
    window.width_anim_from = @floatFromInt(from);
    window.width_anim_start_ms = now_ms();
    if (!ticking) {
        ticking = true;
        ctx.run_later(.fromMilliseconds(frame_ms), tick);
    }
}


fn tick(_: *Context) void {
    const now = now_ms();
    var active = false;

    var wit = ctx.windows.iterator(.forward);
    while (wit.next()) |window| {
        if (window.move_anim_start_ms) |start| {
            if (ease(now, start, window.move_anim_from)) |offset| {
                window.move_offset_x = offset;
                active = true;
            } else {
                window.move_offset_x = 0;
                window.move_anim_start_ms = null;
            }
        }
        if (window.width_anim_start_ms) |start| {
            if (ease(now, start, window.width_anim_from)) |offset| {
                window.width_offset = offset;
                active = true;
            } else {
                window.width_offset = 0;
                window.width_anim_start_ms = null;
            }
        }
    }

    var it = ctx.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (output.gesture_anim_start_ms) |start| {
            if (ease(now, start, output.gesture_anim_from)) |offset| {
                output.gesture_offset_x = offset;
                active = true;
            } else {
                output.gesture_offset_x = 0;
                output.gesture_anim_start_ms = null;
            }
        }
        if (output.gesture_anim_y_start_ms) |start| {
            if (ease(now, start, output.gesture_anim_y_from)) |offset| {
                output.gesture_offset_y = offset;
                active = true;
            } else {
                output.gesture_offset_y = 0;
                output.gesture_anim_y_start_ms = null;
                output.gesture_peek_tag = 0;
            }
        }
        if (output.workspace_anim_start_ms) |start| {
            // the old workspace leaves in half the time
            if (progress_in(now, start, ctx.cfg.gesture.settle_ms / 2)) |p| {
                output.peek_workspace_offset_x = @intFromFloat(@round(output.workspace_anim_from * p));
                output.peek_workspace_overhang_x = @intFromFloat(@round(@as(f64, @floatFromInt(output.peek_workspace_overhang)) * (1 - p)));
            } else {
                output.peek_workspace_offset_x = 0;
                output.peek_workspace_overhang_x = output.peek_workspace_overhang;
            }
            if (ease(now, start, output.workspace_anim_from)) |offset| {
                output.workspace_offset_x = offset;
                active = true;
            } else {
                output.workspace_offset_x = 0;
                output.workspace_anim_start_ms = null;
                output.peek_workspace = null;
            }
        }
        if (output.zoom_anim_start_ms) |start| {
            if (progress(now, start)) |p| {
                output.zoom = output.zoom_anim_to + (output.zoom_anim_from - output.zoom_anim_to) * p;
                active = true;
            } else {
                output.zoom = output.zoom_anim_to;
                output.zoom_anim_start_ms = null;
            }
        }
    }

    // render_ghosts() moves them and drops the finished ones
    if (ghosts.items.len > 0) active = true;

    ctx.rwm.manageDirty();
    if (active) ctx.run_later(.fromMilliseconds(frame_ms), tick) else ticking = false;
}


// called at render start: an animation's clock starts with its first shown frame. river
// waits for the clients to answer a manage sequence before rendering it, and after a focus
// change a big browser redrawing itself as deactivated can take long enough that the
// easing would already be far along, so the slide would start with a jump
pub fn restart_unshown() void {
    const now = now_ms();
    defer last_render_ms = now;

    var wit = ctx.windows.iterator(.forward);
    while (wit.next()) |window| {
        restart_if_unshown(&window.move_anim_start_ms, now);
        restart_if_unshown(&window.width_anim_start_ms, now);
    }
    var it = ctx.outputs.iterator(.forward);
    while (it.next()) |output| {
        restart_if_unshown(&output.gesture_anim_start_ms, now);
        restart_if_unshown(&output.gesture_anim_y_start_ms, now);
        restart_if_unshown(&output.workspace_anim_start_ms, now);
        restart_if_unshown(&output.zoom_anim_start_ms, now);
    }
}

fn restart_if_unshown(start_ms: *?i64, now: i64) void {
    const start = start_ms.* orelse return;
    // a clock restarted by the previous render equals last_render_ms, it has been shown
    if (start <= last_render_ms) return;
    if (now - start > frame_ms) log.debug("animation shown {} ms after it started", .{now - start});
    start_ms.* = now;
}


// offset at `now` of an animation from `from` to 0, null once finished
fn ease(now: i64, start: i64, from: f64) ?i32 {
    const p = progress(now, start) orelse return null;
    return @intFromFloat(@round(from * p));
}

// remaining part of an animation at `now`, from 1 down to 0, null once finished
fn progress(now: i64, start: i64) ?f64 {
    return progress_in(now, start, ctx.cfg.gesture.settle_ms);
}

// like progress(), for an animation lasting `duration_ms`
fn progress_in(now: i64, start: i64, duration_ms: u32) ?f64 {
    const t = @as(f64, @floatFromInt(now - start)) / @as(f64, @floatFromInt(@max(1, duration_ms)));
    if (t >= 1) return null;
    // ease-out cubic: fast at first, slows down near the resting position
    return std.math.pow(f64, 1 - t, 3);
}


fn now_ms() i64 {
    return Io.Timestamp.now(ctx.io, .awake).toMilliseconds();
}


// the current output if its tags can follow the fingers vertically
fn tag_output() ?*Output {
    if (ctx.overview.active) return null;
    const output = ctx.current_output orelse return null;
    if (output.fullscreen_window() != null) return null;
    return output;
}


// pick the tag revealed by a vertical `offset`: dragging up shows the next tag below
fn set_peek(output: *Output, offset: i32) void {
    if (offset == 0) {
        output.gesture_peek_tag = 0;
        return;
    }
    const forward = offset < 0;
    const tag: binding.Tag = .{ .direction = if (forward) .forward else .reverse };
    const peek = tag.of(.{ .output = output });
    if (peek == 0 or peek == output.tag) {
        output.gesture_peek_tag = 0;
        return;
    }
    output.gesture_peek_tag = peek;
    output.gesture_peek_side = if (forward) 1 else -1;
}


// the current output if its workspaces can follow the fingers; the overview that is not
// zoomed lays out its own windows and switches without the slide
fn workspace_output() ?*Output {
    if (ctx.overview.active and !Overview.zoomed()) return null;
    return ctx.current_output;
}


// workspace next to the current one in the direction of `forward`, null at either end
fn neighbor_workspace(output: *const Output, forward: bool) ?u8 {
    if (forward) return if (output.workspace + 1 < Output.workspace_max) output.workspace + 1 else null;
    return if (output.workspace > 0) output.workspace - 1 else null;
}


// pick the workspace revealed by a horizontal `offset`: dragging left shows the next one on the right
fn set_peek_workspace(output: *Output, offset: i32) void {
    if (offset == 0) {
        output.peek_workspace = null;
        return;
    }
    const forward = offset < 0;
    output.peek_workspace = neighbor_workspace(output, forward);
    output.peek_workspace_side = if (forward) 1 else -1;
}


// the current output, its scroller can follow the fingers
fn scroller_output() ?*Output {
    if (ctx.overview.active) return null;
    return ctx.current_output;
}


// how many columns to move after a horizontal swipe on the scroller
fn scroll_steps(output: *Output, dx: f64) usize {
    if (@abs(dx) < ctx.cfg.gesture.threshold) return 0;
    const focus_top = ctx.focus_top_in(output, true) orelse return 0;
    const column: f64 = @floatFromInt(focus_top.width + output.scroller().inner_gap);
    const offset = @abs(dx * ctx.cfg.gesture.scroll_factor);
    // a short flick past the threshold still moves one column
    const steps = @max(1, @as(usize, @intFromFloat(@round(offset / column))));
    // never go past the end
    return @min(steps, windows_beyond(output, focus_top, dx < 0));
}


// number of tiled windows after (`forward`) or before the focused one
fn windows_beyond(output: *Output, focus_top: *Window, forward: bool) usize {
    var count: usize = 0;
    var seen_focus = false;
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (!window.is_visible_in(output) or window.floating) continue;
        if (window == focus_top) {
            seen_focus = true;
            if (!forward) return count;
            continue;
        }
        if (seen_focus) count += 1 else if (!forward) count += 1;
    }
    return count;
}


fn resolve_action(self: *const Self) ?binding.Action {
    if (self.workspace_swipe) {
        if (@abs(self.dx) < @abs(self.dy) or @abs(self.dx) < ctx.cfg.gesture.threshold) return null;
        const output = ctx.current_output orelse return null;
        const workspace = neighbor_workspace(output, self.dx < 0) orelse return null;
        return .{ .set_workspace = .{ .workspace = workspace + 1 } };
    }
    // like niri: fingers move left -> content moves left -> go to the next one
    if (@abs(self.dx) >= @abs(self.dy)) {
        if (@abs(self.dx) < ctx.cfg.gesture.threshold) return null;
        return .{ .focus_iter = .{ .direction = if (self.dx < 0) .forward else .reverse } };
    } else {
        if (@abs(self.dy) < ctx.cfg.gesture.threshold) return null;
        return .{ .set_output_tag = .{ .tag = .{ .direction = if (self.dy < 0) .forward else .reverse } } };
    }
}


fn trigger(action: binding.Action) void {
    const seat = ctx.current_seat orelse return;
    seat.append_action(action);
    ctx.rwm.manageDirty();
}


fn open_restricted(path: [*:0]const u8, flags: c_int, _: ?*anyopaque) callconv(.c) c_int {
    const fd = std.c.open(path, @bitCast(@as(u32, @intCast(flags))));
    return if (fd < 0) -@as(c_int, @intCast(@intFromEnum(std.c.errno(fd)))) else fd;
}


fn close_restricted(fd: c_int, _: ?*anyopaque) callconv(.c) void {
    _ = std.c.close(fd);
}
