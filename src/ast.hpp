#pragma once
#include "token.hpp"
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <span>
#include <string_view>

// Every expression node starts with this header. The kind tag tells us
// which concrete struct it really is, so we can cast safely.
enum class ExprKind : std::uint8_t { Int, Ident, Unary, Binary };

struct Expr {
  ExprKind kind;
  std::uint32_t offset; // where it starts in the source, for errors
};

struct IntExpr : Expr {
  static constexpr ExprKind Kind = ExprKind::Int;
  std::uint64_t value;

  IntExpr(std::uint32_t off, std::uint64_t v) : Expr{Kind, off}, value(v) {}
};

struct IdentExpr : Expr {
  static constexpr ExprKind Kind = ExprKind::Ident;
  std::string_view name; // points into the source buffer, no copy

  IdentExpr(std::uint32_t off, std::string_view n) : Expr{Kind, off}, name(n) {}
};

struct UnaryExpr : Expr {
  static constexpr ExprKind Kind = ExprKind::Unary;
  TokenKind op; // Minus or Amp
  bool is_mut;  // true for &mut
  Expr *operand;

  UnaryExpr(std::uint32_t off, TokenKind o, bool m, Expr *e)
      : Expr{Kind, off}, op(o), is_mut(m), operand(e) {}
};

struct BinaryExpr : Expr {
  static constexpr ExprKind Kind = ExprKind::Binary;
  TokenKind op; // Plus, Minus, Star, Slash, EqEq
  Expr *lhs;
  Expr *rhs;

  BinaryExpr(std::uint32_t off, TokenKind o, Expr *l, Expr *r)
      : Expr{Kind, off}, op(o), lhs(l), rhs(r) {}
};

// Checked downcast: crashes in debug builds if the kind is wrong.
template <typename T> T *cast(Expr *e) {
  assert(e->kind == T::Kind);
  return static_cast<T *>(e);
}

inline const char *op_text(TokenKind op) {
  switch (op) {
  case TokenKind::Plus:
    return "+";
  case TokenKind::Minus:
    return "-";
  case TokenKind::Star:
    return "*";
  case TokenKind::Slash:
    return "/";
  case TokenKind::EqEq:
    return "==";
  case TokenKind::Amp:
    return "&";
  default:
    return "?";
  }
}

// Prints the tree as an S-expression, e.g. (* (- (+ 1 x)) 2).
inline void dump(Expr *e) {
  switch (e->kind) {
  case ExprKind::Int:
    std::printf("%llu",
                static_cast<unsigned long long>(cast<IntExpr>(e)->value));
    break;
  case ExprKind::Ident: {
    const auto n = cast<IdentExpr>(e)->name;
    std::printf("%.*s", static_cast<int>(n.size()), n.data());
    break;
  }
  case ExprKind::Unary: {
    auto *u = cast<UnaryExpr>(e);
    std::printf("(%s%s ", op_text(u->op), u->is_mut ? "mut" : "");
    dump(u->operand);
    std::printf(")");
    break;
  }
  case ExprKind::Binary: {
    auto *b = cast<BinaryExpr>(e);
    std::printf("(%s ", op_text(b->op));
    dump(b->lhs);
    std::printf(" ");
    dump(b->rhs);
    std::printf(")");
    break;
  }
  }
}

// ---------------------------------------------------------------- statements

enum class StmtKind : std::uint8_t { Var, Return, Expr, Block };

struct Stmt {
  StmtKind kind;
  std::uint32_t offset;
};

// var x = e   (mutable)     let x = e   (immutable)
struct VarStmt : Stmt {
  static constexpr StmtKind Kind = StmtKind::Var;
  std::string_view name;
  bool is_mut;
  Expr *init;

  VarStmt(std::uint32_t off, std::string_view n, bool m, Expr *e)
      : Stmt{Kind, off}, name(n), is_mut(m), init(e) {}
};

// return      or      return e
struct ReturnStmt : Stmt {
  static constexpr StmtKind Kind = StmtKind::Return;
  Expr *value; // nullptr for a bare return

  ReturnStmt(std::uint32_t off, Expr *v) : Stmt{Kind, off}, value(v) {}
};

// An expression used as a statement, e.g. a call: f(x)
struct ExprStmt : Stmt {
  static constexpr StmtKind Kind = StmtKind::Expr;
  Expr *expr;

  ExprStmt(std::uint32_t off, Expr *e) : Stmt{Kind, off}, expr(e) {}
};

struct BlockStmt : Stmt {
  static constexpr StmtKind Kind = StmtKind::Block;
  std::span<Stmt *> stmts; // stored in the arena

  BlockStmt(std::uint32_t off, std::span<Stmt *> s)
      : Stmt{Kind, off}, stmts(s) {}
};

template <typename T> T *cast(Stmt *s) {
  assert(s->kind == T::Kind);
  return static_cast<T *>(s);
}

inline void dump(Stmt *s) {
  switch (s->kind) {
  case StmtKind::Var: {
    auto *v = cast<VarStmt>(s);
    std::printf("(%s %.*s ", v->is_mut ? "var" : "let",
                static_cast<int>(v->name.size()), v->name.data());
    dump(v->init);
    std::printf(")");
    break;
  }
  case StmtKind::Return: {
    auto *r = cast<ReturnStmt>(s);
    std::printf("(return");
    if (r->value) {
      std::printf(" ");
      dump(r->value);
    }
    std::printf(")");
    break;
  }
  case StmtKind::Expr:
    dump(cast<ExprStmt>(s)->expr);
    break;
  case StmtKind::Block:
    std::printf("(block");
    for (Stmt *child : cast<BlockStmt>(s)->stmts) {
      std::printf(" ");
      dump(child);
    }
    std::printf(")");
    break;
  }
}

// --------------------------------------------------------------- declarations

// fn name() { ... }      Parameters and return types come later.
struct FnDecl {
  std::uint32_t offset;
  std::string_view name;
  BlockStmt *body;
};

inline void dump(FnDecl *f) {
  std::printf("(fn %.*s ", static_cast<int>(f->name.size()), f->name.data());
  dump(f->body);
  std::printf(")");
}
