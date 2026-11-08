#pragma once
#include "arena.hpp"
#include <string>
#include <vector>

enum class TypeKind : std::uint8_t { Error, I64, Bool, Ref };

// Types are interned: each distinct type exists exactly once, so two
// types are equal if and only if their pointers are equal.
struct Type {
  TypeKind kind;
  Type *pointee = nullptr; // for Ref: the type being pointed at
  bool is_mut = false;     // for Ref: &mut vs &
};

class TypeTable {
public:
  explicit TypeTable(Arena &arena) : arena_(arena) {}

  TypeTable(const TypeTable &) = delete;
  TypeTable &operator=(const TypeTable &) = delete;

  Type *error() {
    return &error_;
  } // "already reported", silences follow-up errors
  Type *i64() { return &i64_; }
  Type *boolean() { return &bool_; }

  // Returns the one shared Type for &T or &mut T.
  Type *ref(Type *pointee, bool is_mut) {
    for (Type *t : refs_) {
      if (t->pointee == pointee && t->is_mut == is_mut)
        return t;
    }
    Type *t = arena_.make<Type>(TypeKind::Ref, pointee, is_mut);
    refs_.push_back(t);
    return t;
  }

private:
  Arena &arena_;
  Type error_{TypeKind::Error};
  Type i64_{TypeKind::I64};
  Type bool_{TypeKind::Bool};
  std::vector<Type *> refs_;
};

inline std::string type_name(const Type *t) {
  switch (t->kind) {
  case TypeKind::Error:
    return "<error>";
  case TypeKind::I64:
    return "i64";
  case TypeKind::Bool:
    return "bool";
  case TypeKind::Ref:
    return (t->is_mut ? "&mut " : "&") + type_name(t->pointee);
  }
  return "?";
}
