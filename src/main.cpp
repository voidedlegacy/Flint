#include "arena.hpp"
#include "lexer.hpp"
#include "parser.hpp"
#include <cstdio>

int main() {
  const char *source = R"(var count = 42
let limit = count * 2 +
    1
count == limit
let 5 = oops
return
return count
)";

  Arena arena;
  Lexer lexer(source);
  Parser parser(lexer, arena);

  while (!parser.at_eof()) {
    dump(parser.parse_stmt());
    std::printf("\n");
  }
  std::printf("had error: %s\n", parser.had_error() ? "yes" : "no");
}
