// A runtime description of the `Config` type, built at compile time.
//
// Child types are reached through functions, so recursive types such as
// `Action.group` need no special care.

const std = @import("std");
const mem = std.mem;
const Writer = std.Io.Writer;

pub const TypeFn = *const fn () *const Type;

pub const Field = struct {
    name: []const u8,
    type: TypeFn,
    // the field's default value, of the field's type
    default: ?*const anyopaque,
    // e.g. the `getter` of `meta.enum_struct`
    hidden: bool,
};

pub const Kind = union(enum) {
    void,
    bool,
    int: struct { signed: bool, bits: u16 },
    float,
    string,
    @"enum": []const []const u8,
    @"struct": []const Field,
    tuple: []const TypeFn,
    @"union": []const Field,
    optional: TypeFn,
    slice: TypeFn,
    array: struct { len: usize, child: TypeFn },
};

pub const Type = struct {
    name: []const u8,
    kind: Kind,
    // write a value of this type as ZON
    serialize: *const fn (*const anyopaque, *Writer) Writer.Error!void,

    pub fn unwrap(self: *const Type) *const Type {
        return switch (self.kind) {
            .optional => |child| child(),
            else => self,
        };
    }

    pub fn field(self: *const Type, name: []const u8) ?*const Field {
        const fields = switch (self.kind) {
            .@"struct", .@"union" => |fields| fields,
            else => return null,
        };
        for (fields) |*f| {
            if (mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    pub fn is_container(self: *const Type) bool {
        return switch (self.kind) {
            .@"struct", .tuple, .slice, .array => true,
            else => false,
        };
    }
};

pub fn of(comptime T: type) *const Type {
    return Holder(T).get();
}

fn Holder(comptime T: type) type {
    return struct {
        const value: Type = make(T);
        fn get() *const Type {
            return &value;
        }
    };
}

fn serializer(comptime T: type) *const fn (*const anyopaque, *Writer) Writer.Error!void {
    return struct {
        fn f(ptr: *const anyopaque, w: *Writer) Writer.Error!void {
            const v: *const T = @ptrCast(@alignCast(ptr));
            try serialize(T, v.*, w, 0);
        }
    }.f;
}

// write a value as ZON, multi-line like hand-written config
pub fn serialize(comptime T: type, v: T, w: *Writer, depth: usize) Writer.Error!void {
    @setEvalBranchQuota(100_000);
    switch (@typeInfo(T)) {
        .void => try w.writeAll("{}"),
        .bool => try w.writeAll(if (v) "true" else "false"),
        .int => try w.print("{d}", .{v}),
        .float => {
            // keep a dot so the value reads as a float
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            try w.writeAll(text);
            if (mem.indexOfAny(u8, text, ".eni") == null) try w.writeAll(".0");
        },
        .@"enum" => if (std.enums.tagName(T, v)) |name|
            try w.print(".{f}", .{std.zig.fmtIdPU(name)})
        else
            try w.print("@enumFromInt({d})", .{@intFromEnum(v)}),
        .optional => if (v) |x| try serialize(@TypeOf(x), x, w, depth) else try w.writeAll("null"),
        .pointer => |info| {
            if (info.size != .slice) @compileError("unsupported pointer " ++ @typeName(T));
            if (info.child == u8) return w.print("\"{f}\"", .{std.zig.fmtString(v)});
            try write_list(info.child, v, w, depth);
        },
        .array => |info| try write_list(info.child, &v, w, depth),
        .@"struct" => |info| {
            if (info.is_tuple) {
                try w.writeAll(".{ ");
                inline for (info.fields, 0..) |f, i| {
                    if (i > 0) try w.writeAll(", ");
                    try serialize(f.type, @field(v, f.name), w, depth + 1);
                }
                return w.writeAll(" }");
            }
            var any = false;
            inline for (info.fields) |f| {
                const skip = @typeInfo(f.type) == .@"struct" and @typeInfo(f.type).@"struct".fields.len == 0;
                if (!skip) {
                    if (!any) try w.writeAll(".{\n");
                    any = true;
                    try w.splatByteAll(' ', (depth + 1) * 4);
                    try w.print(".{f} = ", .{std.zig.fmtIdPU(f.name)});
                    try serialize(f.type, @field(v, f.name), w, depth + 1);
                    try w.writeAll(",\n");
                }
            }
            if (!any) return w.writeAll(".{}");
            try w.splatByteAll(' ', depth * 4);
            try w.writeAll("}");
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("untagged union " ++ @typeName(T));
            switch (v) {
                inline else => |payload, tag| {
                    if (@TypeOf(payload) == void) {
                        try w.print(".{f}", .{std.zig.fmtIdPU(@tagName(tag))});
                    } else {
                        try w.print(".{{ .{f} = ", .{std.zig.fmtIdPU(@tagName(tag))});
                        try serialize(@TypeOf(payload), payload, w, depth);
                        try w.writeAll(" }");
                    }
                },
            }
        },
        else => @compileError("unsupported type " ++ @typeName(T)),
    }
}

fn is_scalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => true,
        .pointer => |info| info.size == .slice and info.child == u8,
        .optional => |info| is_scalar(info.child),
        else => false,
    };
}

fn write_list(comptime E: type, items: []const E, w: *Writer, depth: usize) Writer.Error!void {
    if (items.len == 0) return w.writeAll(".{}");
    if (comptime is_scalar(E)) {
        try w.writeAll(".{ ");
        for (items, 0..) |x, i| {
            if (i > 0) try w.writeAll(", ");
            try serialize(E, x, w, depth + 1);
        }
        return w.writeAll(" }");
    }
    try w.writeAll(".{\n");
    for (items) |x| {
        try w.splatByteAll(' ', (depth + 1) * 4);
        try serialize(E, x, w, depth + 1);
        try w.writeAll(",\n");
    }
    try w.splatByteAll(' ', depth * 4);
    try w.writeAll("}");
}

fn short_name(comptime T: type) []const u8 {
    const full = @typeName(T);
    // drop module paths: "config.rule.window" -> "window"
    var depth: usize = 0;
    var last: usize = 0;
    for (full, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -|= 1,
        '.' => if (depth == 0) {
            last = i + 1;
        },
        else => {},
    };
    return full[last..];
}

fn make(comptime T: type) Type {
    @setEvalBranchQuota(100_000);
    const kind: Kind = switch (@typeInfo(T)) {
        .void => .void,
        .bool => .bool,
        .int => |info| .{ .int = .{ .signed = info.signedness == .signed, .bits = info.bits } },
        .float => .float,
        .@"enum" => |info| blk: {
            var names: [info.fields.len][]const u8 = undefined;
            for (info.fields, 0..) |f, i| names[i] = f.name;
            const final = names;
            break :blk .{ .@"enum" = &final };
        },
        .optional => |info| .{ .optional = Holder(info.child).get },
        .pointer => |info| blk: {
            if (info.size != .slice) @compileError("unsupported pointer " ++ @typeName(T));
            if (info.child == u8) break :blk .string;
            break :blk .{ .slice = Holder(info.child).get };
        },
        .array => |info| .{ .array = .{ .len = info.len, .child = Holder(info.child).get } },
        .@"struct" => |info| blk: {
            if (info.is_tuple) {
                var types: [info.fields.len]TypeFn = undefined;
                for (info.fields, 0..) |f, i| types[i] = Holder(f.type).get;
                const final = types;
                break :blk .{ .tuple = &final };
            }
            var fields: [info.fields.len]Field = undefined;
            for (info.fields, 0..) |f, i| fields[i] = .{
                .name = f.name,
                .type = Holder(f.type).get,
                .default = f.default_value_ptr,
                .hidden = @typeInfo(f.type) == .@"struct" and @typeInfo(f.type).@"struct".fields.len == 0,
            };
            const final = fields;
            break :blk .{ .@"struct" = &final };
        },
        .@"union" => |info| blk: {
            if (info.tag_type == null) @compileError("untagged union " ++ @typeName(T));
            var fields: [info.fields.len]Field = undefined;
            for (info.fields, 0..) |f, i| fields[i] = .{
                .name = f.name,
                .type = Holder(f.type).get,
                .default = null,
                .hidden = false,
            };
            const final = fields;
            break :blk .{ .@"union" = &final };
        },
        else => @compileError("unsupported type " ++ @typeName(T)),
    };
    return .{ .name = short_name(T), .kind = kind, .serialize = serializer(T) };
}

// a minimal valid ZON value of the type, for new list items and union payloads
pub fn template(gpa: mem.Allocator, ty: *const Type) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try write_template(&out.writer, ty, 0);
    return out.toOwnedSlice();
}

fn write_template(w: *Writer, ty: *const Type, depth: usize) Writer.Error!void {
    if (depth > 16) return w.writeAll(".{}");
    switch (ty.kind) {
        .void => try w.writeAll("{}"),
        .bool => try w.writeAll("false"),
        .int => try w.writeAll("0"),
        .float => try w.writeAll("0.0"),
        .string => try w.writeAll("\"\""),
        .@"enum" => |names| try w.print(".{f}", .{std.zig.fmtIdPU(names[0])}),
        .optional => try w.writeAll("null"),
        .slice => try w.writeAll(".{}"),
        .array => |info| {
            try w.writeAll(".{ ");
            for (0..info.len) |i| {
                if (i > 0) try w.writeAll(", ");
                try write_template(w, info.child(), depth + 1);
            }
            try w.writeAll(" }");
        },
        .tuple => |types| {
            try w.writeAll(".{ ");
            for (types, 0..) |t, i| {
                if (i > 0) try w.writeAll(", ");
                try write_template(w, t(), depth + 1);
            }
            try w.writeAll(" }");
        },
        .@"struct" => |fields| {
            var any = false;
            for (fields) |f| {
                if (f.default != null or f.hidden) continue;
                try w.writeAll(if (any) ", " else ".{ ");
                any = true;
                try w.print(".{f} = ", .{std.zig.fmtIdPU(f.name)});
                try write_template(w, f.type(), depth + 1);
            }
            try w.writeAll(if (any) " }" else ".{}");
        },
        .@"union" => |fields| try write_union(w, &fields[0], depth),
    }
}

pub fn union_template(gpa: mem.Allocator, f: *const Field) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try write_union(&out.writer, f, 0);
    return out.toOwnedSlice();
}

fn write_union(w: *Writer, f: *const Field, depth: usize) Writer.Error!void {
    if (f.type().kind == .void) {
        try w.print(".{f}", .{std.zig.fmtIdPU(f.name)});
    } else {
        try w.print(".{{ .{f} = ", .{std.zig.fmtIdPU(f.name)});
        try write_template(w, f.type(), depth + 1);
        try w.writeAll(" }");
    }
}

pub fn default_text(gpa: mem.Allocator, f: *const Field) !?[]u8 {
    const ptr = f.default orelse return null;
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try f.type().serialize(ptr, &out.writer);
    return try out.toOwnedSlice();
}

pub fn describe(gpa: mem.Allocator, ty: *const Type) ![]u8 {
    return switch (ty.kind) {
        .void => gpa.dupe(u8, "void"),
        .bool => gpa.dupe(u8, "bool"),
        .int => |i| std.fmt.allocPrint(gpa, "{c}{d}", .{ @as(u8, if (i.signed) 'i' else 'u'), i.bits }),
        .float => gpa.dupe(u8, "float"),
        .string => gpa.dupe(u8, "string"),
        .@"enum" => |names| blk: {
            const list = try mem.join(gpa, " | ", names);
            defer gpa.free(list);
            break :blk std.fmt.allocPrint(gpa, "enum: {s}", .{list});
        },
        .@"struct" => |fields| if (mem.indexOf(u8, ty.name, "__struct_") != null)
            std.fmt.allocPrint(gpa, "group of {d}", .{fields.len})
        else
            std.fmt.allocPrint(gpa, "{s}", .{ty.name}),
        .tuple => gpa.dupe(u8, "tuple"),
        .@"union" => |fields| blk: {
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(gpa);
            for (fields) |f| try names.append(gpa, f.name);
            const list = try mem.join(gpa, " | ", names.items);
            defer gpa.free(list);
            break :blk std.fmt.allocPrint(gpa, "one of: {s}", .{list});
        },
        .optional => |child| blk: {
            const inner = try describe(gpa, child());
            defer gpa.free(inner);
            break :blk std.fmt.allocPrint(gpa, "optional {s}", .{inner});
        },
        .slice => |child| blk: {
            const inner = try describe(gpa, child());
            defer gpa.free(inner);
            break :blk std.fmt.allocPrint(gpa, "list of {s}", .{inner});
        },
        .array => |a| std.fmt.allocPrint(gpa, "array[{d}]", .{a.len}),
    };
}

test "templates" {
    const gpa = std.testing.allocator;
    const S = struct {
        a: u32,
        b: bool = true,
        c: union(enum) { x, y: struct { n: i32 } },
        d: []const []const u8,
        e: ?f32,
    };
    const t = try template(gpa, of(S));
    defer gpa.free(t);
    try std.testing.expectEqualStrings(".{ .a = 0, .c = .x, .d = .{}, .e = null }", t);
    const u = try union_template(gpa, &of(S).field("c").?.type().kind.@"union"[1]);
    defer gpa.free(u);
    try std.testing.expectEqualStrings(".{ .y = .{ .n = 0 } }", u);
    const d = (try default_text(gpa, of(S).field("b").?)).?;
    defer gpa.free(d);
    try std.testing.expectEqualStrings("true", d);
}
