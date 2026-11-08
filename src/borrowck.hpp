#pragma once
#include "ast.hpp"
#include "diag.hpp"
#include "types.hpp"
#include <cstdint>
#include <span>
#include <string>
#include <unordered_map>

// Copy types are duplicated on use. Everything else is *moved*: after
// `let b = a`, the value lives in b and a may not be used again.
// Like Rust, i64, bool and shared refs (&T) are Copy; &mut T is not,
// because two usable &mut to the same place would break exclusivity.
inline bool is_copy(const Type *t) {
  switch (t->kind) {
  case TypeKind::Error:
  case TypeKind::I64:
  case TypeKind::Bool:
    return true;
  case TypeKind::Ref:
    return !t->is_mut;
  }
  return true;
}

// Borrow checker, rule 1: no use after move.
//
//   let m  = &mut a      m: Live
//   let m2 = m           m: Moved (at this offset)   m2: Live
//   let m3 = m           ✗ error: use of moved value 'm'
//
// Runs only on programs that passed name and type checking.
class BorrowChecker {
public:
  explicit BorrowChecker(Diagnostics &diag) : diag_(diag) {}

  void run(std::span<FnDecl *> fns) {
    for (FnDecl *fn : fns) {
      moved_.clear();
      check_stmt(fn->body);
    }
  }

private:
  Diagnostics &diag_;
  // Variables currently moved-out, and where the move happened.
  // Not in the map = Live.
  std::unordered_map<const VarStmt *, std::uint32_t> moved_;

  void check_stmt(Stmt *s) {
    switch (s->kind) {
    case StmtKind::Var:
      consume(cast<VarStmt>(s)->init);
      break;
    case StmtKind::Return: {
      auto *r = cast<ReturnStmt>(s);
      if (r->value)
        consume(r->value);
      break;
    }
    case StmtKind::Expr:
      consume(cast<ExprStmt>(s)->expr);
      break;
    case StmtKind::Assign: {
      auto *a = cast<AssignStmt>(s);
      consume(a->value);
      // Assigning gives the variable a fresh value: Live again.
      if (a->target->kind == ExprKind::Ident) {
        moved_.erase(cast<IdentExpr>(a->target)->decl);
      }
      break;
    }
    case StmtKind::Block:
      for (Stmt *child : cast<BlockStmt>(s)->stmts)
        check_stmt(child);
      break;
    }
  }

  // `e` is used by value: its result is copied or moved somewhere.
  void consume(Expr *e) {
    switch (e->kind) {
    case ExprKind::Int:
      break;
    case ExprKind::Ident: {
      auto *id = cast<IdentExpr>(e);
      require_live(id, "use");
      // try_emplace keeps the *first* move if it was already moved.
      if (!is_copy(id->type))
        moved_.try_emplace(id->decl, id->offset);
      break;
    }
    case ExprKind::Unary: {
      auto *u = cast<UnaryExpr>(e);
      if (u->op == TokenKind::Amp) {
        inspect(u->operand); // borrowing reads the place, never moves it
      } else {
        consume(u->operand);
      }
      break;
    }
    case ExprKind::Binary: {
      auto *b = cast<BinaryExpr>(e);
      // Operators only read their operands (they are all Copy types anyway).
      inspect(b->lhs);
      inspect(b->rhs);
      break;
    }
    }
  }

  // `e` is looked at but not moved: e.g. the operand of & or ==.
  void inspect(Expr *e) {
    if (e->kind == ExprKind::Ident) {
      require_live(cast<IdentExpr>(e), "borrow");
    } else {
      consume(e); // temporaries like (1 + 2) have nothing to move
    }
  }

  void require_live(IdentExpr *id, const char *action) {
    const auto it = moved_.find(id->decl);
    if (it == moved_.end())
      return;
    diag_.error(id->offset, std::string(action) + " of moved value '" +
                                std::string(id->name) + "'");
    diag_.note(it->second, "'" + std::string(id->name) + "' was moved here");
  }
};
