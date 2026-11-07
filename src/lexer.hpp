#pragma once
#include "token.hpp"
#include <cstdint>
#include <string_view>

class Lexer {
public:
  explicit Lexer(std::string_view source) : src_(source) {}

  // Returns the next token. Returns Eof forever once the input ends.
  Token next() {
    const Token t = scan();
    last_ = t.kind;
    return t;
  }

  // The source text a token covers.
  std::string_view text(Token t) const {
    return src_.substr(t.offset, t.length);
  }

private:
  std::string_view src_;
  std::uint32_t pos_ = 0;           // next byte to read
  std::uint32_t start_ = 0;         // first byte of the current token
  TokenKind last_ = TokenKind::Eof; // kind of the last token returned

  Token scan() {
    skip_whitespace();
    start_ = pos_;

    if (at_end()) {
      // A file that ends mid-statement still ends the statement.
      if (ends_statement(last_))
        return make(TokenKind::Semicolon);
      return make(TokenKind::Eof);
    }

    const char c = advance();
    switch (c) {
    case '\n': {
      // skip_whitespace only stops at a newline that ends a statement.
      Token t = make(TokenKind::Semicolon);
      t.length = 0; // inserted, not written by the user
      return t;
    }
    case '(':
      return make(TokenKind::LParen);
    case ')':
      return make(TokenKind::RParen);
    case '{':
      return make(TokenKind::LBrace);
    case '}':
      return make(TokenKind::RBrace);
    case ',':
      return make(TokenKind::Comma);
    case ';':
      return make(TokenKind::Semicolon);
    case ':':
      return make(TokenKind::Colon);
    case '.':
      return make(TokenKind::Dot);
    case '+':
      return make(TokenKind::Plus);
    case '-':
      return make(TokenKind::Minus);
    case '*':
      return make(TokenKind::Star);
    case '/':
      return make(TokenKind::Slash);
    case '&':
      return make(TokenKind::Amp);
    case '=':
      return make(match('=') ? TokenKind::EqEq : TokenKind::Assign);
    default:
      if (is_ident_start(c))
        return lex_word();
      if (is_digit(c))
        return lex_number();
      return make(TokenKind::Error);
    }
  }

  bool at_end() const { return pos_ >= src_.size(); }
  char peek() const { return at_end() ? '\0' : src_[pos_]; }
  char advance() { return src_[pos_++]; }

  // Skips spaces, tabs and newlines, but stops at a newline that
  // ends a statement so scan() can turn it into a Semicolon.
  void skip_whitespace() {
    while (!at_end()) {
      const char c = peek();
      if (c == '\n' && ends_statement(last_))
        return;
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        ++pos_;
      } else {
        return;
      }
    }
  }

  static bool is_ident_start(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
  }

  static bool is_digit(char c) { return c >= '0' && c <= '9'; }

  static bool is_ident_char(char c) { return is_ident_start(c) || is_digit(c); }

  // First character is already consumed. Read the rest of the word,
  // then decide: keyword or identifier?
  Token lex_word() {
    while (is_ident_char(peek()))
      ++pos_;
    const std::string_view word = src_.substr(start_, pos_ - start_);
    return make(keyword_or_ident(word));
  }

  // First digit is already consumed. Read the rest of the digits.
  Token lex_number() {
    while (is_digit(peek()))
      ++pos_;
    return make(TokenKind::IntLit);
  }

  // If the next character is `expected`, consume it and return true.
  bool match(char expected) {
    if (peek() != expected)
      return false;
    ++pos_;
    return true;
  }

  Token make(TokenKind kind) const {
    return Token{
        .offset = start_,
        .length = static_cast<std::uint16_t>(pos_ - start_),
        .kind = kind,
    };
  }
};
