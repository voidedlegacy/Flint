#pragma once
#include "arena.hpp"
#include "ast.hpp"
#include "diag.hpp"
#include "lexer.hpp"
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <span>
#include <vector>

class Parser {
public:
  Parser(Lexer &lexer, Arena &arena, Diagnostics &diag)
      : lex_(lexer), arena_(arena), diag_(diag) {
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

  // Parses a whole file: a list of top-level fn declarations.
  std::span<FnDecl *> parse_file() {
    std::vector<FnDecl *> fns;
    while (!at_eof()) {
      if (tok_.kind == TokenKind::KwFn) {
        fns.push_back(parse_fn());
      } else {
        error(tok_, "expected 'fn'");
        synchronize();
        panicking_ = false;
      }
    }
    return arena_.copy_array(fns);
  }

  // Parses one statement, including its terminating semicolon.
  Stmt *parse_stmt() {
    const Token t = tok_;
    Stmt *s = nullptr;

    if (t.kind == TokenKind::KwVar || t.kind == TokenKind::KwLet) {
      bump();
      const Token name = tok_;
      expect(TokenKind::Ident, "expected a variable name");
      expect(TokenKind::Assign, "expected '='");
      Expr *init = parse_expr();
      s = arena_.make<VarStmt>(t.offset, lex_.text(name),
                               t.kind == TokenKind::KwVar, init);
    } else if (t.kind == TokenKind::LBrace) {
      s = parse_block();
    } else if (t.kind == TokenKind::KwIf) {
      s = parse_if();
    } else if (t.kind == TokenKind::KwReturn) {
      bump();
      Expr *value = tok_.kind == TokenKind::Semicolon ? nullptr : parse_expr();
      s = arena_.make<ReturnStmt>(t.offset, value);
    } else {
      Expr *e = parse_expr();
      if (tok_.kind == TokenKind::Assign) {
        bump(); // '='
        Expr *value = parse_expr();
        s = arena_.make<AssignStmt>(t.offset, e, value);
      } else {
        s = arena_.make<ExprStmt>(t.offset, e);
      }
    }

    if (tok_.kind == TokenKind::Semicolon) {
      bump();
    } else if (tok_.kind == TokenKind::RBrace) {
      // Last statement in a block may skip the semicolon: { return x }
    } else {
      error(tok_, "expected end of statement");
      synchronize();
    }
    panicking_ = false; // next statement gets a fresh start
    return s;
  }

  bool at_eof() const { return tok_.kind == TokenKind::Eof; }

  bool had_error() const { return had_error_; }

private:
  Lexer &lex_;
  Arena &arena_;
  Diagnostics &diag_;
  Token tok_{}; // current token, not yet consumed
  bool had_error_ = false;
  bool panicking_ = false; // true after an error until the statement ends

  void bump() { tok_ = lex_.next(); }

  // fn name() { ... }
  FnDecl *parse_fn() {
    const Token fn_tok = tok_;
    bump(); // 'fn'
    const Token name = tok_;
    expect(TokenKind::Ident, "expected a function name");
    expect(TokenKind::LParen, "expected '('");
    expect(TokenKind::RParen, "expected ')'");
    BlockStmt *body = parse_block();
    if (tok_.kind == TokenKind::Semicolon)
      bump(); // inserted after '}'
    panicking_ = false;
    return arena_.make<FnDecl>(fn_tok.offset, lex_.text(name), body);
  }

  // if cond { ... } [else { ... } | else if ...]
  // Like Go, `else` must be on the same line as the closing `}`.
  Stmt *parse_if() {
    const Token if_tok = tok_;
    bump(); // 'if'
    Expr *cond = parse_expr();
    BlockStmt *then_block = parse_block();
    Stmt *else_stmt = nullptr;
    if (tok_.kind == TokenKind::KwElse) {
      bump();
      else_stmt = tok_.kind == TokenKind::KwIf ? parse_if() : parse_block();
    }
    return arena_.make<IfStmt>(if_tok.offset, cond, then_block, else_stmt);
  }

  // { stmt; stmt; ... }
  BlockStmt *parse_block() {
    const Token open = tok_;
    expect(TokenKind::LBrace, "expected '{'");
    std::vector<Stmt *> stmts;
    while (tok_.kind != TokenKind::RBrace && !at_eof()) {
      stmts.push_back(parse_stmt());
    }
    expect(TokenKind::RBrace, "expected '}'");
    return arena_.make<BlockStmt>(open.offset, arena_.copy_array(stmts));
  }

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
      expect(TokenKind::RParen, "expected ')'");
      return inner;
    }
    default:
      error(t, t.kind == TokenKind::KwElse
                   ? "'else' must be on the same line as the '}' before it"
                   : "expected an expression");
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

  // After an error, skip ahead to the next statement boundary so one
  // mistake does not cause a flood of follow-up errors.
  void synchronize() {
    while (tok_.kind != TokenKind::Semicolon && tok_.kind != TokenKind::Eof)
      bump();
    if (tok_.kind == TokenKind::Semicolon)
      bump();
  }

  void error(Token at, const char *msg) {
    had_error_ = true;
    if (panicking_)
      return; // report only the first error per statement
    panicking_ = true;
    diag_.error(at.offset, msg);
  }
};
