#pragma once
#include "ast.hpp"
#include "diag.hpp"
#include "types.hpp"
#include <cstdint>
#include <span>
#include <string>
#include <unordered_map>
#include <vector>

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

// Borrow checker.
//
// Rule 1, moves:     a moved variable may not be used again.
// Rule 2, aliasing:  while a borrow ("loan") of x is alive,
//                      &x      → x may be read, not written or &mut-borrowed
//                      &mut x  → x may not be touched at all
//
// A loan is alive while some variable holding it is still used later
// (like Rust's non-lexical lifetimes). Flint has no loops or branches
// yet, so "later" simply means "further down in the source".
//
//   var a = 1
//   let m = &mut a     loan #0: &mut a, held by m
//   a = 2              ✗ m is used below, so loan #0 is alive
//   let k = m          last use of m: loan #0 ends here
//   a = 3              ✓
//
// Runs only on programs that passed name and type checking.
class BorrowChecker {
public:
  explicit BorrowChecker(Diagnostics &diag) : diag_(diag) {}

  void run(std::span<FnDecl *> fns) {
    for (FnDecl *fn : fns) {
      moved_.clear();
      loans_.clear();
      holds_.clear();
      last_use_.clear();
      record_last_uses(fn->body);
      check_stmt(fn->body);
    }
  }

private:
  using LoanId = std::uint32_t;

  struct Loan {
    const VarStmt *place; // the variable being borrowed
    bool is_mut;
    std::uint32_t offset; // where the & or &mut is
  };

  Diagnostics &diag_;
  std::unordered_map<const VarStmt *, std::uint32_t>
      moved_;               // var → where it was moved
  std::vector<Loan> loans_; // every loan, by id
  std::unordered_map<const VarStmt *, std::vector<LoanId>>
      holds_; // var → loans inside its value
  std::unordered_map<const VarStmt *, std::uint32_t>
      last_use_; // var → offset of its last read

  // ------------------------------------------------------------ last uses

  // Pre-pass: remember the last place each variable is read.
  // Assignment targets don't count: `r = ...` overwrites r, it doesn't read it.
  void record_last_uses(Stmt *s) {
    switch (s->kind) {
    case StmtKind::Var:
      record_last_uses(cast<VarStmt>(s)->init);
      break;
    case StmtKind::Expr:
      record_last_uses(cast<ExprStmt>(s)->expr);
      break;
    case StmtKind::Assign:
      record_last_uses(cast<AssignStmt>(s)->value);
      break;
    case StmtKind::Return: {
      auto *r = cast<ReturnStmt>(s);
      if (r->value)
        record_last_uses(r->value);
      break;
    }
    case StmtKind::Block:
      for (Stmt *child : cast<BlockStmt>(s)->stmts)
        record_last_uses(child);
      break;
    }
  }

  void record_last_uses(Expr *e) {
    switch (e->kind) {
    case ExprKind::Int:
      break;
    case ExprKind::Ident: {
      auto *id = cast<IdentExpr>(e);
      auto &last = last_use_[id->decl];
      if (id->offset > last)
        last = id->offset;
      break;
    }
    case ExprKind::Unary:
      record_last_uses(cast<UnaryExpr>(e)->operand);
      break;
    case ExprKind::Binary: {
      auto *b = cast<BinaryExpr>(e);
      record_last_uses(b->lhs);
      record_last_uses(b->rhs);
      break;
    }
    }
  }

  // ------------------------------------------------------------ statements

  void check_stmt(Stmt *s) {
    switch (s->kind) {
    case StmtKind::Var: {
      auto *v = cast<VarStmt>(s);
      holds_[v] = eval(v->init);
      break;
    }
    case StmtKind::Return: {
      auto *r = cast<ReturnStmt>(s);
      if (r->value)
        eval(r->value);
      break;
    }
    case StmtKind::Expr:
      eval(cast<ExprStmt>(s)->expr);
      break;
    case StmtKind::Assign: {
      auto *a = cast<AssignStmt>(s);
      std::vector<LoanId> loans = eval(a->value);
      if (a->target->kind == ExprKind::Ident) {
        auto *id = cast<IdentExpr>(a->target);
        check_conflicts(id, /*want_mut=*/true, "assign to", "");
        moved_.erase(id->decl);              // fresh value: usable again
        holds_[id->decl] = std::move(loans); // old loans are dropped
      }
      break;
    }
    case StmtKind::Block:
      for (Stmt *child : cast<BlockStmt>(s)->stmts)
        check_stmt(child);
      break;
    }
  }

  // ------------------------------------------------------------ expressions

  // Evaluates `e` by value and returns the loans carried by the result.
  std::vector<LoanId> eval(Expr *e) {
    switch (e->kind) {
    case ExprKind::Int:
      return {};
    case ExprKind::Ident: {
      auto *id = cast<IdentExpr>(e);
      require_not_moved(id, "use");
      check_conflicts(id, /*want_mut=*/false, "use", "");
      if (is_copy(id->type))
        return holds_[id->decl]; // copy keeps both
      // Move: the loans travel with the value and leave the old variable.
      moved_.try_emplace(id->decl, id->offset);
      std::vector<LoanId> loans = std::move(holds_[id->decl]);
      holds_[id->decl].clear();
      return loans;
    }
    case ExprKind::Unary: {
      auto *u = cast<UnaryExpr>(e);
      if (u->op == TokenKind::Amp)
        return borrow(u);
      eval(u->operand);
      return {};
    }
    case ExprKind::Binary: {
      auto *b = cast<BinaryExpr>(e);
      read_only(b->lhs);
      read_only(b->rhs);
      return {}; // results are i64 or bool: no loans inside
    }
    }
    return {};
  }

  // Operands of operators are read, never moved.
  void read_only(Expr *e) {
    if (e->kind == ExprKind::Ident) {
      auto *id = cast<IdentExpr>(e);
      require_not_moved(id, "use");
      check_conflicts(id, /*want_mut=*/false, "use", "");
    } else {
      eval(e);
    }
  }

  // &x or &mut x: creates a new loan on x.
  std::vector<LoanId> borrow(UnaryExpr *u) {
    if (u->operand->kind != ExprKind::Ident) {
      eval(u->operand); // borrowing a temporary like &(1 + 2)
      return {};
    }
    auto *id = cast<IdentExpr>(u->operand);
    require_not_moved(id, "borrow");

    if (u->is_mut && !id->decl->is_mut) {
      diag_.error(id->offset, "cannot borrow '" + std::string(id->name) +
                                  "' as mutable: it was declared with 'let'");
    }
    check_conflicts(id, u->is_mut, "borrow", u->is_mut ? " as mutable" : "");

    loans_.push_back({id->decl, u->is_mut, u->offset});
    return {static_cast<LoanId>(loans_.size() - 1)};
  }

  // ------------------------------------------------------------ the rules

  void require_not_moved(IdentExpr *id, const char *action) {
    const auto it = moved_.find(id->decl);
    if (it == moved_.end())
      return;
    diag_.error(id->offset, std::string(action) + " of moved value '" +
                                std::string(id->name) + "'");
    diag_.note(it->second, "'" + std::string(id->name) + "' was moved here");
  }

  // Is there a live loan on `id` that forbids this access?
  //   want_mut = false (read, &x):          blocked by a live &mut loan
  //   want_mut = true  (write, &mut x):     blocked by any live loan
  void check_conflicts(IdentExpr *id, bool want_mut, const char *verb,
                       const char *suffix) {
    for (const auto &[holder, loan_ids] : holds_) {
      const auto last = last_use_.find(holder);
      if (last == last_use_.end() || last->second <= id->offset)
        continue; // holder is done

      for (LoanId lid : loan_ids) {
        const Loan &loan = loans_[lid];
        if (loan.place != id->decl)
          continue;
        if (!want_mut && !loan.is_mut)
          continue; // reading during a shared borrow is fine

        const std::string name(id->name);
        diag_.error(id->offset, "cannot " + std::string(verb) + " '" + name +
                                    "'" + suffix + " while it is " +
                                    (loan.is_mut ? "mutably " : "") +
                                    "borrowed");
        diag_.note(loan.offset, "'" + name + "' was " +
                                    (loan.is_mut ? "mutably " : "") +
                                    "borrowed here");
        diag_.note(last->second, "the borrow is still used here");
        return; // one report per access is enough
      }
    }
  }
};
