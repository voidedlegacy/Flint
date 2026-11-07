#pragma once
#include <cstddef>
#include <memory>
#include <new>
#include <type_traits>
#include <utility>
#include <vector>

// Bump allocator for AST nodes. Allocation is a pointer bump; everything
// is freed at once when the Arena is destroyed. Destructors never run,
// so only trivially destructible types may live here.
class Arena {
public:
  explicit Arena(std::size_t block_size = 64 * 1020)
      : block_size_(block_size) {}

  Arena(const Arena &) = delete;
  Arena &operator=(const Arena &) = delete;

  template <typename T, typename... Args> T *make(Args &&...args) {
    static_assert(std::is_trivially_destructible_v<T>,
                  "Arena never runs destructors");
    static_assert(alignof(T) <= alignof(std::max_align_t),
                  "over-aligned types are not supported");
    void *mem = allocate(sizeof(T), alignof(T));
    return ::new (mem) T{std::forward<Args>(args)...};
  }

  std::size_t bytes_used() const { return used_; }

private:
  std::vector<std::unique_ptr<std::byte[]>> blocks_;
  std::size_t block_size_;
  std::size_t capacity_ = 0; // size of the current block
  std::size_t offset_ = 0;   // next free byte in the current block
  std::size_t used_ = 0;     // total bytes handed out

  void *allocate(std::size_t size, std::size_t align) {
    // Round offset_ up to a multiple of align (align is a power of two).
    std::size_t start = (offset_ + align - 1) & ~(align - 1);

    if (blocks_.empty() || start + size > capacity_) {
      capacity_ = size > block_size_ ? size : block_size_;
      blocks_.push_back(std::unique_ptr<std::byte[]>(new std::byte[capacity_]));
      start = 0; // new[] memory is aligned for any standard type
    }

    offset_ = start + size;
    used_ += size;
    return blocks_.back().get() + start;
  }
};
