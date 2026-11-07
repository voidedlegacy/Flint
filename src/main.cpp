#include "lexer.hpp"
#include <cstdio>

int main() {
  Lexer lex("fn main() {\n\tvar count=\n\t\t42\n}");

  for (Token t = lex.next(); t.kind != TokenKind::Eof; t = lex.next()) {
    const auto s = lex.text(t);
    std::printf("kind=%-3d offset=%-3u text='%.*s'\n", static_cast<int>(t.kind),
                t.offset, static_cast<int>(s.size()), s.data());
  }
}
