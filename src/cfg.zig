//! Control-flow graph of one function body, plus liveness.
//!
//! Each node is one simple statement (let/var, expression, assignment,
//! return), one `if`/`for` condition, or a join where paths meet. Edges
//! are the ways control can go next.
//!
//!   fn f() -> i64 {        node                  goes to
//!       var a = 1          [0] entry             1
//!       for a < 9 {        [1] var a = 1         2
//!           if a == 5 {    [2] cond a < 9        3, 6
//!               break      [3] cond a == 5       4, 6 (break)
//!           }              [4] join (if done)    5
//!           a = a + 1      [5] a = a + 1         2 (loop back)
//!       }                  [6] join (loop done)  7
//!       return a           [7] return a          -
//!   }
//!
//! Liveness: a variable is live at a point if some path from there reads it
//! before overwriting it. The borrow checker asks "is the variable holding
//! this loan live here?" instead of "is it read later in the source?".
const std = @import("std");
const ast = @import("ast.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Var = ast.Var;

const Error = std.mem.Allocator.Error;
pub const NodeId = u32;

/// One read of a variable.
pub const Use = struct {
    v: *const Var,
    expr: *const Expr, // the identifier, for its offset
};

pub const Node = struct {
    kind: Kind,
    succs: std.ArrayList(NodeId) = .empty,
    preds: std.ArrayList(NodeId) = .empty,
    uses: []const Use = &.{}, // variables read, in evaluation order
    def: ?*const Var = null, // variable given a new value, after the reads
    live_in: std.DynamicBitSetUnmanaged = .{}, // live before the node (by var index)
    live_out: std.DynamicBitSetUnmanaged = .{}, // live after it

    pub const Kind = union(enum) {
        stmt: *Stmt, // .var_decl, .expr, .assign or .ret
        cond: *Expr, // an `if` or `for` condition: two ways out
        join, // the entry, or where paths meet: does nothing
    };
};

pub const Cfg = struct {
    nodes: std.ArrayList(Node) = .empty, // node 0 is the entry
    vars: std.AutoArrayHashMapUnmanaged(*const Var, void) = .empty, // var -> bit index
    use_pos: std.AutoHashMapUnmanaged(*const Expr, u32) = .empty, // read -> index in its node's uses

    /// Builds the graph of `f` (not an extern fn) and computes liveness.
    /// Everything lives in `a`.
    pub fn build(a: std.mem.Allocator, f: *const ast.FnDecl) Error!Cfg {
        var cfg: Cfg = .{};
        var b: Builder = .{ .a = a, .cfg = &cfg };
        for (f.params) |p| _ = try cfg.varIndex(a, p);
        const entry = try b.add(.join, null);
        _ = try b.stmt(f.body.?, entry);
        try cfg.computeLiveness(a);
        return cfg;
    }

    fn varIndex(self: *Cfg, a: std.mem.Allocator, v: *const Var) Error!usize {
        const gop = try self.vars.getOrPut(a, v);
        return gop.index;
    }

    // Backward dataflow, repeated until nothing changes (loops feed back):
    //
    //   live_out(n) = union of live_in(s) for every successor s
    //   live_in(n)  = uses(n) + (live_out(n) - def(n))
    fn computeLiveness(self: *Cfg, a: std.mem.Allocator) Error!void {
        const nvars = self.vars.count();
        for (self.nodes.items) |*n| {
            n.live_in = try .initEmpty(a, nvars);
            n.live_out = try .initEmpty(a, nvars);
        }
        var scratch = try std.DynamicBitSetUnmanaged.initEmpty(a, nvars);
        var changed = true;
        while (changed) {
            changed = false;
            var i = self.nodes.items.len;
            while (i > 0) { // backwards: information flows from later nodes
                i -= 1;
                const n = &self.nodes.items[i];
                for (n.succs.items) |s| n.live_out.setUnion(self.nodes.items[s].live_in);

                scratch.unsetAll();
                scratch.setUnion(n.live_out);
                if (n.def) |d| scratch.unset(self.vars.getIndex(d).?);
                for (n.uses) |u| scratch.set(self.vars.getIndex(u.v).?);
                if (!scratch.eql(n.live_in)) {
                    n.live_in.unsetAll();
                    n.live_in.setUnion(scratch);
                    changed = true;
                }
            }
        }
    }

    /// Node `node` has done its first `done` reads. Is `v` read again before
    /// it is overwritten? Returns the offset of such a read (the nearest one,
    /// for the error note), or null if `v` is dead.
    pub fn nextUse(self: *const Cfg, a: std.mem.Allocator, node: NodeId, done: usize, v: *const Var) Error!?u32 {
        const n = &self.nodes.items[node];
        for (n.uses[@min(done, n.uses.len)..]) |u| {
            if (u.v == v) return u.expr.offset;
        }
        if (n.def == v) return null;
        const index = self.vars.getIndex(v) orelse return null;
        if (!n.live_out.isSet(index)) return null;

        // Live: search breadth-first for the nearest read, to point at it.
        var seen = try std.DynamicBitSetUnmanaged.initEmpty(a, self.nodes.items.len);
        var queue: std.ArrayList(NodeId) = .empty;
        try queue.appendSlice(a, n.succs.items);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const id = queue.items[head];
            if (seen.isSet(id)) continue;
            seen.set(id);
            const m = &self.nodes.items[id];
            for (m.uses) |u| {
                if (u.v == v) return u.expr.offset;
            }
            if (m.def == v) continue; // overwritten first: no read this way
            try queue.appendSlice(a, m.succs.items);
        }
        return null; // not reached: live_out said there is a read
    }
};

const Builder = struct {
    a: std.mem.Allocator,
    cfg: *Cfg,
    loops: std.ArrayList(Loop) = .empty, // loops we are inside, innermost last

    const Loop = struct {
        head: NodeId, // the condition: `continue` goes here
        breaks: std.ArrayList(NodeId) = .empty, // nodes that `break` out
    };

    /// Adds a node, with an edge from `from` if control can get there.
    fn add(self: *Builder, kind: Node.Kind, from: ?NodeId) Error!NodeId {
        const id: NodeId = @intCast(self.cfg.nodes.items.len);
        try self.cfg.nodes.append(self.a, .{ .kind = kind });
        if (from) |f| try self.edge(f, id);
        return id;
    }

    fn edge(self: *Builder, from: NodeId, to: NodeId) Error!void {
        try self.cfg.nodes.items[from].succs.append(self.a, to);
        try self.cfg.nodes.items[to].preds.append(self.a, from);
    }

    /// Adds `s` after `cur` (null: unreachable, e.g. after `return`).
    /// Returns the node control falls out of, or null if it never does.
    fn stmt(self: *Builder, s: *Stmt, cur: ?NodeId) Error!?NodeId {
        switch (s.data) {
            .var_decl, .expr, .assign, .ret => {
                const id = try self.add(.{ .stmt = s }, cur);
                try self.recordUses(id, s);
                return if (s.data == .ret) null else id;
            },
            .block => |b| {
                var at = cur;
                for (b.stmts) |child| at = try self.stmt(child, at);
                return at;
            },
            //   cond --> then ... --+
            //     \                 +--> join
            //      +-> else ... ----+     (no else: cond --> join)
            .if_ => |i| {
                const c = try self.add(.{ .cond = i.cond }, cur);
                try self.recordCondUses(c, i.cond);
                const then_end = try self.stmt(i.then_block, c);
                const else_end = if (i.else_stmt) |e| try self.stmt(e, c) else c;
                if (then_end == null and else_end == null) return null; // both left
                const j = try self.add(.join, null);
                if (then_end) |t| try self.edge(t, j);
                if (else_end) |e| try self.edge(e, j);
                return j;
            },
            //   cond <-------------+  (end of body, continue)
            //    |  \              |
            //    |   +--> body ... +
            //    v
            //   exit  <-- false condition, break
            .for_ => |f| {
                const head = try self.add(.{ .cond = f.cond }, cur);
                try self.recordCondUses(head, f.cond);
                try self.loops.append(self.a, .{ .head = head });
                const body_end = try self.stmt(f.body, head);
                var loop = self.loops.pop().?;
                if (body_end) |e| try self.edge(e, head);

                // `for { }` only exits through `break`.
                const forever = f.cond.data == .bool and f.cond.data.bool;
                if (forever and loop.breaks.items.len == 0) return null;
                const exit = try self.add(.join, if (forever) null else head);
                for (loop.breaks.items) |from| try self.edge(from, exit);
                loop.breaks.deinit(self.a);
                return exit;
            },
            .break_ => {
                const loop = &self.loops.items[self.loops.items.len - 1];
                if (cur) |c| try loop.breaks.append(self.a, c);
                return null;
            },
            .continue_ => {
                if (cur) |c| try self.edge(c, self.loops.getLast().head);
                return null;
            },
        }
    }

    // ------------------------------------------------------------ uses

    // Reads are listed in the order the borrow checker evaluates them,
    // so "reads after this one" means the same thing to both.

    fn recordUses(self: *Builder, id: NodeId, s: *Stmt) Error!void {
        var uses: std.ArrayList(Use) = .empty;
        var def: ?*const Var = null;
        switch (s.data) {
            .var_decl => |*v| {
                try self.collect(&uses, v.init.?);
                def = v;
            },
            .expr => |e| try self.collect(&uses, e),
            .assign => |as| {
                try self.collect(&uses, as.value); // the value is evaluated first
                switch (as.target.data) {
                    .ident => |t| def = t.decl.?, // `x = e` overwrites x, doesn't read it
                    .unary => |u| try self.collect(&uses, u.operand), // `*r = e` reads r
                    else => {},
                }
            },
            .ret => |value| if (value) |e| try self.collect(&uses, e),
            else => unreachable,
        }
        try self.finish(id, &uses, def);
    }

    fn recordCondUses(self: *Builder, id: NodeId, e: *Expr) Error!void {
        var uses: std.ArrayList(Use) = .empty;
        try self.collect(&uses, e);
        try self.finish(id, &uses, null);
    }

    fn finish(self: *Builder, id: NodeId, uses: *std.ArrayList(Use), def: ?*const Var) Error!void {
        for (uses.items, 0..) |u, i| {
            _ = try self.cfg.varIndex(self.a, u.v);
            try self.cfg.use_pos.put(self.a, u.expr, @intCast(i));
        }
        if (def) |d| _ = try self.cfg.varIndex(self.a, d);
        const n = &self.cfg.nodes.items[id];
        n.uses = uses.items;
        n.def = def;
    }

    fn collect(self: *Builder, uses: *std.ArrayList(Use), e: *Expr) Error!void {
        switch (e.data) {
            .int, .bool => {},
            .ident => |id| try uses.append(self.a, .{ .v = id.decl.?, .expr = e }),
            .unary => |u| try self.collect(uses, u.operand), // &x counts as a use of x
            .binary => |b| {
                try self.collect(uses, b.lhs);
                try self.collect(uses, b.rhs);
            },
            .call => |c| for (c.args) |arg| try self.collect(uses, arg),
        }
    }
};
