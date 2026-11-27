//! Example runner: run-examples <flint> <examples-dir> <expected-dir> <out-dir>
//!
//! For every examples/<name>.fl:
//!   1. copy it into <out-dir> (so build output never lands in examples/)
//!   2. run `flint <name>.fl` inside <out-dir>
//!   3. check flint's exit code and the number of errors, or run the
//!      program and check its exit code
//!   4. if tests/expected/<name>.txt exists, flint's stderr must match it
//!      byte for byte (messages, line:col, source lines and carets).
//!      Files for examples that predate the Zig port came from the C++ version;
//!      since step 30 their notes point at the next read, not the last one.
//!   5. if tests/expected/<name>.out exists, the program's stdout must match
//!      it byte for byte (programs that print, via `extern fn putchar`).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const Expect = union(enum) {
    runs: u8, // builds, and the program exits with this code
    errors: u32, // flint exits 1 with exactly this many errors
};

const expectations = std.StaticStringMap(Expect).initComptime(.{
    .{ "hello", Expect{ .runs = 0 } },
    .{ "answer", Expect{ .runs = 42 } },
    .{ "branch", Expect{ .runs = 42 } },
    .{ "compare", Expect{ .runs = 42 } },
    .{ "loop", Expect{ .runs = 42 } },
    .{ "signatures", Expect{ .runs = 42 } },
    .{ "calls", Expect{ .runs = 42 } },
    .{ "moves", Expect{ .errors = 3 } },
    .{ "aliasing", Expect{ .errors = 5 } },
    .{ "branch_moves", Expect{ .errors = 1 } },
    .{ "scopes", Expect{ .errors = 3 } },
    .{ "mutability", Expect{ .errors = 3 } },
    .{ "types", Expect{ .errors = 3 } },
    .{ "loop_borrows", Expect{ .errors = 2 } },
    .{ "returns", Expect{ .errors = 6 } },
    .{ "call_errors", Expect{ .errors = 5 } },
    .{ "call_borrows", Expect{ .errors = 5 } },
    .{ "errors", Expect{ .errors = 3 } }, // parse errors
    .{ "deref", Expect{ .runs = 42 } },
    .{ "deref_types", Expect{ .errors = 3 } },
    .{ "deref_borrows", Expect{ .errors = 3 } },
    .{ "break_continue", Expect{ .runs = 42 } },
    .{ "flow", Expect{ .runs = 42 } },
    .{ "break_errors", Expect{ .errors = 3 } },
    .{ "break_borrows", Expect{ .errors = 2 } },
    .{ "logic", Expect{ .runs = 42 } },
    .{ "logic_errors", Expect{ .errors = 4 } },
    .{ "extern", Expect{ .runs = 42 } },
    .{ "extern_errors", Expect{ .errors = 10 } },
    .{ "extern_syntax", Expect{ .errors = 3 } }, // parse errors
});

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.debug.print("usage: run-examples <flint> <examples-dir> <expected-dir> <out-dir>\n", .{});
        return 2;
    }
    const cwd = Io.Dir.cwd();
    // Absolute paths: flint and the programs run with <out-dir> as their cwd.
    const flint = try cwd.realPathFileAlloc(io, args[1], arena);
    var examples = try cwd.openDir(io, args[2], .{ .iterate = true });
    defer examples.close(io);
    var expected_dir = try cwd.openDir(io, args[3], .{});
    defer expected_dir.close(io);
    const out_path = try cwd.realPathFileAlloc(io, args[4], arena);
    var out = try cwd.openDir(io, out_path, .{});
    defer out.close(io);

    // Collect and sort the names so the report is stable.
    var names: std.ArrayList([]const u8) = .empty;
    var it = examples.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".fl")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - 3]));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var failed: u32 = 0;
    for (names.items) |name| {
        const problem = try checkOne(gpa, arena, io, flint, examples, expected_dir, out, out_path, name);
        if (problem) |msg| {
            failed += 1;
            std.debug.print("FAIL {s}: {s}\n", .{ name, msg });
        } else {
            std.debug.print("ok   {s}\n", .{name});
        }
    }
    std.debug.print("{d} passed, {d} failed\n", .{ names.items.len - failed, failed });
    return if (failed == 0) 0 else 1;
}

/// Returns null on success, or a description of what went wrong.
fn checkOne(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    flint: []const u8,
    examples: Io.Dir,
    expected_dir: Io.Dir,
    out: Io.Dir,
    out_path: []const u8,
    name: []const u8,
) !?[]const u8 {
    const file = try std.fmt.allocPrint(arena, "{s}.fl", .{name});
    const src = try examples.readFileAlloc(io, file, arena, .unlimited);
    try out.writeFile(io, .{ .sub_path = file, .data = src });

    const want = expectations.get(name) orelse return "no expectation listed in tests/run_examples.zig";

    const res = try std.process.run(gpa, io, .{
        .argv = &.{ flint, file },
        .cwd = .{ .path = out_path },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => return "flint crashed",
    };

    // Golden stderr, generated from the C++ reference implementation.
    const golden_name = try std.fmt.allocPrint(arena, "{s}.txt", .{name});
    if (expected_dir.readFileAlloc(io, golden_name, arena, .unlimited)) |golden| {
        if (!std.mem.eql(u8, golden, res.stderr)) {
            return try std.fmt.allocPrint(arena, "stderr differs from tests/expected/{s}\n--- expected\n{s}--- got\n{s}", .{ golden_name, golden, res.stderr });
        }
    } else |_| {}

    switch (want) {
        .errors => |n| {
            const got = std.mem.count(u8, res.stderr, ": error: ");
            if (code != 1) return try std.fmt.allocPrint(arena, "flint exited {d}, expected 1", .{code});
            if (got != n) return try std.fmt.allocPrint(arena, "{d} error(s), expected {d}", .{ got, n });
        },
        .runs => |n| {
            if (code != 0) return try std.fmt.allocPrint(arena, "flint exited {d}:\n{s}", .{ code, res.stderr });
            const base = if (builtin.os.tag == .windows) try std.fmt.allocPrint(arena, "{s}.exe", .{name}) else name;
            const exe = try std.fs.path.join(arena, &.{ out_path, base });
            const run = try std.process.run(gpa, io, .{ .argv = &.{exe}, .cwd = .{ .path = out_path } });
            defer gpa.free(run.stdout);
            defer gpa.free(run.stderr);
            switch (run.term) {
                .exited => |c| if (c != n) return try std.fmt.allocPrint(arena, "program exited {d}, expected {d}", .{ c, n }),
                else => return "program crashed",
            }
            const out_name = try std.fmt.allocPrint(arena, "{s}.out", .{name});
            if (expected_dir.readFileAlloc(io, out_name, arena, .unlimited)) |golden| {
                if (!std.mem.eql(u8, golden, run.stdout)) {
                    return try std.fmt.allocPrint(arena, "stdout differs from tests/expected/{s}\n--- expected\n{s}--- got\n{s}", .{ out_name, golden, run.stdout });
                }
            } else |_| {}
        },
    }
    return null;
}
