// flat-config: a TUI for flat-wm's config.zon
//
// Saving checks the file with flat-wm's own parser, keeps a .bak of the
// original, and sends SIGUSR1 to the running flat-wm so it reloads.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const process = std.process;

const flags = @import("flags");
const config = @import("config");

const doc = @import("doc.zig");
const schema = @import("schema.zig");
const Model = @import("model.zig");
const Term = @import("term.zig");
const App = @import("app.zig");

const usage =
    \\usage: flat-config [options]
    \\  -h,-help        Print this help message and exit.
    \\  -c,-config      Edit this file instead of ~/.config/flat-wm/config.zon.
    \\  -no-reload      Do not tell the running flat-wm to reload after saving.
    \\  -sibling-bg COLOR
    \\                  Background of the rows on the cursor's level
    \\                  (default 236, or $FLAT_CONFIG_SIBLING_BG).
    \\  -child-bg COLOR Background of the rows under the cursor
    \\                  (default 234, or $FLAT_CONFIG_CHILD_BG).
    \\
    \\COLOR is a 256-color index (0-255), #rrggbb, or none.
    \\
;

pub const std_options: std.Options = .{ .logFn = log };

// while the TUI runs, log lines (e.g. from the config parser) are kept for messages
var log_buffer: ?*std.ArrayList(u8) = null;
var log_gpa: mem.Allocator = undefined;

fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (log_buffer) |buf| {
        if (@intFromEnum(level) > @intFromEnum(std.log.Level.warn)) return;
        if (buf.items.len > 0) buf.appendSlice(log_gpa, "; ") catch {};
        buf.print(log_gpa, format, args) catch {};
        return;
    }
    std.log.defaultLog(level, scope, format, args);
}

const Context = struct {
    gpa: mem.Allocator,
    io: Io,
    path: []const u8,
    reload: bool,
    backed_up: bool = false,
    original: []const u8,

    fn check_path(self: *Context) ![]u8 {
        return mem.concat(self.gpa, u8, &.{ self.path, ".flat-config-check" });
    }

    fn validate(ptr: *anyopaque, text: []const u8, msg: *std.ArrayList(u8)) bool {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const tmp = self.check_path() catch return false;
        defer self.gpa.free(tmp);
        const cwd = Io.Dir.cwd();
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = text }) catch |err| {
            msg.print(self.gpa, "cannot write {s}: {s}", .{ tmp, @errorName(err) }) catch {};
            return false;
        };
        defer cwd.deleteFile(self.io, tmp) catch {};

        log_buffer = msg;
        defer log_buffer = null;
        const cfg = config.load(.{ .gpa = self.gpa, .io = self.io }, tmp) catch |err| {
            if (msg.items.len == 0) msg.print(self.gpa, "{s}", .{@errorName(err)}) catch {};
            // the check file's name means nothing to the user
            if (mem.indexOf(u8, msg.items, tmp)) |_| {
                const fixed = mem.replaceOwned(u8, self.gpa, msg.items, tmp, self.path) catch return false;
                msg.clearRetainingCapacity();
                msg.appendSlice(self.gpa, fixed) catch {};
                self.gpa.free(fixed);
            }
            return false;
        };
        config.free(self.gpa, cfg);
        msg.clearRetainingCapacity();
        return true;
    }

    fn save(ptr: *anyopaque, text: []const u8, msg: *std.ArrayList(u8)) bool {
        const self: *Context = @ptrCast(@alignCast(ptr));
        const cwd = Io.Dir.cwd();
        if (!self.backed_up) {
            const bak = mem.concat(self.gpa, u8, &.{ self.path, ".bak" }) catch return false;
            defer self.gpa.free(bak);
            cwd.writeFile(self.io, .{ .sub_path = bak, .data = self.original }) catch |err| {
                msg.print(self.gpa, "cannot write {s}: {s}", .{ bak, @errorName(err) }) catch {};
                return false;
            };
            self.backed_up = true;
        }
        // write next to the file, then rename over it
        const tmp = mem.concat(self.gpa, u8, &.{ self.path, ".flat-config-new" }) catch return false;
        defer self.gpa.free(tmp);
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = text }) catch |err| {
            msg.print(self.gpa, "cannot write {s}: {s}", .{ tmp, @errorName(err) }) catch {};
            return false;
        };
        cwd.rename(tmp, cwd, self.path, self.io) catch |err| {
            msg.print(self.gpa, "cannot replace {s}: {s}", .{ self.path, @errorName(err) }) catch {};
            cwd.deleteFile(self.io, tmp) catch {};
            return false;
        };

        msg.appendSlice(self.gpa, "saved") catch {};
        if (self.reload) {
            const r = signal_flat_wm(self.io);
            if (r.sent > 0) {
                msg.appendSlice(self.gpa, ", flat-wm reloaded") catch {};
            } else if (r.old > 0) {
                msg.appendSlice(self.gpa, "; the running flat-wm is too old for automatic reload, press Mod4-Shift-r") catch {};
            } else {
                msg.appendSlice(self.gpa, "; flat-wm is not running") catch {};
            }
        }
        return true;
    }
};

// SIGUSR1 kills a process that does not handle it, so only flat-wm builds that
// block it (they read it from a signalfd) are signalled.
fn signal_flat_wm(io: Io) struct { sent: usize, old: usize } {
    var sent: usize = 0;
    var old: usize = 0;
    var proc = Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return .{ .sent = 0, .old = 0 };
    defer proc.close(io);
    const uid = std.os.linux.getuid();
    var it = proc.iterate();
    while (it.next(io) catch null) |entry| {
        const pid = std.fmt.parseInt(posix.pid_t, entry.name, 10) catch continue;
        var comm_buf: [64]u8 = undefined;
        const comm = read_proc(pid, "comm", &comm_buf) orelse continue;
        if (!mem.eql(u8, mem.trimEnd(u8, comm, "\n"), "flat-wm")) continue;

        var status_buf: [8192]u8 = undefined;
        const status = read_proc(pid, "status", &status_buf) orelse continue;
        const proc_uid = status_field(status, "Uid:") orelse continue;
        var uids = mem.tokenizeAny(u8, proc_uid, " \t");
        const real = std.fmt.parseInt(u32, uids.next() orelse continue, 10) catch continue;
        if (real != uid) continue;
        const blocked = std.fmt.parseInt(u64, status_field(status, "SigBlk:") orelse continue, 16) catch continue;
        const usr1: u6 = @intCast(@intFromEnum(posix.SIG.USR1) - 1);
        if (blocked & (@as(u64, 1) << usr1) == 0) {
            old += 1;
            continue;
        }
        posix.kill(pid, .USR1) catch continue;
        sent += 1;
    }
    return .{ .sent = sent, .old = old };
}

// files in /proc report size 0, so read them by hand
fn read_proc(pid: posix.pid_t, name: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/{s}", .{ pid, name }) catch return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = posix.read(fd, buf[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

fn status_field(status: []const u8, name: []const u8) ?[]const u8 {
    var lines = mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (mem.startsWith(u8, line, name)) return mem.trim(u8, line[name.len..], " \t");
    }
    return null;
}

fn default_config_path(gpa: mem.Allocator, env: *const process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |dir| return mem.concat(gpa, u8, &.{ dir, "/flat-wm/config.zon" });
    if (env.get("HOME")) |home| return mem.concat(gpa, u8, &.{ home, "/.config/flat-wm/config.zon" });
    return error.GetConfigHomeFailed;
}

fn fatal(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    w.interface.print("flat-config: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    process.exit(1);
}

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    log_gpa = gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const result = flags.parser(&.{
        .{ .name = "h", .kind = .boolean },
        .{ .name = "help", .kind = .boolean },
        .{ .name = "c", .kind = .arg },
        .{ .name = "config", .kind = .arg },
        .{ .name = "no-reload", .kind = .boolean },
        .{ .name = "sibling-bg", .kind = .arg },
        .{ .name = "child-bg", .kind = .arg },
    }).parse(args[1..]) catch fatal(io, "bad arguments\n{s}", .{usage});
    if (result.flags.h or result.flags.help) {
        var buf: [1024]u8 = undefined;
        var w = Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(usage);
        try w.interface.flush();
        return;
    }
    if (result.args.len != 0) fatal(io, "unexpected argument\n{s}", .{usage});

    var colors: App.Colors = .{};
    if (result.flags.@"sibling-bg" orelse init.environ_map.get("FLAT_CONFIG_SIBLING_BG")) |c| {
        colors.sibling = App.Bg.parse(c) catch fatal(io, "bad color for the sibling rows: {s}\n{s}", .{ c, usage });
    }
    if (result.flags.@"child-bg" orelse init.environ_map.get("FLAT_CONFIG_CHILD_BG")) |c| {
        colors.child = App.Bg.parse(c) catch fatal(io, "bad color for the child rows: {s}\n{s}", .{ c, usage });
    }

    const default_path = try default_config_path(gpa, init.environ_map);
    defer gpa.free(default_path);
    const custom = result.flags.c orelse result.flags.config;
    const path: []const u8 = custom orelse default_path;

    const cwd = Io.Dir.cwd();
    const source = cwd.readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            // start from the shipped default
            const def = @import("config_def").text;
            if (Io.Dir.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};
            cwd.writeFile(io, .{ .sub_path = path, .data = def }) catch |e|
                fatal(io, "cannot create {s}: {s}", .{ path, @errorName(e) });
            break :blk try gpa.dupe(u8, def);
        },
        else => fatal(io, "cannot read {s}: {s}", .{ path, @errorName(err) }),
    };
    defer gpa.free(source);

    // the defaults flat-wm was built with, as ZON text
    var default_text: Io.Writer.Allocating = .init(gpa);
    defer default_text.deinit();
    try schema.serialize(config.Config, config.default, &default_text.writer, 0);

    var model = Model.init(gpa, schema.of(config.Config), source, default_text.written(), @import("config_def").text) catch |err| switch (err) {
        error.SyntaxError => {
            const pos = doc.error_position(gpa, source);
            var line: usize = 1;
            for (source[0..@min(pos, source.len)]) |c| {
                if (c == '\n') line += 1;
            }
            fatal(io, "{s}:{d}: cannot parse the file, fix it by hand first", .{ path, line });
        },
        else => return err,
    };
    defer model.deinit();

    // reload only the file flat-wm reads
    const same_file = blk: {
        if (custom == null) break :blk true;
        const a = cwd.realPathFileAlloc(io, path, gpa) catch break :blk false;
        defer gpa.free(a);
        const b = cwd.realPathFileAlloc(io, default_path, gpa) catch break :blk false;
        defer gpa.free(b);
        break :blk mem.eql(u8, a, b);
    };

    var ctx: Context = .{
        .gpa = gpa,
        .io = io,
        .path = path,
        .reload = same_file and !result.flags.@"no-reload",
        .original = source,
    };

    if (std.c.isatty(posix.STDIN_FILENO) == 0 or std.c.isatty(posix.STDOUT_FILENO) == 0) {
        fatal(io, "needs a terminal", .{});
    }

    var term = try Term.init(gpa);
    defer term.deinit();
    var app = try App.init(gpa, &model, &term, .{
        .ctx = &ctx,
        .validate = Context.validate,
        .save = Context.save,
    }, path, colors);
    defer app.deinit();
    app.run();
}

test {
    _ = @import("doc.zig");
    _ = @import("schema.zig");
    _ = @import("model.zig");
    _ = @import("term.zig");
    _ = @import("app.zig");
}

test "the real Config type and defaults" {
    const gpa = std.testing.allocator;
    var default_text: Io.Writer.Allocating = .init(gpa);
    defer default_text.deinit();
    try schema.serialize(config.Config, config.default, &default_text.writer, 0);
    var model = try Model.init(gpa, schema.of(config.Config), @import("config_def").text, default_text.written(), @import("config_def").text);
    defer model.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const expanded: std.StringHashMapUnmanaged(void) = .empty;
    const rows = try model.rows(arena.allocator(), &expanded, true);
    try std.testing.expect(rows.len > 100);
    // every value resolves to something
    for (rows) |row| {
        if (row.st.eff == null) {
            std.debug.print("missing: {s}\n", .{row.key});
            return error.Missing;
        }
    }
    try model.set(&.{ .{ .field = "layout" }, .{ .field = "scroller" }, .{ .field = "center_single" } }, "false", "");
    try std.testing.expect(mem.indexOf(u8, model.source, ".center_single = false") != null);
}
