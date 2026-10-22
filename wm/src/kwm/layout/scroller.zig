const Self = @This();

const std = @import("std");
const log = std.log.scoped(.scroller);

const Context = @import("../context.zig");
const Gesture = @import("../gesture.zig");
const Output = @import("../output.zig");
const Window = @import("../window.zig");

const ctx = Context.get();


outer_gap: i32,
inner_gap: i32,
mfact: f32,
// a lone tiled window sits in the middle of the output instead of at the left
center_single: bool = false,


pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    const focus_top = ctx.focus_top_in(output, true) orelse return;

    // focus moved since the last arrange (key binding, click, new window): slide instead of jumping
    if (output.gesture_anchor == null and ctx.cfg.gesture.animate_bindings) {
        if (output.scroller_prev_focus) |prev| if (prev != focus_top) {
            if (find_tiled(output, prev)) |window| {
                output.gesture_anchor = .{ .window = window, .x = window.x };
            }
        };
    }
    output.scroller_prev_focus = focus_top;

    const available_width = output.exclusive_width();
    const available_height = output.exclusive_height();

    const master_width = self.animated_width(focus_top, available_width);
    const height = available_height - 2*self.outer_gap;
    const y = self.outer_gap;

    const left = @max(self.outer_gap, blk: {
        var link = &focus_top.link;
        while (link.prev.? != &ctx.windows.link) {
            defer link = link.prev.?;
            const window: *Window = @fieldParentPtr("link", link.prev.?);
            if (window.is_visible_in(output) and !window.floating) {
                break :blk switch (window.scroller_x orelse break :blk self.outer_gap) {
                    .x => |x| x,
                    .center => window.x,
                } + window.width + self.inner_gap;
            }
        }
        break :blk self.outer_gap;
    });
    const right = output.width - self.outer_gap - master_width;
    const master_x = blk: {
        if (self.center_single and is_single(output, focus_top)) {
            break :blk @divFloor(output.width-master_width, 2);
        }
        const x = if (focus_top.scroller_x) |scroller_x| switch (scroller_x) {
            .x => |x| x,
            .center => break :blk @divFloor(output.width-focus_top.width, 2),
        } else left;
        break :blk if (x > right) right else left;
    };
    if (focus_top.scroller_x == null or focus_top.scroller_x.? == .x) {
        focus_top.scroller_x = .{ .x = master_x };
    }

    focus_top.unbound_move(master_x, y);
    focus_top.unbound_resize(master_width, height);

    {
        var link = &focus_top.link;
        var x = master_x;
        while (link.prev.? != &ctx.windows.link) {
            defer link = link.prev.?;
            const window: *Window = @fieldParentPtr("link", link.prev.?);
            if (!window.is_visible_in(output) or window.floating) continue;

            x -= self.inner_gap;

            const width = self.animated_width(window, available_width);

            x -= width;
            window.scroller_x = .{ .x = x };
            window.unbound_move(x, y);
            window.unbound_resize(width, height);
        }
    }

    {
        var link = &focus_top.link;
        var x = master_x + master_width;
        while (link.next.? != &ctx.windows.link) {
            defer link = link.next.?;
            const window: *Window = @fieldParentPtr("link", link.next.?);
            if (!window.is_visible_in(output) or window.floating) continue;

            x += self.inner_gap;

            const width = self.animated_width(window, available_width);

            window.scroller_x = .{ .x = x };
            window.unbound_move(x, y);
            window.unbound_resize(width, height);
            x += width;
        }
    }

    if (output.gesture_anchor) |anchor| {
        output.gesture_anchor = null;
        if (find_tiled(output, anchor.window)) |window| {
            Gesture.start_settle(output, anchor.x - window.x);
        }
    }

    const offset_x = output.gesture_offset_x;
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (!window.is_visible_in(output) or window.floating) continue;
        // the window list was reordered: slide each window from where it was shown
        if (window.move_from_x) |from| {
            window.move_from_x = null;
            Gesture.start_settle_window(window, from - (window.x + offset_x));
        }
        window.unbound_move(window.x + offset_x + window.move_offset_x, null);
    }
}


// column width while a width change animates, starting it if one is pending
fn animated_width(self: *const Self, window: *Window, available_width: i32) i32 {
    const width = self.column_width(available_width, window.scroller_mfact);
    // a new window opens as a thin column and grows to its own width
    if (window.opening) {
        window.opening = false;
        window.width_from = window.width_from orelse 1;
    }
    if (window.width_from) |from| {
        window.width_from = null;
        window.width_hold = @max(from, width);
        window.width_settling = true;
        Gesture.start_settle_width(window, from - width);
    }
    return @max(1, width + window.width_offset);
}


// mfact 1 (a maximized window) fills the space between the outer gaps
fn column_width(self: *const Self, available_width: i32, mfact: f32) i32 {
    const width: i32 = @intFromFloat(@as(f32, @floatFromInt(available_width)) * mfact);
    return @min(width, available_width - 2*self.outer_gap);
}


// `window` is the only tiled window visible in `output`
fn is_single(output: *Output, window: *Window) bool {
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |other| {
        if (other != window and other.is_visible_in(output) and !other.floating) return false;
    }
    return true;
}


// compare by address only, `target` may already be destroyed
fn find_tiled(output: *Output, target: *Window) ?*Window {
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window == target and window.is_visible_in(output) and !window.floating) return window;
    }
    return null;
}
