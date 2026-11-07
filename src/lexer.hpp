#pragma once
#include "token.hpp"
#include <cstdint>
#include <string_view>

class Lexer {
public:
  explicit Lexer(std::string_view source) : src_(source) {}

  // Returns the next token. Returns Eof forever once the input ends.
  Token next() {
    skip_whitespace();
    start_ = pos_;

    if (at_end())
      return make(TokenKind::Eof);

    const char c = advance();
    switch (c) {
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
    default:
      return make(TokenKind::Error);
    }
  }

  // The source text a token covers.
  std::string_view text(Token t) const {
    return src_.substr(t.offset, t.length);
  }

private:
  std::string_view src_;
  std::uint32_t pos_ = 0;   // next byte to read
  std::uint16_t start_ = 0; // first byte of the current token

  bool at_end() const { return pos_ >= src_.size(); }
  char peek() const { return at_end() ? '\0' : src_[pos_]; }
  char advance() { return src_[pos_++]; }

  void skip_whitespace() {
    while (!at_end()) {
      const char c = peek();
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        ++pos_;
      } else {
        return;
      }
    }
  }

  Token make(TokenKind kind) const {
    return Token{
        .offset = start_,
        .length = static_cast<std::uint16_t>(pos_ - start_),
        .kind = kind,
    };
  }
};
