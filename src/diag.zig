const std = @import("std");

/// Turns byte offsets into "file:line:col" messages with the source line
/// and a caret under the problem. Line and column are only computed when
/// a message is actually printed, so the lexer stays fast.
pub const Diagnostics = struct {
    path: []const u8,
    src: []const u8,
    out: *std.Io.Writer,
    errors: u32 = 0,

    pub fn init(path: []const u8, src: []const u8, out: *std.Io.Writer) Diagnostics {
        return .{ .path = path, .src = src, .out = out };
    }

    pub fn err(self: *Diagnostics, offset: u32, comptime fmt: []const u8, args: anytype) void {
        self.errors += 1;
        self.report("error", offset, fmt, args);
    }

    /// Extra context for the previous error, e.g. "'x' was moved here".
    pub fn note(self: *Diagnostics, offset: u32, comptime fmt: []const u8, args: anytype) void {
        self.report("note", offset, fmt, args);
    }

    pub fn errorCount(self: *const Diagnostics) u32 {
        return self.errors;
    }

    fn report(self: *Diagnostics, label: []const u8, offset: u32, comptime fmt: []const u8, args: anytype) void {
        // Printing a diagnostic must never fail the compiler, so write
        // errors (e.g. a closed stderr) are ignored.
        self.write(label, offset, fmt, args) catch {};
    }

    fn write(self: *Diagnostics, label: []const u8, offset: u32, comptime fmt: []const u8, args: anytype) !void {
        const src = self.src;
        // Find the start of the line containing `offset`, and its number.
        var line: u32 = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < offset and i < src.len) : (i += 1) {
            if (src[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        const col = offset - line_start + 1; // 1-based

        var line_end = line_start;
        while (line_end < src.len and src[line_end] != '\n') line_end += 1;
        var text = src[line_start..line_end];
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1]; // CRLF

        const w = self.out;
        try w.print("{s}:{d}:{d}: {s}: ", .{ self.path, line, col, label });
        try w.print(fmt, args);
        try w.print("\n    {s}\n    ", .{text});
        // Copy tabs from the source line so the caret lines up.
        i = line_start;
        while (i < offset and i < line_end) : (i += 1) {
            try w.writeByte(if (src[i] == '\t') '\t' else ' ');
        }
        try w.writeAll("^\n");
    }
};

test "caret copies tabs and strips CR" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const src = "fn main() {\r\n\tlet x = y\r\n}\r\n";
    var d = Diagnostics.init("t.fl", src, &buf.writer);
    d.err(22, "undeclared name '{s}'", .{"y"});
    try std.testing.expectEqualStrings(
        "t.fl:2:10: error: undeclared name 'y'\n    \tlet x = y\n    \t        ^\n",
        buf.written(),
    );
    try std.testing.expectEqual(@as(u32, 1), d.errorCount());
}
