const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const math = std.math;
const log = std.log.scoped(.output);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const config = @import("config");

const utils = @import("utils.zig");
const Layout = @import("layout.zig");
const Context = @import("context.zig");
const Window = @import("window.zig");
const Gesture = @import("gesture.zig");
const Overview = @import("overview.zig");
const types = @import("types.zig");

// number of workspaces per output, switched with mod+1..mod+9
pub const workspace_max = 9;

// rows of a workspace, `tag` selects the shown ones like the tags of dwm
pub const Workspace = struct {
    layouts: [32]Layout,

    tag: u32 = 1,
    main_tag: u32 = 1,
    prev_tag: u32 = 1,
    prev_main_tag: u32 = 1,
};

pub const State = struct {
    layouts: [32]Layout,

    tag: u32 = 1,
    main_tag: u32 = 1,
    prev_tag: u32 = 1,
    prev_main_tag: u32 = 1,

    workspace: u8 = 0,
    workspaces: [workspace_max]Workspace,
};

const ctx = Context.get();

link: wl.list.Link = undefined,

wl_output: ?*wl.Output = null,
rwm_output: *river.OutputV1,
rwm_layer_shell_output: ?*river.LayerShellOutputV1,

// rows of the current workspace
layouts: [32]Layout,

tag: u32 = 1,
main_tag: u32 = 1,
prev_tag: u32 = 1,
prev_main_tag: u32 = 1,

// index of the shown workspace, windows of the other ones are hidden
workspace: u8 = 0,
// rows of every workspace; the entry of the current one is stale, the fields above are used instead
workspaces: [workspace_max]Workspace,
// horizontal offset applied by scroller layout while a touchpad swipe is in progress
gesture_offset_x: i32 = 0,
// offset when the current swipe started, the finger movement is added on top of it
gesture_base: i32 = 0,
// window to keep at its on-screen x on the next arrange, so the release does not jump
gesture_anchor: ?struct { window: *Window, x: i32 } = null,
// settle animation of gesture_offset_x back to 0
gesture_anim_from: f64 = 0,
gesture_anim_start_ms: ?i64 = null,
// vertical offset of the tiled windows during a vertical swipe
gesture_offset_y: i32 = 0,
// adjacent tag shown next to the current one during a vertical swipe, 0 if none
gesture_peek_tag: u32 = 0,
// 1: the peek tag is below the current one, -1: above
gesture_peek_side: i32 = 1,
// settle animation of gesture_offset_y back to 0
gesture_anim_y_from: f64 = 0,
gesture_anim_y_start_ms: ?i64 = null,
// tag shown by the last arrange, to animate tag switches; 0 if unknown
gesture_prev_tag: u32 = 0,
// direction of the last step_tag (1: next, -1: previous, 0: none), so a wrap-around
// still slides in from the direction of travel
tag_step_direction: i32 = 0,
// focused window of the last scroller arrange, to animate focus changes
scroller_prev_focus: ?*Window = null,
// the view is zoomed by this factor around the center of the output, see Window.render
zoom: f64 = 1,
// zoom animation between overview and normal view
zoom_anim_from: f64 = 1,
zoom_anim_to: f64 = 1,
zoom_anim_start_ms: ?i64 = null,
// horizontal offset of the current workspace while a workspace switch slides
workspace_offset_x: i32 = 0,
workspace_anim_from: f64 = 0,
workspace_anim_start_ms: ?i64 = null,
// workspace sliding out next to the current one, null if none
peek_workspace: ?u8 = null,
// added to the peek workspace's resting place, settles to 0 faster than workspace_offset_x
// so the old workspace is gone before the new one has come to rest
peek_workspace_offset_x: i32 = 0,
// 1: the peek workspace is right of the current one, -1: left
peek_workspace_side: i32 = 1,
// how much farther than workspace_distance() the peek workspace slides out: a row wider than
// the output reaches past its edge and has to leave the view too
peek_workspace_overhang: i32 = 0,
// part of peek_workspace_overhang added so far, grows to it as peek_workspace_offset_x settles
peek_workspace_overhang_x: i32 = 0,
// the workspaces as published to other clients through river-workspace-v1, null if unsupported
rwm_workspaces: [workspace_max]?*river.WorkspaceV1 = @splat(null),
// state last sent for each of rwm_workspaces
sent_workspace_states: [workspace_max]?river.WorkspaceV1.State = @splat(null),
// workspace another client asked to show, switched to in the next manage sequence
requested_workspace: ?u8 = null,

name: ?[]const u8 = null,
x: i32 = undefined,
y: i32 = undefined,
width: i32 = undefined,
height: i32 = undefined,

background: if (build_options.background_enabled) @import("background.zig") else void = undefined,
bar: if (build_options.bar_enabled) @import("bar.zig") else void = undefined,

pub fn create(
    rwm_output: *river.OutputV1,
    rwm_layer_shell_output: ?*river.LayerShellOutputV1,
) !*Self {
    const output = try ctx.gpa.create(Self);
    errdefer ctx.gpa.destroy(output);

    defer log.debug("<{*}> created", .{output});

    output.* = .{
        .rwm_output = rwm_output,
        .rwm_layer_shell_output = rwm_layer_shell_output,
        .layouts = .{ctx.cfg.layout} ** 32,
        .workspaces = .{Workspace{ .layouts = .{ctx.cfg.layout} ** 32 }} ** workspace_max,
    };
    output.link.init();

    if (comptime build_options.background_enabled) {
        try output.background.init(output);
    }

    if (comptime build_options.bar_enabled) {
        try output.bar.init(output);
    }

    rwm_output.setListener(*Self, rwm_output_listener, output);

    if (rwm_layer_shell_output) |layer_shell_output| {
        layer_shell_output.setListener(*Self, rwm_layer_shell_output_listener, output);
    }

    if (ctx.rwm_workspace_manager) |workspace_manager| {
        output.create_rwm_workspaces(workspace_manager);
    }

    return output;
}

pub fn destroy(self: *Self) void {
    defer log.debug("<{*}> destroyed", .{self});

    {
        var it = ctx.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            switch (seat.previous_focused) {
                .output => |output| if (self == output) {
                    seat.previous_focused = .none;
                },
                else => {},
            }
        }
    }

    self.set_name(null);

    for (self.rwm_workspaces) |rwm_workspace| {
        if (rwm_workspace) |workspace| workspace.destroy();
    }

    self.link.remove();
    self.rwm_output.destroy();
    if (self.wl_output) |wl_output| wl_output.destroy();

    if (self.rwm_layer_shell_output) |rwm_layer_shell_output| {
        rwm_layer_shell_output.destroy();
    }

    if (comptime build_options.background_enabled) self.background.deinit();

    if (comptime build_options.bar_enabled) self.bar.deinit();

    ctx.gpa.destroy(self);
}

pub fn get_state(self: *const Self) State {
    var state: State = undefined;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        @field(state, field.name) = @field(self, field.name);
    }
    return state;
}

pub fn sync_state(self: *Self, state: *const State) void {
    inline for (@typeInfo(State).@"struct".fields) |field| {
        @field(self, field.name) = @field(state, field.name);
    }
}

pub fn apply_rules(self: *Self) void {
    log.debug("<{*}> apply rules", .{self});

    for (ctx.cfg.output_rules) |rule| {
        if (rule.match(self.name)) {
            self.apply_rule(&rule);
            break;
        }
    }
}

pub inline fn exclusive_x(self: *Self) i32 {
    return self.x;
}

pub inline fn exclusive_y(self: *Self) i32 {
    return if (comptime build_options.bar_enabled)
        if (ctx.cfg.bar.position == .bottom or self.bar.hidden) self.y else self.y + self.bar.height(true)
    else
        self.y;
}

pub inline fn exclusive_width(self: *Self) i32 {
    return self.width;
}

pub inline fn exclusive_height(self: *Self) i32 {
    return if (comptime build_options.bar_enabled)
        if (self.bar.hidden) self.height else self.height - self.bar.height(true)
    else
        self.height;
}

pub fn fullscreen_window(self: *Self) ?*Window {
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (!window.is_visible_in(self)) continue;

            switch (window.fullscreen) {
                .output => |output| {
                    if (output == self) {
                        return window;
                    }
                },
                else => {},
            }
        }
    }

    return null;
}

pub fn set_presentation(self: *Self, mode: river.OutputV1.PresentationMode) void {
    log.debug("<{*}> set presentation mode to {s}", .{ self, @tagName(mode) });

    self.rwm_output.setPresentationMode(mode);
}

pub fn set_tag(self: *Self, tag: u32) void {
    if (tag == 0 or self.tag == tag) return;

    log.debug("<{*}> set tag: {b}", .{ self, tag });

    self.prev_tag = self.tag;
    self.prev_main_tag = self.main_tag;

    self.tag = tag;
    if (self.main_tag & tag == 0) {
        // use the lowest bit 1 as new main tag
        self.main_tag = tag ^ (tag & (tag - 1));

        log.debug("<{*}> update main tag to {b}", .{ self, self.main_tag });
    }

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}

pub fn set_workspace(self: *Self, workspace: u8) void {
    if (workspace >= workspace_max or workspace == self.workspace) return;

    log.debug("<{*}> set workspace: {}", .{ self, workspace });

    const prev = self.workspace;
    self.swap_workspace(workspace);
    self.animate_workspace_change(prev);

    // rows of different workspaces are unrelated, do not slide between them
    self.gesture_prev_tag = 0;
    self.gesture_peek_tag = 0;
    self.gesture_offset_y = 0;
    self.gesture_anim_y_start_ms = null;
    self.tag_step_direction = 0;
    self.scroller_prev_focus = null;

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}

// make `workspace` the current one without any side effects
fn swap_workspace(self: *Self, workspace: u8) void {
    inline for (@typeInfo(Workspace).@"struct".fields) |field| {
        @field(self.workspaces[self.workspace], field.name) = @field(self, field.name);
        @field(self, field.name) = @field(self.workspaces[workspace], field.name);
    }
    self.workspace = workspace;
}

// the previous workspace stays where it is and slides out, the new one slides in next to it;
// a higher workspace comes in from the right
fn animate_workspace_change(self: *Self, prev: u8) void {
    if (!ctx.cfg.gesture.animate_bindings) {
        self.peek_workspace = null;
        Gesture.start_settle_workspace(self, 0);
        return;
    }
    const side: i32 = if (self.workspace > prev) -1 else 1;
    self.peek_workspace = prev;
    self.peek_workspace_side = side;
    Gesture.start_settle_workspace(self, self.workspace_offset_x - side * self.workspace_distance());
}

// how far the overview is zoomed out, 0 in the normal view and 1 in the overview
fn zoom_progress(self: *const Self) f64 {
    const target = ctx.cfg.gesture.overview_zoom;
    if (target == 1) return 0;
    return std.math.clamp((1 - self.zoom) / (1 - target), 0, 1);
}

// distance on the plane between a row and the next one; the overview opens a gap between them
pub fn row_distance(self: *Self) i32 {
    const height = self.exclusive_height();
    const gap: f64 = @floatFromInt(@divFloor(height, 10));
    return height + @as(i32, @intFromFloat(@round(gap * self.zoom_progress())));
}

// distance between a workspace and the next one while a switch slides: far enough that a
// workspace at rest next to the current one is out of the view, which the overview widens
pub fn workspace_distance(self: *Self) i32 {
    const width: f64 = @floatFromInt(self.exclusive_width());
    const view = width / 2 + width / (2 * self.zoom);
    return @as(i32, @intFromFloat(@round(view + width / 10 * self.zoom_progress())));
}

// horizontal offset of the windows of `workspace` while a workspace switch slides
pub fn workspace_shift(self: *Self, workspace: u8) i32 {
    if (workspace == self.workspace) return self.workspace_offset_x;
    return self.peek_workspace_offset_x + self.peek_workspace_side * (self.workspace_distance() + self.peek_workspace_overhang_x);
}

// how much farther than workspace_distance() the peek workspace has to slide to leave the view
pub fn peek_overhang(self: *Self) i32 {
    const peek = self.peek_workspace orelse return 0;
    const border_width = ctx.cfg.border.width;
    // the part of the plane shown by the output, as in Window.render()
    const center_x = @as(f64, @floatFromInt(self.exclusive_width())) / 2;
    const view_left: i32 = @intFromFloat(@floor(center_x - center_x / self.zoom));
    const view_right: i32 = @intFromFloat(@ceil(center_x + (@as(f64, @floatFromInt(self.width)) - center_x) / self.zoom));
    const distance = self.workspace_distance();

    var overhang: i32 = 0;
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.output != self or window.workspace != peek or window.sticky or window.geometry_undefined) continue;
        if (!window.is_visible()) continue;
        const needed = if (self.peek_workspace_side < 0)
            window.x + window.width + border_width - view_left - distance
        else
            view_right - (window.x - border_width) - distance;
        overhang = @max(overhang, needed);
    }
    return overhang;
}

// every row of the workspace is shown: in the zoomed out overview and while zooming
pub fn shows_all_rows(self: *const Self) bool {
    return Overview.zoomed() and (ctx.overview.active or self.zoom != 1);
}

// rows shown in `workspace`
pub fn workspace_tag(self: *const Self, workspace: u8) u32 {
    return if (workspace == self.workspace) self.main_tag else self.workspaces[workspace].main_tag;
}

// workspaces holding windows of this output
pub fn occupied_workspaces(self: *const Self) u32 {
    var mask: u32 = 0;
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.output == self and window.swallowed_by == null) mask |= @as(u32, 1) << @intCast(window.workspace);
    }
    return mask;
}

fn create_rwm_workspaces(self: *Self, workspace_manager: *river.WorkspaceManagerV1) void {
    for (&self.rwm_workspaces, 0..) |*slot, i| {
        const workspace = workspace_manager.getWorkspace(self.rwm_output) catch |err| {
            log.err("<{*}> create workspace {} failed: {}", .{ self, i + 1, err });
            continue;
        };
        var buffer: [4]u8 = undefined;
        workspace.setName(fmt.bufPrintZ(&buffer, "{}", .{i + 1}) catch unreachable);
        workspace.setPosition(@intCast(i));
        workspace.setListener(*Self, rwm_workspace_listener, self);
        slot.* = workspace;
    }
    self.sync_rwm_workspaces();
}

// tell other clients which workspace is shown and which ones hold windows
pub fn sync_rwm_workspaces(self: *Self) void {
    const occupied = self.occupied_workspaces();
    for (self.rwm_workspaces, &self.sent_workspace_states, 0..) |rwm_workspace, *sent, i| {
        const workspace = rwm_workspace orelse continue;
        const active = i == self.workspace;
        const state: river.WorkspaceV1.State = .{
            .active = active,
            // empty workspaces are not listed, the shown one and the first one always are
            .hidden = !active and i != 0 and occupied & (@as(u32, 1) << @intCast(i)) == 0,
        };
        if (sent.*) |s| if (@as(u32, @bitCast(s)) == @as(u32, @bitCast(state))) continue;
        workspace.setState(state);
        sent.* = state;
    }
}

// switch to the workspace another client asked for, and to this output
pub fn apply_requested_workspace(self: *Self) void {
    const workspace = self.requested_workspace orelse return;
    self.requested_workspace = null;

    log.debug("<{*}> workspace {} requested", .{ self, workspace + 1 });

    ctx.set_current_output(self);
    if (ctx.overview.active) {
        ctx.overview.set_workspace(self, workspace);
    } else self.set_workspace(workspace);
}

pub fn switch_to_previous_tag(self: *Self) void {
    const prev_main_tag = self.prev_main_tag;

    self.set_tag(self.prev_tag);
    log.debug("<{*}> switch to previous tag", .{self});

    self.main_tag = prev_main_tag;
    log.debug("<{*}> switch to previous main tag", .{self});
}

pub fn occupied_tags(self: *const Self) u32 {
    var mask: u32 = 0;
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (window.output == self and window.workspace == self.workspace and window.swallowed_by == null) mask |= window.tag;
        }
    }
    return mask;
}

pub fn toggle_tag(self: *Self, mask: u32) void {
    if (self.tag ^ mask == 0) return;

    log.debug("<{*}> toggle tag: (tag: {b}, mask: {b})", .{ self, self.tag, mask });

    self.tag ^= mask;
    // if there is only one bit 1, set it as new main tag
    if (self.tag & (self.tag - 1) == 0) {
        log.debug("<{*}> update main tag to {b}", .{ self, self.tag });

        self.main_tag = self.tag;
    }

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}

pub fn scroller(self: *Self) *Layout.Scroller {
    std.debug.assert(self.main_tag != 0 and self.main_tag & (self.main_tag - 1) == 0);

    return &self.layouts[@ctz(self.main_tag)].scroller;
}

pub inline fn scroller_mfact(self: *const Self) f32 {
    std.debug.assert(self.main_tag != 0 and self.main_tag & (self.main_tag - 1) == 0);

    const i = @ctz(self.main_tag);
    return self.layouts[i].scroller.mfact;
}

pub fn manage(self: *Self) void {
    // leave overview once the last window on the current output is closed
    if (ctx.overview.active and ctx.overview.check_empty and ctx.current_output == self) {
        ctx.overview.check_empty = false;
        if (Overview.first_candidate() == null) ctx.overview.exit();
    }
    if (ctx.overview.active and !Overview.zoomed()) {
        self.scroller_prev_focus = null;
        ctx.overview.arrange(self);
        return;
    }

    self.normalize_tags();
    self.animate_tag_change();
    if (self.peek_workspace) |peek| self.arrange_peek_workspace(peek);
    self.arrange_workspace();

    log.debug("<{*}> managed", .{self});
}

// arrange the rows of the current workspace, every row is arranged by its own scroller
fn arrange_workspace(self: *Self) void {
    if (self.shows_all_rows()) {
        var rows = self.dynamic_occupied() & ~self.main_tag;
        while (rows != 0) : (rows &= rows - 1) {
            const row = rows ^ (rows & (rows - 1));
            const distance = @as(i32, @ctz(row)) - @as(i32, @ctz(self.main_tag));
            self.arrange_row(row, self.gesture_offset_y + distance * self.row_distance());
        }
    } else if (self.gesture_peek_tag != 0) {
        self.arrange_row(self.gesture_peek_tag, self.gesture_offset_y + self.gesture_peek_side * self.row_distance());
    }

    self.scroller().arrange(self) catch |err| {
        log.err("<{*}> arrange windows failed: {}", .{ self, err });
        return;
    };
    self.shift_tiled(self.gesture_offset_y);
}

// arrange the workspace sliding out with its own rows and settings
fn arrange_peek_workspace(self: *Self, peek: u8) void {
    const workspace = self.workspace;
    const saved = .{
        self.gesture_offset_x,      self.gesture_anchor,    self.gesture_offset_y,
        self.gesture_peek_tag,      self.gesture_prev_tag,  self.scroller_prev_focus,
    };
    self.swap_workspace(peek);
    self.gesture_offset_x = 0;
    self.gesture_anchor = null;
    self.gesture_offset_y = 0;
    self.gesture_peek_tag = 0;
    defer {
        self.swap_workspace(workspace);
        self.gesture_offset_x, self.gesture_anchor, self.gesture_offset_y,
        self.gesture_peek_tag, self.gesture_prev_tag, self.scroller_prev_focus = saved;
    }
    self.arrange_workspace();
}

// arrange the row `tag` of the current workspace other than the shown one, `dy` below it
fn arrange_row(self: *Self, tag: u32, dy: i32) void {
    const saved = .{ self.tag, self.main_tag, self.gesture_offset_x, self.gesture_anchor, self.scroller_prev_focus };
    self.tag = tag;
    self.main_tag = tag ^ (tag & (tag - 1));
    // the horizontal slide belongs to the focused row
    self.gesture_offset_x = 0;
    self.gesture_anchor = null;
    defer self.tag, self.main_tag, self.gesture_offset_x, self.gesture_anchor, self.scroller_prev_focus = saved;

    self.scroller().arrange(self) catch |err| {
        log.err("<{*}> arrange row {b} failed: {}", .{ self, tag, err });
        return;
    };
    self.shift_tiled(dy);
}

pub fn dynamic_tags() bool {
    return ctx.cfg.dynamic_tags and !ctx.cfg.single_tagset;
}

fn tag_limit() usize {
    return if (ctx.cfg.bar.tags) |area| area.tags.len else 32;
}

// rows of the current workspace holding windows of this output; sticky windows are on every row and do not count
fn dynamic_occupied(self: *const Self) u32 {
    var mask: u32 = 0;
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.output == self and window.workspace == self.workspace and window.swallowed_by == null and !window.sticky) mask |= window.tag;
    }
    return mask;
}

// number of rows of the current workspace with dynamic tags: the occupied ones (packed to
// the front by normalize_tags), the current one even if empty, and one empty row after them
pub fn row_count(self: *const Self) usize {
    const occupied = self.dynamic_occupied();
    const kept = occupied | self.tag;
    if (kept == 0) return 1;
    const last: u5 = @intCast(31 - @clz(kept));
    const trailing_empty: usize = if (occupied & (@as(u32, 1) << last) != 0) 1 else 0;
    return @min(@as(usize, last) + 1 + trailing_empty, tag_limit());
}

// next/previous row of `base`, wrapping around at both ends
pub fn ring_neighbor(self: *const Self, base: u32, direction: types.Direction) u32 {
    if (base == 0) return 0;
    const n = self.row_count();
    const current = @ctz(base);
    const next: usize = switch (direction) {
        .forward => if (current + 1 < n) current + 1 else 0,
        .reverse => if (current > 0) current - 1 else n - 1,
    };
    return @as(u32, 1) << @intCast(next);
}

// switch to the next/previous row, wrapping around at both ends
pub fn step_tag(self: *Self, direction: types.Direction) void {
    // windows may have been closed since the last arrange
    self.normalize_tags();
    if (self.row_count() < 2) return;
    self.tag_step_direction = switch (direction) {
        .forward => 1,
        .reverse => -1,
    };
    self.set_tag(self.ring_neighbor(self.main_tag, direction));
}

// drop empty tags (except the shown ones) and pack the rest to the front, keeping their order
fn normalize_tags(self: *Self) void {
    if (!dynamic_tags()) return;

    const kept = self.dynamic_occupied() | self.tag;
    var perm: Permutation = undefined;
    var next: u6 = 0;
    for (0..32) |i| {
        if (kept & (@as(u32, 1) << @intCast(i)) != 0) {
            perm[i] = @intCast(next);
            next += 1;
        }
    }
    for (0..32) |i| {
        if (kept & (@as(u32, 1) << @intCast(i)) == 0) {
            perm[i] = @intCast(next);
            next += 1;
        }
    }
    if (std.mem.eql(u5, &perm, &identity)) return;
    self.permute_tags(&perm);
}

// old tag index -> new tag index
const Permutation = [32]u5;

const identity: Permutation = blk: {
    var perm: Permutation = undefined;
    for (0..32) |i| perm[i] = i;
    break :blk perm;
};

fn apply_permutation(perm: *const Permutation, mask: u32) u32 {
    var result: u32 = 0;
    for (0..32) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) != 0) result |= @as(u32, 1) << perm[i];
    }
    return result;
}

// renumber the rows of the current workspace and everything that refers to them
fn permute_tags(self: *Self, perm: *const Permutation) void {
    if (std.mem.eql(u5, perm, &identity)) return;
    log.debug("<{*}> renumber tags", .{self});

    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (window.output == self and window.workspace == self.workspace) window.tag = apply_permutation(perm, window.tag);
    }

    inline for (.{ "tag", "main_tag", "prev_tag", "prev_main_tag", "gesture_peek_tag", "gesture_prev_tag" }) |name| {
        @field(self, name) = apply_permutation(perm, @field(self, name));
    }

    const layouts = self.layouts;
    for (0..32) |i| self.layouts[perm[i]] = layouts[i];

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}

// slide between tags when the tag was switched by other means than a swipe
fn animate_tag_change(self: *Self) void {
    const prev = self.gesture_prev_tag;
    self.gesture_prev_tag = self.tag;
    const step_direction = self.tag_step_direction;
    self.tag_step_direction = 0;
    if (prev == 0 or (prev & self.tag) != 0) return;
    const prev_main = prev ^ (prev & (prev - 1));
    if (!ctx.cfg.gesture.animate_bindings) {
        self.gesture_offset_y = 0;
        self.gesture_anim_y_start_ms = null;
        self.gesture_peek_tag = 0;
        return;
    }

    // the next tag comes in from below, the previous one from above, also when wrapping;
    // for direct jumps compare the positions
    const from_below = if (step_direction != 0) step_direction > 0 else @ctz(self.main_tag) > @ctz(prev_main);
    const side: i32 = if (from_below) -1 else 1;
    // every row is shown at its own place, the view moves the whole distance
    const rows: i32 = if (self.shows_all_rows()) @as(i32, @ctz(self.main_tag)) - @as(i32, @ctz(prev_main)) else -side;
    // the previous tag stays where it is now (still moving if a switch was animating),
    // the new one starts right next to it
    const offset = self.gesture_offset_y + rows * self.row_distance();
    self.gesture_peek_tag = prev;
    self.gesture_peek_side = side;
    Gesture.start_settle_y(self, offset);
}

// move the tiled windows of the current tag vertically, they are re-arranged every manage
fn shift_tiled(self: *Self, dy: i32) void {
    if (dy == 0) return;
    var it = ctx.windows.iterator(.forward);
    while (it.next()) |window| {
        if (!window.is_visible_in(self) or window.floating) continue;
        window.unbound_move(null, window.y + dy);
    }
}

fn apply_rule(self: *Self, rule: *const config.OutputRule) void {
    if (rule.presentation_mode) |mode| self.set_presentation(mode);
    if (rule.layout) |layout| {
        for (&self.layouts) |*l| l.* = config.meta.override(l.*, layout);
        for (&self.workspaces) |*workspace| {
            for (&workspace.layouts) |*l| l.* = config.meta.override(l.*, layout);
        }
    }
}

fn set_name(self: *Self, name: ?[]const u8) void {
    if (self.name) |name_| {
        ctx.gpa.free(name_);
        self.name = null;
    }

    if (name) |name_| {
        self.name = ctx.gpa.dupe(u8, name_) catch null;
    }
}

fn rwm_output_listener(rwm_output: *river.OutputV1, event: river.OutputV1.Event, output: *Self) void {
    std.debug.assert(rwm_output == output.rwm_output);

    switch (event) {
        .dimensions => |data| {
            log.debug("<{*}> new dimensions: (width: {}, height: {})", .{ output, data.width, data.height });

            output.width = data.width;
            output.height = data.height;

            if (comptime build_options.background_enabled) output.background.damage();
            if (comptime build_options.bar_enabled) output.bar.damage(.all);
        },
        .position => |data| {
            log.debug("<{*}> new position: (x: {}, y: {})", .{ output, data.x, data.y });

            output.x = data.x;
            output.y = data.y;

            if (comptime build_options.background_enabled) output.background.damage();
            if (comptime build_options.bar_enabled) output.bar.damage(.all);
        },
        .removed => {
            log.debug("<{*}> removed, name: {s}", .{ output, output.name orelse "" });

            ctx.prepare_remove_output(output);

            output.destroy();
        },
        .wl_output => |data| {
            log.debug("<{*}> wl_output: {}", .{ output, data.name });

            const wl_output = ctx.wl_registry.bind(data.name, wl.Output, 4) catch return;
            output.wl_output = wl_output;
            wl_output.setListener(*Self, wl_output_listener, output);
        },
    }
}

fn rwm_workspace_listener(rwm_workspace: *river.WorkspaceV1, event: river.WorkspaceV1.Event, output: *Self) void {
    switch (event) {
        .activate => {
            const index = mem.indexOfScalar(?*river.WorkspaceV1, &output.rwm_workspaces, rwm_workspace) orelse return;
            output.requested_workspace = @intCast(index);
            ctx.rwm.manageDirty();
        },
    }
}

fn rwm_layer_shell_output_listener(
    rwm_layer_shell_output: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    output: *Self,
) void {
    std.debug.assert(rwm_layer_shell_output == output.rwm_layer_shell_output.?);

    switch (event) {
        .non_exclusive_area => |data| {
            log.debug(
                "<{*}> non exclusive area: (width: {}, height: {}, x: {}, y: {})",
                .{ output, data.width, data.height, data.x, data.y },
            );

            output.width = data.width;
            output.height = data.height;
            output.x = data.x;
            output.y = data.y;

            if (comptime build_options.bar_enabled) {
                output.bar.damage(.all);
            }
        },
    }
}

fn wl_output_listener(wl_output: *wl.Output, event: wl.Output.Event, output: *Self) void {
    std.debug.assert(wl_output == output.wl_output.?);

    switch (event) {
        .geometry => |data| {
            log.debug(
                "<{*}> geometry: (x: {}, y: {}, physical_width: {}, physical_height: {}, subpixel: {s}, make: {s}, model: {s}, transform: {s})",
                .{ output, data.x, data.y, data.physical_width, data.physical_height, @tagName(data.subpixel), data.make, data.model, @tagName(data.transform) },
            );
        },
        .mode => |data| {
            log.debug(
                "<{*}> mode: (flags: (current: {}, preferred: {}), width: {}, height: {}, refresh: {})",
                .{ output, data.flags.current, data.flags.preferred, data.width, data.height, data.refresh },
            );
        },
        .scale => |data| {
            log.debug("<{*}> scale: {}", .{ output, data.factor });
        },
        .name => |data| {
            log.debug("<{*}> name: {s}", .{ output, data.name });

            const name = mem.span(data.name);
            output.set_name(name);

            if (ctx.output_states.fetchRemove(name)) |kv| {
                log.debug("<{*}> restore state: {any}", .{ output, kv.value });
                output.sync_state(kv.value);
                ctx.gpa.free(kv.key);
                ctx.gpa.destroy(kv.value);

                ctx.rwm.manageDirty();
            }

            {
                var it = ctx.windows.safeIterator(.forward);
                while (it.next()) |window| {
                    if (window.former_output) |former| {
                        if (mem.eql(u8, former, name)) {
                            log.debug("{*} former output match `{s}`", .{ window, name });
                            window.set_output(output, true);
                        }
                    }
                }
            }
        },
        .description => |data| {
            log.debug("<{*}> description: {s}", .{ output, data.description });
        },
        .done => {
            log.debug("<{*}> done", .{output});

            output.apply_rules();
        },
    }
}
