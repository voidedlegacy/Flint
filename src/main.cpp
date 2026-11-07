#include "arena.hpp"
#include "ast.hpp"
#include <cstdio>

int main() {
  Arena arena;

  // Build the tree for:  -(1 + x) * &mut y
  // by hand. The parser will do this for us in a later step.
  Expr *one = arena.make<IntExpr>(2u, 1u);
  Expr *x = arena.make<IdentExpr>(6u, "x");
  Expr *sum = arena.make<BinaryExpr>(2u, TokenKind::Plus, one, x);
  Expr *neg = arena.make<UnaryExpr>(0u, TokenKind::Minus, false, sum);
  Expr *y = arena.make<IdentExpr>(16u, "y");
  Expr *ref = arena.make<UnaryExpr>(11u, TokenKind::Amp, true, y);
  Expr *root = arena.make<BinaryExpr>(0u, TokenKind::Star, neg, ref);

  dump(root);
  std::printf("\nsizeof: Int=%zu Ident=%zu Unary=%zu Binary=%zu\n",
              sizeof(IntExpr), sizeof(IdentExpr), sizeof(UnaryExpr),
              sizeof(BinaryExpr));
}
