#pragma once
#include <array>
#include <cstdint>
#include <string_view>
#include <utility>

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
  KwTrue,
  KwFalse,
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
  NotEq,
  Less,
  LessEq,
  Greater,
  GreaterEq,
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
  case TokenKind::KwTrue:
  case TokenKind::KwFalse:
    return true;
  default:
    return false;
  }
}

static_assert(ends_statement(TokenKind::RParen));
static_assert(!ends_statement(TokenKind::Assign));

// == != <= > >= all produce a bool.
constexpr bool is_comparison(TokenKind k) {
  switch (k) {
  case TokenKind::EqEq:
  case TokenKind::NotEq:
  case TokenKind::Less:
  case TokenKind::LessEq:
  case TokenKind::Greater:
  case TokenKind::GreaterEq:
    return true;
  default:
    return false;
  }
}

// Keyword table: The lexer scans a word, then asks this table
// whether it is a keyword or a plain identifier.
inline constexpr std::array<std::pair<std::string_view, TokenKind>, 13>
    keywords{{
        {"fn", TokenKind::KwFn},
        {"var", TokenKind::KwVar},
        {"let", TokenKind::KwLet},
        {"type", TokenKind::KwType},
        {"struct", TokenKind::KwStruct},
        {"if", TokenKind::KwIf},
        {"else", TokenKind::KwElse},
        {"for", TokenKind::KwFor},
        {"return", TokenKind::KwReturn},
        {"unsafe", TokenKind::KwUnsafe},
        {"mut", TokenKind::KwMut},
        {"true", TokenKind::KwTrue},
        {"false", TokenKind::KwFalse},
    }};

constexpr TokenKind keyword_or_ident(std::string_view word) {
  for (const auto &[text, kind] : keywords) {
    if (text == word)
      return kind;
  }
  return TokenKind::Ident;
}

static_assert(keyword_or_ident("fn") == TokenKind::KwFn);
static_assert(keyword_or_ident("mut") == TokenKind::KwMut);
static_assert(keyword_or_ident("count") == TokenKind::Ident);
static_assert(keyword_or_ident("fnx") == TokenKind::Ident);
