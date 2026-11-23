const std = @import("std");

/// Types are interned: each distinct type exists exactly once, so two
/// types are equal if and only if their pointers are equal.
pub const Type = union(enum) {
    err, // "already reported", silences follow-up errors
    void, // "returns nothing"
    i64,
    bool,
    ref: Ref,

    pub const Ref = struct {
        pointee: *const Type,
        is_mut: bool,
    };

    pub fn isRef(t: *const Type) bool {
        return t.* == .ref;
    }

    pub fn isMutRef(t: *const Type) bool {
        return switch (t.*) {
            .ref => |r| r.is_mut,
            else => false,
        };
    }

    /// Prints "i64", "&mut bool", "<error>", ... Use with "{f}".
    pub fn format(t: *const Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (t.*) {
            .err => try w.writeAll("<error>"),
            .void => try w.writeAll("void"),
            .i64 => try w.writeAll("i64"),
            .bool => try w.writeAll("bool"),
            .ref => |r| {
                try w.writeAll(if (r.is_mut) "&mut " else "&");
                try r.pointee.format(w);
            },
        }
    }
};

// The four built-in types live in static memory, so their addresses
// never change.
pub const error_type: Type = .err;
pub const void_type: Type = .void;
pub const i64_type: Type = .i64;
pub const bool_type: Type = .bool;

pub const TypeTable = struct {
    arena: std.mem.Allocator,
    refs: std.ArrayList(*const Type) = .empty,

    pub fn init(arena: std.mem.Allocator) TypeTable {
        return .{ .arena = arena };
    }

    pub fn err(_: *const TypeTable) *const Type {
        return &error_type;
    }
    pub fn voidType(_: *const TypeTable) *const Type {
        return &void_type;
    }
    pub fn int(_: *const TypeTable) *const Type {
        return &i64_type;
    }
    pub fn boolean(_: *const TypeTable) *const Type {
        return &bool_type;
    }

    /// Returns the one shared Type for &T or &mut T.
    pub fn ref(self: *TypeTable, pointee: *const Type, is_mut: bool) !*const Type {
        for (self.refs.items) |t| {
            if (t.ref.pointee == pointee and t.ref.is_mut == is_mut) return t;
        }
        const t = try self.arena.create(Type);
        t.* = .{ .ref = .{ .pointee = pointee, .is_mut = is_mut } };
        try self.refs.append(self.arena, t);
        return t;
    }
};

test "interning and names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tt = TypeTable.init(arena.allocator());
    const a = try tt.ref(tt.int(), true);
    const b = try tt.ref(tt.int(), true);
    const c = try tt.ref(tt.int(), false);
    try std.testing.expect(a == b);
    try std.testing.expect(a != c);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("&mut i64", try std.fmt.bufPrint(&buf, "{f}", .{a}));
    try std.testing.expectEqualStrings("&&bool", try std.fmt.bufPrint(&buf, "{f}", .{try tt.ref(try tt.ref(tt.boolean(), false), false)}));
}
