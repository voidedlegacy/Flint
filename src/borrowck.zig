//! Borrow checker. Runs only on programs that passed name and type checks.
//!
//! Rule 1, moves:     a moved variable may not be used again.
//! Rule 2, aliasing:  while a borrow ("loan") of x is alive,
//!                      &x      -> x may be read, not written or &mut-borrowed
//!                      &mut x  -> x may not be touched at all
//!
//! A loan is alive while some variable holding it is still live: some path
//! from here reads it before overwriting it (like Rust's non-lexical
//! lifetimes). Liveness comes from the control-flow graph in cfg.zig.
//!
//!   var a = 1
//!   let m = &mut a     loan #0: &mut a, held by m
//!   a = 2              x  m is read below, so loan #0 is alive
//!   let k = m          last read of m: loan #0 ends here
//!   a = 3              ok
//!
//! State, one per graph node, merged where paths meet:
//!
//!   moved:  var -> offset of its first move
//!   holds:  var -> [loan ids carried by its value]
//!   loans:  [ {place, is_mut, offset}, ... ]   (by id, per function)
const std = @import("std");
const ast = @import("ast.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const Type = @import("types.zig").Type;
const cfg_mod = @import("cfg.zig");
const Cfg = cfg_mod.Cfg;
const NodeId = cfg_mod.NodeId;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Var = ast.Var;

const Error = std.mem.Allocator.Error;
const LoanId = u32;
const Loans = []const LoanId; // immutable, so states can share them

/// Copy types are duplicated on use; everything else is moved. Like Rust,
/// i64, bool and &T are Copy; &mut T is not, because two usable &mut to
/// the same place would break exclusivity.
pub fn isCopy(t: *const Type) bool {
    return switch (t.*) {
        .ref => |r| !r.is_mut,
        else => true,
    };
}

const Loan = struct {
    place: *const Var, // the variable being borrowed
    is_mut: bool,
    offset: u32, // where the & or &mut is
};

const State = struct {
    moved: std.AutoArrayHashMapUnmanaged(*const Var, u32) = .empty,
    holds: std.AutoArrayHashMapUnmanaged(*const Var, Loans) = .empty,
};

pub const BorrowChecker = struct {
    gpa: std.mem.Allocator,
    diag: *Diagnostics,
    // Per-function scratch memory: the graph, states, loan lists, maps.
    scratch: std.heap.ArenaAllocator,
    cfg: Cfg = .{},
    node: NodeId = 0, // the graph node being checked
    state: State = .{},
    loans: std.ArrayList(Loan) = .empty, // every loan, by id
    silent: bool = false, // true while finding the fixpoint

    pub fn init(gpa: std.mem.Allocator, diag: *Diagnostics) BorrowChecker {
        return .{ .gpa = gpa, .diag = diag, .scratch = .init(gpa) };
    }

    pub fn deinit(self: *BorrowChecker) void {
        self.scratch.deinit();
    }

    pub fn run(self: *BorrowChecker, fns: []*ast.FnDecl) Error!void {
        for (fns) |f| {
            _ = self.scratch.reset(.retain_capacity);
            self.state = .{};
            self.loans = .empty;
            self.cfg = try Cfg.build(self.a(), f);
            try self.checkFn();
        }
    }

    fn a(self: *BorrowChecker) std.mem.Allocator {
        return self.scratch.allocator();
    }

    // Nodes inside loops are checked several times on the way to the
    // fixpoint. Only the final pass may report, or errors would repeat.
    fn err(self: *BorrowChecker, offset: u32, comptime fmt: []const u8, args: anytype) void {
        if (!self.silent) self.diag.err(offset, fmt, args);
    }
    fn note(self: *BorrowChecker, offset: u32, comptime fmt: []const u8, args: anytype) void {
        if (!self.silent) self.diag.note(offset, fmt, args);
    }

    fn holdsOf(self: *BorrowChecker, v: *const Var) Error!Loans {
        const gop = try self.state.holds.getOrPut(self.a(), v);
        if (!gop.found_existing) gop.value_ptr.* = &.{};
        return gop.value_ptr.*;
    }

    fn setHolds(self: *BorrowChecker, v: *const Var, loans: Loans) Error!void {
        try self.state.holds.put(self.a(), v, loans);
    }

    // ------------------------------------------------------------ the graph

    // Forward dataflow over the graph. The state before a node is the
    // merge of the states after its predecessors:
    //
    //   entry --> [cond] --> [body] --+
    //               ^                 |   before(cond) = after(entry)
    //               +-----------------+                u after(body)
    //
    // Loops feed back, so sweep all nodes silently until no state changes
    // (states only grow, so this ends), then sweep once more for real.
    // Nodes nothing reaches (code after `return`) are not checked.
    fn checkFn(self: *BorrowChecker) Error!void {
        const nodes = self.cfg.nodes.items;
        const after = try self.a().alloc(?State, nodes.len); // null: not reached yet
        @memset(after, null);

        self.silent = true;
        var round: u32 = 0;
        while (round < 1000) : (round += 1) {
            var changed = false;
            for (0..nodes.len) |i| {
                if (!try self.enter(@intCast(i), after)) continue;
                try self.transfer();
                if (after[i] == null or !sameState(&after[i].?, &self.state)) {
                    after[i] = self.state;
                    changed = true;
                }
            }
            if (!changed) break;
        }
        self.silent = false;

        for (0..nodes.len) |i| {
            if (!try self.enter(@intCast(i), after)) continue;
            try self.transfer();
        }
    }

    /// Sets up the state before node `id`. False if nothing reaches it yet.
    fn enter(self: *BorrowChecker, id: NodeId, after: []const ?State) Error!bool {
        var reached = id == 0; // the entry
        var s: State = .{};
        for (self.cfg.nodes.items[id].preds.items) |p| {
            const from = &(after[p] orelse continue);
            try self.mergeInto(&s, from);
            reached = true;
        }
        self.node = id;
        self.state = s;
        return reached;
    }

    /// Applies one node to self.state.
    fn transfer(self: *BorrowChecker) Error!void {
        switch (self.cfg.nodes.items[self.node].kind) {
            .stmt => |s| try self.checkStmt(s),
            .cond => |e| _ = try self.eval(e),
            .join => {},
        }
    }

    // ------------------------------------------------------------ statements

    fn checkStmt(self: *BorrowChecker, s: *Stmt) Error!void {
        switch (s.data) {
            .var_decl => |*v| {
                const loans = try self.eval(v.init.?);
                // A fresh variable, even if this line ran before (in a loop).
                _ = self.state.moved.swapRemove(v);
                try self.setHolds(v, loans);
            },
            .ret => |value| {
                const e = value orelse return;
                // Every local (parameters included) dies when the function
                // returns, so a returned reference must not carry a loan.
                // References that came *in* through parameters carry none.
                const loans = try self.eval(e);
                if (loans.len > 0) {
                    const loan = self.loans.items[loans[0]];
                    const name = loan.place.name;
                    self.err(e.offset, "cannot return a reference to local variable '{s}'", .{name});
                    self.note(loan.offset, "'{s}' is borrowed here, and it stops existing when the function returns", .{name});
                }
            },
            .expr => |e| _ = try self.eval(e),
            .assign => |as| {
                const loans = try self.eval(as.value);
                switch (as.target.data) {
                    .ident => |id| {
                        try self.checkConflicts(as.target, true, "assign to", "");
                        _ = self.state.moved.swapRemove(id.decl.?); // fresh value: usable again
                        try self.setHolds(id.decl.?, loans); // old loans are dropped
                    },
                    .unary => |u| if (u.op == .star) {
                        // *r = e: e's loans flow into whatever r points at. r may
                        // point at several places, so add to each (never replace).
                        //
                        //   r --loan--> x        *r = &y   =>  x now also holds &y
                        const targets = try self.pointerLoans(u.operand, true, "assign through");
                        for (targets) |lid| {
                            const place = self.loans.items[lid].place;
                            try self.setHolds(place, try self.unionLoans(try self.holdsOf(place), loans));
                        }
                    },
                    else => {},
                }
            },
            // Control flow is in the graph's edges, not in these nodes.
            .if_, .for_, .block, .break_, .continue_ => unreachable,
        }
    }

    /// Adds everything in `from` to `into`: moved on either path = moved,
    /// and a variable may hold the loans from either path.
    fn mergeInto(self: *BorrowChecker, into: *State, from: *const State) Error!void {
        var mit = from.moved.iterator();
        while (mit.next()) |kv| {
            const gop = try into.moved.getOrPut(self.a(), kv.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = kv.value_ptr.*;
        }
        var hit = from.holds.iterator();
        while (hit.next()) |kv| {
            const gop = try into.holds.getOrPut(self.a(), kv.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = &.{};
            gop.value_ptr.* = try self.unionLoans(gop.value_ptr.*, kv.value_ptr.*);
        }
    }

    fn containsLoans(sub: *const State, sup: *const State) bool {
        var it = sub.holds.iterator();
        while (it.next()) |kv| {
            const other = sup.holds.get(kv.key_ptr.*) orelse &.{};
            for (kv.value_ptr.*) |lid| {
                if (std.mem.indexOfScalar(LoanId, other, lid) == null) return false;
            }
        }
        return true;
    }

    fn sameState(x: *const State, y: *const State) bool {
        if (x.moved.count() != y.moved.count()) return false;
        for (x.moved.keys()) |v| {
            if (!y.moved.contains(v)) return false;
        }
        // Same set of (var, loan) pairs.
        return containsLoans(x, y) and containsLoans(y, x);
    }

    // ------------------------------------------------------------ expressions

    /// Evaluates `e` by value and returns the loans its result carries.
    fn eval(self: *BorrowChecker, e: *Expr) Error!Loans {
        switch (e.data) {
            .int, .bool => return &.{},
            .ident => |id| {
                const decl = id.decl.?;
                self.requireNotMoved(e, "use");
                try self.checkConflicts(e, false, "use", "");
                if (isCopy(e.type)) return self.holdsOf(decl); // a copy keeps both
                // Move: the loans travel with the value and leave the variable.
                const gop = try self.state.moved.getOrPut(self.a(), decl);
                if (!gop.found_existing) gop.value_ptr.* = e.offset;
                const loans = try self.holdsOf(decl);
                try self.setHolds(decl, &.{});
                return loans;
            },
            .unary => |u| {
                if (u.op == .amp) return self.borrow(e, u);
                if (u.op == .star) return self.deref(e, u);
                _ = try self.eval(u.operand);
                return &.{};
            },
            .binary => |b| {
                try self.readOnly(b.lhs);
                try self.readOnly(b.rhs);
                return &.{}; // results are i64 or bool: no loans inside
            },
            .call => |c| return self.evalCall(c),
        }
    }

    // f(args)
    //
    // Flint has no lifetime annotations, so assume the worst: if f returns
    // a reference, it might point at anything its arguments point at, so
    // the result carries every argument's loans.
    //
    //   let r = first(&a, &b)    r holds loans on a AND b
    //   b = 3                    x  r might point at b
    //
    // If f returns no reference, nothing it was given can escape. A &mut
    // variable passed in is only lent for the call (a reborrow), so it
    // stays usable afterwards instead of being moved.
    fn evalCall(self: *BorrowChecker, c: Expr.Call) Error!Loans {
        const returns_ref = c.func.?.ret_type.isRef();
        const arg_loans = try self.a().alloc(Loans, c.args.len); // what each argument points at
        const reported = try self.a().alloc(bool, c.args.len);
        @memset(reported, false);
        var lent: std.ArrayList(*const Var) = .empty; // &mut variables lent to this call

        for (c.args, 0..) |arg, i| {
            const lent_mut_ref = !returns_ref and arg.data == .ident and arg.type.isMutRef();
            if (lent_mut_ref) {
                const decl = arg.data.ident.decl.?;
                try self.readOnly(arg); // checked like a read, but not moved
                if (std.mem.indexOfScalar(*const Var, lent.items, decl) != null) {
                    self.err(arg.offset, "cannot pass '{s}' twice in one call: a &mut must be the only way in", .{arg.data.ident.name});
                    reported[i] = true;
                }
                try lent.append(self.a(), decl);
                arg_loans[i] = try self.holdsOf(decl);
            } else {
                arg_loans[i] = try self.eval(arg);
            }
        }

        // Inside the callee all arguments are alive at once, so two of them
        // must not point at the same variable if either one is &mut.
        //   f(&mut a, &a)    x  the callee would see a through both
        var j: usize = 1;
        while (j < arg_loans.len) : (j += 1) {
            if (reported[j]) continue;
            for (0..j) |i| {
                if (self.clash(arg_loans[i], arg_loans[j])) |loan| {
                    const name = loan.place.name;
                    self.err(c.args[j].offset, "cannot pass two references to '{s}' into one call when one of them is &mut", .{name});
                    self.note(c.args[i].offset, "the other reference to '{s}' is passed here", .{name});
                    break; // one report per argument is enough
                }
            }
        }

        if (!returns_ref) return &.{};
        var result: std.ArrayList(LoanId) = .empty;
        for (arg_loans) |loans| try result.appendSlice(self.a(), loans);
        return result.items;
    }

    fn clash(self: *const BorrowChecker, xs: Loans, ys: Loans) ?Loan {
        for (xs) |x| {
            for (ys) |y| {
                const lx = self.loans.items[x];
                const ly = self.loans.items[y];
                if (lx.place == ly.place and (lx.is_mut or ly.is_mut)) return lx;
            }
        }
        return null;
    }

    /// Operands of operators are read, never moved.
    fn readOnly(self: *BorrowChecker, e: *Expr) Error!void {
        if (e.data == .ident) {
            self.requireNotMoved(e, "use");
            try self.checkConflicts(e, false, "use", "");
        } else {
            _ = try self.eval(e);
        }
    }

    /// &x or &mut x: creates a new loan on x.
    fn borrow(self: *BorrowChecker, e: *Expr, u: Expr.Unary) Error!Loans {
        if (derefPointer(u.operand)) |ptr| {
            // &*r and &mut *r point where r points: no new loan, same places.
            return self.pointerLoans(ptr, u.is_mut, "reborrow");
        }
        if (u.operand.data != .ident) {
            _ = try self.eval(u.operand); // borrowing a temporary like &(1 + 2)
            return &.{};
        }
        const id = u.operand.data.ident;
        const decl = id.decl.?;
        self.requireNotMoved(u.operand, "borrow");

        if (u.is_mut and !decl.is_mut) {
            self.err(u.operand.offset, "cannot borrow '{s}' as mutable: it was declared with 'let'", .{id.name});
        }
        try self.checkConflicts(u.operand, u.is_mut, "borrow", if (u.is_mut) " as mutable" else "");

        const one = try self.a().alloc(LoanId, 1);
        // A loop body runs this line again on every pass of the fixpoint.
        // Reuse the loan created here last time, so the state can settle.
        for (self.loans.items, 0..) |loan, lid| {
            if (loan.offset == e.offset) {
                one[0] = @intCast(lid);
                return one;
            }
        }
        try self.loans.append(self.a(), .{ .place = decl, .is_mut = u.is_mut, .offset = e.offset });
        one[0] = @intCast(self.loans.items.len - 1);
        return one;
    }

    /// *r: reads the value r points at. The result carries the loans held
    /// by the places r points at (r --loan--> x, result = holds[x]).
    fn deref(self: *BorrowChecker, e: *Expr, u: Expr.Unary) Error!Loans {
        const targets = try self.pointerLoans(u.operand, false, "use");
        if (!isCopy(e.type)) {
            // A &mut behind a reference can't be copied, and taking it out
            // would leave the place it came from without a value.
            self.err(e.offset, "cannot move a '{f}' out from behind a reference", .{e.type});
        }
        var result: Loans = &.{};
        for (targets) |lid| result = try self.unionLoans(result, try self.holdsOf(self.loans.items[lid].place));
        return result;
    }

    /// Evaluates the pointer in *p or &*p and returns its loans (the places
    /// it points at). A variable is used, not moved: going through a &mut
    /// doesn't use it up. want_mut: writing through it needs no live loan on p.
    fn pointerLoans(self: *BorrowChecker, p: *Expr, want_mut: bool, verb: []const u8) Error!Loans {
        if (p.data != .ident) return self.eval(p);
        self.requireNotMoved(p, "use");
        try self.checkConflicts(p, want_mut, verb, "");
        return self.holdsOf(p.data.ident.decl.?);
    }

    fn unionLoans(self: *BorrowChecker, xs: Loans, ys: Loans) Error!Loans {
        var out: std.ArrayList(LoanId) = .empty;
        try out.appendSlice(self.a(), xs);
        for (ys) |lid| {
            if (std.mem.indexOfScalar(LoanId, out.items, lid) == null) try out.append(self.a(), lid);
        }
        return out.items;
    }

    // ------------------------------------------------------------ the rules

    /// Does `loans` include one on `place` that this access conflicts with?
    fn holdsMatter(self: *const BorrowChecker, loans: Loans, place: *const Var, want_mut: bool) bool {
        for (loans) |lid| {
            const loan = self.loans.items[lid];
            if (loan.place == place and (want_mut or loan.is_mut)) return true;
        }
        return false;
    }

    fn requireNotMoved(self: *BorrowChecker, e: *const Expr, action: []const u8) void {
        const where = self.state.moved.get(e.data.ident.decl.?) orelse return;
        const name = e.data.ident.name;
        self.err(e.offset, "{s} of moved value '{s}'", .{ action, name });
        // A move *after* this use in the source can only have happened on
        // an earlier trip around a loop.
        self.note(where, "'{s}' was moved here{s}", .{
            name,
            if (where >= e.offset) ", in the previous iteration of the loop" else "",
        });
    }

    /// Is there a live loan on the variable `e` names that forbids this access?
    ///   want_mut = false (read, &x):      blocked by a live &mut loan
    ///   want_mut = true  (write, &mut x): blocked by any live loan
    fn checkConflicts(self: *BorrowChecker, e: *const Expr, want_mut: bool, verb: []const u8, suffix: []const u8) Error!void {
        const decl = e.data.ident.decl.?;
        // Reads this node has done, counting e itself. An assignment target
        // isn't a read: it comes after all of them.
        const done = if (self.cfg.use_pos.get(e)) |i| i + 1 else self.cfg.nodes.items[self.node].uses.len;
        var it = self.state.holds.iterator();
        while (it.next()) |kv| {
            if (!self.holdsMatter(kv.value_ptr.*, decl, want_mut)) continue;
            const later = try self.cfg.nextUse(self.a(), self.node, done, kv.key_ptr.*) orelse continue; // the holder is done

            for (kv.value_ptr.*) |lid| {
                const loan = self.loans.items[lid];
                if (loan.place != decl) continue;
                if (!want_mut and !loan.is_mut) continue; // reading during a shared borrow is fine

                const name = e.data.ident.name;
                const mutably = if (loan.is_mut) "mutably " else "";
                self.err(e.offset, "cannot {s} '{s}'{s} while it is {s}borrowed", .{ verb, name, suffix, mutably });
                self.note(loan.offset, "'{s}' was {s}borrowed here", .{ name, mutably });
                self.note(later, "the borrow is still used here", .{});
                return; // one report per access is enough
            }
        }
    }
};

/// For `*p`, returns p. Otherwise null.
fn derefPointer(e: *Expr) ?*Expr {
    return switch (e.data) {
        .unary => |u| if (u.op == .star) u.operand else null,
        else => null,
    };
}
