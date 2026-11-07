#include "arena.hpp"
#include "lexer.hpp"
#include "parser.hpp"
#include <cstdio>

static void run(const char *source) {
  Arena arena;
  Lexer lexer(source);
  Parser parser(lexer, arena);

  Expr *e = parser.parse_expr();
  std::printf("%-22s => ", source);
  dump(e);
  std::printf("%s\n", parser.had_error() ? "   [had error]" : "");
}

int main() {
  run("1 + 2 * 3");
  run("1 - 2 - 3");
  run("(1 + 2) * 3");
  run("-(1 + x) * &mut y");
  run("a == b + 1");
  run("1 + )");
}
