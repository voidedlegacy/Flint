//! flint [--ast] [-O0|-O1|-O2|-O3] <file.fl>
//!
//!   source --lexer--> tokens --parser--> AST (arena)
//!          --checker--> names+types --borrowck--> ok?
//!          --codegen--> file.ll --clang--> executable
//!
//! Exit codes: 0 success, 1 errors in the code, 2 usage or file problems.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Diagnostics = @import("diag.zig").Diagnostics;
const TypeTable = @import("types.zig").TypeTable;
const Checker = @import("checker.zig").Checker;
const BorrowChecker = @import("borrowck.zig").BorrowChecker;
const CodeGen = @import("codegen.zig").CodeGen;
const ast = @import("ast.zig");

pub fn main(init: std.process.Init) !u8 {
    // init.gpa checks for leaks in debug builds.
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Streaming, not positional: positional writes start at offset 0, so
    // `flint f.fl > log` or `2>&1` would overwrite earlier output.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const code = try compile(gpa, io, args, stdout, stderr);
    stdout.flush() catch {};
    stderr.flush() catch {};
    return code;
}

fn compile(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    var show_ast = false;
    var opt: []const u8 = "-O0"; // passed straight through to clang
    var path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--ast")) {
            show_ast = true;
        } else if (isOptFlag(arg)) {
            opt = arg;
        } else if (path == null) {
            path = arg;
        } else {
            path = null; // more than one file: a usage error
            break;
        }
    }
    const file = path orelse {
        try stderr.writeAll("usage: flint [--ast] [-O0|-O1|-O2|-O3] <file.fl>\n");
        return 2;
    };

    const source = Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited) catch {
        try stderr.print("flint: cannot open '{s}'\n", .{file});
        return 2;
    };
    defer gpa.free(source);

    // `source` must outlive the arena: AST names point into it.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag = Diagnostics.init(file, source, stderr);
    var lexer = Lexer.init(source);
    var parser = Parser.init(&lexer, arena, &diag);

    // Parse.
    const fns = try parser.parseFile();
    if (diag.errorCount() > 0) return 1; // don't analyse a broken tree

    // Names and types.
    var types = TypeTable.init(arena);
    var checker = Checker.init(arena, &diag, &types);
    try checker.run(fns);

    if (show_ast) {
        for (fns) |f| {
            try ast.dumpFn(stdout, f);
            try stdout.writeAll("\n");
        }
    }
    if (diag.errorCount() > 0) return 1; // borrow checking needs valid types

    // Ownership and borrows.
    var borrowck = BorrowChecker.init(gpa, &diag);
    defer borrowck.deinit();
    try borrowck.run(fns);
    if (diag.errorCount() > 0) return 1;

    const has_main = for (fns) |f| {
        if (std.mem.eql(u8, f.name, "main")) break true;
    } else false;
    if (!has_main) {
        try stderr.print("{s}: error: no 'fn main' to run\n", .{file});
        return 1;
    }

    // LLVM IR -> native executable via clang.
    // examples/answer.fl -> examples/answer.ll -> examples/answer
    const stem = if (std.mem.endsWith(u8, file, ".fl"))
        file[0 .. file.len - 3]
    else
        try std.fmt.allocPrint(arena, "{s}.out", .{file});
    const ll = try std.fmt.allocPrint(arena, "{s}.ll", .{stem});
    // Windows only runs files that end in .exe.
    const exe = if (builtin.os.tag == .windows) try std.fmt.allocPrint(arena, "{s}.exe", .{stem}) else stem;

    var ir: Io.Writer.Allocating = .init(arena);
    var codegen = CodeGen.init(arena);
    try codegen.run(&ir.writer, fns);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = ll, .data = ir.written() }) catch {
        try stderr.print("flint: cannot write '{s}'\n", .{ll});
        return 2;
    };

    // An argument list, not a shell command: no quoting problems anywhere.
    try stdout.flush();
    try stderr.flush();
    const argv = [_][]const u8{ "clang", opt, "-Wno-override-module", "-o", exe, ll };
    const ok = runChild(io, &argv);
    if (!ok) {
        try stderr.print("flint: clang failed on '{s}'\n", .{ll});
        return 1;
    }
    try stdout.print("built {s} ({s})\n", .{ exe, opt });
    return 0;
}

fn isOptFlag(arg: []const u8) bool {
    for ([_][]const u8{ "-O0", "-O1", "-O2", "-O3" }) |o| {
        if (std.mem.eql(u8, arg, o)) return true;
    }
    return false;
}

/// Runs a program with inherited stdio and waits for it. True on exit code 0.
fn runChild(io: Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv }) catch return false;
    const term = child.wait(io) catch return false;
    return term.success();
}

test {
    _ = @import("token.zig");
    _ = @import("lexer.zig");
    _ = @import("types.zig");
    _ = @import("diag.zig");
    _ = @import("parser.zig");
    _ = @import("checker.zig");
    _ = @import("cfg.zig");
    _ = @import("borrowck.zig");
    _ = @import("codegen.zig");
}
