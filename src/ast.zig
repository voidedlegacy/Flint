//! The syntax tree. Every node lives in one ArenaAllocator and is freed
//! all at once. Child lists are arena slices. Names are slices into the
//! source buffer (no copies), so the source must outlive the arena.
//!
//!   Expr                         Stmt
//!   +--------+------+------+     +--------+--------------------+
//!   | offset | type | data |     | offset | data: union(enum)  |
//!   +--------+------+------+     +--------+--------------------+
//!                     |                     var_decl | ret | expr
//!     int | bool | ident | unary            block | assign | if_ | for_
//!     binary | call                         break_ | continue_
const std = @import("std");
const TokenKind = @import("token.zig").TokenKind;
const Type = @import("types.zig").Type;

pub const Expr = struct {
    offset: u32, // where it starts in the source, for errors
    type: *const Type = undefined, // filled in by the checker
    data: Data,

    pub const Data = union(enum) {
        int: u64,
        bool: bool,
        ident: Ident,
        unary: Unary,
        binary: Binary,
        call: Call,
    };

    pub const Ident = struct {
        name: []const u8,
        decl: ?*Var = null, // filled in by the checker
    };

    pub const Unary = struct {
        op: TokenKind, // .minus, .bang (not), .amp (& / &mut) or .star (deref)
        is_mut: bool, // true for &mut
        operand: *Expr,
    };

    pub const Binary = struct {
        op: TokenKind,
        lhs: *Expr,
        rhs: *Expr,
    };

    /// name(arg, arg, ...)
    pub const Call = struct {
        name: []const u8,
        args: []*Expr,
        func: ?*FnDecl = null, // filled in by the checker
    };
};

/// A type written in the source, e.g. `i64` or `&mut bool`.
/// The checker turns it into a real *const Type.
pub const TypeRef = struct {
    offset: u32,
    name: []const u8, // "i64", "bool", ... (empty for a reference)
    pointee: ?*TypeRef, // non-null: this is &pointee or &mut pointee
    is_mut: bool,
};

/// var x = e (mutable), let x = e (immutable), or a function parameter.
pub const Var = struct {
    offset: u32,
    name: []const u8,
    is_mut: bool,
    init: ?*Expr, // null for function parameters
    type: *const Type = undefined, // inferred by the checker
    type_syntax: ?*TypeRef = null, // written type, e.g. a parameter's `: i64`
};

pub const Stmt = struct {
    offset: u32,
    data: Data,

    pub const Data = union(enum) {
        var_decl: Var,
        ret: ?*Expr, // null for a bare `return`
        expr: *Expr,
        block: Block,
        assign: Assign,
        if_: If,
        for_: For,
        break_, // leaves the innermost loop
        continue_, // jumps to the innermost loop's condition
    };

    pub const Block = struct {
        stmts: []*Stmt,
        end_offset: u32, // where the closing '}' is
    };

    /// target = value. Only a `var` may be assigned to.
    pub const Assign = struct {
        target: *Expr,
        value: *Expr,
    };

    /// if cond { } else { }. `else if` is an If in the else slot.
    pub const If = struct {
        cond: *Expr,
        then_block: *Stmt, // always a .block
        else_stmt: ?*Stmt, // null, a .block, or another .if_
    };

    /// for cond { } and for { } (forever: cond is `true`).
    pub const For = struct {
        cond: *Expr,
        body: *Stmt, // always a .block
    };

    pub fn endOffset(s: *const Stmt) u32 {
        return s.data.block.end_offset;
    }
};

/// fn name(a: i64, b: &mut i64) -> i64 { ... }
/// extern fn putchar(c: i32) -> i32      (no body: it is defined in C)
pub const FnDecl = struct {
    offset: u32,
    name: []const u8,
    params: []*Var, // each has type_syntax set and no init
    ret_syntax: ?*TypeRef, // null: the function returns nothing
    body: ?*Stmt, // a .block; null for an extern fn
    ret_type: *const Type = undefined, // filled in by the checker

    /// Declared with `extern`: called by its plain C name, never defined here.
    pub fn isExtern(f: *const FnDecl) bool {
        return f.body == null;
    }
};

// ---------------------------------------------------------------- dump

pub fn opText(op: TokenKind) []const u8 {
    return switch (op) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .eq_eq => "==",
        .not_eq => "!=",
        .less => "<",
        .less_eq => "<=",
        .greater => ">",
        .greater_eq => ">=",
        .amp => "&",
        .amp_amp => "&&",
        .pipe_pipe => "||",
        .bang => "!",
        else => "?",
    };
}

pub fn dumpTypeRef(w: *std.Io.Writer, t: *const TypeRef) std.Io.Writer.Error!void {
    if (t.pointee) |p| {
        try w.writeAll(if (t.is_mut) "&mut " else "&");
        return dumpTypeRef(w, p);
    }
    try w.writeAll(t.name);
}

/// Prints the tree as an S-expression, e.g. (* (- (+ 1 x)) 2).
pub fn dumpExpr(w: *std.Io.Writer, e: *const Expr) std.Io.Writer.Error!void {
    switch (e.data) {
        .int => |v| try w.print("{d}", .{v}),
        .bool => |v| try w.writeAll(if (v) "true" else "false"),
        .ident => |id| try w.writeAll(id.name),
        .unary => |u| {
            try w.print("({s}{s} ", .{ opText(u.op), if (u.is_mut) "mut" else "" });
            try dumpExpr(w, u.operand);
            try w.writeAll(")");
        },
        .binary => |b| {
            try w.print("({s} ", .{opText(b.op)});
            try dumpExpr(w, b.lhs);
            try w.writeAll(" ");
            try dumpExpr(w, b.rhs);
            try w.writeAll(")");
        },
        .call => |c| {
            try w.print("(call {s}", .{c.name});
            for (c.args) |arg| {
                try w.writeAll(" ");
                try dumpExpr(w, arg);
            }
            try w.writeAll(")");
        },
    }
}

pub fn dumpStmt(w: *std.Io.Writer, s: *const Stmt) std.Io.Writer.Error!void {
    switch (s.data) {
        .var_decl => |*v| {
            try w.print("({s} {s}", .{ if (v.is_mut) "var" else "let", v.name });
            try w.print(": {f} ", .{v.type});
            try dumpExpr(w, v.init.?);
            try w.writeAll(")");
        },
        .ret => |value| {
            try w.writeAll("(return");
            if (value) |e| {
                try w.writeAll(" ");
                try dumpExpr(w, e);
            }
            try w.writeAll(")");
        },
        .expr => |e| try dumpExpr(w, e),
        .break_ => try w.writeAll("(break)"),
        .continue_ => try w.writeAll("(continue)"),
        .assign => |a| {
            try w.writeAll("(= ");
            try dumpExpr(w, a.target);
            try w.writeAll(" ");
            try dumpExpr(w, a.value);
            try w.writeAll(")");
        },
        .for_ => |f| {
            try w.writeAll("(for ");
            try dumpExpr(w, f.cond);
            try w.writeAll(" ");
            try dumpStmt(w, f.body);
            try w.writeAll(")");
        },
        .if_ => |i| {
            try w.writeAll("(if ");
            try dumpExpr(w, i.cond);
            try w.writeAll(" ");
            try dumpStmt(w, i.then_block);
            if (i.else_stmt) |e| {
                try w.writeAll(" ");
                try dumpStmt(w, e);
            }
            try w.writeAll(")");
        },
        .block => |b| {
            try w.writeAll("(block");
            for (b.stmts) |child| {
                try w.writeAll(" ");
                try dumpStmt(w, child);
            }
            try w.writeAll(")");
        },
    }
}

pub fn dumpFn(w: *std.Io.Writer, f: *const FnDecl) std.Io.Writer.Error!void {
    try w.print("({s}fn {s} (", .{ if (f.isExtern()) "extern " else "", f.name });
    for (f.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(" ");
        try w.print("{s}: ", .{p.name});
        try dumpTypeRef(w, p.type_syntax.?);
    }
    try w.writeAll(")");
    if (f.ret_syntax) |r| {
        try w.writeAll(" -> ");
        try dumpTypeRef(w, r);
    }
    if (f.body) |body| {
        try w.writeAll(" ");
        try dumpStmt(w, body);
    }
    try w.writeAll(")");
}
