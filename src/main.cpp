#include "arena.hpp"
#include <cstdint>
#include <cstdio>

struct Point {
  int x;
  int y;
};
struct Wide {
  char tag;
  double value;
};

int main() {
  Arena arena(1024); // small blocks so we force several of them

  Point *first = nullptr;
  Point *last = nullptr;
  for (int i = 0; i < 1000; ++i) {
    Point *p = arena.make<Point>(i, i * 2);
    if (i == 0)
      first = p;
    if (i == 999)
      last = p;
  }

  Wide *w = arena.make<Wide>('w', 3.5);
  const bool aligned = reinterpret_cast<std::uintptr_t>(w) % alignof(Wide) == 0;

  std::printf("first = (%d, %d)\n", first->x, first->y);
  std::printf("last  = (%d, %d)\n", last->x, last->y);
  std::printf("wide  = %c %.1f, aligned = %s\n", w->tag, w->value,
              aligned ? "yes" : "no");
  std::printf("bytes used = %zu\n", arena.bytes_used());
}
