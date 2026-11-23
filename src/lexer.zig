const std = @import("std");
const tok = @import("token.zig");
const Token = tok.Token;
const TokenKind = tok.TokenKind;

/// Pull-based lexer: call next() for each token. Returns .eof forever
/// once the input ends.
pub const Lexer = struct {
    src: []const u8,
    pos: u32 = 0, // next byte to read
    start: u32 = 0, // first byte of the current token
    last: TokenKind = .eof, // kind of the last token returned

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    pub fn next(self: *Lexer) Token {
        const t = self.scan();
        self.last = t.kind;
        return t;
    }

    /// The source text a token covers.
    pub fn text(self: *const Lexer, t: Token) []const u8 {
        return self.src[t.offset..][0..t.len];
    }

    fn scan(self: *Lexer) Token {
        self.skipWhitespace();
        self.start = self.pos;

        if (self.atEnd()) {
            // A file that ends mid-statement still ends the statement.
            if (self.last.endsStatement()) return self.make(.semicolon);
            return self.make(.eof);
        }

        const c = self.advance();
        return switch (c) {
            '\n' => blk: {
                // skipWhitespace only stops at a newline that ends a statement.
                var t = self.make(.semicolon);
                t.len = 0; // inserted, not written by the user
                break :blk t;
            },
            '(' => self.make(.lparen),
            ')' => self.make(.rparen),
            '{' => self.make(.lbrace),
            '}' => self.make(.rbrace),
            ',' => self.make(.comma),
            ';' => self.make(.semicolon),
            ':' => self.make(.colon),
            '.' => self.make(.dot),
            '+' => self.make(.plus),
            '-' => self.make(if (self.match('>')) .arrow else .minus),
            '*' => self.make(.star),
            '/' => self.make(.slash),
            '&' => self.make(.amp),
            '=' => self.make(if (self.match('=')) .eq_eq else .assign),
            '!' => self.make(if (self.match('=')) .not_eq else .err),
            '<' => self.make(if (self.match('=')) .less_eq else .less),
            '>' => self.make(if (self.match('=')) .greater_eq else .greater),
            '"' => self.lexString(),
            else => if (isIdentStart(c))
                self.lexWord()
            else if (isDigit(c))
                self.lexNumber()
            else
                self.make(.err),
        };
    }

    fn atEnd(self: *const Lexer) bool {
        return self.pos >= self.src.len;
    }
    fn peek(self: *const Lexer) u8 {
        return if (self.atEnd()) 0 else self.src[self.pos];
    }
    fn peekNext(self: *const Lexer) u8 {
        return if (self.pos + 1 >= self.src.len) 0 else self.src[self.pos + 1];
    }
    fn advance(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    /// Skips spaces, tabs, newlines and // comments, but stops at a newline
    /// that ends a statement so scan() can turn it into a semicolon.
    fn skipWhitespace(self: *Lexer) void {
        while (!self.atEnd()) {
            const c = self.peek();
            if (c == '\n' and self.last.endsStatement()) return;
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
            } else if (c == '/' and self.peekNext() == '/') {
                // Leave the '\n' alone so semicolon insertion still sees it.
                while (!self.atEnd() and self.peek() != '\n') self.pos += 1;
            } else {
                return;
            }
        }
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
    fn isIdentChar(c: u8) bool {
        return isIdentStart(c) or isDigit(c);
    }

    fn lexWord(self: *Lexer) Token {
        while (isIdentChar(self.peek())) self.pos += 1;
        return self.make(tok.keywordOrIdent(self.src[self.start..self.pos]));
    }

    fn lexNumber(self: *Lexer) Token {
        while (isDigit(self.peek())) self.pos += 1;
        return self.make(.int_lit);
    }

    /// Opening quote already consumed. The token's text includes both
    /// quotes. A backslash skips the next character, so \" does not end it.
    fn lexString(self: *Lexer) Token {
        while (!self.atEnd() and self.peek() != '"' and self.peek() != '\n') {
            if (self.advance() == '\\' and !self.atEnd()) self.pos += 1;
        }
        if (!self.match('"')) return self.make(.err); // unterminated
        return self.make(.string_lit);
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.peek() != expected) return false;
        self.pos += 1;
        return true;
    }

    fn make(self: *const Lexer, kind: TokenKind) Token {
        return .{ .offset = self.start, .len = @intCast(self.pos - self.start), .kind = kind };
    }
};

// ---------------------------------------------------------------- tests

fn expectKinds(src: []const u8, expected: []const TokenKind) !void {
    var lx = Lexer.init(src);
    for (expected) |k| try std.testing.expectEqual(k, lx.next().kind);
}

test "semicolon insertion" {
    try expectKinds("var x = 1\nx = x + 2\n", &.{
        .kw_var,    .ident,  .assign, .int_lit, .semicolon,
        .ident,     .assign, .ident,  .plus,    .int_lit,
        .semicolon, .eof,    .eof,
    });
}

test "eof inserts a semicolon" {
    try expectKinds("return", &.{ .kw_return, .semicolon, .eof });
}

test "operators and comments" {
    try expectKinds("a == b != c <= d >= e -> &mut ! // hi\n", &.{
        .ident, .eq_eq, .ident, .not_eq, .ident, .less_eq, .ident, .greater_eq, .ident, .arrow, .amp, .kw_mut, .err, .eof,
    });
}

test "strings and CRLF" {
    var lx = Lexer.init("\"a\\\"b\"\r\n\"oops");
    const s = lx.next();
    try std.testing.expectEqual(TokenKind.string_lit, s.kind);
    try std.testing.expectEqualStrings("\"a\\\"b\"", lx.text(s));
    try std.testing.expectEqual(TokenKind.semicolon, lx.next().kind);
    try std.testing.expectEqual(TokenKind.err, lx.next().kind);
}

test "inserted semicolon has zero length" {
    var lx = Lexer.init("x\n");
    _ = lx.next();
    const semi = lx.next();
    try std.testing.expectEqual(TokenKind.semicolon, semi.kind);
    try std.testing.expectEqual(@as(u16, 0), semi.len);
}
