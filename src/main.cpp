#include "arena.hpp"
#include "lexer.hpp"
#include "parser.hpp"
#include <cstdio>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>

// Reads a whole file into a string. Returns nullopt if it can't be opened.
static std::optional<std::string> read_file(const char *path) {
  std::ifstream in(path, std::ios::binary);
  if (!in)
    return std::nullopt;
  std::ostringstream buf;
  buf << in.rdbuf();
  return std::move(buf).str();
}

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: flint <file.fl>\n");
    return 2;
  }

  const auto source = read_file(argv[1]);
  if (!source) {
    std::fprintf(stderr, "flint: cannot open '%s'\n", argv[1]);
    return 2;
  }

  // `source` must outlive the arena: AST names point into it.
  Diagnostics diag(argv[1], *source);
  Arena arena;
  Lexer lexer(*source);
  Parser parser(lexer, arena, diag);

  for (FnDecl *fn : parser.parse_file()) {
    dump(fn);
    std::printf("\n");
  }
  return parser.had_error() ? 1 : 0;
}
