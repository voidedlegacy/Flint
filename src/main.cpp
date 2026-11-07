#include "token.hpp"
#include <cstdio>

int main() {
  Token t{.offset = 0, .length = 3, .kind = TokenKind::KwVar};
  std::printf("sizeof(Token) = %zu, kind = %d\n", sizeof(Token),
              static_cast<int>(t.kind));
}
