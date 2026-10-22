// Just enough terminal handling for a full-screen program: raw mode, the
// alternate screen, key decoding and display width.

const Self = @This();

const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;

pub const Key = union(enum) {
    char: u21,
    ctrl: u8, // 'a'..'z'
    enter,
    esc,
    backspace,
    tab,
    shift_tab,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
};

gpa: mem.Allocator,
orig: posix.termios,
out: std.ArrayList(u8) = .empty,
width: u16 = 80,
height: u16 = 24,
pending: [64]u8 = undefined,
pending_len: usize = 0,

pub fn init(gpa: mem.Allocator) !Self {
    const orig = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    var self: Self = .{ .gpa = gpa, .orig = orig };
    _ = self.update_size();
    // alternate screen, hide cursor
    write_all("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J");
    return self;
}

pub fn deinit(self: *Self) void {
    write_all("\x1b[0m\x1b[?25h\x1b[?1049l");
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.orig) catch {};
    self.out.deinit(self.gpa);
}

// returns true when the size changed
pub fn update_size(self: *Self) bool {
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(posix.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(rc) != .SUCCESS or ws.col == 0) return false;
    const changed = ws.col != self.width or ws.row != self.height;
    self.width = ws.col;
    self.height = ws.row;
    return changed;
}

fn write_all(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(posix.STDOUT_FILENO, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

pub fn flush(self: *Self) void {
    write_all(self.out.items);
    self.out.clearRetainingCapacity();
}

pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
    self.out.print(self.gpa, fmt, args) catch {};
}

pub fn put(self: *Self, bytes: []const u8) void {
    self.out.appendSlice(self.gpa, bytes) catch {};
}

pub fn move(self: *Self, row: usize, col: usize) void {
    self.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
}

// writes at most `cols` columns of `text`, returns the columns used
pub fn put_clipped(self: *Self, text: []const u8, cols: usize) usize {
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch '?';
        const w: usize = if (cp == '\t') 1 else char_width(cp);
        if (used + w > cols) break;
        if (cp < 0x20 or cp == 0x7f) {
            self.put(" ");
        } else {
            self.put(text[i .. i + len]);
        }
        used += w;
        i += len;
    }
    return used;
}

pub fn spaces(self: *Self, n: usize) void {
    for (0..n) |_| self.put(" ");
}

pub fn char_width(cp: u21) usize {
    if (cp < 0x20) return 0;
    if (cp >= 0x300 and cp <= 0x36f) return 0;
    if (cp == 0x200b or cp == 0x200d or (cp >= 0xfe00 and cp <= 0xfe0f)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or
        (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
        (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe30 and cp <= 0xfe4f) or
        (cp >= 0xff00 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1f64f) or
        (cp >= 0x1f900 and cp <= 0x1f9ff) or
        (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

pub fn width_of(text: []const u8) usize {
    var used: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return text.len).iterator();
    while (it.nextCodepoint()) |cp| used += char_width(cp);
    return used;
}

// waits up to `timeout_ms` for a key
pub fn read_key(self: *Self, timeout_ms: i32) ?Key {
    if (self.pending_len == 0) {
        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, timeout_ms) catch return null;
        if (n == 0) return null;
        const got = posix.read(posix.STDIN_FILENO, &self.pending) catch return null;
        if (got == 0) return null;
        self.pending_len = got;
    }
    const buf = self.pending[0..self.pending_len];
    const key, const used = decode(buf);
    mem.copyForwards(u8, self.pending[0 .. self.pending_len - used], self.pending[used..self.pending_len]);
    self.pending_len -= used;
    return key;
}

fn decode(buf: []const u8) struct { ?Key, usize } {
    const c = buf[0];
    if (c == 0x1b) {
        if (buf.len == 1) return .{ .esc, 1 };
        if (buf[1] == '[' or buf[1] == 'O') {
            var i: usize = 2;
            while (i < buf.len and (std.ascii.isDigit(buf[i]) or buf[i] == ';')) i += 1;
            if (i >= buf.len) return .{ .esc, 1 };
            const params = buf[2..i];
            const key: ?Key = switch (buf[i]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                'Z' => .shift_tab,
                '~' => if (mem.eql(u8, params, "1") or mem.eql(u8, params, "7"))
                    .home
                else if (mem.eql(u8, params, "4") or mem.eql(u8, params, "8"))
                    .end
                else if (mem.eql(u8, params, "3"))
                    .delete
                else if (mem.eql(u8, params, "5"))
                    .page_up
                else if (mem.eql(u8, params, "6"))
                    .page_down
                else
                    null,
                else => null,
            };
            return .{ key, i + 1 };
        }
        // alt+key: ignore the alt
        return .{ .esc, 1 };
    }
    switch (c) {
        '\r', '\n' => return .{ .enter, 1 },
        '\t' => return .{ .tab, 1 },
        0x7f, 0x08 => return .{ .backspace, 1 },
        1...7, 11, 12, 14...26 => return .{ .{ .ctrl = 'a' + c - 1 }, 1 },
        else => {},
    }
    const len = std.unicode.utf8ByteSequenceLength(c) catch return .{ null, 1 };
    if (len > buf.len) return .{ null, buf.len };
    const cp = std.unicode.utf8Decode(buf[0..len]) catch return .{ null, len };
    return .{ .{ .char = cp }, len };
}

test "decode keys" {
    try std.testing.expectEqual(Key.up, decode("\x1b[A").@"0".?);
    try std.testing.expectEqual(Key.page_down, decode("\x1b[6~").@"0".?);
    try std.testing.expectEqual(@as(u21, 'j'), decode("j").@"0".?.char);
    try std.testing.expectEqual(@as(u8, 's'), decode("\x13").@"0".?.ctrl);
    try std.testing.expectEqual(@as(u21, '中'), decode("中").@"0".?.char);
    try std.testing.expectEqual(@as(usize, 4), width_of("中文"));
}
