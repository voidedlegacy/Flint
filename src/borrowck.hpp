#pragma once
#include "ast.hpp"
#include "diag.hpp"
#include "types.hpp"
#include <algorithm>
#include <cstdint>
#include <span>
#include <string>
#include <unordered_map>
#include <unordered_set>
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
// (like Rust's non-lexical lifetimes). "Later" is measured by source
// offset, with one twist for loops: a use inside a loop body happens
// again on the next iteration, so it counts as a use at the loop's end.
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
      state_ = {};
      loans_.clear();
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

  // Everything that changes as we walk through the code. Branches and
  // loops copy it, check each path, and merge the copies back together.
  struct State {
    std::unordered_map<const VarStmt *, std::uint32_t>
        moved; // var → where it was moved
    std::unordered_map<const VarStmt *, std::vector<LoanId>>
        holds; // var → loans inside its value
  };

  struct LoopRange {
    std::uint32_t start; // offset of `for`
    std::uint32_t end;   // offset of the body's closing `}`
  };

  Diagnostics &diag_;
  State state_;
  std::vector<Loan> loans_; // every loan, by id
  std::unordered_map<const VarStmt *, std::uint32_t>
      last_use_;                 // var → offset of its last read
  std::vector<LoopRange> loops_; // loops we are inside (pre-pass)
  bool silent_ = false;          // true while finding a loop's fixpoint

  // While a loop is being analysed to a fixpoint, the body is walked
  // several times. Only the final walk may report, or errors would repeat.
  void error(std::uint32_t offset, const std::string &msg) {
    if (!silent_)
      diag_.error(offset, msg);
  }
  void note(std::uint32_t offset, const std::string &msg) {
    if (!silent_)
      diag_.note(offset, msg);
  }

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
    case StmtKind::If: {
      auto *i = cast<IfStmt>(s);
      record_last_uses(i->cond);
      record_last_uses(i->then_block);
      if (i->else_stmt)
        record_last_uses(i->else_stmt);
      break;
    }
    case StmtKind::For: {
      auto *f = cast<ForStmt>(s);
      loops_.push_back({f->offset, f->body->end_offset});
      record_last_uses(f->cond);
      record_last_uses(f->body);
      loops_.pop_back();
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
    case ExprKind::Bool:
      break;
    case ExprKind::Ident: {
      auto *id = cast<IdentExpr>(e);
      std::uint32_t when = id->offset;
      // Inside a loop, a variable from outside the loop is used again
      // on the next iteration: treat it as used at the loop's end.
      //
      //   var r = &a
      //   for c {
      //       let x = r    ← runs again after `a = 5` below
      //       a = 5        ✗ r is still alive here
      //   }
      for (const LoopRange &loop : loops_) {
        if (id->decl->offset < loop.start)
          when = std::max(when, loop.end);
      }
      auto &last = last_use_[id->decl];
      if (when > last)
        last = when;
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
      state_.holds[v] = eval(v->init);
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
        state_.moved.erase(id->decl);              // fresh value: usable again
        state_.holds[id->decl] = std::move(loans); // old loans are dropped
      }
      break;
    }
    case StmtKind::If:
      check_if(cast<IfStmt>(s));
      break;
    case StmtKind::For:
      check_for(cast<ForStmt>(s));
      break;
    case StmtKind::Block:
      for (Stmt *child : cast<BlockStmt>(s)->stmts)
        check_stmt(child);
      break;
    }
  }

  // Adds everything in `from` to `into`: moved on either path = moved,
  // and a variable may hold the loans from either path.
  static void merge_into(State &into, const State &from) {
    for (const auto &[var, where] : from.moved)
      into.moved.try_emplace(var, where);
    for (const auto &[var, loans] : from.holds) {
      auto &merged = into.holds[var];
      for (LoanId lid : loans) {
        if (std::find(merged.begin(), merged.end(), lid) == merged.end()) {
          merged.push_back(lid);
        }
      }
    }
  }

  static bool same_state(const State &a, const State &b) {
    if (a.moved.size() != b.moved.size())
      return false;
    for (const auto &[var, where] : a.moved) {
      if (!b.moved.contains(var))
        return false;
    }
    auto loan_set = [](const State &s) {
      std::unordered_set<std::uint64_t> out; // (var, loan) pairs
      for (const auto &[var, loans] : s.holds) {
        for (LoanId lid : loans) {
          out.insert(reinterpret_cast<std::uintptr_t>(var) * 31 + lid);
        }
      }
      return out;
    };
    return loan_set(a) == loan_set(b);
  }

  //              state S
  //          ┌──────┴──────┐
  //    then: S → T    else: S → E
  //          └──────┬──────┘
  //          after: T ∪ E
  void check_if(IfStmt *i) {
    eval(i->cond);
    const State before = state_;

    check_stmt(i->then_block);
    State after_then = std::move(state_);

    state_ = before;
    if (i->else_stmt)
      check_stmt(i->else_stmt);
    merge_into(state_, after_then);
  }

  // A loop body can run many times, so the state at the top of the body
  // is "the state before the loop, OR the state after any number of
  // iterations". We find it by repeating the body until nothing changes
  // (a *fixpoint*), silently, then check it once more for real.
  //
  //   entry ──▶ [cond] ──▶ [body] ──┐
  //               ▲                 │   top = entry ∪ end-of-body
  //               └─────────────────┘
  void check_for(ForStmt *f) {
    const State entry = state_;
    State top = entry;

    const bool was_silent = silent_;
    silent_ = true;
    for (int round = 0; round < 32;
         ++round) { // states only grow, so this ends fast
      state_ = top;
      eval(f->cond);
      check_stmt(f->body);
      State next = entry;
      merge_into(next, state_);
      if (same_state(next, top))
        break;
      top = std::move(next);
    }
    silent_ = was_silent;

    // The reporting pass, starting from the fixpoint.
    state_ = top;
    eval(f->cond);
    check_stmt(f->body);

    // The loop exits after the condition, from the top-of-loop state.
    merge_into(state_, top);
  }

  // ------------------------------------------------------------ expressions

  // Evaluates `e` by value and returns the loans carried by the result.
  std::vector<LoanId> eval(Expr *e) {
    switch (e->kind) {
    case ExprKind::Int:
    case ExprKind::Bool:
      return {};
    case ExprKind::Ident: {
      auto *id = cast<IdentExpr>(e);
      require_not_moved(id, "use");
      check_conflicts(id, /*want_mut=*/false, "use", "");
      if (is_copy(id->type))
        return state_.holds[id->decl]; // copy keeps both
      // Move: the loans travel with the value and leave the old variable.
      state_.moved.try_emplace(id->decl, id->offset);
      std::vector<LoanId> loans = std::move(state_.holds[id->decl]);
      state_.holds[id->decl].clear();
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
      error(id->offset, "cannot borrow '" + std::string(id->name) +
                            "' as mutable: it was declared with 'let'");
    }
    check_conflicts(id, u->is_mut, "borrow", u->is_mut ? " as mutable" : "");

    // A loop body runs this line again on every pass of the fixpoint.
    // Reuse the loan created here last time, so the state can settle.
    for (LoanId lid = 0; lid < loans_.size(); ++lid) {
      if (loans_[lid].offset == u->offset)
        return {lid};
    }
    loans_.push_back({id->decl, u->is_mut, u->offset});
    return {static_cast<LoanId>(loans_.size() - 1)};
  }

  // ------------------------------------------------------------ the rules

  void require_not_moved(IdentExpr *id, const char *action) {
    const auto it = state_.moved.find(id->decl);
    if (it == state_.moved.end())
      return;
    const std::string name(id->name);
    error(id->offset, std::string(action) + " of moved value '" + name + "'");
    // A move *after* this use in the source can only have happened on
    // an earlier trip around a loop.
    note(it->second, "'" + name + "' was moved here" +
                         (it->second >= id->offset
                              ? ", in the previous iteration of the loop"
                              : ""));
  }

  // Is there a live loan on `id` that forbids this access?
  //   want_mut = false (read, &x):          blocked by a live &mut loan
  //   want_mut = true  (write, &mut x):     blocked by any live loan
  void check_conflicts(IdentExpr *id, bool want_mut, const char *verb,
                       const char *suffix) {
    for (const auto &[holder, loan_ids] : state_.holds) {
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
        error(id->offset, "cannot " + std::string(verb) + " '" + name + "'" +
                              suffix + " while it is " +
                              (loan.is_mut ? "mutably " : "") + "borrowed");
        note(loan.offset, "'" + name + "' was " +
                              (loan.is_mut ? "mutably " : "") +
                              "borrowed here");
        note(last->second, "the borrow is still used here");
        return; // one report per access is enough
      }
    }
  }
};
