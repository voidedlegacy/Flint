#include "arena.hpp"
#include "borrowck.hpp"
#include "codegen.hpp"
#include "diag.hpp"
#include "lexer.hpp"
#include "parser.hpp"
#include "sema.hpp"
#include "types.hpp"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>

// Reads a whole file into a string. Returns nullopt if it can't be opened.
static std::optional<std::string> read_file(const std::string &path) {
  std::ifstream in(path, std::ios::binary);
  if (!in)
    return std::nullopt;
  std::ostringstream buf;
  buf << in.rdbuf();
  return std::move(buf).str();
}

static bool write_file(const std::string &path, const std::string &text) {
  std::ofstream out(path, std::ios::binary);
  out << text;
  return static_cast<bool>(out);
}

int main(int argc, char **argv) {
  // flint [--ast] <file.fl>
  bool show_ast = false;
  std::string path;
  for (int i = 1; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (arg == "--ast") {
      show_ast = true;
    } else if (path.empty()) {
      path = arg;
    } else {
      path.clear(); // more than one file: treat as a usage error
      break;
    }
  }
  if (path.empty()) {
    std::fprintf(stderr, "usage: flint [--ast] <file.fl>\n");
    return 2;
  }

  const auto source = read_file(path);
  if (!source) {
    std::fprintf(stderr, "flint: cannot open '%s'\n", path.c_str());
    return 2;
  }

  // `source` must outlive the arena: AST names point into it.
  Diagnostics diag(path, *source);
  Arena arena;
  Lexer lexer(*source);
  Parser parser(lexer, arena, diag);

  // Stage 2: parse.
  const auto fns = parser.parse_file();
  if (diag.error_count() > 0)
    return 1; // don't analyse a broken tree

  // Stage 3: names and types.
  TypeTable types(arena);
  Checker checker(diag, types);
  checker.run(fns);

  if (show_ast) {
    for (FnDecl *fn : fns) {
      dump(fn);
      std::printf("\n");
    }
  }
  if (diag.error_count() > 0)
    return 1; // borrow checking needs valid types

  // Stage 4: ownership and borrows.
  BorrowChecker borrowck(diag);
  borrowck.run(fns);
  if (diag.error_count() > 0)
    return 1;

  bool has_main = false;
  for (FnDecl *fn : fns)
    has_main = has_main || fn->name == "main";
  if (!has_main) {
    std::fprintf(stderr, "%s: error: no 'fn main' to run\n", path.c_str());
    return 1;
  }

  // Stage 5: LLVM IR → native executable via clang.
  // examples/answer.fl → examples/answer.ll → examples/answer
  const std::string stem =
      path.ends_with(".fl") ? path.substr(0, path.size() - 3) : path + ".out";
  const std::string ll = stem + ".ll";

  CodeGen codegen;
  if (!write_file(ll, codegen.run(fns))) {
    std::fprintf(stderr, "flint: cannot write '%s'\n", ll.c_str());
    return 2;
  }

  const std::string cmd =
      "clang -Wno-override-module -o '" + stem + "' '" + ll + "'";
  if (std::system(cmd.c_str()) != 0) {
    std::fprintf(stderr, "flint: clang failed on '%s'\n", ll.c_str());
    return 1;
  }
  std::printf("built %s\n", stem.c_str());
  return 0;
}
