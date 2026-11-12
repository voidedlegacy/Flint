#pragma once
#include "ast.hpp"
#include "diag.hpp"
#include "types.hpp"
#include <cstddef>
#include <span>
#include <string>
#include <string_view>
#include <vector>

// Semantic checker. One walk over each function that:
//   1. links every identifier to the `var`/`let` that declared it,
//   2. gives every expression and variable a type,
//   3. enforces the rules: no undeclared names, no same-scope redeclaration,
//      no assigning to `let`, and operands must have the right types.
class Checker {
public:
  Checker(Diagnostics &diag, TypeTable &types) : diag_(diag), types_(types) {}

  void run(std::span<FnDecl *> fns) {
    for (FnDecl *fn : fns)
      check_stmt(fn->body);
  }

private:
  struct Symbol {
    std::string_view name;
    VarStmt *decl;
  };

  Diagnostics &diag_;
  TypeTable &types_;
  std::vector<Symbol> symbols_; // every visible name, innermost last
  std::vector<std::size_t>
      scope_starts_; // index in symbols_ where each scope begins

  //   symbols_:      [ a | b | a | x ]
  //   scope_starts_:   ^0      ^2         → inner scope holds "a", "x"

  // ------------------------------------------------------------ scopes

  void push_scope() { scope_starts_.push_back(symbols_.size()); }

  void pop_scope() {
    symbols_.resize(scope_starts_.back()); // forget the inner names
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

  // ------------------------------------------------------------ statements

  void check_stmt(Stmt *s) {
    switch (s->kind) {
    case StmtKind::Var: {
      auto *v = cast<VarStmt>(s);
      v->type = check_expr(v->init); // before declare: `var x = x` is an error
      declare(v);
      break;
    }
    case StmtKind::Return: {
      auto *r = cast<ReturnStmt>(s);
      if (r->value)
        check_expr(r->value);
      break;
    }
    case StmtKind::Expr:
      check_expr(cast<ExprStmt>(s)->expr);
      break;
    case StmtKind::Assign: {
      auto *a = cast<AssignStmt>(s);
      Type *value = check_expr(a->value);
      Type *target = check_expr(a->target);
      check_assign_target(a->target);
      expect_type(a->value, value, target);
      break;
    }
    case StmtKind::For: {
      auto *f = cast<ForStmt>(s);
      expect_type(f->cond, check_expr(f->cond), types_.boolean());
      check_stmt(f->body);
      break;
    }
    case StmtKind::If: {
      auto *i = cast<IfStmt>(s);
      expect_type(i->cond, check_expr(i->cond), types_.boolean());
      check_stmt(i->then_block);
      if (i->else_stmt)
        check_stmt(i->else_stmt);
      break;
    }
    case StmtKind::Block:
      push_scope();
      for (Stmt *child : cast<BlockStmt>(s)->stmts)
        check_stmt(child);
      pop_scope();
      break;
    }
  }

  // Rule: you may only assign to a variable, and only if it is a `var`.
  void check_assign_target(Expr *target) {
    if (target->kind != ExprKind::Ident) {
      diag_.error(target->offset, "can only assign to a variable");
      return;
    }
    auto *id = cast<IdentExpr>(target);
    if (id->decl && !id->decl->is_mut) {
      diag_.error(
          id->offset,
          "cannot assign to '" + std::string(id->name) +
              "': it was declared with 'let' (use 'var' to make it mutable)");
    }
  }

  // ------------------------------------------------------------ expressions

  // Computes the type of `e`, stores it in e->type, and returns it.
  Type *check_expr(Expr *e) {
    e->type = compute_type(e);
    return e->type;
  }

  Type *compute_type(Expr *e) {
    switch (e->kind) {
    case ExprKind::Int:
      return types_.i64();
    case ExprKind::Bool:
      return types_.boolean();
    case ExprKind::Ident: {
      auto *id = cast<IdentExpr>(e);
      id->decl = lookup(id->name);
      if (!id->decl) {
        diag_.error(id->offset,
                    "undeclared name '" + std::string(id->name) + "'");
        return types_.error();
      }
      return id->decl->type;
    }

    case ExprKind::Unary: {
      auto *u = cast<UnaryExpr>(e);
      Type *operand = check_expr(u->operand);
      if (u->op == TokenKind::Amp)
        return types_.ref(operand, u->is_mut);
      // Unary minus
      if (!expect_type(u->operand, operand, types_.i64()))
        return types_.error();
      return types_.i64();
    }

    case ExprKind::Binary: {
      auto *b = cast<BinaryExpr>(e);
      Type *lhs = check_expr(b->lhs);
      Type *rhs = check_expr(b->rhs);
      if (b->op == TokenKind::EqEq || b->op == TokenKind::NotEq) {
        // == and != need both sides to have the same type, and give bool.
        if (!expect_type(b->rhs, rhs, lhs))
          return types_.error();
        return types_.boolean();
      }
      if (is_comparison(b->op)) {
        // < <= > >= compare two i64 and give bool.
        const bool ok_l = expect_type(b->lhs, lhs, types_.i64());
        const bool ok_r = expect_type(b->rhs, rhs, types_.i64());
        return ok_l && ok_r ? types_.boolean() : types_.error();
      }
      // + - * / need i64 on both sides, and give i64.
      const bool ok_l = expect_type(b->lhs, lhs, types_.i64());
      const bool ok_r = expect_type(b->rhs, rhs, types_.i64());
      return ok_l && ok_r ? types_.i64() : types_.error();
    }
    }
    return types_.error();
  }

  // Reports a mismatch unless `actual` is `expected`. Error types never
  // report again: the real problem was already printed.
  bool expect_type(Expr *where, Type *actual, Type *expected) {
    if (actual == expected)
      return true;
    if (actual == types_.error() || expected == types_.error())
      return false;
    diag_.error(where->offset, "expected '" + type_name(expected) +
                                   "', found '" + type_name(actual) + "'");
    return false;
  }
};
