// The configuration as the TUI sees it: the user's file, the built-in defaults
// and the `Config` type, walked side by side.
//
// Edits are text edits on the user's file. A value that is not in the file yet
// is inserted, creating its parents as needed; a value inherited from a list is
// first copied into the file.

const Self = @This();

const std = @import("std");
const mem = std.mem;

const doc = @import("doc.zig");
const schema = @import("schema.zig");
const Node = doc.Node;

pub const Origin = enum { user, default, type_default };

pub const Val = struct {
    node: *Node,
    src: []const u8,
    origin: Origin,

    fn child(self: Val, node: ?*Node) ?Val {
        return .{ .node = node orelse return null, .src = self.src, .origin = self.origin };
    }

    pub fn is_null(self: Val) bool {
        return self.node.is_null(self.src);
    }

    pub fn text(self: Val) []const u8 {
        return self.node.text(self.src);
    }
};

pub const Seg = union(enum) {
    field: []const u8, // always a name owned by the schema
    index: usize,
};

pub const State = struct {
    // declared type here, possibly optional
    ty: *const schema.Type,
    // the value in the user's file
    user: ?*Node,
    // the value in effect: user's, else a default
    eff: ?Val,
    // the built-in default here
    dflt: ?*Node,
    // missing struct fields here fall back to the built-in defaults
    region: bool,
    // set when this is a struct field
    field: ?*const schema.Field,
};

pub const Row = struct {
    depth: u16,
    label: []const u8,
    path: []const Seg,
    key: []const u8,
    st: State,
    expandable: bool,
    expanded: bool,
    // the row is a list item
    item: bool,
    // a heading that groups key or pointer bindings; `path` is the list's
    group: ?Group = null,
    // the row is a binding inside such a group
    binding: bool = false,
};

pub const Group = struct {
    mode: []const u8,
    // null for the heading of a whole mode
    mods: ?u32,
    count: usize,
};

// modifier names in the order of `Modifiers`, and how they are shown
const modifier_labels = .{
    .{ "mod4", "Super" },
    .{ "ctrl", "Ctrl" },
    .{ "mod1", "Alt" },
    .{ "shift", "Shift" },
    .{ "mod3", "Mod3" },
    .{ "mod5", "Mod5" },
};
const mod4_bit = 1 << 0;
const mod1_bit = 1 << 2;

pub const EditError = error{ Invalid, OutOfMemory, WriteFailed };

gpa: mem.Allocator,
root_type: *const schema.Type,
source: []u8,
user: doc.Doc,
default_source: []u8,
default: doc.Doc,
// comments of the shipped default config, for help text
reference: doc.Doc,
type_defaults: std.AutoHashMapUnmanaged(*const schema.Field, ?Val) = .empty,
type_default_docs: std.ArrayList(doc.Doc) = .empty,
// why the last edit failed
problem: []const u8 = "",

pub fn init(
    gpa: mem.Allocator,
    root_type: *const schema.Type,
    source: []const u8,
    default_source: []const u8,
    reference_source: []const u8,
) !Self {
    const src = try gpa.dupe(u8, source);
    errdefer gpa.free(src);
    var user = try doc.parse(gpa, src);
    errdefer user.deinit();
    const dsrc = try gpa.dupe(u8, default_source);
    errdefer gpa.free(dsrc);
    var default = try doc.parse(gpa, dsrc);
    errdefer default.deinit();
    const reference = doc.parse(gpa, reference_source) catch try doc.parse(gpa, ".{}");
    return .{
        .gpa = gpa,
        .root_type = root_type,
        .source = src,
        .user = user,
        .default_source = dsrc,
        .default = default,
        .reference = reference,
    };
}

pub fn deinit(self: *Self) void {
    self.user.deinit();
    self.gpa.free(self.source);
    self.default.deinit();
    self.gpa.free(self.default_source);
    self.reference.deinit();
    for (self.type_default_docs.items) |*d| {
        self.gpa.free(d.source);
        d.deinit();
    }
    self.type_default_docs.deinit(self.gpa);
    self.type_defaults.deinit(self.gpa);
}

// --- walking ----------------------------------------------------------------

pub fn root(self: *const Self) State {
    return .{
        .ty = self.root_type,
        .user = self.user.root,
        .eff = .{ .node = self.user.root, .src = self.source, .origin = .user },
        .dflt = self.default.root,
        .region = true,
        .field = null,
    };
}

fn type_default(self: *Self, f: *const schema.Field) ?Val {
    if (self.type_defaults.get(f)) |v| return v;
    const v: ?Val = blk: {
        const text = (schema.default_text(self.gpa, f) catch break :blk null) orelse break :blk null;
        var d = doc.parse(self.gpa, text) catch {
            self.gpa.free(text);
            break :blk null;
        };
        self.type_default_docs.append(self.gpa, d) catch {
            self.gpa.free(text);
            d.deinit();
            break :blk null;
        };
        break :blk .{ .node = d.root, .src = text, .origin = .type_default };
    };
    self.type_defaults.put(self.gpa, f, v) catch {};
    return v;
}

fn not_null(node: ?*Node, src: []const u8) ?*Node {
    const n = node orelse return null;
    return if (n.is_null(src)) null else n;
}

fn entry_value(entry: ?*doc.Entry) ?*Node {
    return if (entry) |e| e.value else null;
}

pub fn step(self: *Self, st: State, seg: Seg) ?State {
    const ty = st.ty.unwrap();
    const user = not_null(st.user, self.source);
    const eff: ?Val = if (st.eff) |e| (if (e.is_null()) null else e) else null;
    const dflt = not_null(st.dflt, self.default_source);
    switch (ty.kind) {
        .@"struct" => {
            const name = switch (seg) {
                .field => |n| n,
                .index => return null,
            };
            const f = ty.field(name) orelse return null;
            const cu = if (user) |u| entry_value(u.field(name)) else null;
            const cd = if (dflt) |d| entry_value(d.field(name)) else null;
            var ce: ?Val = null;
            if (cu) |n| {
                ce = .{ .node = n, .src = self.source, .origin = .user };
            } else if (eff) |e| if (e.origin != .user) {
                ce = e.child(entry_value(e.node.field(name)));
            };
            if (ce == null and st.region) {
                if (cd) |n| ce = .{ .node = n, .src = self.default_source, .origin = .default };
            }
            if (ce == null) ce = self.type_default(f);

            const fty = f.type();
            const region = st.region and switch (fty.kind) {
                .@"struct" => true,
                .optional => |c| c().kind == .@"struct" and not_null(cd, self.default_source) != null,
                else => false,
            };
            return .{ .ty = fty, .user = cu, .eff = ce, .dflt = cd, .region = region, .field = f };
        },
        .@"union" => {
            const tag = switch (seg) {
                .field => |n| n,
                .index => return null,
            };
            const f = ty.field(tag) orelse return null;
            const cu = if (user) |u| entry_value(u.field(tag)) else null;
            const cd = if (dflt) |d| entry_value(d.field(tag)) else null;
            var ce: ?Val = null;
            if (eff) |e| ce = e.child(entry_value(e.node.field(tag)));
            return .{ .ty = f.type(), .user = cu, .eff = ce, .dflt = cd, .region = false, .field = null };
        },
        .slice, .tuple, .array => {
            const i = switch (seg) {
                .index => |i| i,
                .field => return null,
            };
            const cty = switch (ty.kind) {
                .slice => |c| c(),
                .tuple => |types| if (i < types.len) types[i]() else return null,
                .array => |a| if (i < a.len) a.child() else return null,
                else => unreachable,
            };
            const cu = if (user) |u| entry_value(u.item(i)) else null;
            const cd = if (dflt) |d| entry_value(d.item(i)) else null;
            const ce: ?Val = if (cu) |n|
                .{ .node = n, .src = self.source, .origin = .user }
            else if (eff) |e| e.child(entry_value(e.node.item(i))) else null;
            return .{ .ty = cty, .user = cu, .eff = ce, .dflt = cd, .region = false, .field = null };
        },
        else => return null,
    }
}

pub fn lookup(self: *Self, path: []const Seg) ?State {
    var st = self.root();
    for (path) |seg| st = self.step(st, seg) orelse return null;
    return st;
}

// tag of a union value, as the schema's field
pub fn union_tag(ty: *const schema.Type, v: Val) ?*const schema.Field {
    if (ty.kind != .@"union") return null;
    const name = switch (v.node.kind) {
        .enum_literal => v.node.enum_name(v.src),
        .container => if (v.node.named and v.node.entries.len == 1) v.node.entries[0].name.? else return null,
        else => return null,
    };
    return ty.field(name);
}

// --- rows -------------------------------------------------------------------

pub fn path_key(arena: mem.Allocator, path: []const Seg) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path, 0..) |seg, i| {
        if (i > 0) try out.append(arena, '.');
        switch (seg) {
            .field => |n| try out.appendSlice(arena, n),
            .index => |idx| try out.print(arena, "{d}", .{idx}),
        }
    }
    return out.items;
}

pub fn expandable(st: State) bool {
    const e = st.eff orelse return false;
    if (e.is_null()) return false;
    const ty = st.ty.unwrap();
    return switch (ty.kind) {
        .@"struct" => |fields| for (fields) |f| {
            if (!f.hidden) break true;
        } else false,
        .@"union" => if (union_tag(ty, e)) |f| f.type().kind != .void else false,
        .slice => e.node.kind == .container and e.node.entries.len > 0,
        .tuple, .array => true,
        else => false,
    };
}

pub fn rows(
    self: *Self,
    arena: mem.Allocator,
    expanded: *const std.StringHashMapUnmanaged(void),
    expand_all: bool,
) ![]Row {
    var out: std.ArrayList(Row) = .empty;
    try self.add_children(arena, &out, &.{}, self.root(), 0, expanded, expand_all);
    return out.items;
}

fn push(
    self: *Self,
    arena: mem.Allocator,
    out: *std.ArrayList(Row),
    path: []const Seg,
    seg: Seg,
    label: []const u8,
    st: State,
    depth: u16,
    expanded: *const std.StringHashMapUnmanaged(void),
    expand_all: bool,
) !void {
    const p = try mem.concat(arena, Seg, &.{ path, &.{seg} });
    const key = try path_key(arena, p);
    const can = expandable(st);
    const open = can and (expand_all or expanded.contains(key));
    try out.append(arena, .{
        .depth = depth,
        .label = label,
        .path = p,
        .key = key,
        .st = st,
        .expandable = can,
        .expanded = open,
        .item = seg == .index,
    });
    if (open) try self.add_children(arena, out, p, st, depth + 1, expanded, expand_all);
}

fn add_children(
    self: *Self,
    arena: mem.Allocator,
    out: *std.ArrayList(Row),
    path: []const Seg,
    st: State,
    depth: u16,
    expanded: *const std.StringHashMapUnmanaged(void),
    expand_all: bool,
) error{OutOfMemory}!void {
    const e = st.eff orelse return;
    if (e.is_null()) return;
    const ty = st.ty.unwrap();
    switch (ty.kind) {
        .@"struct" => |fields| for (fields) |*f| {
            if (f.hidden) continue;
            const seg: Seg = .{ .field = f.name };
            const cst = self.step(st, seg) orelse continue;
            try self.push(arena, out, path, seg, f.name, cst, depth, expanded, expand_all);
        },
        .@"union" => {
            const f = union_tag(ty, e) orelse return;
            const pty = f.type();
            if (pty.kind == .void) return;
            const tag_seg: Seg = .{ .field = f.name };
            const pst = self.step(st, tag_seg) orelse return;
            const pp = try mem.concat(arena, Seg, &.{ path, &.{tag_seg} });
            // a struct payload is shown as the union's own fields
            if (pty.kind == .@"struct" and pst.eff != null) {
                for (pty.kind.@"struct") |*pf| {
                    if (pf.hidden) continue;
                    const seg: Seg = .{ .field = pf.name };
                    const cst = self.step(pst, seg) orelse continue;
                    try self.push(arena, out, pp, seg, pf.name, cst, depth, expanded, expand_all);
                }
            } else {
                try self.push(arena, out, path, tag_seg, f.name, pst, depth, expanded, expand_all);
            }
        },
        .slice, .tuple, .array => {
            if (e.node.kind != .container) return;
            if (is_binding_list(ty)) {
                return self.add_binding_groups(arena, out, path, st, depth, expanded, expand_all);
            }
            const len = switch (ty.kind) {
                .slice => e.node.entries.len,
                .tuple => |t| t.len,
                .array => |a| a.len,
                else => unreachable,
            };
            for (0..len) |i| {
                const seg: Seg = .{ .index = i };
                const cst = self.step(st, seg) orelse continue;
                const label = try std.fmt.allocPrint(arena, "[{d}]", .{i});
                try self.push(arena, out, path, seg, label, cst, depth, expanded, expand_all);
            }
        },
        else => {},
    }
}

// --- binding groups -------------------------------------------------------------
//
// Key and pointer bindings are shown by mode, then by modifiers.

pub fn is_binding_list(ty: *const schema.Type) bool {
    const elem = switch (ty.kind) {
        .slice => |c| c(),
        else => return false,
    };
    return elem.kind == .@"struct" and elem.field("mode") != null and elem.field("modifiers") != null;
}

const BindingInfo = struct { mode: []const u8, mods: u32 };

fn binding_info(arena: mem.Allocator, item: Val) BindingInfo {
    var info: BindingInfo = .{ .mode = "default", .mods = 0 };
    if (item.node.kind != .container) return info;
    if (item.node.field("mode")) |m| if (m.value.kind == .string) {
        info.mode = doc.decode_string(arena, m.value.text(item.src)) catch "default";
    };
    if (item.node.field("modifiers")) |m| if (m.value.kind == .container) {
        inline for (modifier_labels, 0..) |ml, bit| {
            if (m.value.field(ml[0])) |f| {
                if (mem.eql(u8, f.value.text(item.src), "true")) info.mods |= 1 << bit;
            }
        }
    };
    return info;
}

pub fn mods_label(arena: mem.Allocator, mods: u32) []const u8 {
    if (mods == 0) return "no modifier";
    var out: std.ArrayList(u8) = .empty;
    inline for (modifier_labels, 0..) |ml, bit| {
        if (mods & (1 << bit) != 0) {
            if (out.items.len > 0) out.append(arena, '+') catch {};
            out.appendSlice(arena, ml[1]) catch {};
        }
    }
    return out.items;
}

// Super first, then Alt, then the rest; fewer modifiers first; none last
fn mods_rank(mods: u32) u64 {
    const class: u64 = if (mods == 0) 3 else if (mods & mod4_bit != 0) 0 else if (mods & mod1_bit != 0) 1 else 2;
    return class << 40 | @as(u64, @popCount(mods)) << 32 | mods;
}

fn mods_less(_: void, a: u32, b: u32) bool {
    return mods_rank(a) < mods_rank(b);
}

fn group_key(arena: mem.Allocator, list_key: []const u8, mode: []const u8, mods: ?u32) ![]const u8 {
    if (mods) |m| return std.fmt.allocPrint(arena, "{s}#{s}#{s}", .{ list_key, mode, mods_label(arena, m) });
    return std.fmt.allocPrint(arena, "{s}#{s}", .{ list_key, mode });
}

// a binding's own name: its keysym or button
fn binding_label(arena: mem.Allocator, item: Val, index: usize) []const u8 {
    if (item.node.kind == .container) {
        if (item.node.field("keysym")) |k| if (k.value.kind == .string) {
            return doc.decode_string(arena, k.value.text(item.src)) catch "?";
        };
        if (item.node.field("button")) |k| if (k.value.kind == .enum_literal) {
            return k.value.enum_name(item.src);
        };
    }
    return std.fmt.allocPrint(arena, "[{d}]", .{index}) catch "?";
}

fn add_binding_groups(
    self: *Self,
    arena: mem.Allocator,
    out: *std.ArrayList(Row),
    path: []const Seg,
    st: State,
    depth: u16,
    expanded: *const std.StringHashMapUnmanaged(void),
    expand_all: bool,
) !void {
    const list = st.eff.?;
    const entries = list.node.entries;
    const infos = try arena.alloc(BindingInfo, entries.len);
    var modes: std.ArrayList([]const u8) = .empty;
    try modes.append(arena, "default");
    for (entries, 0..) |entry, i| {
        infos[i] = binding_info(arena, list.child(entry.value).?);
        for (modes.items) |m| {
            if (mem.eql(u8, m, infos[i].mode)) break;
        } else try modes.append(arena, infos[i].mode);
    }
    const list_key = try path_key(arena, path);

    for (modes.items) |mode| {
        var count: usize = 0;
        var mods: std.ArrayList(u32) = .empty;
        for (infos) |info| {
            if (!mem.eql(u8, info.mode, mode)) continue;
            count += 1;
            for (mods.items) |m| {
                if (m == info.mods) break;
            } else try mods.append(arena, info.mods);
        }
        if (count == 0) continue;
        const mode_key = try group_key(arena, list_key, mode, null);
        const mode_open = expand_all or expanded.contains(mode_key);
        try out.append(arena, .{
            .depth = depth,
            .label = mode,
            .path = path,
            .key = mode_key,
            .st = st,
            .expandable = true,
            .expanded = mode_open,
            .item = false,
            .group = .{ .mode = mode, .mods = null, .count = count },
        });
        if (!mode_open) continue;

        std.mem.sort(u32, mods.items, {}, mods_less);
        for (mods.items) |m| {
            var n: usize = 0;
            for (infos) |info| {
                if (mem.eql(u8, info.mode, mode) and info.mods == m) n += 1;
            }
            const mods_key = try group_key(arena, list_key, mode, m);
            const mods_open = expand_all or expanded.contains(mods_key);
            try out.append(arena, .{
                .depth = depth + 1,
                .label = mods_label(arena, m),
                .path = path,
                .key = mods_key,
                .st = st,
                .expandable = true,
                .expanded = mods_open,
                .item = false,
                .group = .{ .mode = mode, .mods = m, .count = n },
            });
            if (!mods_open) continue;

            for (infos, 0..) |info, i| {
                if (!mem.eql(u8, info.mode, mode) or info.mods != m) continue;
                const seg: Seg = .{ .index = i };
                const cst = self.step(st, seg) orelse continue;
                const label = binding_label(arena, list.child(entries[i].value).?, i);
                const before = out.items.len;
                try self.push(arena, out, path, seg, label, cst, depth + 2, expanded, expand_all);
                out.items[before].binding = true;
            }
        }
    }
}

// keys to open so the row at `path` is shown
pub fn ancestor_keys(self: *Self, arena: mem.Allocator, path: []const Seg) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    for (1..path.len) |len| {
        try keys.append(arena, try path_key(arena, path[0..len]));
        const list_st = self.lookup(path[0..len]) orelse continue;
        if (!is_binding_list(list_st.ty.unwrap()) or path[len] != .index) continue;
        const list = list_st.eff orelse continue;
        const item = list.child(entry_value(list.node.item(path[len].index))) orelse continue;
        const info = binding_info(arena, item);
        const list_key = keys.items[keys.items.len - 1];
        try keys.append(arena, try group_key(arena, list_key, info.mode, null));
        try keys.append(arena, try group_key(arena, list_key, info.mode, info.mods));
    }
    return keys.items;
}

// one line saying what a binding does
pub fn binding_summary(arena: mem.Allocator, item: Val) []const u8 {
    if (item.node.kind != .container) return "";
    const event = (item.node.field("event") orelse return "").value;
    if (event.kind != .container or !event.named or event.entries.len == 0) return "";
    // key bindings: .{ .click = .{ ... } } or .{ .repeat = action }
    var body = event;
    if (event.entries.len == 1) {
        const tag = event.entries[0].name.?;
        if (mem.eql(u8, tag, "repeat")) {
            return std.fmt.allocPrint(arena, "repeat: {s}", .{action_summary(arena, item.child(event.entries[0].value).?)}) catch "";
        }
        if (mem.eql(u8, tag, "click")) body = event.entries[0].value;
    }
    // .{ .pressed = action, .released = action }
    var out: std.ArrayList(u8) = .empty;
    if (body.kind == .container and body.named) for (body.entries) |e| {
        if (e.value.is_null(item.src)) continue;
        if (out.items.len > 0) out.appendSlice(arena, "; ") catch {};
        if (mem.eql(u8, e.name.?, "released")) out.appendSlice(arena, "released: ") catch {};
        out.appendSlice(arena, action_summary(arena, item.child(e.value).?)) catch {};
    };
    return if (out.items.len > 0) out.items else "nothing";
}

fn action_summary(arena: mem.Allocator, action: Val) []const u8 {
    switch (action.node.kind) {
        .enum_literal => return action.node.enum_name(action.src),
        .container => if (action.node.named and action.node.entries.len == 1) {
            const e = action.node.entries[0];
            const payload = action.child(e.value).?;
            return std.fmt.allocPrint(arena, "{s} {s}", .{ e.name.?, short_value(arena, payload, 0) }) catch "";
        },
        else => {},
    }
    return doc.compact(arena, action.text()) catch "";
}

// `.{ .direction = .forward }` -> `direction=forward`, lists in [], nested groups in {}
fn short_value(arena: mem.Allocator, v: Val, depth: usize) []const u8 {
    switch (v.node.kind) {
        .enum_literal => return v.node.enum_name(v.src),
        .container => {
            var out: std.ArrayList(u8) = .empty;
            if (v.node.named) {
                if (depth > 0) out.append(arena, '{') catch {};
                for (v.node.entries, 0..) |e, i| {
                    if (i > 0) out.append(arena, ' ') catch {};
                    out.print(arena, "{s}={s}", .{ e.name.?, short_value(arena, v.child(e.value).?, depth + 1) }) catch {};
                }
                if (depth > 0) out.append(arena, '}') catch {};
            } else {
                out.append(arena, '[') catch {};
                for (v.node.entries, 0..) |e, i| {
                    if (i > 0) out.appendSlice(arena, ", ") catch {};
                    out.appendSlice(arena, short_value(arena, v.child(e.value).?, depth + 1)) catch {};
                }
                out.append(arena, ']') catch {};
            }
            return out.items;
        },
        else => {},
    }
    return doc.compact(arena, v.text()) catch "";
}

// help text for a row: comments above it in the user's file, else in the shipped default
pub fn comment(self: *Self, gpa: mem.Allocator, row: *const Row) ![]u8 {
    if (row.path.len > 0) {
        if (entry_of(self.user.root, row.path)) |entry| if (doc.starts_line(self.source, entry.start)) {
            const c = try doc.comment_above(gpa, self.source, entry.start);
            if (c.len > 0) return c;
            gpa.free(c);
        };
        // list items differ between files, only plain field paths are looked up
        for (row.path) |seg| if (seg == .index) return gpa.dupe(u8, "");
        if (entry_of(self.reference.root, row.path)) |entry| {
            return doc.comment_above(gpa, self.reference.source, entry.start);
        }
    }
    return gpa.dupe(u8, "");
}

fn entry_of(start: *Node, path: []const Seg) ?*doc.Entry {
    var node = start;
    var entry: ?*doc.Entry = null;
    for (path) |seg| {
        entry = switch (seg) {
            .field => |n| node.field(n),
            .index => |i| node.item(i),
        };
        node = (entry orelse return null).value;
    }
    return entry;
}

// --- editing ----------------------------------------------------------------

fn fail(self: *Self, msg: []const u8) EditError {
    self.problem = msg;
    return error.Invalid;
}

fn apply(self: *Self, new_source: []u8) EditError!void {
    const parsed = doc.parse(self.gpa, new_source) catch {
        self.gpa.free(new_source);
        return self.fail("the edit would break the file");
    };
    self.user.deinit();
    self.gpa.free(self.source);
    self.source = new_source;
    self.user = parsed;
}

pub fn replace_source(self: *Self, new_source: []const u8) EditError!void {
    try self.apply(try self.gpa.dupe(u8, new_source));
}

const Text = struct {
    text: []const u8,
    // indent of its continuation lines
    base: []const u8 = "",
    owned: bool = false,
};

// a value to put into the file for `path`: the default in effect, else a template
fn fresh(self: *Self, path: []const Seg) EditError!Text {
    const st = self.lookup(path) orelse return self.fail("no such value");
    if (st.eff) |e| if (e.origin != .user) {
        return .{ .text = e.text(), .base = doc.line_indent(e.src, e.node.start) };
    };
    return .{ .text = try schema.template(self.gpa, st.ty), .owned = true };
}

pub fn set(self: *Self, path: []const Seg, text: []const u8, base: []const u8) EditError!void {
    if (path.len == 0) return self.fail("cannot replace the whole file");
    var guard: usize = 0;
    while (guard < 2 * path.len + 4) : (guard += 1) {
        const st = self.lookup(path) orelse return self.fail("no such value");
        if (st.user) |node| {
            const moved = try doc.reindent(self.gpa, text, base, doc.line_indent(self.source, node.start));
            defer self.gpa.free(moved);
            return self.apply(try doc.replace(self.gpa, self.source, node.start, node.end, moved));
        }
        const parent_path = path[0 .. path.len - 1];
        const pst = self.lookup(parent_path) orelse return self.fail("no such value");
        const name = switch (path[path.len - 1]) {
            .field => |n| n,
            .index => {
                // an item of an inherited list: copy the list into the file
                if (pst.user != null) return self.fail("list item is missing");
                const f = try self.fresh(parent_path);
                defer if (f.owned) self.gpa.free(f.text);
                try self.set(parent_path, f.text, f.base);
                continue;
            },
        };
        if (pst.user) |parent| {
            if (parent.kind == .container and (parent.named or parent.entries.len == 0)) {
                if (pst.ty.unwrap().kind == .@"union") {
                    // switching a union's tag replaces the whole union
                    const t = try std.fmt.allocPrint(self.gpa, ".{{ .{f} = {s} }}", .{ std.zig.fmtIdPU(name), text });
                    defer self.gpa.free(t);
                    return self.set(parent_path, t, base);
                }
                return self.apply(try doc.insert_field(self.gpa, self.source, parent, name, text, base));
            }
        }
        // create the parent, then try again
        if (pst.user == null and pst.region and pst.ty.unwrap().kind == .@"struct") {
            try self.set(parent_path, ".{}", "");
        } else {
            const f = try self.fresh(parent_path);
            defer if (f.owned) self.gpa.free(f.text);
            if (pst.user != null and pst.eff != null and pst.eff.?.origin == .user) {
                // the parent is in the file but not a container (null)
                const t = try schema.template(self.gpa, pst.ty.unwrap());
                defer self.gpa.free(t);
                try self.set(parent_path, t, "");
            } else {
                try self.set(parent_path, f.text, f.base);
            }
        }
    }
    return self.fail("could not place the value");
}

// copy the value at `path` into the file if it only exists as a default
fn materialize(self: *Self, path: []const Seg) EditError!*Node {
    var st = self.lookup(path) orelse return self.fail("no such value");
    if (st.user == null) {
        const f = try self.fresh(path);
        defer if (f.owned) self.gpa.free(f.text);
        try self.set(path, f.text, f.base);
        st = self.lookup(path) orelse return self.fail("no such value");
    }
    return st.user orelse self.fail("could not place the value");
}

pub fn reset(self: *Self, path: []const Seg) EditError!void {
    if (path.len == 0 or path[path.len - 1] != .field) return self.fail("only fields can be reset");
    const st = self.lookup(path) orelse return self.fail("no such value");
    if (st.user == null) return self.fail("already the default");
    const pst = self.lookup(path[0 .. path.len - 1]).?;
    if (pst.ty.unwrap().kind == .@"union") return self.fail("pick another kind instead");
    if (!pst.region and (st.field == null or st.field.?.default == null)) {
        return self.fail("this field has no default");
    }
    const parent = pst.user orelse return self.fail("already the default");
    for (parent.entries, 0..) |entry, i| {
        if (entry.value == st.user.?) {
            return self.apply(try doc.remove_entry(self.gpa, self.source, parent, i));
        }
    }
    return self.fail("could not find the field");
}

pub fn set_null(self: *Self, path: []const Seg, to_null: bool) EditError!void {
    const st = self.lookup(path) orelse return self.fail("no such value");
    if (st.ty.kind != .optional) return self.fail("this value cannot be null");
    if (to_null) return self.set(path, "null", "");
    // un-null: the default if it is not null, else a template
    if (st.dflt) |d| if (!d.is_null(self.default_source)) {
        return self.set(path, d.text(self.default_source), doc.line_indent(self.default_source, d.start));
    };
    const t = try schema.template(self.gpa, st.ty.unwrap());
    defer self.gpa.free(t);
    return self.set(path, t, "");
}

pub fn set_tag(self: *Self, path: []const Seg, f: *const schema.Field) EditError!void {
    const st = self.lookup(path) orelse return self.fail("no such value");
    // keep the default's payload if it has this tag
    if (st.dflt) |d| if (!d.is_null(self.default_source)) {
        const dv: Val = .{ .node = d, .src = self.default_source, .origin = .default };
        if (union_tag(st.ty.unwrap(), dv) == f) {
            return self.set(path, d.text(self.default_source), doc.line_indent(self.default_source, d.start));
        }
    };
    const t = try schema.union_template(self.gpa, f);
    defer self.gpa.free(t);
    return self.set(path, t, "");
}

// the list at `path` and the item index, for a path ending at a list item
fn list_of(self: *Self, item_path: []const Seg) EditError!struct { []const Seg, usize } {
    if (item_path.len == 0) return self.fail("not a list item");
    const i = switch (item_path[item_path.len - 1]) {
        .index => |i| i,
        .field => return self.fail("not a list item"),
    };
    const list_path = item_path[0 .. item_path.len - 1];
    const st = self.lookup(list_path) orelse return self.fail("no such value");
    if (st.ty.unwrap().kind != .slice) return self.fail("this list has a fixed length");
    return .{ list_path, i };
}

pub fn list_insert(self: *Self, list_path: []const Seg, index: usize, copy_of: ?usize) EditError!void {
    const st = self.lookup(list_path) orelse return self.fail("no such value");
    const ty = st.ty.unwrap();
    const elem = switch (ty.kind) {
        .slice => |c| c(),
        else => return self.fail("not a list"),
    };
    if (st.eff == null or st.eff.?.is_null()) {
        try self.set(list_path, ".{}", "");
    }
    const list = try self.materialize(list_path);
    if (list.kind != .container) return self.fail("not a list in the file");
    if (copy_of) |c| {
        const item = list.item(c) orelse return self.fail("no such item");
        const text = try self.gpa.dupe(u8, item.value.text(self.source));
        defer self.gpa.free(text);
        const base = try self.gpa.dupe(u8, doc.line_indent(self.source, item.value.start));
        defer self.gpa.free(base);
        return self.apply(try doc.insert_item(self.gpa, self.source, list, index, text, base));
    }
    const t = try schema.template(self.gpa, elem);
    defer self.gpa.free(t);
    return self.apply(try doc.insert_item(self.gpa, self.source, list, index, t, ""));
}

pub fn list_insert_text(self: *Self, list_path: []const Seg, index: usize, text: []const u8) EditError!void {
    const st = self.lookup(list_path) orelse return self.fail("no such value");
    if (st.eff == null or st.eff.?.is_null()) try self.set(list_path, ".{}", "");
    const list = try self.materialize(list_path);
    if (list.kind != .container) return self.fail("not a list in the file");
    return self.apply(try doc.insert_item(self.gpa, self.source, list, index, text, ""));
}

pub fn list_duplicate(self: *Self, item_path: []const Seg) EditError!void {
    const list_path, const i = try self.list_of(item_path);
    return self.list_insert(list_path, i + 1, i);
}

pub fn list_add_after(self: *Self, item_path: []const Seg) EditError!void {
    const list_path, const i = try self.list_of(item_path);
    return self.list_insert(list_path, i + 1, null);
}

pub fn list_delete(self: *Self, item_path: []const Seg) EditError!void {
    const list_path, const i = try self.list_of(item_path);
    const list = try self.materialize(list_path);
    if (i >= list.entries.len) return self.fail("no such item");
    return self.apply(try doc.remove_entry(self.gpa, self.source, list, i));
}

pub fn list_move(self: *Self, item_path: []const Seg, down: bool) EditError!void {
    const list_path, const i = try self.list_of(item_path);
    const list = try self.materialize(list_path);
    if (down and i + 1 >= list.entries.len) return self.fail("already the last");
    if (!down and i == 0) return self.fail("already the first");
    const j = if (down) i + 1 else i - 1;
    return self.apply(try doc.swap_values(self.gpa, self.source, list.entries[i].value, list.entries[j].value));
}

pub fn list_swap(self: *Self, list_path: []const Seg, i: usize, j: usize) EditError!void {
    const list = try self.materialize(list_path);
    if (i >= list.entries.len or j >= list.entries.len) return self.fail("no such item");
    return self.apply(try doc.swap_values(self.gpa, self.source, list.entries[i].value, list.entries[j].value));
}

// a new binding in a mode with these modifiers, after the last one like it;
// returns its index
pub fn add_binding(self: *Self, list_path: []const Seg, mode: []const u8, mods: u32) EditError!usize {
    const st = self.lookup(list_path) orelse return self.fail("no such value");
    const elem = switch (st.ty.unwrap().kind) {
        .slice => |c| c(),
        else => return self.fail("not a list"),
    };
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var index: usize = 0;
    if (st.eff) |list| if (list.node.kind == .container) {
        index = list.node.entries.len;
        var last: ?usize = null;
        for (list.node.entries, 0..) |entry, i| {
            const info = binding_info(a, list.child(entry.value).?);
            if (mem.eql(u8, info.mode, mode) and info.mods == mods) last = i;
        }
        if (last) |l| index = l + 1;
    };
    // the mode goes first, as in hand-written bindings
    const template = try schema.template(a, elem);
    const text = if (mem.eql(u8, mode, "default") or !mem.startsWith(u8, template, ".{ "))
        template
    else
        try std.fmt.allocPrint(a, ".{{ .mode = {s}, {s}", .{ try doc.encode_string(a, mode), template[3..] });
    try self.list_insert_text(list_path, index, text);

    const item = try mem.concat(a, Seg, &.{ list_path, &.{.{ .index = index }} });
    const field = struct {
        fn path(alloc: mem.Allocator, base: []const Seg, name: []const u8) ![]const Seg {
            return mem.concat(alloc, Seg, &.{ base, &.{.{ .field = name }} });
        }
    }.path;
    var mods_text: std.ArrayList(u8) = .empty;
    inline for (modifier_labels, 0..) |ml, bit| {
        if (mods & (1 << bit) != 0) {
            try mods_text.appendSlice(a, if (mods_text.items.len == 0) ".{ ." else ", .");
            try mods_text.appendSlice(a, ml[0] ++ " = true");
        }
    }
    try mods_text.appendSlice(a, if (mods_text.items.len == 0) ".{}" else " }");
    try self.set(try field(a, item, elem.field("modifiers").?.name), mods_text.items, "");
    // a key binding that does nothing yet, rather than the first action (quit)
    if (elem.field("event")) |ev| if (ev.type().field("click") != null) {
        try self.set(try field(a, item, ev.name), ".{ .click = .{} }", "");
    };
    return index;
}

// --- tests --------------------------------------------------------------------

const testing = std.testing;

const Test = struct {
    a: u32,
    nested: struct { x: bool, y: i32 },
    list: []const struct { k: []const u8, m: bool = false },
    opt: ?struct { p: u8 },
    u: union(enum) { none, some: struct { n: i32 } },
};

fn test_model(src: []const u8) !Self {
    const dflt =
        \\.{ .a = 1, .nested = .{ .x = true, .y = 2 }, .list = .{ .{ .k = "d" } }, .opt = null, .u = .none }
    ;
    return init(testing.allocator, schema.of(Test), src, dflt, ".{}");
}

test "set a missing nested field creates its parent" {
    var m = try test_model(".{\n    .a = 5,\n}\n");
    defer m.deinit();
    try m.set(&.{ .{ .field = "nested" }, .{ .field = "y" } }, "7", "");
    try testing.expectEqualStrings(".{\n    .a = 5,\n    .nested = .{ .y = 7 },\n}\n", m.source);
    const st = m.lookup(&.{ .{ .field = "nested" }, .{ .field = "x" } }).?;
    try testing.expectEqual(Origin.default, st.eff.?.origin);
}

test "editing an inherited list copies it" {
    var m = try test_model(".{\n    .a = 5,\n}\n");
    defer m.deinit();
    try m.set(&.{ .{ .field = "list" }, .{ .index = 0 }, .{ .field = "m" } }, "true", "");
    try testing.expectEqualStrings(".{\n    .a = 5,\n    .list = .{ .{ .k = \"d\", .m = true } },\n}\n", m.source);
}

test "reset removes the field" {
    var m = try test_model(".{\n    .a = 5,\n    .nested = .{ .y = 7 },\n}\n");
    defer m.deinit();
    try m.reset(&.{.{ .field = "a" }});
    try testing.expectEqualStrings(".{\n    .nested = .{ .y = 7 },\n}\n", m.source);
}

test "union tags and lists" {
    var m = try test_model(".{\n    .a = 5,\n}\n");
    defer m.deinit();
    const ty = schema.of(Test).field("u").?.type();
    try m.set_tag(&.{.{ .field = "u" }}, ty.field("some").?);
    try testing.expect(mem.indexOf(u8, m.source, ".u = .{ .some = .{ .n = 0 } }") != null);
    try m.set(&.{ .{ .field = "u" }, .{ .field = "some" }, .{ .field = "n" } }, "3", "");
    try testing.expect(mem.indexOf(u8, m.source, ".u = .{ .some = .{ .n = 3 } }") != null);

    try m.list_duplicate(&.{ .{ .field = "list" }, .{ .index = 0 } });
    try testing.expect(mem.indexOf(u8, m.source, ".list = .{ .{ .k = \"d\" }, .{ .k = \"d\" } }") != null);
    try m.list_delete(&.{ .{ .field = "list" }, .{ .index = 1 } });
    try testing.expect(mem.indexOf(u8, m.source, ".list = .{ .{ .k = \"d\" } }") != null);

    try m.set_null(&.{.{ .field = "opt" }}, false);
    try testing.expect(mem.indexOf(u8, m.source, ".opt = .{ .p = 0 }") != null);
}

test "rows" {
    var m = try test_model(".{\n    .a = 5,\n}\n");
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const expanded: std.StringHashMapUnmanaged(void) = .empty;
    const rs = try m.rows(arena.allocator(), &expanded, true);
    var keys: std.ArrayList(u8) = .empty;
    for (rs) |r| {
        try keys.appendSlice(arena.allocator(), r.key);
        try keys.append(arena.allocator(), ' ');
    }
    try testing.expectEqualStrings("a nested nested.x nested.y list list.0 list.0.k list.0.m opt u ", keys.items);
}

test "binding groups" {
    const B = struct {
        bindings: []const struct {
            mode: ?[]const u8 = null,
            keysym: []const u8,
            modifiers: struct { shift: bool = false, ctrl: bool = false, mod1: bool = false, mod4: bool = false },
            event: union(enum) { repeat: enum { quit, close }, click: struct { pressed: ?enum { quit, close } = null } },
        },
    };
    const src =
        \\.{
        \\    .bindings = .{
        \\        .{ .keysym = "a", .modifiers = .{ .mod1 = true }, .event = .{ .click = .{ .pressed = .close } } },
        \\        .{ .keysym = "b", .modifiers = .{ .mod4 = true, .shift = true }, .event = .{ .repeat = .quit } },
        \\        .{ .keysym = "c", .modifiers = .{ .mod4 = true }, .event = .{ .click = .{} } },
        \\        .{ .mode = "float", .keysym = "d", .modifiers = .{}, .event = .{ .click = .{} } },
        \\    },
        \\}
    ;
    var m = try init(testing.allocator, schema.of(B), src, ".{ .bindings = .{} }", ".{}");
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const expanded: std.StringHashMapUnmanaged(void) = .empty;
    const rs = try m.rows(arena.allocator(), &expanded, true);
    var labels: std.ArrayList(u8) = .empty;
    for (rs) |r| {
        if (r.group == null and !r.binding) continue;
        try labels.appendSlice(arena.allocator(), r.label);
        try labels.append(arena.allocator(), '|');
    }
    try testing.expectEqualStrings("default|Super|c|Super+Shift|b|Alt|a|float|no modifier|d|", labels.items);

    const i = try m.add_binding(&.{.{ .field = "bindings" }}, "float", 1 << 0 | 1 << 3);
    try testing.expectEqual(@as(usize, 4), i);
    try testing.expect(mem.indexOf(u8, m.source, ".{ .mode = \"float\", .keysym = \"\", .modifiers = .{ .mod4 = true, .shift = true }, .event = .{ .click = .{} } }") != null);
}
