const std = @import("std");
const ast = @import("ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Diagnostics = @import("diag.zig").Diagnostics;
const tok = @import("token.zig");
const Token = tok.Token;
const TokenKind = tok.TokenKind;
const Expr = ast.Expr;
const Stmt = ast.Stmt;

const Error = std.mem.Allocator.Error;

pub const Parser = struct {
    lex: *Lexer,
    arena: std.mem.Allocator,
    diag: *Diagnostics,
    tok: Token, // current token, not yet consumed
    had_error: bool = false,
    panicking: bool = false, // true after an error until the statement ends

    pub fn init(lex: *Lexer, arena: std.mem.Allocator, diag: *Diagnostics) Parser {
        return .{ .lex = lex, .arena = arena, .diag = diag, .tok = lex.next() };
    }

    /// Parses a whole file: a list of top-level `fn` and `extern fn` declarations.
    pub fn parseFile(self: *Parser) Error![]*ast.FnDecl {
        var fns: std.ArrayList(*ast.FnDecl) = .empty;
        while (!self.atEof()) {
            if (self.tok.kind == .kw_fn) {
                try fns.append(self.arena, try self.parseFn(null));
            } else if (self.tok.kind == .kw_extern) {
                const ext = self.tok;
                self.bump(); // 'extern'
                if (self.tok.kind == .kw_fn) {
                    try fns.append(self.arena, try self.parseFn(ext));
                } else {
                    self.err(self.tok, "expected 'fn' after 'extern'");
                    self.synchronize();
                    self.panicking = false;
                }
            } else {
                self.err(self.tok, "expected 'fn'");
                self.synchronize();
                self.panicking = false;
            }
        }
        return fns.toOwnedSlice(self.arena);
    }

    /// Parses a full expression with precedence climbing (Pratt parsing).
    pub fn parseExpr(self: *Parser) Error!*Expr {
        return self.parseExprPrec(1);
    }

    fn parseExprPrec(self: *Parser, min_prec: u8) Error!*Expr {
        var lhs = try self.parseUnary();
        // Keep folding in operators that bind at least as tightly as
        // min_prec. prec + 1 on the right makes them left-associative.
        while (precedence(self.tok.kind) >= min_prec) {
            const op = self.tok;
            const prec = precedence(op.kind);
            self.bump();
            const rhs = try self.parseExprPrec(prec + 1);
            lhs = try self.newExpr(lhs.offset, .{ .binary = .{ .op = op.kind, .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    /// Parses one statement, including its terminating semicolon.
    pub fn parseStmt(self: *Parser) Error!*Stmt {
        const t = self.tok;
        var s: *Stmt = undefined;

        switch (t.kind) {
            .kw_var, .kw_let => {
                self.bump();
                const name = self.tok;
                self.expect(.ident, "expected a variable name");
                self.expect(.assign, "expected '='");
                const init_expr = try self.parseExpr();
                s = try self.newStmt(t.offset, .{ .var_decl = .{
                    .offset = t.offset,
                    .name = self.lex.text(name),
                    .is_mut = t.kind == .kw_var,
                    .init = init_expr,
                } });
            },
            .lbrace => s = try self.parseBlock(),
            .kw_if => s = try self.parseIf(),
            .kw_for => s = try self.parseFor(),
            .kw_break => {
                self.bump();
                s = try self.newStmt(t.offset, .break_);
            },
            .kw_continue => {
                self.bump();
                s = try self.newStmt(t.offset, .continue_);
            },
            .kw_return => {
                self.bump();
                const value = if (self.tok.kind == .semicolon) null else try self.parseExpr();
                s = try self.newStmt(t.offset, .{ .ret = value });
            },
            else => {
                const e = try self.parseExpr();
                if (self.tok.kind == .assign) {
                    self.bump(); // '='
                    const value = try self.parseExpr();
                    s = try self.newStmt(t.offset, .{ .assign = .{ .target = e, .value = value } });
                } else {
                    s = try self.newStmt(t.offset, .{ .expr = e });
                }
            },
        }

        if (self.tok.kind == .semicolon) {
            self.bump();
        } else if (self.tok.kind == .rbrace) {
            // The last statement in a block may skip the semicolon: { return x }
        } else {
            self.err(self.tok, "expected end of statement");
            self.synchronize();
        }
        self.panicking = false; // next statement gets a fresh start
        return s;
    }

    pub fn atEof(self: *const Parser) bool {
        return self.tok.kind == .eof;
    }

    // ------------------------------------------------------------ helpers

    fn bump(self: *Parser) void {
        self.tok = self.lex.next();
    }

    fn newExpr(self: *Parser, offset: u32, data: Expr.Data) Error!*Expr {
        const e = try self.arena.create(Expr);
        e.* = .{ .offset = offset, .data = data };
        return e;
    }

    fn newStmt(self: *Parser, offset: u32, data: Stmt.Data) Error!*Stmt {
        const s = try self.arena.create(Stmt);
        s.* = .{ .offset = offset, .data = data };
        return s;
    }

    fn newTypeRef(self: *Parser, t: ast.TypeRef) Error!*ast.TypeRef {
        const r = try self.arena.create(ast.TypeRef);
        r.* = t;
        return r;
    }

    // ------------------------------------------------------------ declarations

    /// fn name(a: i64, b: &mut i64) -> i64 { ... }
    /// extern fn name(a: i32) -> i32          (`extern` already consumed)
    fn parseFn(self: *Parser, extern_tok: ?Token) Error!*ast.FnDecl {
        const fn_tok = extern_tok orelse self.tok; // the declaration starts here
        self.bump(); // 'fn'
        const name = self.tok;
        self.expect(.ident, "expected a function name");

        self.expect(.lparen, "expected '('");
        var params: std.ArrayList(*ast.Var) = .empty;
        while (self.tok.kind != .rparen and !self.atEof()) {
            const pname = self.tok;
            self.expect(.ident, "expected a parameter name");
            self.expect(.colon, "expected ':' and a type after the parameter name");
            const p = try self.arena.create(ast.Var);
            p.* = .{ .offset = pname.offset, .name = self.lex.text(pname), .is_mut = false, .init = null };
            p.type_syntax = try self.parseType();
            try params.append(self.arena, p);
            if (self.tok.kind != .comma) break;
            self.bump(); // ','
        }
        self.expect(.rparen, "expected ')'");

        var ret: ?*ast.TypeRef = null; // no `->`: the function returns nothing
        if (self.tok.kind == .arrow) {
            self.bump();
            ret = try self.parseType();
        }

        var body: ?*Stmt = null; // an extern fn has none: C defines it
        if (extern_tok == null) {
            body = try self.parseBlock();
            if (self.tok.kind == .semicolon) self.bump(); // inserted after '}'
        } else if (self.tok.kind == .lbrace) {
            self.err(self.tok, "an extern fn has no body: it is defined in C");
            _ = try self.parseBlock(); // skip it as a whole, then carry on
            if (self.tok.kind == .semicolon) self.bump();
        } else if (self.tok.kind == .semicolon) {
            self.bump(); // the newline after `-> i32` or `)`
        } else {
            self.err(self.tok, "expected end of declaration");
            self.synchronize();
        }
        self.panicking = false;

        const f = try self.arena.create(ast.FnDecl);
        f.* = .{
            .offset = fn_tok.offset,
            .name = self.lex.text(name),
            .params = try params.toOwnedSlice(self.arena),
            .ret_syntax = ret,
            .body = body,
        };
        return f;
    }

    /// i64   bool   &T   &mut T
    fn parseType(self: *Parser) Error!*ast.TypeRef {
        const t = self.tok;
        if (t.kind == .amp or t.kind == .amp_amp) {
            self.bump();
            var is_mut = false;
            if (self.tok.kind == .kw_mut) {
                is_mut = true;
                self.bump();
            }
            const pointee = try self.parseType();
            const ref = try self.newTypeRef(.{ .offset = t.offset, .name = "", .pointee = pointee, .is_mut = is_mut });
            if (t.kind == .amp) return ref;
            // &&T is &(&T), as in expressions.
            ref.offset = t.offset + 1;
            return self.newTypeRef(.{ .offset = t.offset, .name = "", .pointee = ref, .is_mut = false });
        }
        if (t.kind == .ident) {
            self.bump();
            return self.newTypeRef(.{ .offset = t.offset, .name = self.lex.text(t), .pointee = null, .is_mut = false });
        }
        self.err(t, "expected a type");
        return self.newTypeRef(.{ .offset = t.offset, .name = "<error>", .pointee = null, .is_mut = false });
    }

    // ------------------------------------------------------------ statements

    /// if cond { ... } [else { ... } | else if ...]
    /// Like Go, `else` must be on the same line as the closing `}`.
    fn parseIf(self: *Parser) Error!*Stmt {
        const if_tok = self.tok;
        self.bump(); // 'if'
        const cond = try self.parseExpr();
        const then_block = try self.parseBlock();
        var else_stmt: ?*Stmt = null;
        if (self.tok.kind == .kw_else) {
            self.bump();
            else_stmt = if (self.tok.kind == .kw_if) try self.parseIf() else try self.parseBlock();
        }
        return self.newStmt(if_tok.offset, .{ .if_ = .{ .cond = cond, .then_block = then_block, .else_stmt = else_stmt } });
    }

    /// for cond { ... }  or  for { ... } (forever)
    fn parseFor(self: *Parser) Error!*Stmt {
        const for_tok = self.tok;
        self.bump(); // 'for'
        const cond = if (self.tok.kind == .lbrace)
            try self.newExpr(for_tok.offset, .{ .bool = true })
        else
            try self.parseExpr();
        const body = try self.parseBlock();
        return self.newStmt(for_tok.offset, .{ .for_ = .{ .cond = cond, .body = body } });
    }

    /// { stmt; stmt; ... }
    fn parseBlock(self: *Parser) Error!*Stmt {
        const open = self.tok;
        self.expect(.lbrace, "expected '{'");
        var stmts: std.ArrayList(*Stmt) = .empty;
        while (self.tok.kind != .rbrace and !self.atEof()) {
            try stmts.append(self.arena, try self.parseStmt());
        }
        const close = self.tok;
        self.expect(.rbrace, "expected '}'");
        return self.newStmt(open.offset, .{ .block = .{
            .stmts = try stmts.toOwnedSlice(self.arena),
            .end_offset = close.offset,
        } });
    }

    // ------------------------------------------------------------ expressions

    /// 0 means "not a binary operator", which ends the loop in parseExprPrec.
    ///   a || b && c == d + e * f   is   a || (b && (c == (d + (e * f))))
    fn precedence(k: TokenKind) u8 {
        return switch (k) {
            .pipe_pipe => 1,
            .amp_amp => 2,
            .eq_eq, .not_eq, .less, .less_eq, .greater, .greater_eq => 3,
            .plus, .minus => 4,
            .star, .slash => 5,
            else => 0,
        };
    }

    /// Prefix operators bind tighter than any binary operator.
    fn parseUnary(self: *Parser) Error!*Expr {
        const t = self.tok;
        if (t.kind == .minus or t.kind == .bang) {
            // -x negates an i64, !x flips a bool.
            self.bump();
            const operand = try self.parseUnary();
            return self.newExpr(t.offset, .{ .unary = .{ .op = t.kind, .is_mut = false, .operand = operand } });
        }
        if (t.kind == .star) {
            // *r: read (or, as an assignment target, write) through a reference.
            self.bump();
            const operand = try self.parseUnary();
            return self.newExpr(t.offset, .{ .unary = .{ .op = .star, .is_mut = false, .operand = operand } });
        }
        if (t.kind == .amp or t.kind == .amp_amp) {
            // The lexer reads `&&` as one token, but in front of an operand
            // it means two borrows: &&x is &(&x), and &&mut x is &(&mut x).
            self.bump();
            var is_mut = false;
            if (self.tok.kind == .kw_mut) {
                is_mut = true;
                self.bump();
            }
            const operand = try self.parseUnary();
            if (t.kind == .amp) {
                return self.newExpr(t.offset, .{ .unary = .{ .op = .amp, .is_mut = is_mut, .operand = operand } });
            }
            const inner = try self.newExpr(t.offset + 1, .{ .unary = .{ .op = .amp, .is_mut = is_mut, .operand = operand } });
            return self.newExpr(t.offset, .{ .unary = .{ .op = .amp, .is_mut = false, .operand = inner } });
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) Error!*Expr {
        const t = self.tok;
        switch (t.kind) {
            .int_lit => {
                self.bump();
                // Like the C++ version: a literal too big for u64 becomes 0.
                const value = std.fmt.parseInt(u64, self.lex.text(t), 10) catch 0;
                return self.newExpr(t.offset, .{ .int = value });
            },
            .kw_true, .kw_false => {
                self.bump();
                return self.newExpr(t.offset, .{ .bool = t.kind == .kw_true });
            },
            .ident => {
                self.bump();
                if (self.tok.kind == .lparen) return self.parseCall(t);
                return self.newExpr(t.offset, .{ .ident = .{ .name = self.lex.text(t) } });
            },
            .lparen => {
                self.bump();
                const inner = try self.parseExpr();
                self.expect(.rparen, "expected ')'");
                return inner;
            },
            else => {
                self.err(t, if (t.kind == .kw_else)
                    "'else' must be on the same line as the '}' before it"
                else
                    "expected an expression");
                self.bump(); // skip the bad token so we always make progress
                return self.newExpr(t.offset, .{ .int = 0 }); // placeholder, never null
            },
        }
    }

    /// name(arg, arg, ...). The name is consumed; the current token is '('.
    fn parseCall(self: *Parser, name: Token) Error!*Expr {
        self.bump(); // '('
        var args: std.ArrayList(*Expr) = .empty;
        while (self.tok.kind != .rparen and !self.atEof()) {
            try args.append(self.arena, try self.parseExpr());
            if (self.tok.kind != .comma) break;
            self.bump(); // ','
        }
        self.expect(.rparen, "expected ')' after the arguments");
        return self.newExpr(name.offset, .{ .call = .{
            .name = self.lex.text(name),
            .args = try args.toOwnedSlice(self.arena),
        } });
    }

    fn expect(self: *Parser, kind: TokenKind, what: []const u8) void {
        if (self.tok.kind == kind) {
            self.bump();
        } else {
            self.err(self.tok, what);
        }
    }

    /// After an error, skip to the next statement boundary so one mistake
    /// does not cause a flood of follow-up errors.
    fn synchronize(self: *Parser) void {
        while (self.tok.kind != .semicolon and self.tok.kind != .eof) self.bump();
        if (self.tok.kind == .semicolon) self.bump();
    }

    fn err(self: *Parser, at: Token, msg: []const u8) void {
        self.had_error = true;
        if (self.panicking) return; // only the first error per statement
        self.panicking = true;
        self.diag.err(at.offset, "{s}", .{msg});
    }
};

// ---------------------------------------------------------------- tests

fn expectDump(src: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var diag = Diagnostics.init("t.fl", src, &sink.writer);
    var lex = Lexer.init(src);
    var p = Parser.init(&lex, arena.allocator(), &diag);
    const e = try p.parseExpr();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try ast.dumpExpr(&out.writer, e);
    try std.testing.expectEqualStrings(expected, out.written());
    try std.testing.expectEqual(@as(u32, 0), diag.errorCount());
}

test "precedence and associativity" {
    try expectDump("1 + 2 * 3", "(+ 1 (* 2 3))");
    try expectDump("1 - 2 - 3", "(- (- 1 2) 3)");
    try expectDump("-(1 + x) * 2", "(* (- (+ 1 x)) 2)");
    try expectDump("a + 1 < b == true", "(== (< (+ a 1) b) true)");
    try expectDump("&mut x", "(&mut x)");
    try expectDump("f(1, g(x), &y)", "(call f 1 (call g x) (& y))");
    try expectDump("*c * **d", "(* (* c) (* (* d)))");
    try expectDump("a || b && c == d + e * f", "(|| a (&& b (== c (+ d (* e f)))))");
    try expectDump("!a && !!b || c", "(|| (&& (! a) (! (! b))) c)");
    try expectDump("&&x == &&mut y", "(== (& (& x)) (& (&mut y)))");
}

test "extern fn has a signature and no body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "extern fn putchar(c: i32) -> i32\nextern fn exit(code: i32)\nfn main() {\n}\n";
    var sink: std.Io.Writer.Discarding = .init(&.{});
    var diag = Diagnostics.init("t.fl", src, &sink.writer);
    var lex = Lexer.init(src);
    var p = Parser.init(&lex, arena.allocator(), &diag);
    const fns = try p.parseFile();
    try std.testing.expectEqual(@as(u32, 0), diag.errorCount());
    try std.testing.expectEqual(@as(usize, 3), fns.len);
    try std.testing.expect(fns[0].isExtern() and fns[1].isExtern() and !fns[2].isExtern());
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try ast.dumpFn(&out.writer, fns[0]);
    try std.testing.expectEqualStrings("(extern fn putchar (c: i32) -> i32)", out.written());
}
