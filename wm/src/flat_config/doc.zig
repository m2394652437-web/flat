// A ZON document that remembers where every value sits in the source text,
// so a single value can be replaced without touching comments or layout.

const std = @import("std");
const mem = std.mem;

pub const Kind = enum {
    container, // .{ ... }
    enum_literal, // .name
    string, // "..." or \\ lines
    number,
    char,
    identifier, // true, false, null, inf, nan
};

pub const Node = struct {
    kind: Kind,
    // value span in the source
    start: u32,
    end: u32,
    // container only
    entries: []Entry = &.{},
    named: bool = false,

    pub fn text(self: *const Node, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    pub fn field(self: *const Node, name: []const u8) ?*Entry {
        if (self.kind != .container or !self.named) return null;
        for (self.entries) |*entry| {
            if (mem.eql(u8, entry.name.?, name)) return entry;
        }
        return null;
    }

    pub fn item(self: *const Node, index: usize) ?*Entry {
        if (self.kind != .container or self.named) return null;
        if (index >= self.entries.len) return null;
        return &self.entries[index];
    }

    // `.name` without the dot, unquoted
    pub fn enum_name(self: *const Node, source: []const u8) []const u8 {
        const raw = source[self.start + 1 .. self.end];
        if (raw.len >= 3 and raw[0] == '@') return raw[2 .. raw.len - 1];
        return raw;
    }

    pub fn is_null(self: *const Node, source: []const u8) bool {
        return self.kind == .identifier and mem.eql(u8, self.text(source), "null");
    }
};

pub const Entry = struct {
    name: ?[]const u8,
    // from the first character of the entry to after its trailing comma
    start: u32,
    end: u32,
    value: *Node,
    // a `,` follows the value
    comma: bool,
};

pub const Error = error{ SyntaxError, OutOfMemory };

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    root: *Node,
    // where parsing failed
    error_offset: u32 = 0,

    pub fn deinit(self: *Doc) void {
        self.arena.deinit();
    }
};

pub fn parse(gpa: mem.Allocator, source: []const u8) Error!Doc {
    var doc: Doc = .{
        .arena = .init(gpa),
        .source = source,
        .root = undefined,
    };
    errdefer doc.arena.deinit();
    var p: Parser = .{ .src = source, .arena = doc.arena.allocator() };
    doc.root = p.value() catch |err| {
        doc.error_offset = p.pos;
        return err;
    };
    p.skip_trivia();
    if (p.pos != source.len) return error.SyntaxError;
    return doc;
}

// position of a syntax error, for messages
pub fn error_position(gpa: mem.Allocator, source: []const u8) u32 {
    var p: Parser = .{ .src = source, .arena = gpa };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    p.arena = arena.allocator();
    _ = p.value() catch return p.pos;
    p.skip_trivia();
    return p.pos;
}

const Parser = struct {
    src: []const u8,
    pos: u32 = 0,
    arena: mem.Allocator,

    fn peek(self: *const Parser, offset: u32) u8 {
        const i = self.pos + offset;
        return if (i < self.src.len) self.src[i] else 0;
    }

    fn skip_trivia(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '/' and self.peek(1) == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    fn value(self: *Parser) Error!*Node {
        self.skip_trivia();
        const start = self.pos;
        const node = try self.arena.create(Node);
        const c = self.peek(0);
        if (c == '.' and self.peek(1) == '{') {
            self.pos += 2;
            try self.container(node);
            node.start = start;
            node.end = self.pos;
            return node;
        }
        node.* = .{ .kind = undefined, .start = start, .end = undefined };
        if (c == '.') {
            self.pos += 1;
            try self.identifier();
            node.kind = .enum_literal;
        } else if (c == '"') {
            try self.string();
            node.kind = .string;
        } else if (c == '\\' and self.peek(1) == '\\') {
            self.multiline_string();
            node.kind = .string;
        } else if (c == '\'') {
            self.pos += 1;
            while (self.pos < self.src.len and self.src[self.pos] != '\'') {
                if (self.src[self.pos] == '\\') self.pos += 1;
                self.pos += 1;
            }
            if (self.pos >= self.src.len) return error.SyntaxError;
            self.pos += 1;
            node.kind = .char;
        } else if (std.ascii.isDigit(c) or (c == '-' and (std.ascii.isDigit(self.peek(1)) or self.peek(1) == 'i'))) {
            if (c == '-') self.pos += 1;
            if (self.peek(0) == 'i') {
                try self.identifier();
            } else {
                self.number();
            }
            node.kind = .number;
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            try self.identifier();
            node.kind = .identifier;
        } else {
            return error.SyntaxError;
        }
        node.end = self.pos;
        return node;
    }

    fn container(self: *Parser, node: *Node) Error!void {
        var entries: std.ArrayList(Entry) = .empty;
        var named: ?bool = null;
        while (true) {
            self.skip_trivia();
            if (self.peek(0) == '}') {
                self.pos += 1;
                break;
            }
            if (self.pos >= self.src.len) return error.SyntaxError;
            const entry_start = self.pos;

            var name: ?[]const u8 = null;
            if (self.peek(0) == '.' and self.peek(1) != '{') {
                // `.name =` or an enum literal item
                const save = self.pos;
                self.pos += 1;
                const name_start = self.pos;
                try self.identifier();
                const raw = self.src[name_start..self.pos];
                self.skip_trivia();
                if (self.peek(0) == '=' and self.peek(1) != '=') {
                    self.pos += 1;
                    name = if (raw.len >= 3 and raw[0] == '@') raw[2 .. raw.len - 1] else raw;
                } else {
                    self.pos = save;
                }
            }
            const is_named = name != null;
            if (named) |n| {
                if (n != is_named) return error.SyntaxError;
            } else named = is_named;

            const v = try self.value();
            self.skip_trivia_inline();
            var comma = false;
            if (self.peek(0) == ',') {
                self.pos += 1;
                comma = true;
            }
            try entries.append(self.arena, .{
                .name = name,
                .start = entry_start,
                .end = if (comma) self.pos else v.end,
                .value = v,
                .comma = comma,
            });
            if (!comma) {
                self.skip_trivia();
                if (self.peek(0) != '}') return error.SyntaxError;
            }
        }
        node.* = .{
            .kind = .container,
            .start = undefined,
            .end = undefined,
            .entries = entries.items,
            .named = named orelse false,
        };
    }

    // whitespace and comments, but the comma is looked for right after them
    fn skip_trivia_inline(self: *Parser) void {
        self.skip_trivia();
    }

    fn identifier(self: *Parser) Error!void {
        if (self.peek(0) == '@' and self.peek(1) == '"') {
            self.pos += 1;
            try self.string();
            return;
        }
        const start = self.pos;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) {
            self.pos += 1;
        }
        if (self.pos == start) return error.SyntaxError;
    }

    fn string(self: *Parser) Error!void {
        self.pos += 1;
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '"' => {
                    self.pos += 1;
                    return;
                },
                '\\' => self.pos += 2,
                '\n' => return error.SyntaxError,
                else => self.pos += 1,
            }
        }
        return error.SyntaxError;
    }

    fn multiline_string(self: *Parser) void {
        while (true) {
            while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            // the next line continues the string when it starts with `\\`
            var i = self.pos;
            while (i < self.src.len and (self.src[i] == ' ' or self.src[i] == '\t' or self.src[i] == '\n' or self.src[i] == '\r')) i += 1;
            if (i + 1 < self.src.len and self.src[i] == '\\' and self.src[i + 1] == '\\') {
                self.pos = i;
            } else return;
        }
    }

    fn number(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
                self.pos += 1;
            } else if ((c == '+' or c == '-') and self.pos > 0 and
                (self.src[self.pos - 1] == 'e' or self.src[self.pos - 1] == 'E' or
                    self.src[self.pos - 1] == 'p' or self.src[self.pos - 1] == 'P'))
            {
                self.pos += 1;
            } else break;
        }
    }
};

// decode a string node; `\\` lines are joined with newlines
pub fn decode_string(gpa: mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (raw.len >= 2 and raw[0] == '\\' and raw[1] == '\\') {
        var lines = mem.splitScalar(u8, raw, '\n');
        var first = true;
        while (lines.next()) |line| {
            const trimmed = mem.trimStart(u8, line, " \t");
            if (!mem.startsWith(u8, trimmed, "\\\\")) continue;
            if (!first) try out.append(gpa, '\n');
            first = false;
            try out.appendSlice(gpa, mem.trimEnd(u8, trimmed[2..], "\r"));
        }
        return out.toOwnedSlice(gpa);
    }
    const parsed = std.zig.string_literal.parseAlloc(gpa, raw) catch {
        try out.appendSlice(gpa, raw);
        return out.toOwnedSlice(gpa);
    };
    out.deinit(gpa);
    return parsed;
}

pub fn encode_string(gpa: mem.Allocator, bytes: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "\"{f}\"", .{std.zig.fmtString(bytes)});
}

pub fn encode_enum(gpa: mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".{f}", .{std.zig.fmtIdPU(name)});
}

// --- text editing -----------------------------------------------------------
//
// Every edit returns a new source; the caller parses it again.

pub fn replace(gpa: mem.Allocator, source: []const u8, start: usize, end: usize, new: []const u8) ![]u8 {
    return mem.concat(gpa, u8, &.{ source[0..start], new, source[end..] });
}

fn line_start(source: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

// leading whitespace of the line holding `pos`
pub fn line_indent(source: []const u8, pos: usize) []const u8 {
    const ls = line_start(source, pos);
    var i = ls;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    return source[ls..i];
}

// only spaces/tabs between the start of the line and `pos`
pub fn starts_line(source: []const u8, pos: usize) bool {
    var i = pos;
    while (i > 0) {
        i -= 1;
        switch (source[i]) {
            '\n' => return true,
            ' ', '\t' => {},
            else => return false,
        }
    }
    return true;
}

// end of the line after `pos` if only whitespace or a comment follows, else null
fn rest_of_line_empty(source: []const u8, pos: usize) ?usize {
    var i = pos;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            ' ', '\t', '\r' => {},
            '\n' => return i,
            '/' => if (i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                return i;
            } else return null,
            else => return null,
        }
    }
    return source.len;
}

fn spans_lines(source: []const u8, node: *const Node) bool {
    return mem.indexOfScalar(u8, source[node.start..node.end], '\n') != null;
}

// move the continuation lines of `text` from one base indent to another
pub fn reindent(gpa: mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try out.append(gpa, '\n');
            if (mem.startsWith(u8, line, from)) {
                try out.appendSlice(gpa, to);
                try out.appendSlice(gpa, line[from.len..]);
            } else {
                try out.appendSlice(gpa, line);
            }
        } else try out.appendSlice(gpa, line);
        first = false;
    }
    return out.toOwnedSlice(gpa);
}

fn child_indent(gpa: mem.Allocator, source: []const u8, container: *const Node) ![]u8 {
    if (container.entries.len > 0 and starts_line(source, container.entries[0].start)) {
        return gpa.dupe(u8, line_indent(source, container.entries[0].start));
    }
    return mem.concat(gpa, u8, &.{ line_indent(source, container.start), "    " });
}

// `body` is `.name = value` or `value`; `value_text` must use `base` as the indent
// of its continuation lines, it is moved to the indent of the new entry.
fn insert_entry(
    gpa: mem.Allocator,
    source: []const u8,
    container: *const Node,
    index: usize,
    prefix: []const u8,
    value_text: []const u8,
    base: []const u8,
) ![]u8 {
    std.debug.assert(container.kind == .container);
    const entries = container.entries;
    const close = container.end - 1; // the `}`
    const multiline = spans_lines(source, container) or mem.indexOfScalar(u8, value_text, '\n') != null;

    if (!multiline) {
        // .{ a, b } style
        const body = try mem.concat(gpa, u8, &.{ prefix, value_text });
        defer gpa.free(body);
        if (entries.len == 0) {
            return mem.concat(gpa, u8, &.{ source[0..container.start], ".{ ", body, " }", source[container.end..] });
        }
        if (index >= entries.len) {
            const last = entries[entries.len - 1];
            const sep: []const u8 = if (last.comma) " " else ", ";
            return mem.concat(gpa, u8, &.{ source[0..last.end], sep, body, if (last.comma) "," else "", source[last.end..] });
        }
        const at = entries[index].start;
        return mem.concat(gpa, u8, &.{ source[0..at], body, ", ", source[at..] });
    }

    const indent = try child_indent(gpa, source, container);
    defer gpa.free(indent);
    const moved = try reindent(gpa, value_text, base, indent);
    defer gpa.free(moved);
    const line = try mem.concat(gpa, u8, &.{ indent, prefix, moved, "," });
    defer gpa.free(line);

    if (entries.len == 0 or !starts_line(source, entries[0].start)) {
        if (entries.len == 0) {
            // .{} -> multi-line block
            const outer = line_indent(source, container.start);
            if (spans_lines(source, container)) {
                // keep whatever comments sit inside, append before `}`
                const ls = line_start(source, close);
                if (starts_line(source, close)) {
                    return mem.concat(gpa, u8, &.{ source[0..ls], line, "\n", source[ls..] });
                }
                return mem.concat(gpa, u8, &.{ source[0..close], "\n", line, "\n", outer, source[close..] });
            }
            return mem.concat(gpa, u8, &.{ source[0..container.start], ".{\n", line, "\n", outer, "}", source[container.end..] });
        }
        // entries on the same line as `.{`: append after the last one
        const last = entries[entries.len - 1];
        const fix: []const u8 = if (last.comma) "" else ",";
        return mem.concat(gpa, u8, &.{ source[0..last.end], fix, "\n", line, source[last.end..] });
    }

    if (index >= entries.len) {
        const last = entries[entries.len - 1];
        const fix: []const u8 = if (last.comma) "" else ",";
        // after the last entry and any comment on its line
        const eol = rest_of_line_empty(source, last.end) orelse last.end;
        return mem.concat(gpa, u8, &.{ source[0..last.end], fix, source[last.end..eol], "\n", line, source[eol..] });
    }
    const ls = line_start(source, entries[index].start);
    return mem.concat(gpa, u8, &.{ source[0..ls], line, "\n", source[ls..] });
}

pub fn insert_field(
    gpa: mem.Allocator,
    source: []const u8,
    container: *const Node,
    name: []const u8,
    value_text: []const u8,
    base: []const u8,
) ![]u8 {
    const prefix = try std.fmt.allocPrint(gpa, ".{f} = ", .{std.zig.fmtIdPU(name)});
    defer gpa.free(prefix);
    return insert_entry(gpa, source, container, container.entries.len, prefix, value_text, base);
}

pub fn insert_item(
    gpa: mem.Allocator,
    source: []const u8,
    container: *const Node,
    index: usize,
    value_text: []const u8,
    base: []const u8,
) ![]u8 {
    return insert_entry(gpa, source, container, index, "", value_text, base);
}

pub fn remove_entry(gpa: mem.Allocator, source: []const u8, container: *const Node, index: usize) ![]u8 {
    const entry = container.entries[index];
    if (starts_line(source, entry.start)) {
        if (rest_of_line_empty(source, entry.end)) |eol| {
            const from = line_start(source, entry.start);
            const to = if (eol < source.len) eol + 1 else eol;
            return mem.concat(gpa, u8, &.{ source[0..from], source[to..] });
        }
    }
    if (container.entries.len == 1) {
        return mem.concat(gpa, u8, &.{ source[0..container.start], ".{}", source[container.end..] });
    }
    // inline: drop the entry and the space after it
    var to: usize = entry.end;
    while (to < source.len and source[to] == ' ') to += 1;
    if (index == container.entries.len - 1 and !entry.comma) {
        // `a, b` -> `a`: drop the comma before
        const prev = container.entries[index - 1];
        return mem.concat(gpa, u8, &.{ source[0..prev.value.end], source[entry.end..] });
    }
    return mem.concat(gpa, u8, &.{ source[0..entry.start], source[to..] });
}

// swap two values, leaving commas and comments where they are
pub fn swap_values(gpa: mem.Allocator, source: []const u8, a: *const Node, b: *const Node) ![]u8 {
    const first, const second = if (a.start < b.start) .{ a, b } else .{ b, a };
    const ta = source[first.start..first.end];
    const tb = source[second.start..second.end];
    const ia = line_indent(source, first.start);
    const ib = line_indent(source, second.start);
    const ta2 = try reindent(gpa, ta, ia, ib);
    defer gpa.free(ta2);
    const tb2 = try reindent(gpa, tb, ib, ia);
    defer gpa.free(tb2);
    return mem.concat(gpa, u8, &.{
        source[0..first.start], tb2,
        source[first.end..second.start], ta2,
        source[second.end..],
    });
}

// `//` lines right above `pos`
pub fn comment_above(gpa: mem.Allocator, source: []const u8, pos: usize) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var ls = line_start(source, pos);
    while (ls > 0) {
        const prev_end = ls - 1;
        const prev_start = line_start(source, prev_end);
        const line = mem.trim(u8, source[prev_start..prev_end], " \t\r");
        if (!mem.startsWith(u8, line, "//")) break;
        try lines.append(gpa, mem.trim(u8, line[2..], " "));
        ls = prev_start;
    }
    mem.reverse([]const u8, lines.items);
    return mem.join(gpa, "\n", lines.items);
}

// one line of text for a value: comments dropped, whitespace collapsed
pub fn compact(gpa: mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var space = false;
    var in_string = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            try out.append(gpa, c);
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                try out.append(gpa, text[i]);
            } else if (c == '"') in_string = false;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            space = true;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            space = true;
            continue;
        }
        if (space and out.items.len > 0) {
            const last = out.items[out.items.len - 1];
            // `.{ x` stays tight on the left of `}` only when empty
            if (!(last == '{' and c == '}')) try out.append(gpa, ' ');
        }
        space = false;
        if (c == '"') in_string = true;
        try out.append(gpa, c);
    }
    // ", }" -> " }"
    var result = try out.toOwnedSlice(gpa);
    var w: usize = 0;
    var r: usize = 0;
    while (r < result.len) : (r += 1) {
        if (result[r] == ',' and r + 2 < result.len and result[r + 1] == ' ' and result[r + 2] == '}') continue;
        result[w] = result[r];
        w += 1;
    }
    return gpa.realloc(result, w);
}

// --- tests --------------------------------------------------------------------

const testing = std.testing;

test "parse and locate" {
    const src =
        \\.{
        \\    .a = 1, // one
        \\    .b = .{ .c = "x", .d = .tag },
        \\    .e = -0.5,
        \\    .f = .{ "p", "q" },
        \\    .g = .{},
        \\}
    ;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    const root = doc.root;
    try testing.expect(root.named);
    try testing.expectEqualStrings("1", root.field("a").?.value.text(src));
    try testing.expectEqualStrings(".tag", root.field("b").?.value.field("d").?.value.text(src));
    try testing.expectEqual(Kind.number, root.field("e").?.value.kind);
    try testing.expectEqualStrings("\"q\"", root.field("f").?.value.item(1).?.value.text(src));
}

test "insert field keeps trailing comment" {
    const gpa = testing.allocator;
    const src =
        \\.{
        \\    .a = 1, // one
        \\}
    ;
    var doc = try parse(gpa, src);
    defer doc.deinit();
    const out = try insert_field(gpa, src, doc.root, "b", "2", "");
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\.{
        \\    .a = 1, // one
        \\    .b = 2,
        \\}
    , out);
}

test "insert into inline and empty" {
    const gpa = testing.allocator;
    const src = ".{ .x = .{}, .y = .{ 1, 2 } }";
    var doc = try parse(gpa, src);
    defer doc.deinit();
    const a = try insert_field(gpa, src, doc.root.field("x").?.value, "k", "true", "");
    defer gpa.free(a);
    try testing.expectEqualStrings(".{ .x = .{ .k = true }, .y = .{ 1, 2 } }", a);
    const b = try insert_item(gpa, src, doc.root.field("y").?.value, 9, "3", "");
    defer gpa.free(b);
    try testing.expectEqualStrings(".{ .x = .{}, .y = .{ 1, 2, 3 } }", b);
}

test "insert multi-line value is reindented" {
    const gpa = testing.allocator;
    const src =
        \\.{
        \\    .list = .{
        \\        .{ .k = 1 },
        \\    },
        \\}
    ;
    var doc = try parse(gpa, src);
    defer doc.deinit();
    const list = doc.root.field("list").?.value;
    const out = try insert_item(gpa, src, list, 1, ".{\n    .k = 2,\n}", "");
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\.{
        \\    .list = .{
        \\        .{ .k = 1 },
        \\        .{
        \\            .k = 2,
        \\        },
        \\    },
        \\}
    , out);
}

test "remove entry" {
    const gpa = testing.allocator;
    const src =
        \\.{
        \\    .a = 1,
        \\    .b = .{ 1, 2, 3 },
        \\}
    ;
    var doc = try parse(gpa, src);
    defer doc.deinit();
    const out = try remove_entry(gpa, src, doc.root, 0);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\.{
        \\    .b = .{ 1, 2, 3 },
        \\}
    , out);
    const b = doc.root.field("b").?.value;
    const out2 = try remove_entry(gpa, src, b, 2);
    defer gpa.free(out2);
    try testing.expect(mem.indexOf(u8, out2, ".{ 1, 2 }") != null);
    const out3 = try remove_entry(gpa, src, b, 0);
    defer gpa.free(out3);
    try testing.expect(mem.indexOf(u8, out3, ".{ 2, 3 }") != null);
}

test "compact" {
    const gpa = testing.allocator;
    const out = try compact(gpa, ".{\n    .a = \"x  y\", // c\n    .b = 2,\n}");
    defer gpa.free(out);
    try testing.expectEqualStrings(".{ .a = \"x  y\", .b = 2 }", out);
}

test "default config parses" {
    // the shipped default must be readable by this parser
    const src = @import("config_def").text;
    var doc = try parse(testing.allocator, src);
    defer doc.deinit();
    try testing.expect(doc.root.field("bindings") != null);
}
