// The interactive part: a tree of every option, edited in place.

const Self = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const doc = @import("doc.zig");
const schema = @import("schema.zig");
const Model = @import("model.zig");
const Term = @import("term.zig");
const Key = Term.Key;
const Row = Model.Row;
const Seg = Model.Seg;

// background of a row, as an SGR sequence; empty means none
pub const Bg = struct {
    buf: [24]u8 = undefined,
    len: usize = 0,

    pub const default_sibling = parse("236") catch unreachable;
    pub const default_child = parse("234") catch unreachable;

    // "none", a 256-color index such as "236", or "#rrggbb" / "0xrrggbb"
    pub fn parse(text: []const u8) error{BadColor}!Bg {
        var bg: Bg = .{};
        if (mem.eql(u8, text, "none")) return bg;
        const written = if (mem.startsWith(u8, text, "#") or mem.startsWith(u8, text, "0x")) blk: {
            const hex = text[if (text[0] == '#') 1 else 2..];
            if (hex.len != 6) return error.BadColor;
            const v = std.fmt.parseInt(u24, hex, 16) catch return error.BadColor;
            break :blk std.fmt.bufPrint(&bg.buf, "\x1b[48;2;{d};{d};{d}m", .{ v >> 16, (v >> 8) & 0xff, v & 0xff });
        } else blk: {
            const n = std.fmt.parseInt(u8, text, 10) catch return error.BadColor;
            break :blk std.fmt.bufPrint(&bg.buf, "\x1b[48;5;{d}m", .{n});
        };
        bg.len = (written catch unreachable).len;
        return bg;
    }

    pub fn seq(self: *const Bg) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Colors = struct {
    sibling: Bg = Bg.default_sibling,
    child: Bg = Bg.default_child,
};

pub const Hooks = struct {
    ctx: *anyopaque,
    // check the text as flat-wm would; on failure returns a message
    validate: *const fn (ctx: *anyopaque, text: []const u8, msg: *std.ArrayList(u8)) bool,
    // write the file; on failure returns a message
    save: *const fn (ctx: *anyopaque, text: []const u8, msg: *std.ArrayList(u8)) bool,
};

const Mode = enum { normal, input, picker, link, help };

const InputPurpose = enum { int, float, string, raw, search };

const PickerPurpose = enum { enum_value, union_tag };

gpa: mem.Allocator,
model: *Model,
term: *Term,
hooks: Hooks,
title: []const u8,
colors: Colors,

arena: std.heap.ArenaAllocator,
rows: []Row = &.{},
expanded: std.StringHashMapUnmanaged(void) = .empty,
cursor: usize = 0,
scroll: usize = 0,

mode: Mode = .normal,
running: bool = true,
quit_armed: bool = false,

input: struct {
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    prompt: []const u8 = "",
    purpose: InputPurpose = .raw,
    path: []Seg = &.{},
} = .{},

picker: struct {
    options: []const []const u8 = &.{},
    shown: std.ArrayList(usize) = .empty,
    sel: usize = 0,
    filter: std.ArrayList(u8) = .empty,
    purpose: PickerPurpose = .enum_value,
    path: []Seg = &.{},
    title: []const u8 = "",
    ty: *const schema.Type = undefined,
    // options[0] stands for null
    has_null: bool = false,
} = .{},

// other places holding the value being changed
link: struct {
    text: []u8 = &.{},
    old: []u8 = &.{},
    path: []Seg = &.{},
    others: std.ArrayList(struct { path: []Seg, key: []u8, checked: bool }) = .empty,
    sel: usize = 0,
} = .{},

undo: std.ArrayList([]u8) = .empty,
redo: std.ArrayList([]u8) = .empty,
saved: []u8,

message: std.ArrayList(u8) = .empty,
message_error: bool = false,
search: std.ArrayList(u8) = .empty,

pub fn init(gpa: mem.Allocator, model: *Model, term: *Term, hooks: Hooks, title: []const u8, colors: Colors) !Self {
    var self: Self = .{
        .gpa = gpa,
        .model = model,
        .term = term,
        .hooks = hooks,
        .title = title,
        .colors = colors,
        .arena = .init(gpa),
        .saved = try gpa.dupe(u8, model.source),
    };
    self.rebuild(null);
    return self;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    var it = self.expanded.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.expanded.deinit(self.gpa);
    self.input.buf.deinit(self.gpa);
    self.gpa.free(self.input.path);
    self.picker.shown.deinit(self.gpa);
    self.picker.filter.deinit(self.gpa);
    self.gpa.free(self.picker.path);
    self.clear_link();
    self.link.others.deinit(self.gpa);
    self.gpa.free(self.link.text);
    self.gpa.free(self.link.old);
    self.gpa.free(self.link.path);
    for (self.undo.items) |s| self.gpa.free(s);
    self.undo.deinit(self.gpa);
    for (self.redo.items) |s| self.gpa.free(s);
    self.redo.deinit(self.gpa);
    self.gpa.free(self.saved);
    self.message.deinit(self.gpa);
    self.search.deinit(self.gpa);
}

pub fn run(self: *Self) void {
    while (self.running) {
        self.render();
        const key = self.term.read_key(500) orelse {
            _ = self.term.update_size();
            continue;
        };
        _ = self.term.update_size();
        switch (self.mode) {
            .normal => self.on_normal(key),
            .input => self.on_input(key),
            .picker => self.on_picker(key),
            .link => self.on_link(key),
            .help => self.mode = .normal,
        }
    }
}

fn dirty(self: *const Self) bool {
    return !mem.eql(u8, self.saved, self.model.source);
}

fn say(self: *Self, comptime fmt: []const u8, args: anytype) void {
    self.message.clearRetainingCapacity();
    self.message.print(self.gpa, fmt, args) catch {};
    self.message_error = false;
}

fn complain(self: *Self, comptime fmt: []const u8, args: anytype) void {
    self.say(fmt, args);
    self.message_error = true;
}

fn current(self: *const Self) ?*const Row {
    return if (self.cursor < self.rows.len) &self.rows[self.cursor] else null;
}

const Focus = union(enum) {
    key: []const u8,
    path: []const Seg,
};

// rebuild the rows, keeping the cursor on `focus` or on the same row as before
fn rebuild(self: *Self, focus: ?Focus) void {
    var keep_key: ?[]u8 = null;
    var keep_path: ?[]Seg = null;
    defer if (keep_key) |k| self.gpa.free(k);
    defer if (keep_path) |p| self.gpa.free(p);
    if (focus) |f| switch (f) {
        .key => |k| keep_key = self.gpa.dupe(u8, k) catch null,
        .path => |p| keep_path = self.gpa.dupe(Seg, p) catch null,
    } else if (self.current()) |row| {
        // a group heading has no path of its own
        if (row.group != null) {
            keep_key = self.gpa.dupe(u8, row.key) catch null;
        } else {
            keep_path = self.gpa.dupe(Seg, row.path) catch null;
        }
    }

    self.build_rows();
    if (keep_key) |k| {
        if (self.find_key(k)) return;
    } else if (keep_path) |p| {
        if (self.find_key(Model.path_key(self.arena.allocator(), p) catch "")) return;
        // e.g. a binding moved to another group: open the way to it
        self.open_to(p);
        self.build_rows();
        if (self.find_key(Model.path_key(self.arena.allocator(), p) catch "")) return;
    }
    if (self.cursor >= self.rows.len) self.cursor = self.rows.len -| 1;
}

fn build_rows(self: *Self) void {
    _ = self.arena.reset(.retain_capacity);
    self.rows = self.model.rows(self.arena.allocator(), &self.expanded, false) catch &.{};
}

fn find_key(self: *Self, key: []const u8) bool {
    for (self.rows, 0..) |row, i| {
        if (mem.eql(u8, row.key, key)) {
            self.cursor = i;
            return true;
        }
    }
    return false;
}

// open every row above `path`
fn open_to(self: *Self, path: []const Seg) void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const keys = self.model.ancestor_keys(arena.allocator(), path) catch return;
    for (keys) |k| self.set_expanded(k, true);
}

fn set_expanded(self: *Self, key: []const u8, open: bool) void {
    if (open) {
        if (self.expanded.contains(key)) return;
        const k = self.gpa.dupe(u8, key) catch return;
        self.expanded.put(self.gpa, k, {}) catch self.gpa.free(k);
    } else if (self.expanded.fetchRemove(key)) |kv| {
        self.gpa.free(kv.key);
    }
}

// --- edits --------------------------------------------------------------------

fn begin_edit(self: *Self) ?[]u8 {
    return self.gpa.dupe(u8, self.model.source) catch null;
}

fn end_edit(self: *Self, before: ?[]u8, result: Model.EditError!void, focus: ?Focus) void {
    const b = before orelse return;
    result catch |err| {
        self.gpa.free(b);
        switch (err) {
            error.Invalid => self.complain("{s}", .{self.model.problem}),
            else => self.complain("edit failed: {s}", .{@errorName(err)}),
        }
        return;
    };
    if (mem.eql(u8, b, self.model.source)) {
        self.gpa.free(b);
        self.rebuild(focus);
        return;
    }
    self.undo.append(self.gpa, b) catch self.gpa.free(b);
    for (self.redo.items) |s| self.gpa.free(s);
    self.redo.clearRetainingCapacity();
    self.quit_armed = false;
    self.rebuild(focus);
}

fn undo_redo(self: *Self, is_undo: bool) void {
    const from = if (is_undo) &self.undo else &self.redo;
    const to = if (is_undo) &self.redo else &self.undo;
    const text = from.pop() orelse {
        self.say("nothing to {s}", .{if (is_undo) "undo" else "redo"});
        return;
    };
    defer self.gpa.free(text);
    const now = self.gpa.dupe(u8, self.model.source) catch return;
    self.model.replace_source(text) catch {
        self.gpa.free(now);
        return;
    };
    to.append(self.gpa, now) catch self.gpa.free(now);
    self.rebuild(null);
    self.say("{s}", .{if (is_undo) "undone" else "redone"});
}

fn owned_path(self: *Self, path: []const Seg) []Seg {
    return self.gpa.dupe(Seg, path) catch &.{};
}

fn edit_row(self: *Self, raw: bool) void {
    const row = self.current() orelse return;
    if (row.group != null) {
        if (raw) return self.complain("a group of bindings; open it to change one", .{});
        self.set_expanded(row.key, !row.expanded);
        return self.rebuild(null);
    }
    const st = row.st;
    const ty = st.ty.unwrap();
    const null_now = if (st.eff) |e| e.is_null() else false;
    if (raw) {
        const text = if (st.eff) |e| e.text() else "";
        const compacted = doc.compact(self.gpa, text) catch return;
        defer self.gpa.free(compacted);
        self.start_input(.raw, row, compacted);
        return;
    }
    if (null_now and ty.kind != .@"enum" and ty.kind != .@"union") {
        // give the value something to edit
        const b = self.begin_edit();
        self.end_edit(b, self.model.set_null(row.path, false), null);
        return;
    }
    switch (ty.kind) {
        .bool => {
            const now = if (st.eff) |e| mem.eql(u8, e.text(), "true") else false;
            const b = self.begin_edit();
            self.end_edit(b, self.model.set(row.path, if (now) "false" else "true", ""), null);
        },
        .int, .float => {
            const text = if (st.eff) |e| e.text() else "";
            const shown = if (self.is_color(row)) self.color_hex(text) orelse text else text;
            self.start_input(if (ty.kind == .int) .int else .float, row, shown);
        },
        .string => {
            var decoded: []u8 = &.{};
            defer self.gpa.free(decoded);
            if (st.eff) |e| {
                if (e.node.kind == .string) {
                    decoded = doc.decode_string(self.gpa, e.text()) catch &.{};
                } else {
                    decoded = self.gpa.dupe(u8, e.text()) catch &.{};
                }
            }
            self.start_input(.string, row, decoded);
        },
        .@"enum" => |names| self.start_picker(.enum_value, row, names, ty),
        .@"union" => |fields| {
            const names = self.arena.allocator().alloc([]const u8, fields.len) catch return;
            for (fields, 0..) |f, i| names[i] = f.name;
            self.start_picker(.union_tag, row, names, ty);
        },
        .@"struct", .tuple, .array, .slice => {
            if (row.expandable) {
                self.set_expanded(row.key, !row.expanded);
                self.rebuild(null);
            } else {
                self.edit_row(true);
            }
        },
        else => {},
    }
}

fn start_input(self: *Self, purpose: InputPurpose, row: ?*const Row, text: []const u8) void {
    self.input.buf.clearRetainingCapacity();
    self.input.buf.appendSlice(self.gpa, text) catch {};
    self.input.pos = self.input.buf.items.len;
    self.input.purpose = purpose;
    self.gpa.free(self.input.path);
    self.input.path = if (row) |r| self.owned_path(r.path) else &.{};
    self.input.prompt = if (row) |r| r.label else "/";
    self.mode = .input;
}

fn start_picker(self: *Self, purpose: PickerPurpose, row: *const Row, names: []const []const u8, ty: *const schema.Type) void {
    // an optional value can also go back to null
    self.picker.has_null = row.st.ty.kind == .optional;
    const options = if (self.picker.has_null) blk: {
        const all = self.arena.allocator().alloc([]const u8, names.len + 1) catch return;
        all[0] = "null";
        @memcpy(all[1..], names);
        break :blk all;
    } else names;
    self.picker.options = options;
    self.picker.purpose = purpose;
    self.picker.filter.clearRetainingCapacity();
    self.gpa.free(self.picker.path);
    self.picker.path = self.owned_path(row.path);
    self.picker.title = row.label;
    self.picker.ty = ty;
    self.refilter();
    // start on the current value
    const now: ?[]const u8 = if (row.st.eff) |e| switch (purpose) {
        .enum_value => if (e.node.kind == .enum_literal) e.node.enum_name(e.src) else null,
        .union_tag => if (Model.union_tag(ty, e)) |f| f.name else null,
    } else null;
    const null_now = if (row.st.eff) |e| e.is_null() else false;
    for (self.picker.shown.items, 0..) |opt, i| {
        const is_null_opt = self.picker.has_null and opt == 0;
        if (is_null_opt) {
            if (null_now) self.picker.sel = i;
        } else if (now) |n| if (mem.eql(u8, options[opt], n)) {
            self.picker.sel = i;
        };
    }
    self.mode = .picker;
}

fn refilter(self: *Self) void {
    self.picker.shown.clearRetainingCapacity();
    for (self.picker.options, 0..) |opt, i| {
        if (contains_ci(opt, self.picker.filter.items)) self.picker.shown.append(self.gpa, i) catch {};
    }
    self.picker.sel = 0;
}

fn contains_ci(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn commit_input(self: *Self) void {
    const text = self.input.buf.items;
    const path = self.input.path;
    switch (self.input.purpose) {
        .search => {
            self.search.clearRetainingCapacity();
            self.search.appendSlice(self.gpa, text) catch {};
            self.mode = .normal;
            self.find(true, false);
            return;
        },
        .int => {
            const t = mem.trim(u8, text, " ");
            _ = std.fmt.parseInt(i128, t, 0) catch {
                self.complain("not an integer: {s}", .{t});
                return;
            };
            self.commit_value(path, t);
        },
        .float => {
            const t = mem.trim(u8, text, " ");
            _ = std.fmt.parseFloat(f64, t) catch {
                self.complain("not a number: {s}", .{t});
                return;
            };
            self.commit_value(path, t);
        },
        .string => {
            const encoded = doc.encode_string(self.gpa, text) catch return;
            defer self.gpa.free(encoded);
            self.commit_value(path, encoded);
        },
        .raw => {
            var check = doc.parse(self.gpa, text) catch {
                self.complain("not a valid ZON value", .{});
                return;
            };
            check.deinit();
            self.mode = .normal;
            const b = self.begin_edit();
            self.end_edit(b, self.model.set(path, text, ""), null);
        },
    }
}

// set a number or string; if other places in the file hold the old value,
// ask whether to change them too
fn commit_value(self: *Self, path: []const Seg, text: []const u8) void {
    self.mode = .normal;
    if (self.model.lookup(path)) |st| if (st.eff) |old| {
        const ty = st.ty.unwrap();
        if (old.origin == .user and !old.is_null() and !same_value(ty, old.text(), text)) {
            if (self.collect_same(path, ty, old.text()) > 0) {
                self.gpa.free(self.link.text);
                self.link.text = self.gpa.dupe(u8, text) catch return;
                self.gpa.free(self.link.old);
                self.link.old = self.gpa.dupe(u8, old.text()) catch return;
                self.gpa.free(self.link.path);
                self.link.path = self.owned_path(path);
                self.link.sel = 0;
                self.mode = .link;
                return;
            }
        }
    };
    const b = self.begin_edit();
    self.end_edit(b, self.model.set(path, text, ""), null);
}

fn same_value(ty: *const schema.Type, a: []const u8, b: []const u8) bool {
    return switch (ty.kind) {
        .int => blk: {
            const x = std.fmt.parseInt(i128, a, 0) catch break :blk false;
            const y = std.fmt.parseInt(i128, b, 0) catch break :blk false;
            break :blk x == y;
        },
        .float => blk: {
            const x = std.fmt.parseFloat(f64, a) catch break :blk false;
            const y = std.fmt.parseFloat(f64, b) catch break :blk false;
            break :blk x == y;
        },
        else => mem.eql(u8, a, b),
    };
}

// other values in the file of the same kind holding `old`; returns how many
fn collect_same(self: *Self, path: []const Seg, ty: *const schema.Type, old: []const u8) usize {
    self.clear_link();
    if (ty.kind != .int and ty.kind != .float and ty.kind != .string) return 0;
    if (ty.kind == .string and mem.eql(u8, old, "\"\"")) return 0;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const all = self.model.rows(a, &self.expanded, true) catch return 0;
    const key = Model.path_key(a, path) catch return 0;
    for (all) |r| {
        const e = r.st.eff orelse continue;
        if (r.st.user == null or e.origin != .user or e.is_null()) continue;
        const rty = r.st.ty.unwrap();
        if (std.meta.activeTag(rty.kind) != std.meta.activeTag(ty.kind)) continue;
        if (mem.eql(u8, r.key, key) or !same_value(ty, e.text(), old)) continue;
        const p = self.gpa.dupe(Seg, r.path) catch continue;
        const k = self.gpa.dupe(u8, r.key) catch {
            self.gpa.free(p);
            continue;
        };
        self.link.others.append(self.gpa, .{ .path = p, .key = k, .checked = true }) catch {
            self.gpa.free(p);
            self.gpa.free(k);
        };
    }
    return self.link.others.items.len;
}

fn clear_link(self: *Self) void {
    for (self.link.others.items) |o| {
        self.gpa.free(o.path);
        self.gpa.free(o.key);
    }
    self.link.others.clearRetainingCapacity();
}

fn set_linked(self: *Self, all: bool) Model.EditError!usize {
    try self.model.set(self.link.path, self.link.text, "");
    var n: usize = 1;
    if (all) for (self.link.others.items) |o| {
        if (!o.checked) continue;
        try self.model.set(o.path, self.link.text, "");
        n += 1;
    };
    return n;
}

fn commit_link(self: *Self, all: bool) void {
    self.mode = .normal;
    const b = self.begin_edit();
    var n: usize = 0;
    const result = if (self.set_linked(all)) |count| blk: {
        n = count;
        break :blk {};
    } else |err| err;
    self.end_edit(b, result, null);
    if (!self.message_error and n > 1) self.say("changed {d} places", .{n});
    self.clear_link();
}

fn on_link(self: *Self, key: Key) void {
    const others = self.link.others.items;
    switch (key) {
        .esc => self.commit_link(false),
        .enter => self.commit_link(true),
        .up => self.link.sel -|= 1,
        .down => if (self.link.sel + 1 < others.len) {
            self.link.sel += 1;
        },
        .ctrl => |c| switch (c) {
            'c' => {
                self.clear_link();
                self.mode = .normal;
            },
            else => {},
        },
        .char => |c| switch (c) {
            'k' => self.link.sel -|= 1,
            'j' => if (self.link.sel + 1 < others.len) {
                self.link.sel += 1;
            },
            ' ' => if (self.link.sel < others.len) {
                others[self.link.sel].checked = !others[self.link.sel].checked;
            },
            'a' => {
                const any_off = for (others) |o| {
                    if (!o.checked) break true;
                } else false;
                for (others) |*o| o.checked = any_off;
            },
            else => {},
        },
        else => {},
    }
}

fn commit_picker(self: *Self) void {
    if (self.picker.sel >= self.picker.shown.items.len) return;
    const opt = self.picker.shown.items[self.picker.sel];
    const name = self.picker.options[opt];
    self.mode = .normal;
    const b = self.begin_edit();
    if (self.picker.has_null and opt == 0) {
        self.end_edit(b, self.model.set_null(self.picker.path, true), null);
        return;
    }
    switch (self.picker.purpose) {
        .enum_value => {
            const text = doc.encode_enum(self.gpa, name) catch return;
            defer self.gpa.free(text);
            self.end_edit(b, self.model.set(self.picker.path, text, ""), null);
        },
        .union_tag => {
            const f = self.picker.ty.field(name) orelse return;
            // keep the payload if the tag did not change
            const st = self.model.lookup(self.picker.path);
            if (st) |s| if (s.eff) |e| if (Model.union_tag(self.picker.ty, e) == f) {
                if (b) |x| self.gpa.free(x);
                return;
            };
            self.end_edit(b, self.model.set_tag(self.picker.path, f), null);
            // show what the new kind needs
            if (self.current()) |row| if (row.expandable and !row.expanded) {
                self.set_expanded(row.key, true);
                self.rebuild(null);
            };
        },
    }
}

fn list_op(self: *Self, comptime op: enum { add, duplicate, delete, up, down }) void {
    const row = self.current() orelse return;
    const ty = row.st.ty.unwrap();
    const arena = self.arena.allocator();
    if (row.group) |g| {
        if (op != .add) return self.complain("a group of bindings; open it to change one", .{});
        const b = self.begin_edit();
        const mods = g.mods orelse 0;
        const index = self.model.add_binding(row.path, g.mode, mods) catch |err| {
            self.end_edit(b, err, null);
            return;
        };
        // land on the new binding's key or button
        const elem = ty.kind.slice();
        const name: []const u8 = if (elem.field("keysym") != null) "keysym" else "button";
        const item_path = mem.concat(arena, Seg, &.{ row.path, &.{.{ .index = index }} }) catch return;
        self.set_expanded(Model.path_key(arena, item_path) catch return, true);
        const focus = mem.concat(arena, Seg, &.{ item_path, &.{.{ .field = name }} }) catch return;
        self.end_edit(b, {}, .{ .path = focus });
        return;
    }
    const b = self.begin_edit();
    if (!row.item) {
        if (op == .add and ty.kind == .slice) {
            const len = if (row.st.eff) |e| (if (e.node.kind == .container) e.node.entries.len else 0) else 0;
            const focus = mem.concat(arena, Seg, &.{ row.path, &.{.{ .index = len }} }) catch return;
            self.set_expanded(row.key, true);
            self.end_edit(b, self.model.list_insert(row.path, len, null), .{ .path = focus });
            return;
        }
        if (b) |x| self.gpa.free(x);
        self.complain("not a list item", .{});
        return;
    }
    const i = row.path[row.path.len - 1].index;
    const parent = row.path[0 .. row.path.len - 1];
    // bindings move among their group, which need not be next to each other in the file
    if (row.binding and (op == .up or op == .down)) {
        const j = self.group_neighbor(op == .down) orelse {
            if (b) |x| self.gpa.free(x);
            self.complain("already the {s} in this group", .{if (op == .down) "last" else "first"});
            return;
        };
        const focus = mem.concat(arena, Seg, &.{ parent, &.{.{ .index = j }} }) catch return;
        self.end_edit(b, self.model.list_swap(parent, i, j), .{ .path = focus });
        return;
    }
    const target: usize = switch (op) {
        .add, .duplicate => i + 1,
        .delete => if (i > 0) i - 1 else 0,
        .up => i -| 1,
        .down => i + 1,
    };
    const focus = mem.concat(arena, Seg, &.{ parent, &.{.{ .index = target }} }) catch return;
    const result = switch (op) {
        .add => self.model.list_add_after(row.path),
        .duplicate => self.model.list_duplicate(row.path),
        .delete => self.model.list_delete(row.path),
        .up => self.model.list_move(row.path, false),
        .down => self.model.list_move(row.path, true),
    };
    self.end_edit(b, result, .{ .path = focus });
}

// index of the binding shown before or after the current one in its group
fn group_neighbor(self: *Self, down: bool) ?usize {
    const row = self.current() orelse return null;
    var i = self.cursor;
    while (true) {
        if (down) {
            i += 1;
            if (i >= self.rows.len) return null;
        } else {
            if (i == 0) return null;
            i -= 1;
        }
        const r = self.rows[i];
        if (r.depth < row.depth) return null;
        if (r.depth == row.depth and r.binding) return r.path[r.path.len - 1].index;
    }
}

fn save(self: *Self) void {
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(self.gpa);
    if (!self.hooks.validate(self.hooks.ctx, self.model.source, &msg)) {
        self.complain("not saved, flat-wm rejects it: {s}", .{msg.items});
        return;
    }
    msg.clearRetainingCapacity();
    if (!self.hooks.save(self.hooks.ctx, self.model.source, &msg)) {
        self.complain("{s}", .{msg.items});
        return;
    }
    const copy = self.gpa.dupe(u8, self.model.source) catch return;
    self.gpa.free(self.saved);
    self.saved = copy;
    self.say("{s}", .{msg.items});
}

// --- search -------------------------------------------------------------------

fn find(self: *Self, forward: bool, skip_current: bool) void {
    if (self.search.items.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const all = self.model.rows(a, &self.expanded, true) catch return;
    if (all.len == 0) return;

    var start: usize = 0;
    if (self.current()) |row| for (all, 0..) |r, i| {
        if (mem.eql(u8, r.key, row.key)) start = i;
    };
    var n: usize = 0;
    while (n < all.len) : (n += 1) {
        const off = if (skip_current or n > 0) n + 1 else n;
        const i = if (forward) (start + off) % all.len else (start + all.len * 2 - off) % all.len;
        const r = &all[i];
        const value = self.value_text(a, r);
        if (contains_ci(r.label, self.search.items) or contains_ci(value, self.search.items)) {
            if (r.group) |g| {
                // a heading: open the list and, for a modifier group, its mode
                self.open_to(r.path);
                self.set_expanded(Model.path_key(a, r.path) catch return, true);
                if (g.mods != null) self.set_expanded(r.key[0..mem.lastIndexOfScalar(u8, r.key, '#').?], true);
                self.rebuild(.{ .key = r.key });
            } else {
                self.open_to(r.path);
                self.rebuild(.{ .path = r.path });
            }
            self.say("/{s}", .{self.search.items});
            return;
        }
    }
    self.complain("not found: {s}", .{self.search.items});
}

// --- keys ---------------------------------------------------------------------

fn move_cursor(self: *Self, delta: isize) void {
    if (self.rows.len == 0) return;
    const now: isize = @intCast(self.cursor);
    const max: isize = @intCast(self.rows.len - 1);
    self.cursor = @intCast(std.math.clamp(now + delta, 0, max));
}

fn body_height(self: *const Self) usize {
    return @max(1, @as(usize, self.term.height) -| 5);
}

fn on_normal(self: *Self, key: Key) void {
    const was_armed = self.quit_armed;
    self.quit_armed = false;
    if (key != .char or key.char != 'q') self.message.clearRetainingCapacity();
    const page: isize = @intCast(self.body_height());
    switch (key) {
        .up => self.move_cursor(-1),
        .down => self.move_cursor(1),
        .page_up => self.move_cursor(-page),
        .page_down => self.move_cursor(page),
        .home => self.cursor = 0,
        .end => self.cursor = self.rows.len -| 1,
        .right => self.expand_or_enter(),
        .left => self.collapse_or_leave(),
        .enter => self.edit_row(false),
        .esc => {},
        .ctrl => |c| switch (c) {
            'd' => self.move_cursor(@divTrunc(page, 2)),
            'u' => self.move_cursor(-@divTrunc(page, 2)),
            'n' => self.move_cursor(1),
            'p' => self.move_cursor(-1),
            'r' => self.undo_redo(false),
            's' => self.save(),
            'c' => self.try_quit(was_armed),
            else => {},
        },
        .char => |c| switch (c) {
            'j' => self.move_cursor(1),
            'k' => self.move_cursor(-1),
            'g' => self.cursor = 0,
            'G' => self.cursor = self.rows.len -| 1,
            'l' => self.expand_or_enter(),
            'h' => self.collapse_or_leave(),
            ' ' => self.toggle(),
            'e' => self.edit_row(false),
            'E' => self.edit_row(true),
            'x' => self.toggle_null(),
            'r' => self.reset(),
            'a' => self.list_op(.add),
            'y' => self.list_op(.duplicate),
            'd' => self.list_op(.delete),
            'K' => self.list_op(.up),
            'J' => self.list_op(.down),
            'u' => self.undo_redo(true),
            'w' => self.save(),
            '/' => self.start_input(.search, null, ""),
            'n' => self.find(true, true),
            'N' => self.find(false, true),
            'C' => self.collapse_all(),
            '?' => self.mode = .help,
            'q' => self.try_quit(was_armed),
            else => {},
        },
        else => {},
    }
}

fn try_quit(self: *Self, armed: bool) void {
    if (self.dirty() and !armed) {
        self.quit_armed = true;
        self.complain("unsaved changes: q again to quit without saving, w to save", .{});
        return;
    }
    self.running = false;
}

fn toggle(self: *Self) void {
    const row = self.current() orelse return;
    if (row.st.ty.unwrap().kind == .bool) return self.edit_row(false);
    if (row.expandable) {
        self.set_expanded(row.key, !row.expanded);
        self.rebuild(null);
    }
}

fn expand_or_enter(self: *Self) void {
    const row = self.current() orelse return;
    if (!row.expandable) return;
    if (!row.expanded) {
        self.set_expanded(row.key, true);
        self.rebuild(null);
    } else self.move_cursor(1);
}

fn collapse_or_leave(self: *Self) void {
    const row = self.current() orelse return;
    if (row.expanded) {
        self.set_expanded(row.key, false);
        self.rebuild(null);
        return;
    }
    var i = self.cursor;
    while (i > 0) {
        i -= 1;
        if (self.rows[i].depth < row.depth) {
            self.cursor = i;
            return;
        }
    }
}

fn collapse_all(self: *Self) void {
    var it = self.expanded.keyIterator();
    while (it.next()) |k| self.gpa.free(k.*);
    self.expanded.clearRetainingCapacity();
    // stay on the top-level ancestor
    const row = self.current() orelse return;
    if (row.path.len == 0) return self.rebuild(null);
    self.rebuild(.{ .path = row.path[0..1] });
}

fn toggle_null(self: *Self) void {
    const row = self.current() orelse return;
    if (row.group != null) return self.complain("a group of bindings; open it to change one", .{});
    if (row.st.ty.kind != .optional) {
        self.complain("this value cannot be null", .{});
        return;
    }
    const is_null = if (row.st.eff) |e| e.is_null() else true;
    const b = self.begin_edit();
    self.end_edit(b, self.model.set_null(row.path, !is_null), null);
}

fn reset(self: *Self) void {
    const row = self.current() orelse return;
    if (row.group != null) return self.complain("a group of bindings; open it to change one", .{});
    const b = self.begin_edit();
    self.end_edit(b, self.model.reset(row.path), null);
    if (!self.message_error) self.say("reset to the default", .{});
}

fn on_input(self: *Self, key: Key) void {
    const buf = &self.input.buf;
    switch (key) {
        .esc => self.mode = .normal,
        .enter => self.commit_input(),
        .left => self.input.pos = prev_char(buf.items, self.input.pos),
        .right => self.input.pos = next_char(buf.items, self.input.pos),
        .home => self.input.pos = 0,
        .end => self.input.pos = buf.items.len,
        .backspace => if (self.input.pos > 0) {
            const p = prev_char(buf.items, self.input.pos);
            buf.replaceRange(self.gpa, p, self.input.pos - p, "") catch {};
            self.input.pos = p;
        },
        .delete => if (self.input.pos < buf.items.len) {
            const n = next_char(buf.items, self.input.pos);
            buf.replaceRange(self.gpa, self.input.pos, n - self.input.pos, "") catch {};
        },
        .ctrl => |c| switch (c) {
            'a' => self.input.pos = 0,
            'e' => self.input.pos = buf.items.len,
            'u' => {
                buf.replaceRange(self.gpa, 0, self.input.pos, "") catch {};
                self.input.pos = 0;
            },
            'k' => buf.shrinkRetainingCapacity(self.input.pos),
            'c' => self.mode = .normal,
            else => {},
        },
        .char => |cp| {
            var tmp: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &tmp) catch return;
            buf.insertSlice(self.gpa, self.input.pos, tmp[0..len]) catch return;
            self.input.pos += len;
        },
        else => {},
    }
}

fn prev_char(text: []const u8, pos: usize) usize {
    var p = pos;
    while (p > 0) {
        p -= 1;
        if (text[p] & 0xc0 != 0x80) break;
    }
    return p;
}

fn next_char(text: []const u8, pos: usize) usize {
    var p = pos;
    if (p < text.len) p += 1;
    while (p < text.len and text[p] & 0xc0 == 0x80) p += 1;
    return p;
}

fn on_picker(self: *Self, key: Key) void {
    const n = self.picker.shown.items.len;
    switch (key) {
        .esc => self.mode = .normal,
        .enter => self.commit_picker(),
        .up, .shift_tab => if (self.picker.sel > 0) {
            self.picker.sel -= 1;
        },
        .down, .tab => if (self.picker.sel + 1 < n) {
            self.picker.sel += 1;
        },
        .ctrl => |c| switch (c) {
            'p', 'k' => if (self.picker.sel > 0) {
                self.picker.sel -= 1;
            },
            'n', 'j' => if (self.picker.sel + 1 < n) {
                self.picker.sel += 1;
            },
            'c' => self.mode = .normal,
            else => {},
        },
        .backspace => {
            const f = &self.picker.filter;
            f.shrinkRetainingCapacity(prev_char(f.items, f.items.len));
            self.refilter();
        },
        .char => |cp| {
            var tmp: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &tmp) catch return;
            self.picker.filter.appendSlice(self.gpa, tmp[0..len]) catch return;
            self.refilter();
        },
        else => {},
    }
}

// --- drawing ------------------------------------------------------------------

fn is_color(self: *const Self, row: *const Row) bool {
    _ = self;
    const ty = row.st.ty.unwrap();
    if (ty.kind != .int or ty.kind.int.bits != 32 or ty.kind.int.signed) return false;
    for (row.path) |seg| switch (seg) {
        .field => |name| {
            if (mem.indexOf(u8, name, "color") != null or mem.eql(u8, name, "scheme") or
                mem.eql(u8, name, "background") or mem.eql(u8, name, "fg") or mem.eql(u8, name, "bg"))
                return true;
        },
        .index => {},
    };
    return false;
}

fn color_value(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 0) catch null;
}

fn color_hex(self: *Self, text: []const u8) ?[]const u8 {
    const v = color_value(text) orelse return null;
    return std.fmt.allocPrint(self.arena.allocator(), "0x{x:0>8}", .{v}) catch null;
}

fn value_text(self: *Self, arena: mem.Allocator, row: *const Row) []const u8 {
    if (row.group) |g| return std.fmt.allocPrint(arena, "{d}", .{g.count}) catch "";
    const e = row.st.eff orelse return "<missing>";
    if (row.binding and !row.expanded) return Model.binding_summary(arena, e);
    if (e.is_null()) return "null";
    const ty = row.st.ty.unwrap();
    return switch (ty.kind) {
        .bool, .float => e.text(),
        .int => if (self.is_color(row))
            (if (color_value(e.text())) |v| std.fmt.allocPrint(arena, "0x{x:0>8}", .{v}) catch e.text() else e.text())
        else
            e.text(),
        .string => if (e.node.kind == .string) blk: {
            const s = doc.decode_string(arena, e.text()) catch break :blk e.text();
            break :blk std.fmt.allocPrint(arena, "\"{s}\"", .{s}) catch e.text();
        } else e.text(),
        .@"enum" => if (e.node.kind == .enum_literal) e.node.enum_name(e.src) else e.text(),
        .@"union" => blk: {
            const f = Model.union_tag(ty, e) orelse break :blk e.text();
            if (row.expanded or e.node.kind != .container) break :blk f.name;
            const payload = e.node.entries[0].value.text(e.src);
            const c = doc.compact(arena, payload) catch break :blk f.name;
            break :blk std.fmt.allocPrint(arena, "{s}  {s}", .{ f.name, c }) catch f.name;
        },
        .slice => blk: {
            const n = if (e.node.kind == .container) e.node.entries.len else 0;
            if (row.expanded) break :blk std.fmt.allocPrint(arena, "{d} items", .{n}) catch "";
            const c = doc.compact(arena, e.text()) catch break :blk "";
            break :blk std.fmt.allocPrint(arena, "[{d}] {s}", .{ n, c }) catch "";
        },
        .@"struct", .tuple, .array => if (row.expanded) "" else doc.compact(arena, e.text()) catch "",
        .void, .optional => e.text(),
    };
}

const style = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const reverse = "\x1b[7m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";
    const gray = "\x1b[90m";
};

// rows sharing the cursor row's parent, and the rows under the cursor row
const Scope = struct {
    first: usize = 0,
    end: usize = 0,
    sub_end: usize = 0,
    depth: u16 = 0,
};

fn scope(self: *const Self) Scope {
    if (self.cursor >= self.rows.len) return .{};
    const d = self.rows[self.cursor].depth;
    var sc: Scope = .{ .first = self.cursor, .end = self.cursor + 1, .sub_end = self.cursor + 1, .depth = d };
    while (sc.first > 0 and self.rows[sc.first - 1].depth >= d) sc.first -= 1;
    while (sc.end < self.rows.len and self.rows[sc.end].depth >= d) sc.end += 1;
    while (sc.sub_end < self.rows.len and self.rows[sc.sub_end].depth > d) sc.sub_end += 1;
    return sc;
}

fn row_bg(self: *const Self, sc: Scope, idx: usize) []const u8 {
    if (idx > self.cursor and idx < sc.sub_end) return self.colors.child.seq();
    // at the top every row is a sibling; shading them all says nothing
    if (sc.depth == 0) return "";
    if (idx != self.cursor and idx >= sc.first and idx < sc.end and self.rows[idx].depth == sc.depth) return self.colors.sibling.seq();
    return "";
}

fn value_style(row: *const Row) []const u8 {
    const e = row.st.eff orelse return style.red;
    if (e.origin != .user) return style.gray;
    if (e.is_null()) return style.blue;
    return switch (row.st.ty.unwrap().kind) {
        .bool => style.blue,
        .int, .float => style.magenta,
        .string => style.yellow,
        .@"enum" => style.green,
        .@"union" => style.cyan,
        else => style.dim,
    };
}

fn render(self: *Self) void {
    const t = self.term;
    const w: usize = t.width;
    const h: usize = t.height;
    const arena = self.arena.allocator();
    t.put("\x1b[?25l");

    // header
    t.move(0, 0);
    t.put(style.reverse);
    var used = t.put_clipped(" flat-config  ", w);
    used += t.put_clipped(self.title, w - used);
    if (self.dirty()) used += t.put_clipped("  [modified]", w - used);
    t.spaces(w - used);
    t.put(style.reset);

    // body
    const body = self.body_height();
    if (self.cursor < self.scroll) self.scroll = self.cursor;
    if (self.cursor >= self.scroll + body) self.scroll = self.cursor + 1 - body;
    var label_end: usize = 0;
    for (self.rows[self.scroll..@min(self.rows.len, self.scroll + body)]) |row| {
        label_end = @max(label_end, @as(usize, row.depth) * 2 + 2 + Term.width_of(row.label));
    }
    const value_col = std.math.clamp(label_end + 2, 16, @max(16, w * 11 / 20));

    const sc = self.scope();
    for (0..body) |i| {
        t.move(1 + i, 0);
        const idx = self.scroll + i;
        if (idx < self.rows.len) self.draw_row(&self.rows[idx], idx == self.cursor, self.row_bg(sc, idx), value_col, w, arena);
        t.put(style.reset ++ "\x1b[K");
    }

    // info
    const info_row = h -| 4;
    t.move(info_row, 0);
    t.put(style.dim);
    if (self.current()) |row| {
        const desc = if (row.group) |g| (if (g.mods) |m|
            std.fmt.allocPrint(arena, "{s} bindings in mode {s}", .{ Model.mods_label(arena, m), g.mode }) catch ""
        else
            std.fmt.allocPrint(arena, "bindings in mode {s}, by modifiers", .{g.mode}) catch "")
        else
            schema.describe(arena, row.st.ty) catch "";
        const origin: []const u8 = if (row.st.eff) |e| switch (e.origin) {
            .user => "set in the file",
            .default => "default",
            .type_default => "default",
        } else "missing";
        const pos = std.fmt.allocPrint(arena, " {d}/{d} ", .{ self.cursor + 1, self.rows.len }) catch "";
        const left = std.fmt.allocPrint(arena, "── {s} · {s} ", .{ origin, desc }) catch "";
        const lw = t.put_clipped(left, w -| pos.len);
        for (0..w -| (lw + pos.len)) |_| t.put("─");
        _ = t.put_clipped(pos, w -| lw);
    }
    t.put(style.reset ++ "\x1b[K");

    // help text of the field
    var comment_lines: [2][]const u8 = .{ "", "" };
    if (self.current()) |row| {
        const c = self.model.comment(arena, row) catch "";
        var it = mem.splitScalar(u8, c, '\n');
        var n: usize = 0;
        while (it.next()) |line| {
            if (n == 2) break;
            if (mem.trim(u8, line, " ").len == 0 or mem.startsWith(u8, mem.trim(u8, line, " "), "@")) continue;
            comment_lines[n] = line;
            n += 1;
        }
    }
    for (comment_lines, 0..) |line, i| {
        t.move(info_row + 1 + i, 0);
        t.put(style.dim);
        _ = t.put_clipped(" ", w);
        _ = t.put_clipped(line, w -| 1);
        t.put(style.reset ++ "\x1b[K");
    }

    // status
    t.move(h -| 1, 0);
    switch (self.mode) {
        .input => self.draw_input(w),
        else => {
            if (self.message.items.len > 0) {
                t.put(if (self.message_error) style.red else style.green);
                _ = t.put_clipped(self.message.items, w);
            } else {
                t.put(style.dim);
                _ = t.put_clipped(" ? help  ⏎ edit  space toggle  r reset  x null  a/y/d add/copy/delete  J/K move  / find  u undo  w save  q quit", w);
            }
            t.put(style.reset ++ "\x1b[K");
        },
    }

    if (self.mode == .picker) self.draw_picker(w, h);
    if (self.mode == .link) self.draw_link(w, h);
    if (self.mode == .help) self.draw_help(w, h);
    if (self.mode == .input) t.put("\x1b[?25h") else t.put("\x1b[?25l");
    if (self.mode == .input) {
        // the cursor was placed by draw_input
        t.put("\x1b8");
    }
    t.flush();
}

fn draw_row(self: *Self, row: *const Row, selected: bool, bg: []const u8, value_col: usize, w: usize, arena: mem.Allocator) void {
    const t = self.term;
    if (selected) t.put(style.reverse);
    t.put(bg);
    var used: usize = 0;
    const indent = @as(usize, row.depth) * 2;
    t.spaces(@min(indent, w));
    used += @min(indent, w);
    const marker: []const u8 = if (!row.expandable) "  " else if (row.expanded) "▾ " else "▸ ";
    used += t.put_clipped(marker, w -| used);
    const set_here = row.st.user != null;
    if (set_here and !selected) t.put(style.bold);
    if (!set_here and !selected) t.put(style.gray);
    used += t.put_clipped(row.label, w -| used);
    if (!selected) t.put(style.reset);
    if (selected) t.put(style.reverse);
    t.put(bg);

    // dots up to the value
    if (used + 1 < value_col) {
        if (!selected) t.put(style.dim);
        t.put(" ");
        used += 1;
        while (used + 1 < value_col and used < w) : (used += 1) t.put("·");
        t.put(" ");
        used += 1;
        if (!selected) t.put(style.reset);
        t.put(bg);
    } else if (used < w) {
        t.put(" ");
        used += 1;
    }

    const value = self.value_text(arena, row);
    if (self.is_color(row)) if (row.st.eff) |e| if (color_value(e.text())) |c| {
        if (used + 3 <= w) {
            t.print("\x1b[38;2;{d};{d};{d}m██" ++ style.reset, .{ (c >> 24) & 0xff, (c >> 16) & 0xff, (c >> 8) & 0xff });
            if (selected) t.put(style.reverse);
            t.put(bg);
            t.put(" ");
            used += 3;
        }
    };
    if (!selected) t.put(value_style(row));
    used += t.put_clipped(value, w -| used);
    if (selected or bg.len > 0) t.spaces(w -| used);
}

fn draw_input(self: *Self, w: usize) void {
    const t = self.term;
    const prompt = if (self.input.purpose == .search)
        "/"
    else
        std.fmt.allocPrint(self.arena.allocator(), "{s} = ", .{self.input.prompt}) catch "";
    t.put(style.bold);
    const pw = t.put_clipped(prompt, w);
    t.put(style.reset);
    const room = w -| pw -| 1;
    const text = self.input.buf.items;
    // keep the cursor visible
    var start: usize = 0;
    while (Term.width_of(text[start..self.input.pos]) > room) start = next_char(text, start);
    const before = Term.width_of(text[start..self.input.pos]);
    _ = t.put_clipped(text[start..], room);
    t.put("\x1b[K");
    t.move(t.height -| 1, pw + before);
    t.put("\x1b7");
}

fn draw_picker(self: *Self, w: usize, h: usize) void {
    const t = self.term;
    var width: usize = Term.width_of(self.picker.title) + 4;
    for (self.picker.options) |o| width = @max(width, Term.width_of(o) + 6);
    width = @min(@max(width, 24), w -| 4);
    const list_h = @min(self.picker.shown.items.len, @max(3, h -| 10));
    const box_h = list_h + 3;
    const top = (h -| box_h) / 2;
    const left = (w -| width) / 2;

    var first: usize = 0;
    if (self.picker.sel >= list_h) first = self.picker.sel + 1 - list_h;

    t.move(top, left);
    t.put(style.bold);
    t.put("┌");
    var used = t.put_clipped(self.picker.title, width -| 2);
    for (0..width -| 2 -| used) |_| t.put("─");
    t.put("┐" ++ style.reset);

    t.move(top + 1, left);
    t.put("│ " ++ style.cyan);
    used = t.put_clipped(self.picker.filter.items, width -| 4);
    t.put(style.reset);
    if (self.picker.filter.items.len == 0) {
        t.put(style.dim);
        used += t.put_clipped("type to filter", width -| 4 -| used);
        t.put(style.reset);
    }
    t.spaces(width -| 3 -| used);
    t.put("│");

    for (0..list_h) |i| {
        t.move(top + 2 + i, left);
        t.put("│ ");
        const idx = first + i;
        if (idx < self.picker.shown.items.len) {
            if (idx == self.picker.sel) t.put(style.reverse);
            const name = self.picker.options[self.picker.shown.items[idx]];
            used = t.put_clipped(name, width -| 4);
            t.spaces(width -| 4 -| used);
            t.put(style.reset);
        } else t.spaces(width -| 4);
        t.put(" │");
    }
    t.move(top + 2 + list_h, left);
    t.put("└");
    for (0..width -| 2) |_| t.put("─");
    t.put("┘");
}

fn draw_link(self: *Self, w: usize, h: usize) void {
    const t = self.term;
    const others = self.link.others.items;
    const arena = self.arena.allocator();
    const title = std.fmt.allocPrint(arena, " {d} more {s} {s} ", .{
        others.len, if (others.len == 1) "place holds" else "places hold", self.link.old,
    }) catch "";
    const footer = " space toggle  a all  ⏎ change checked  esc only this one ";
    var width: usize = @max(Term.width_of(title), Term.width_of(footer)) + 2;
    for (others) |o| width = @max(width, Term.width_of(o.key) + 8);
    width = @min(width, w -| 4);
    const list_h = @min(others.len, @max(3, h -| 10));
    const top = (h -| (list_h + 3)) / 2;
    const left = (w -| width) / 2;
    var first: usize = 0;
    if (self.link.sel >= list_h) first = self.link.sel + 1 - list_h;

    t.move(top, left);
    t.put(style.bold ++ "┌");
    var used = t.put_clipped(title, width -| 2);
    for (0..width -| 2 -| used) |_| t.put("─");
    t.put("┐" ++ style.reset);
    for (0..list_h) |i| {
        t.move(top + 1 + i, left);
        t.put("│ ");
        const idx = first + i;
        if (idx < others.len) {
            const o = others[idx];
            if (idx == self.link.sel) t.put(style.reverse);
            used = t.put_clipped(if (o.checked) "[x] " else "[ ] ", width -| 4);
            // keep the end of a long path, it names the value
            const room = width -| 4 -| used;
            var key = o.key;
            if (Term.width_of(key) > room) {
                used += t.put_clipped("…", room);
                while (key.len > 0 and Term.width_of(key) > room -| 1) key = key[1..];
            }
            used += t.put_clipped(key, width -| 4 -| used);
            t.spaces(width -| 4 -| used);
            t.put(style.reset);
        } else t.spaces(width -| 4);
        t.put(" │");
    }
    t.move(top + 1 + list_h, left);
    t.put("│");
    t.put(style.dim);
    used = t.put_clipped(footer, width -| 2);
    t.put(style.reset);
    t.spaces(width -| 2 -| used);
    t.put("│");
    t.move(top + 2 + list_h, left);
    t.put("└");
    for (0..width -| 2) |_| t.put("─");
    t.put("┘");
}

fn draw_help(self: *Self, w: usize, h: usize) void {
    const t = self.term;
    const lines = [_][]const u8{
        "flat-config: edit ~/.config/flat-wm/config.zon",
        "",
        "  j k ↑ ↓        move            g G         top / bottom",
        "  ctrl-d ctrl-u  half page       PgUp PgDn   page",
        "  l → / h ←      open / close, go to parent  C  close all",
        "",
        "  ⏎ e            edit the value: type, pick from a list, or toggle",
        "  space          toggle a switch, open or close a group",
        "  E              edit the value as raw ZON text",
        "  x              set to null / give a value",
        "  r              reset: remove from the file, use the default",
        "",
        "  a              add an item to a list; on a group of bindings,",
        "                 a binding with that mode and those modifiers",
        "  y              duplicate the item      d   delete the item",
        "  J K            move the item down / up",
        "",
        "  / n N          find, next, previous",
        "  u ctrl-r       undo, redo",
        "  w ctrl-s       check with flat-wm's parser, save, and reload flat-wm",
        "  q              quit",
        "",
        "Bold names are set in the file; gray ones use the default.",
        "Shaded rows: the cursor's level (not at the top), and what lies under it.",
        "Bindings are grouped by mode, then by modifiers (Super, Alt, ...).",
        "Comments and layout in the file are kept. Changing a number or a",
        "string offers to change the other places that hold the same value.",
        "",
        "any key to close",
    };
    const width = @min(w -| 2, 76);
    const top = (h -| lines.len -| 2) / 2;
    const left = (w -| width) / 2;
    for (0..lines.len + 2) |i| {
        if (top + i >= h) break;
        t.move(top + i, left);
        t.put(style.reverse);
        t.put(" ");
        const used = if (i > 0 and i <= lines.len) t.put_clipped(lines[i - 1], width -| 2) else 0;
        t.spaces(width -| 1 -| used);
        t.put(style.reset);
    }
}

test "Bg.parse" {
    try std.testing.expectEqualStrings("\x1b[48;5;236m", (try Bg.parse("236")).seq());
    try std.testing.expectEqualStrings("\x1b[48;2;18;52;86m", (try Bg.parse("#123456")).seq());
    try std.testing.expectEqualStrings("\x1b[48;2;255;0;16m", (try Bg.parse("0xff0010")).seq());
    try std.testing.expectEqualStrings("", (try Bg.parse("none")).seq());
    try std.testing.expectError(error.BadColor, Bg.parse("256"));
    try std.testing.expectError(error.BadColor, Bg.parse("#12345"));
    try std.testing.expectError(error.BadColor, Bg.parse("blue"));
}
