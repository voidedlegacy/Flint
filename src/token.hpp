#pragma once
#include <cstdint>

enum class TokenKind : std::uint8_t {
  // Specials
  Eof,
  Error,
  Ident,
  IntLit,
  StringLit,

  // Keywords
  KwFn,
  KwVar,
  KwLet,
  KwType,
  KwStruct,
  KwIf,
  KwElse,
  KwFor,
  KwReturn,
  KwUnsafe,
  KwMut,

  // Punctuation
  LParen,
  RParen,
  LBrace,
  RBrace, // ( ) { }
  Comma,
  Semicolon,
  Colon,
  Dot, // , ; : .

  // Operators
  Assign,
  EqEq, // = ==
  Plus,
  Minus,
  Star,
  Slash, // + - * /
  Amp,   // & (&mut = Amp + KwMut)
};

struct Token {
  std::uint32_t offset; // byte index into source    (4)
  std::uint16_t length; // byte length of the lexeme (2)
  TokenKind kind;       // what it is                (1) + 1 pad
};

static_assert(sizeof(Token) == 8, "Token must stay 8 bytes");

// Go-style semicolon insertion: a newline ends the statement
// only if the previous token could end one.
constexpr bool ends_statement(TokenKind k) {
  switch (k) {
  case TokenKind::Ident:
  case TokenKind::IntLit:
  case TokenKind::StringLit:
  case TokenKind::RParen:
  case TokenKind::RBrace:
  case TokenKind::KwReturn:
    return true;
  default:
    return false;
  }
}

static_assert(ends_statement(TokenKind::RParen));
static_assert(!ends_statement(TokenKind::Assign));
