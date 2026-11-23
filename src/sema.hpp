#pragma once
#include "ast.hpp"
#include "diag.hpp"
#include "types.hpp"
#include <cstddef>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
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
    // Pass 1: every signature, so bodies can rely on them.
    for (FnDecl *fn : fns)
      check_signature(fn);

    // Pass 2: every body.
    for (FnDecl *fn : fns) {
      current_fn_ = fn;
      push_scope();
      for (VarStmt *p : fn->params)
        declare(p); // parameters are `let` variables
      check_stmt(fn->body);
      pop_scope();

      if (fn->ret_type != types_.void_type() && fn->ret_type != types_.error() && !always_returns(fn->body)) {
        diag_.error(fn->body->end_offset,
                    "function '" + std::string(fn->name) + "' must return a '" +
                        type_name(fn->ret_type) + "' on every path");
      }
    }
  }

private:
  struct Symbol {
    std::string_view name;
    VarStmt *decl;
  };

  Diagnostics &diag_;
  TypeTable &types_;
  std::unordered_map<std::string_view, FnDecl *> functions_;
  FnDecl *current_fn_ = nullptr; // whose body we are checking
  std::vector<Symbol> symbols_;  // every visible name, innermost last
  std::vector<std::size_t>
      scope_starts_; // index in symbols_ where each scope begins

  //   symbols_:      [ a | b | a | x ]
  //   scope_starts_:   ^0      ^2         → inner scope holds "a", "x"

  // ------------------------------------------------------------ functions

  void check_signature(FnDecl *fn) {
    // Functions can be called before they're defined, so they all go
    // into one table up front.
    if (!functions_.try_emplace(fn->name, fn).second) {
      diag_.error(fn->offset, "function '" + std::string(fn->name) +
                                  "' is already defined");
    }
    for (VarStmt *p : fn->params)
      p->type = resolve_type(p->type_syntax);
    fn->ret_type =
        fn->ret_syntax ? resolve_type(fn->ret_syntax) : types_.void_type();

    if (fn->name == "main") {
      if (!fn->params.empty()) {
        diag_.error(fn->offset, "'main' must not take parameters");
      }
      if (fn->ret_type != types_.void_type() && fn->ret_type != types_.i64()) {
        diag_.error(fn->ret_syntax->offset,
                    "'main' must return 'i64' or nothing");
      }
    }
  }

  // Turns written syntax like `&mut i64` into the one shared Type*.
  Type *resolve_type(const TypeRef *t) {
    if (t->pointee)
      return types_.ref(resolve_type(t->pointee), t->is_mut);
    if (t->name == "i64")
      return types_.i64();
    if (t->name == "bool")
      return types_.boolean();
    if (t->name == "<error>")
      return types_.error(); // parser already reported it
    diag_.error(t->offset, "unknown type '" + std::string(t->name) + "'");
    return types_.error();
  }

  // Can control reach the end of `s`? If not, `s` always returns.
  //   return            → always returns
  //   { a; b; c }       → if any statement always returns
  //   if/else           → only if BOTH branches always return
  //   for { }           → a loop with no exit never falls through
  static bool always_returns(const Stmt *s) {
    switch (s->kind) {
    case StmtKind::Return:
      return true;
    case StmtKind::Block:
      for (const Stmt *child : static_cast<const BlockStmt *>(s)->stmts) {
        if (always_returns(child))
          return true;
      }
      return false;
    case StmtKind::If: {
      const auto *i = static_cast<const IfStmt *>(s);
      return i->else_stmt && always_returns(i->then_block) &&
             always_returns(i->else_stmt);
    }
    case StmtKind::For: {
      const auto *f = static_cast<const ForStmt *>(s);
      return f->cond->kind == ExprKind::Bool &&
             static_cast<const BoolExpr *>(f->cond)->value;
    }
    default:
      return false;
    }
  }

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
      if (v->type == types_.void_type()) {
        diag_.error(v->init->offset,
                    "this call returns nothing, so there is no value to store");
        v->type = types_.error();
      }
      declare(v);
      break;
    }
    case StmtKind::Return: {
      auto *r = cast<ReturnStmt>(s);
      Type *ret = current_fn_->ret_type;
      if (!r->value) {
        if (ret != types_.void_type() && ret != types_.error())
          diag_.error(r->offset, "missing return value");
        break;
      }
      Type *got = check_expr(r->value);
      if (ret == types_.void_type()) {
        diag_.error(r->value->offset, "'" + std::string(current_fn_->name) + "' does not return a value");
        break;
      }
      expect_type(r->value, got, ret);
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
    case ExprKind::Call:
      return check_call(cast<CallExpr>(e));
    }
    return types_.error();
  }

  // name(args): the function must exist, and each argument must match
  // its parameter's type. The call's type is the function's return type.
  Type *check_call(CallExpr *c) {
    const auto it = functions_.find(c->name);
    if (it == functions_.end()) {
      diag_.error(c->offset,
                  "undeclared function '" + std::string(c->name) + "'");
      for (Expr *arg : c->args)
        check_expr(arg);
      return types_.error();
    }
    c->fn = it->second;
    const auto &params = c->fn->params;

    if (c->args.size() != params.size()) {
      diag_.error(c->offset, "'" + std::string(c->name) + "' takes " +
                                 std::to_string(params.size()) +
                                 " argument(s), but got " +
                                 std::to_string(c->args.size()));
    }
    for (std::size_t i = 0; i < c->args.size(); ++i) {
      Type *got = check_expr(c->args[i]);
      if (i < params.size())
        expect_type(c->args[i], got, params[i]->type);
    }
    return c->fn->ret_type;
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
