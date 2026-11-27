# Flint roadmap

Work through these one micro-step at a time, in order, after the Zig port matches the C++ version.
Each step needs: a working build, an example in examples/ (a passing program and/or an error file),
an update to the test runner's expected results, and a commit.

## Language

- [x] 29. Dereference: `*r` reads through `&T`/`&mut T`; `*r = e` writes, and only through `&mut T`.
      Borrowck: writing through r counts as a use of r's loans. Codegen: load/store through the ptr.
      Test: `fn bump(c: &mut i64) { *c = *c + 1 }` changes the caller's variable.
- [x] 30. `break` and `continue`. Replace the borrow checker's "later in the source" rule with a real
      control-flow graph plus liveness analysis. This also fixes if/else being too strict, where a use
      in `else` counted as "after" code in `then`. A `for { }` that contains `break` no longer counts
      as "always returns".
- [x] 31. Logic: `!x`, `a && b`, `a || b` on bool, with short-circuit codegen (branches, not `and`).
      Precedence, lowest first: `||`, `&&`, comparisons, `+ -`, `* /`, prefix.
- [x] 32. Calling C: `extern fn putchar(c: i32) -> i32` declares a C function (emitted as an LLVM `declare`).
      First visible output: print digits and a newline.
      The signature needed `i32`, so it came early, along with the literal rule from step 33: an integer
      literal takes the integer type its context wants (default i64), and must fit in it. No casts yet.
      The example runner also checks a program's stdout against tests/expected/<name>.out.
- [ ] 33. More integer types: i8 i16 u8 u16 u32 u64 (i32 and i64 exist), explicit casts with `as`, no
      implicit conversions. Integer literals already take the type they're used as (default i64).
- [ ] 34. Strings: `str` type = (ptr, len) and a `print(s: str)` built on the C call from step 32.
      Real "Hello, world!".
- [ ] 35. Structs: `type Point struct { x: i64, y: i64 }`, literals `Point{ x: 1, y: 2 }`, field
      access and assignment. A struct is Copy only if every field is Copy. Borrowck tracks places
      like `p.x`, so borrowing `p.x` and `p.y` at the same time is fine.
- [ ] 36. Fixed arrays `[4]i64` and slices `[]i64` with bounds checks that trap. Indexing is a place,
      like a field.
- [ ] 37. `unsafe { }` blocks: raw pointers `*T` and `*mut T`, `&x as *T`, pointer arithmetic, and
      deref allowed only inside unsafe. Borrowck doesn't track raw pointers.
- [ ] 38. Inline assembly inside unsafe, `asm("...")`, lowered to LLVM inline asm.
- [ ] 39. Modules: one file per module, `import "math"`, `pub fn` to export. No headers and no
      declaration order inside a module.
- [ ] 40. Owned heap values: a `Box(T)`-style type that's freed when its owner goes out of scope
      (drop), and moved like `&mut`. No garbage collector and no hidden allocations.

## Compiler

- [ ] 41. Own IR: lower the checked AST to a small SSA IR, then emit LLVM IR from that.
- [ ] 42. Speed: measure compile time on a large generated file and make it fast (aim for Zig-level).
- [ ] 43. Optional custom backend: emit x86-64 or ARM64 assembly directly for -O0 builds.
