//! Semantic checker. One walk over each function that:
//!   1. links every identifier to the `var`/`let` that declared it,
//!   2. gives every expression and variable a type,
//!   3. enforces the rules: no undeclared names, no same-scope
//!      redeclaration, no assigning to `let`, operand types must fit.
//!
//! Types flow up from the leaves, with one exception: an integer literal
//! has no type of its own and takes the one its context asks for (the
//! `hint`), so `putchar(10)` passes an i32. With no integer hint it is
//! an i64. There are no implicit conversions between integer types.
const std = @import("std");
const ast = @import("ast.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const types = @import("types.zig");
const Type = types.Type;
const TypeTable = types.TypeTable;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

const Error = std.mem.Allocator.Error;

pub const Checker = struct {
    arena: std.mem.Allocator,
    diag: *Diagnostics,
    types: *TypeTable,
    functions: std.StringHashMapUnmanaged(*ast.FnDecl) = .empty, // every fn, by name
    current_fn: *ast.FnDecl = undefined, // whose body we are checking
    loop_depth: u32 = 0, // how many loops we are inside, for break/continue

    //   symbols:      [ a | b | a | x ]
    //   scope_starts:   ^0      ^2        -> inner scope holds "a", "x"
    symbols: std.ArrayList(*ast.Var) = .empty, // every visible name, innermost last
    scope_starts: std.ArrayList(usize) = .empty,

    pub fn init(arena: std.mem.Allocator, diag: *Diagnostics, tt: *TypeTable) Checker {
        return .{ .arena = arena, .diag = diag, .types = tt };
    }

    pub fn run(self: *Checker, fns: []*ast.FnDecl) Error!void {
        // Pass 1: every signature, so bodies can call in any order.
        for (fns) |f| try self.checkSignature(f);

        // Pass 2: every body.
        for (fns) |f| {
            self.current_fn = f;
            try self.pushScope();
            for (f.params) |p| try self.declare(p); // parameters are `let`
            const body = f.body orelse { // extern: C has the body
                self.popScope();
                continue;
            };
            try self.checkStmt(body);
            self.popScope();

            if (f.ret_type != self.types.voidType() and f.ret_type != self.types.err() and !alwaysReturns(body)) {
                self.diag.err(body.endOffset(), "function '{s}' must return a '{f}' on every path", .{ f.name, f.ret_type });
            }
        }
    }

    // ------------------------------------------------------------ functions

    fn checkSignature(self: *Checker, f: *ast.FnDecl) Error!void {
        const gop = try self.functions.getOrPut(self.arena, f.name);
        if (gop.found_existing) {
            self.diag.err(f.offset, "function '{s}' is already defined", .{f.name});
        } else {
            gop.value_ptr.* = f;
        }
        for (f.params) |p| p.type = try self.resolveType(p.type_syntax.?);
        f.ret_type = if (f.ret_syntax) |r| try self.resolveType(r) else self.types.voidType();

        if (std.mem.eql(u8, f.name, "main")) {
            // The C entry point is already called main.
            if (f.isExtern()) {
                self.diag.err(f.offset, "'main' cannot be extern: it must be the 'fn main' the program starts in", .{});
                return;
            }
            if (f.params.len != 0) self.diag.err(f.offset, "'main' must not take parameters", .{});
            if (f.ret_type != self.types.voidType() and f.ret_type != self.types.int()) {
                self.diag.err(f.ret_syntax.?.offset, "'main' must return 'i64' or nothing", .{});
            }
        }
    }

    /// Turns written syntax like `&mut i64` into the one shared *const Type.
    fn resolveType(self: *Checker, t: *const ast.TypeRef) Error!*const Type {
        if (t.pointee) |p| return self.types.ref(try self.resolveType(p), t.is_mut);
        if (std.mem.eql(u8, t.name, "i64")) return self.types.int();
        if (std.mem.eql(u8, t.name, "i32")) return self.types.int32();
        if (std.mem.eql(u8, t.name, "bool")) return self.types.boolean();
        if (std.mem.eql(u8, t.name, "<error>")) return self.types.err(); // parser reported it
        self.diag.err(t.offset, "unknown type '{s}'", .{t.name});
        return self.types.err();
    }

    /// Can control reach the end of `s`? If not, `s` always returns.
    ///   return          -> always returns
    ///   { a; b; c }     -> if any statement always returns
    ///   if/else         -> only if BOTH branches always return
    ///   for { }         -> a loop with no exit never falls through,
    ///                      unless a `break` gets out of it
    fn alwaysReturns(s: *const Stmt) bool {
        return switch (s.data) {
            .ret => true,
            .block => |b| for (b.stmts) |child| {
                if (alwaysReturns(child)) break true;
            } else false,
            .if_ => |i| if (i.else_stmt) |e| alwaysReturns(i.then_block) and alwaysReturns(e) else false,
            .for_ => |f| switch (f.cond.data) {
                .bool => |v| v and !breaksOut(f.body),
                else => false,
            },
            else => false,
        };
    }

    /// Does `s` contain a `break` that leaves the loop around it? A break
    /// inside a nested loop only leaves that inner loop.
    fn breaksOut(s: *const Stmt) bool {
        return switch (s.data) {
            .break_ => true,
            .block => |b| for (b.stmts) |child| {
                if (breaksOut(child)) break true;
            } else false,
            .if_ => |i| breaksOut(i.then_block) or (if (i.else_stmt) |e| breaksOut(e) else false),
            else => false, // includes .for_: its breaks are its own
        };
    }

    // ------------------------------------------------------------ scopes

    fn pushScope(self: *Checker) Error!void {
        try self.scope_starts.append(self.arena, self.symbols.items.len);
    }

    fn popScope(self: *Checker) void {
        self.symbols.shrinkRetainingCapacity(self.scope_starts.pop().?); // forget inner names
    }

    fn declare(self: *Checker, v: *ast.Var) Error!void {
        // Only the current scope counts as a clash; outer names may be shadowed.
        const start = self.scope_starts.items[self.scope_starts.items.len - 1];
        for (self.symbols.items[start..]) |sym| {
            if (std.mem.eql(u8, sym.name, v.name)) {
                self.diag.err(v.offset, "'{s}' is already declared in this scope", .{v.name});
                return;
            }
        }
        try self.symbols.append(self.arena, v);
    }

    fn lookup(self: *const Checker, name: []const u8) ?*ast.Var {
        var i = self.symbols.items.len;
        while (i > 0) { // innermost first
            i -= 1;
            if (std.mem.eql(u8, self.symbols.items[i].name, name)) return self.symbols.items[i];
        }
        return null;
    }

    // ------------------------------------------------------------ statements

    fn checkStmt(self: *Checker, s: *Stmt) Error!void {
        switch (s.data) {
            .var_decl => |*v| {
                v.type = try self.checkExpr(v.init.?, null); // before declare: `var x = x` is an error
                if (v.type == self.types.voidType()) {
                    self.diag.err(v.init.?.offset, "this call returns nothing, so there is no value to store", .{});
                    v.type = self.types.err();
                }
                try self.declare(v);
            },
            .ret => |value| {
                const ret = self.current_fn.ret_type;
                const e = value orelse {
                    if (ret != self.types.voidType() and ret != self.types.err()) {
                        self.diag.err(s.offset, "missing return value", .{});
                    }
                    return;
                };
                const got = try self.checkExpr(e, ret);
                if (ret == self.types.voidType()) {
                    self.diag.err(e.offset, "'{s}' does not return a value", .{self.current_fn.name});
                    return;
                }
                _ = self.expectType(e, got, ret);
            },
            .expr => |e| _ = try self.checkExpr(e, null),
            .assign => |a| {
                // The target goes first, so `x = 5` knows what type 5 is.
                const target = try self.checkExpr(a.target, null);
                const value = try self.checkExpr(a.value, target);
                self.checkAssignTarget(a.target);
                _ = self.expectType(a.value, value, target);
            },
            .for_ => |f| {
                _ = self.expectType(f.cond, try self.checkExpr(f.cond, self.types.boolean()), self.types.boolean());
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkStmt(f.body);
            },
            .break_, .continue_ => if (self.loop_depth == 0) {
                self.diag.err(s.offset, "'{s}' outside of a loop", .{if (s.data == .break_) "break" else "continue"});
            },
            .if_ => |i| {
                _ = self.expectType(i.cond, try self.checkExpr(i.cond, self.types.boolean()), self.types.boolean());
                try self.checkStmt(i.then_block);
                if (i.else_stmt) |e| try self.checkStmt(e);
            },
            .block => |b| {
                try self.pushScope();
                for (b.stmts) |child| try self.checkStmt(child);
                self.popScope();
            },
        }
    }

    /// You may assign to a `var`, or write through a `&mut` with `*r = e`.
    fn checkAssignTarget(self: *Checker, target: *Expr) void {
        if (derefPointer(target)) |ptr| {
            if (ptr.type.isRef() and !ptr.type.isMutRef()) {
                self.diag.err(target.offset, "cannot assign through a shared reference '{f}' (use '&mut' to write through it)", .{ptr.type});
            }
            return; // a non-reference was already reported by the deref itself
        }
        switch (target.data) {
            .ident => |id| if (id.decl) |d| {
                if (!d.is_mut) {
                    self.diag.err(target.offset, "cannot assign to '{s}': it was declared with 'let' (use 'var' to make it mutable)", .{id.name});
                }
            },
            else => self.diag.err(target.offset, "can only assign to a variable", .{}),
        }
    }

    /// For `*p`, returns p. Otherwise null.
    fn derefPointer(e: *Expr) ?*Expr {
        return switch (e.data) {
            .unary => |u| if (u.op == .star) u.operand else null,
            else => null,
        };
    }

    // ------------------------------------------------------------ expressions

    /// Computes the type of `e`, stores it in e.type, and returns it.
    /// `hint` is the type the code around `e` wants, if it knows one. Only
    /// integer literals use it, and it never causes an error by itself:
    /// a mismatch is reported by whoever asked for the type.
    fn checkExpr(self: *Checker, e: *Expr, hint: ?*const Type) Error!*const Type {
        e.type = try self.computeType(e, hint);
        return e.type;
    }

    fn computeType(self: *Checker, e: *Expr, hint: ?*const Type) Error!*const Type {
        const tt = self.types;
        switch (e.data) {
            .int => |v| {
                const t = self.literalType(hint);
                self.checkLiteral(e, t, v, false);
                return t;
            },
            .bool => return tt.boolean(),
            .ident => |*id| {
                id.decl = self.lookup(id.name);
                const d = id.decl orelse {
                    self.diag.err(e.offset, "undeclared name '{s}'", .{id.name});
                    return tt.err();
                };
                return d.type;
            },
            .unary => |u| {
                if (u.op == .amp) {
                    // &5 where a &i32 is wanted: the 5 is an i32.
                    const pointee: ?*const Type = if (hint) |h| switch (h.*) {
                        .ref => |r| r.pointee,
                        else => null,
                    } else null;
                    const operand = try self.checkExpr(u.operand, pointee);
                    // &mut *r would let you write through r, so r must be &mut.
                    if (u.is_mut) {
                        if (derefPointer(u.operand)) |ptr| {
                            if (ptr.type.isRef() and !ptr.type.isMutRef()) {
                                self.diag.err(e.offset, "cannot borrow as mutable through a shared reference '{f}'", .{ptr.type});
                            }
                        }
                    }
                    return tt.ref(operand, u.is_mut);
                }
                if (u.op == .star) {
                    // *r gives the value r points at.
                    const operand = try self.checkExpr(u.operand, null);
                    return switch (operand.*) {
                        .ref => |r| r.pointee,
                        .err => tt.err(),
                        else => blk: {
                            self.diag.err(e.offset, "cannot dereference a value of type '{f}'", .{operand});
                            break :blk tt.err();
                        },
                    };
                }
                if (u.op == .bang) {
                    // !x needs a bool and gives a bool.
                    const operand = try self.checkExpr(u.operand, tt.boolean());
                    if (!self.expectType(u.operand, operand, tt.boolean())) return tt.err();
                    return tt.boolean();
                }
                // unary minus. -2147483648 is an i32 although 2147483648
                // alone is not, so a negated literal is checked as a whole.
                if (u.operand.data == .int) {
                    const t = self.literalType(hint);
                    u.operand.type = t;
                    self.checkLiteral(e, t, u.operand.data.int, true);
                    return t;
                }
                const operand = try self.checkExpr(u.operand, hint);
                const want = if (operand.isInt()) operand else tt.int();
                if (!self.expectType(u.operand, operand, want)) return tt.err();
                return want;
            },
            .binary => |b| {
                if (b.op == .amp_amp or b.op == .pipe_pipe) {
                    // && and || need bool on both sides, and give bool.
                    const lhs = try self.checkExpr(b.lhs, tt.boolean());
                    const rhs = try self.checkExpr(b.rhs, tt.boolean());
                    const ok_l = self.expectType(b.lhs, lhs, tt.boolean());
                    const ok_r = self.expectType(b.rhs, rhs, tt.boolean());
                    if (!(ok_l and ok_r)) return tt.err();
                    return tt.boolean();
                }
                // A comparison gives a bool whatever it compares, so the
                // hint says nothing about its operands.
                const operand_hint = if (b.op.isComparison()) null else hint;
                // One side's type decides a literal on the other side:
                //   n + 1,  1 + n,  48 + n * 2    are all i32 when n is.
                // So if only the left side is a bare literal, do the right first.
                var lhs: *const Type = undefined;
                var rhs: *const Type = undefined;
                if (isLiteral(b.lhs) and !isLiteral(b.rhs)) {
                    rhs = try self.checkExpr(b.rhs, operand_hint);
                    lhs = try self.checkExpr(b.lhs, rhs);
                } else {
                    lhs = try self.checkExpr(b.lhs, operand_hint);
                    rhs = try self.checkExpr(b.rhs, lhs);
                }
                if (b.op == .eq_eq or b.op == .not_eq) {
                    // == and != need both sides to have the same type, and give bool.
                    if (!self.expectType(b.rhs, rhs, lhs)) return tt.err();
                    return tt.boolean();
                }
                // < <= > >= compare two integers of the same type and give bool.
                // + - * / need two integers of the same type, and give that type.
                const want = if (lhs.isInt()) lhs else tt.int();
                const ok_l = self.expectType(b.lhs, lhs, want);
                const ok_r = self.expectType(b.rhs, rhs, want);
                if (!(ok_l and ok_r)) return tt.err();
                return if (b.op.isComparison()) tt.boolean() else want;
            },
            .call => |*c| return self.checkCall(e, c),
        }
    }

    /// The type an integer literal takes: the hint if it is an integer type.
    fn literalType(self: *const Checker, hint: ?*const Type) *const Type {
        if (hint) |h| if (h.isInt()) return h;
        return self.types.int();
    }

    /// An i32 literal must fit in 32 bits. (An i64 literal too big for u64
    /// already became 0 in the parser, like the C++ version.)
    fn checkLiteral(self: *Checker, e: *const Expr, t: *const Type, v: u64, negated: bool) void {
        if (t.* != .i32) return;
        const limit: u64 = if (negated) 1 << 31 else (1 << 31) - 1;
        if (v > limit) {
            self.diag.err(e.offset, "integer literal '{s}{d}' does not fit in 'i32'", .{ if (negated) "-" else "", v });
        }
    }

    /// An expression made only of integer literals, like 7, -1 or 2 * 3.
    /// Its type comes from the context instead of from itself.
    fn isLiteral(e: *const Expr) bool {
        return switch (e.data) {
            .int => true,
            .unary => |u| u.op == .minus and isLiteral(u.operand),
            .binary => |b| switch (b.op) {
                .plus, .minus, .star, .slash => isLiteral(b.lhs) and isLiteral(b.rhs),
                else => false,
            },
            else => false,
        };
    }

    /// name(args): the function must exist, and each argument must match
    /// its parameter's type. The call's type is the function's return type.
    fn checkCall(self: *Checker, e: *Expr, c: *Expr.Call) Error!*const Type {
        const f = self.functions.get(c.name) orelse {
            self.diag.err(e.offset, "undeclared function '{s}'", .{c.name});
            for (c.args) |arg| _ = try self.checkExpr(arg, null);
            return self.types.err();
        };
        c.func = f;
        if (c.args.len != f.params.len) {
            self.diag.err(e.offset, "'{s}' takes {d} argument(s), but got {d}", .{ c.name, f.params.len, c.args.len });
        }
        for (c.args, 0..) |arg, i| {
            const param: ?*const Type = if (i < f.params.len) f.params[i].type else null;
            const got = try self.checkExpr(arg, param);
            if (param) |p| _ = self.expectType(arg, got, p);
        }
        return f.ret_type;
    }

    /// Reports a mismatch unless `actual` is `expected`. Error types never
    /// report again: the real problem was already printed.
    fn expectType(self: *Checker, where: *const Expr, actual: *const Type, expected: *const Type) bool {
        if (actual == expected) return true;
        if (actual == self.types.err() or expected == self.types.err()) return false;
        self.diag.err(where.offset, "expected '{f}', found '{f}'", .{ expected, actual });
        return false;
    }
};
