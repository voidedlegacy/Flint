//! Semantic checker. One walk over each function that:
//!   1. links every identifier to the `var`/`let` that declared it,
//!   2. gives every expression and variable a type,
//!   3. enforces the rules: no undeclared names, no same-scope
//!      redeclaration, no assigning to `let`, operand types must fit.
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
            try self.checkStmt(f.body);
            self.popScope();

            if (f.ret_type != self.types.voidType() and f.ret_type != self.types.err() and !alwaysReturns(f.body)) {
                self.diag.err(f.body.endOffset(), "function '{s}' must return a '{f}' on every path", .{ f.name, f.ret_type });
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
        if (std.mem.eql(u8, t.name, "bool")) return self.types.boolean();
        if (std.mem.eql(u8, t.name, "<error>")) return self.types.err(); // parser reported it
        self.diag.err(t.offset, "unknown type '{s}'", .{t.name});
        return self.types.err();
    }

    /// Can control reach the end of `s`? If not, `s` always returns.
    ///   return          -> always returns
    ///   { a; b; c }     -> if any statement always returns
    ///   if/else         -> only if BOTH branches always return
    ///   for { }         -> a loop with no exit never falls through
    fn alwaysReturns(s: *const Stmt) bool {
        return switch (s.data) {
            .ret => true,
            .block => |b| for (b.stmts) |child| {
                if (alwaysReturns(child)) break true;
            } else false,
            .if_ => |i| if (i.else_stmt) |e| alwaysReturns(i.then_block) and alwaysReturns(e) else false,
            .for_ => |f| switch (f.cond.data) {
                .bool => |v| v,
                else => false,
            },
            else => false,
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
                v.type = try self.checkExpr(v.init.?); // before declare: `var x = x` is an error
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
                const got = try self.checkExpr(e);
                if (ret == self.types.voidType()) {
                    self.diag.err(e.offset, "'{s}' does not return a value", .{self.current_fn.name});
                    return;
                }
                _ = self.expectType(e, got, ret);
            },
            .expr => |e| _ = try self.checkExpr(e),
            .assign => |a| {
                const value = try self.checkExpr(a.value);
                const target = try self.checkExpr(a.target);
                self.checkAssignTarget(a.target);
                _ = self.expectType(a.value, value, target);
            },
            .for_ => |f| {
                _ = self.expectType(f.cond, try self.checkExpr(f.cond), self.types.boolean());
                try self.checkStmt(f.body);
            },
            .if_ => |i| {
                _ = self.expectType(i.cond, try self.checkExpr(i.cond), self.types.boolean());
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
    fn checkExpr(self: *Checker, e: *Expr) Error!*const Type {
        e.type = try self.computeType(e);
        return e.type;
    }

    fn computeType(self: *Checker, e: *Expr) Error!*const Type {
        const tt = self.types;
        switch (e.data) {
            .int => return tt.int(),
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
                const operand = try self.checkExpr(u.operand);
                if (u.op == .amp) {
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
                    return switch (operand.*) {
                        .ref => |r| r.pointee,
                        .err => tt.err(),
                        else => blk: {
                            self.diag.err(e.offset, "cannot dereference a value of type '{f}'", .{operand});
                            break :blk tt.err();
                        },
                    };
                }
                // unary minus
                if (!self.expectType(u.operand, operand, tt.int())) return tt.err();
                return tt.int();
            },
            .binary => |b| {
                const lhs = try self.checkExpr(b.lhs);
                const rhs = try self.checkExpr(b.rhs);
                if (b.op == .eq_eq or b.op == .not_eq) {
                    // == and != need both sides to have the same type, and give bool.
                    if (!self.expectType(b.rhs, rhs, lhs)) return tt.err();
                    return tt.boolean();
                }
                // < <= > >= compare two i64 and give bool.
                // + - * / need i64 on both sides, and give i64.
                const ok_l = self.expectType(b.lhs, lhs, tt.int());
                const ok_r = self.expectType(b.rhs, rhs, tt.int());
                if (!(ok_l and ok_r)) return tt.err();
                return if (b.op.isComparison()) tt.boolean() else tt.int();
            },
            .call => |*c| return self.checkCall(e, c),
        }
    }

    /// name(args): the function must exist, and each argument must match
    /// its parameter's type. The call's type is the function's return type.
    fn checkCall(self: *Checker, e: *Expr, c: *Expr.Call) Error!*const Type {
        const f = self.functions.get(c.name) orelse {
            self.diag.err(e.offset, "undeclared function '{s}'", .{c.name});
            for (c.args) |arg| _ = try self.checkExpr(arg);
            return self.types.err();
        };
        c.func = f;
        if (c.args.len != f.params.len) {
            self.diag.err(e.offset, "'{s}' takes {d} argument(s), but got {d}", .{ c.name, f.params.len, c.args.len });
        }
        for (c.args, 0..) |arg, i| {
            const got = try self.checkExpr(arg);
            if (i < f.params.len) _ = self.expectType(arg, got, f.params[i].type);
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
