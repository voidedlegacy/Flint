#pragma once
#include "arena.hpp"
#include "ast.hpp"
#include "lexer.hpp"
#include <charconv>
#include <cstdint>
#include <cstdio>

class Parser {
public:
  Parser(Lexer &lexer, Arena &arena) : lex_(lexer), arena_(arena) {
    tok_ = lex_.next(); // prime the first token
  }

  // Parses a full expression using precedence climbing (Pratt parsing).
  Expr *parse_expr(int min_prec = 1) {
    Expr *lhs = parse_unary();

    // Keep folding in binary operators that bind at least as tightly
    // as min_prec. prec + 1 on the right makes them left-associative.
    while (precedence(tok_.kind) >= min_prec) {
      const Token op = tok_;
      const int prec = precedence(op.kind);
      bump();
      Expr *rhs = parse_expr(prec + 1);
      lhs = arena_.make<BinaryExpr>(lhs->offset, op.kind, lhs, rhs);
    }
    return lhs;
  }

  bool had_error() const { return had_error_; }

private:
  Lexer &lex_;
  Arena &arena_;
  Token tok_{}; // current token, not yet consumed
  bool had_error_ = false;

  void bump() { tok_ = lex_.next(); }

  // 0 means "not a binary operator", which ends the loop above.
  static int precedence(TokenKind k) {
    switch (k) {
    case TokenKind::EqEq:
      return 1;
    case TokenKind::Plus:
    case TokenKind::Minus:
      return 2;
    case TokenKind::Star:
    case TokenKind::Slash:
      return 3;
    default:
      return 0;
    }
  }

  // Prefix operators bind tighter than any binary operator.
  Expr *parse_unary() {
    const Token t = tok_;
    if (t.kind == TokenKind::Minus) {
      bump();
      return arena_.make<UnaryExpr>(t.offset, TokenKind::Minus, false,
                                    parse_unary());
    }
    if (t.kind == TokenKind::Amp) {
      bump();
      bool is_mut = false;
      if (tok_.kind == TokenKind::KwMut) {
        is_mut = true;
        bump();
      }
      return arena_.make<UnaryExpr>(t.offset, TokenKind::Amp, is_mut,
                                    parse_unary());
    }
    return parse_primary();
  }

  Expr *parse_primary() {
    const Token t = tok_;
    switch (t.kind) {
    case TokenKind::IntLit: {
      bump();
      const auto text = lex_.text(t);
      std::uint64_t value = 0;
      std::from_chars(text.data(), text.data() + text.size(), value);
      return arena_.make<IntExpr>(t.offset, value);
    }
    case TokenKind::Ident:
      bump();
      return arena_.make<IdentExpr>(t.offset, lex_.text(t));
    case TokenKind::LParen: {
      bump();
      Expr *inner = parse_expr();
      expect(TokenKind::RParen, "')'");
      return inner;
    }
    default:
      error(t, "expected an expression");
      bump(); // skip the bad token so we always make progress
      return arena_.make<IntExpr>(t.offset, 0u); // placeholder, never null
    }
  }

  void expect(TokenKind kind, const char *what) {
    if (tok_.kind == kind) {
      bump();
    } else {
      error(tok_, what);
    }
  }

  void error(Token at, const char *msg) {
    had_error_ = true;
    std::fprintf(stderr, "error at offset %u: %s\n", at.offset, msg);
  }
};
