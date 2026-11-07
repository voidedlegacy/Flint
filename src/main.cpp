#include "arena.hpp"
#include "lexer.hpp"
#include "parser.hpp"
#include <cstdio>

int main() {
  const char *source = R"(fn main() {
	var count = 42
}

fn helper() {
	let x = 1
	{ var y = x + 1 }
	return x
}

var stray = 5

fn empty() {}
)";

  Arena arena;
  Lexer lexer(source);
  Parser parser(lexer, arena);

  for (FnDecl *fn : parser.parse_file()) {
    dump(fn);
    std::printf("\n");
  }
  std::printf("had error: %s\n", parser.had_error() ? "yes" : "no");
}
