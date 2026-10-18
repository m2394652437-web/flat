const Self = @This();
const std = @import("std");
const log = std.log.scoped(.overview);
const config = @import("config");
const Context = @import("context.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const Gesture = @import("gesture.zig");

pub const mode = "overview";
pub const Direction = enum {
    up,
    down,
    left,
    right,
};

const ctx = Context.get();

active: bool = false,
selected: ?*Window = null,
// a window was closed, leave if the current output has none left
check_empty: bool = false,

// the compositor can scale windows: the overview zooms out of the workspace like niri,
// instead of resizing every window to fit its rows on the output
pub fn zoomed() bool {
    return ctx.rwm_window_scale != null;
}

pub fn toggle(self: *Self) void {
    if (self.active) self.exit() else self.enter();
}

pub fn enter(self: *Self) void {
    if (self.active) return;
    if (first_candidate() == null) return;
    log.debug("enter overview", .{});

    self.active = true;
    self.selected = ctx.focused_window();
    ctx.switch_mode(mode);

    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        const fullscreen_output: ?*Output = switch (window.fullscreen) {
            .output => |output| output,
            else => null,
        };
        window.overview_saved = .{
            .x = window.x,
            .y = window.y,
            .width = window.width,
            .height = window.height,
            .fullscreen = fullscreen_output,
        };
        if (fullscreen_output != null) window.prepare_unfullscreen();
    }

    if (zoomed()) {
        var oit = ctx.outputs.iterator(.forward);
        while (oit.next()) |output| Gesture.start_zoom(output, ctx.cfg.gesture.overview_zoom);
    }
}

pub fn exit(self: *Self) void {
    if (!self.active) return;
    log.debug("exit overview", .{});

    self.active = false;
    self.selected = null;
    self.check_empty = false;

    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        const saved = window.overview_saved orelse continue;
        window.overview_saved = null;
        // the zoomed out overview keeps the layout, the windows are arranged where they belong
        if (!zoomed()) {
            window.unbound_move(saved.x, saved.y);
            window.unbound_resize(saved.width, saved.height);
        }
        if (saved.fullscreen) |output| window.prepare_fullscreen(output);
    }

    var oit = ctx.outputs.iterator(.forward);
    while (oit.next()) |output| {
        if (zoomed()) {
            Gesture.start_zoom(output, 1);
        } else {
            // stop a workspace slide, the scroller reads this offset too
            Gesture.start_settle(output, 0);
        }
    }

    ctx.switch_mode(config.default_mode);
}

// switch the workspace of `output` while staying in overview; the new one slides in
// from the side it lies on, so going left moves the windows to the right
pub fn set_workspace(self: *Self, output: *Output, workspace: u8) void {
    const prev = output.workspace;
    output.set_workspace(workspace);
    if (output.workspace == prev) return;

    self.selected = null;
    // set_workspace slides the workspaces itself
    if (zoomed() or !ctx.cfg.gesture.animate_bindings) return;
    const side: i32 = if (workspace < prev) -1 else 1;
    Gesture.start_settle(output, side * output.exclusive_width());
}

pub fn arrange(self: *Self, output: *Output) void {
    log.debug("arrange output {*}", .{output});
    const outer_gap = ctx.cfg.layout.scroller.outer_gap;
    const inner_gap = ctx.cfg.layout.scroller.inner_gap;
    const width = output.exclusive_width();
    const height = output.exclusive_height();

    if (self.selected) |s| {
        if (s.output == output and !is_candidate(s, output)) self.selected = null;
    }
    if (self.selected == null and ctx.current_output == output) {
        self.selected = first_candidate();
    }

    const mask = rows_mask(output) | output.main_tag;
    const nrows: i32 = @popCount(mask);

    const full_height = height - 2 * outer_gap;
    const row_height = @divFloor(full_height - (nrows - 1) * inner_gap, nrows);
    if (row_height <= 0) return;
    const scale = @as(f32, @floatFromInt(row_height)) / @as(f32, @floatFromInt(full_height));

    var m = mask;
    var r: i32 = 0;
    while (m != 0) : ({
        m &= m - 1;
        r += 1;
    }) {
        const row: u5 = @intCast(@ctz(m));
        const y = outer_gap + r * (row_height + inner_gap);

        const anchor = blk: {
            if (self.selected) |s| {
                if (s.output == output and row_of(s) == row) break :blk s;
            }
            break :blk focus_top_in_row(output, row);
        };

        var total_width: i32 = 0;
        var anchor_x: i32 = 0;
        var anchor_width: i32 = 0;
        {
            var it = ctx.windows.safeIterator(.forward);
            while (it.next()) |window| {
                if (!in_row(window, output, row)) continue;
                const w = cell_width(window, width, scale);
                if (total_width > 0) total_width += inner_gap;
                if (window == anchor) {
                    anchor_x = total_width;
                    anchor_width = w;
                }
                total_width += w;
            }
        }

        var x = output.gesture_offset_x + if (total_width <= width - 2 * outer_gap) @divFloor(width - total_width, 2) else std.math.clamp(@divFloor(width - anchor_width, 2) - anchor_x, width - outer_gap - total_width, outer_gap);

        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (!in_row(window, output, row)) continue;
            const w = cell_width(window, width, scale);
            window.unbound_move(x, y);
            window.unbound_resize(w, row_height);
            x += w + inner_gap;
        }
    }
}

pub fn is_candidate(window: *const Window, output: *const Output) bool {
    return window.output == output and window.workspace == output.workspace and !window.floating and window.swallowed_by == null;
}

inline fn row_of(window: *const Window) u5 {
    return @intCast(@ctz(window.tag));
}

inline fn in_row(window: *const Window, output: *const Output, row: u5) bool {
    return is_candidate(window, output) and row_of(window) == row;
}

inline fn rows_mask(output: *const Output) u32 {
    var mask: u32 = 0;
    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (is_candidate(window, output)) mask |= @as(u32, 1) << row_of(window);
    }
    return mask;
}

inline fn cell_width(window: *const Window, output_width: i32, scale: f32) i32 {
    return @max(window.min_width, @as(i32, @intFromFloat(window.scroller_mfact * @as(f32, @floatFromInt(output_width)) * scale)));
}

fn neighbor(window: *Window, comptime dir: enum { prev, next }) ?*Window {
    const output = window.output orelse return null;
    const row = row_of(window);
    var link = &window.link;
    while (@field(link, @tagName(dir)).? != &ctx.windows.link) {
        link = @field(link, @tagName(dir)).?;
        const w: *Window = @fieldParentPtr("link", link);
        if (in_row(w, output, row)) return w;
    }
    return null;
}

pub fn select(self: *Self, direction: Direction) void {
    if (zoomed()) return select_focus(direction);

    const current = self.selected orelse {
        self.selected = first_candidate();
        return;
    };

    const output = current.output orelse return;

    self.selected = switch (direction) {
        .left => neighbor(current, .prev),
        .right => neighbor(current, .next),
        .up, .down => blk: {
            const target = adjacent_row(output, row_of(current), direction) orelse break :blk null;
            break :blk nth_in_row(output, target, column_of(current));
        },
    } orelse current;
}

pub fn first_candidate() ?*Window {
    const output = ctx.current_output orelse return null;
    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (is_candidate(window, output)) return window;
    }
    return null;
}

fn adjacent_row(output: *const Output, row: u5, direction: Direction) ?u5 {
    const mask = rows_mask(output);
    const bit = @as(u32, 1) << row;
    return switch (direction) {
        .up => blk: {
            const above = mask & (bit - 1);
            break :blk if (above == 0) null else @intCast(31 - @clz(above));
        },
        .down => blk: {
            const below = mask & ~((bit << 1) -% 1);
            break :blk if (below == 0) null else @intCast(@ctz(below));
        },
        else => unreachable,
    };
}

fn column_of(window: *Window) usize {
    const output = window.output orelse return 0;
    const row = row_of(window);
    var i: usize = 0;
    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |w| {
        if (w == window) break;
        if (in_row(w, output, row)) i += 1;
    }
    return i;
}

fn nth_in_row(output: *const Output, row: u5, n: usize) ?*Window {
    var last: ?*Window = null;
    var i: usize = 0;
    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (!in_row(window, output, row)) continue;
        if (i == n) return window;
        last = window;
        i += 1;
    }
    return last;
}

fn focus_top_in_row(output: *const Output, row: u5) ?*Window {
    var it = ctx.focus_stack.safeIterator(.forward);
    while (it.next()) |window| {
        if (in_row(window, output, row)) return window;
    }
    return null;
}

fn tag_count() u32 {
    return if (ctx.cfg.bar.tags) |area| @intCast(area.tags.len) else 9;
}

// the zoomed out overview moves the real focus, the view follows it like outside the overview
fn select_focus(direction: Direction) void {
    const current = ctx.focused_window() orelse {
        if (first_candidate()) |window| focus_row(window);
        return;
    };
    const output = current.output orelse return;
    const target = switch (direction) {
        .left => neighbor(current, .prev),
        .right => neighbor(current, .next),
        .up, .down => blk: {
            const row = adjacent_row(output, row_of(current), direction) orelse break :blk null;
            break :blk focus_top_in_row(output, row);
        },
    } orelse return;
    focus_row(target);
}

// focus `window` and show its row
fn focus_row(window: *Window) void {
    const output = window.output orelse return;
    output.set_tag(@as(u32, 1) << row_of(window));
    ctx.focus(window, true);
}

pub fn move(self: *Self, direction: Direction) void {
    if (zoomed()) {
        const current = ctx.focused_window() orelse return;
        const output = current.output orelse return;
        switch (direction) {
            .left => ctx.swap(.reverse),
            .right => ctx.swap(.forward),
            .up, .down => {
                const row = row_of(current);
                const new_row: u5 = switch (direction) {
                    .up => if (row == 0) return else row - 1,
                    .down => if (@as(u32, row) + 1 >= tag_count()) return else row + 1,
                    else => unreachable,
                };
                current.set_tag(@as(u32, 1) << new_row);
                // the view follows the window to its new row
                output.set_tag(current.tag);
                ctx.focus(current, true);
            },
        }
        return;
    }

    const current = self.selected orelse return;

    switch (direction) {
        .left => if (neighbor(current, .prev)) |w| current.link.swapWith(&w.link),
        .right => if (neighbor(current, .next)) |w| current.link.swapWith(&w.link),
        .up, .down => {
            const row = row_of(current);
            const new_row: u5 = switch (direction) {
                .up => if (row == 0) return else row - 1,
                .down => if (@as(u32, row) + 1 >= tag_count()) return else row + 1,
                else => unreachable,
            };
            current.set_tag(@as(u32, 1) << new_row);
        },
    }
}

pub fn confirm(self: *Self) void {
    // the focused window is already the selected one and its row is shown
    if (zoomed()) return self.exit();

    const window = self.selected orelse return self.exit();

    self.exit();

    if (window.output) |output| {
        if (!window.is_visible_in(output)) output.set_tag(@as(u32, 1) << row_of(window));
    }
    ctx.focus(window, true);
}
