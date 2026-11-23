const std = @import("std");

pub const TokenKind = enum(u8) {
    // Specials
    eof,
    err,
    ident,
    int_lit,
    string_lit,

    // Keywords
    kw_fn,
    kw_var,
    kw_let,
    kw_type,
    kw_struct,
    kw_if,
    kw_else,
    kw_true,
    kw_false,
    kw_for,
    kw_return,
    kw_unsafe,
    kw_mut,

    // Punctuation: ( ) { } , ; : .
    lparen,
    rparen,
    lbrace,
    rbrace,
    comma,
    semicolon,
    colon,
    dot,

    // Operators
    assign, // =
    eq_eq, // ==
    not_eq, // !=
    less,
    less_eq,
    greater,
    greater_eq,
    plus,
    minus,
    star,
    slash,
    amp, // & (&mut = amp + kw_mut)
    arrow, // ->

    /// Go-style semicolon insertion: a newline ends the statement only
    /// if the previous token could end one.
    pub fn endsStatement(k: TokenKind) bool {
        return switch (k) {
            .ident, .int_lit, .string_lit, .rparen, .rbrace, .kw_return, .kw_true, .kw_false => true,
            else => false,
        };
    }

    /// == != < <= > >= all produce a bool.
    pub fn isComparison(k: TokenKind) bool {
        return switch (k) {
            .eq_eq, .not_eq, .less, .less_eq, .greater, .greater_eq => true,
            else => false,
        };
    }
};

//   Token, 8 bytes:
//   +---------------+-------+---+---+
//   | offset (u32)  |len u16|knd|pad|
//   +---------------+-------+---+---+
//   0               4       6   7   8
pub const Token = struct {
    offset: u32, // byte index into source
    len: u16, // byte length of the lexeme
    kind: TokenKind,
};

comptime {
    std.debug.assert(@sizeOf(Token) == 8);
    std.debug.assert(@sizeOf(TokenKind) == 1);
}

pub const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "fn", .kw_fn },
    .{ "var", .kw_var },
    .{ "let", .kw_let },
    .{ "type", .kw_type },
    .{ "struct", .kw_struct },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "for", .kw_for },
    .{ "return", .kw_return },
    .{ "unsafe", .kw_unsafe },
    .{ "mut", .kw_mut },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
});

pub fn keywordOrIdent(word: []const u8) TokenKind {
    return keywords.get(word) orelse .ident;
}

comptime {
    std.debug.assert(TokenKind.rparen.endsStatement());
    std.debug.assert(!TokenKind.assign.endsStatement());
}

test "keywords" {
    try std.testing.expectEqual(TokenKind.kw_fn, keywordOrIdent("fn"));
    try std.testing.expectEqual(TokenKind.kw_mut, keywordOrIdent("mut"));
    try std.testing.expectEqual(TokenKind.ident, keywordOrIdent("count"));
    try std.testing.expectEqual(TokenKind.ident, keywordOrIdent("fnx"));
}
