#pragma once
#include "ast.hpp"
#include "diag.hpp"
#include <cstddef>
#include <span>
#include <string>
#include <string_view>
#include <vector>

// Name resolution: links every identifier to the `var`/`let` that
// declared it, and reports names that are undeclared or declared twice
// in the same scope.
class Resolver {
public:
  explicit Resolver(Diagnostics &diag) : diag_(diag) {}

  void run(std::span<FnDecl *> fns) {
    for (FnDecl *fn : fns)
      resolve_stmt(fn->body);
  }

private:
  struct Symbol {
    std::string_view name;
    VarStmt *decl;
  };

  Diagnostics &diag_;
  std::vector<Symbol> symbols_; // every visible name, innermost last
  std::vector<std::size_t>
      scope_starts_; // index in symbols_ where each scope begins

  // symbols:       | a | b | a | x |
  // scope_starts:    ^0      ^2           -> inner scope hols "a", "x"

  void push_scope() { scope_starts_.push_back(symbols_.size()); }

  void pop_scope() {
    symbols_.resize(scope_starts_.back());
    scope_starts_.pop_back();
  }

  void declare(VarStmt *v) {
    // Only the current scope counts as a clash; outer names may be shadowed.
    for (std::size_t i = scope_starts_.back(); i < symbols_.size(); ++i) {
      if (symbols_[i].name == v->name) {
        diag_.error(v->offset, "'" + std::string(v->name) +
                                   "' is already declared in this scope");
        return;
      }
    }
    symbols_.push_back({v->name, v});
  }

  VarStmt *lookup(std::string_view name) const {
    for (std::size_t i = symbols_.size(); i-- > 0;) { // innermost first
      if (symbols_[i].name == name)
        return symbols_[i].decl;
    }
    return nullptr;
  }

  void resolve_stmt(Stmt *s) {
    switch (s->kind) {
    case StmtKind::Var: {
      auto *v = cast<VarStmt>(s);
      resolve_expr(v->init); // before declares: `var x = x` is an error
      declare(v);
      break;
    }
    case StmtKind::Return: {
      auto *r = cast<ReturnStmt>(s);
      if (r->value)
        resolve_expr(r->value);
      break;
    }
    case StmtKind::Expr:
      resolve_expr(cast<ExprStmt>(s)->expr);
      break;
    case StmtKind::Block:
      push_scope();
      for (Stmt *child : cast<BlockStmt>(s)->stmts)
        resolve_stmt(child);
      pop_scope();
      break;
    }
  }

  void resolve_expr(Expr *e) {
    switch (e->kind) {
    case ExprKind::Int:
      break;
    case ExprKind::Ident: {
      auto *id = cast<IdentExpr>(e);
      id->decl = lookup(id->name);
      if (!id->decl) {
        diag_.error(id->offset,
                    "'undeclared name '" + std::string(id->name) + "'");
      }
      break;
    }
    case ExprKind::Unary:
      resolve_expr(cast<UnaryExpr>(e)->operand);
      break;
    case ExprKind::Binary: {
      auto *b = cast<BinaryExpr>(e);
      resolve_expr(b->lhs);
      resolve_expr(b->rhs);
      break;
    }
    }
  }
};
