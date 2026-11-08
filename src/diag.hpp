#pragma once
#include <cstdint>
#include <cstdio>
#include <string_view>

// Turns byte offsets into "file:line:col" messages with the source line
// and a caret under the problem. Line/col are only computed when a
// message is actually reported, so the lexer stays fast.
class Diagnostics {
public:
  Diagnostics(std::string_view path, std::string_view source)
      : path_(path), src_(source) {}

  void error(std::uint32_t offset, std::string_view msg) {
    ++errors_;
    report("error", offset, msg);
  }

  // Extra context for the previous error, e.g. "value was moved here".
  void note(std::uint32_t offset, std::string_view msg) {
    report("note", offset, msg);
  }

  int error_count() const { return errors_; }

private:
  std::string_view path_;
  std::string_view src_;
  int errors_ = 0;

  void report(const char *label, std::uint32_t offset, std::string_view msg) {
    // Find the start of the line containing `offset`, and its number.
    std::uint32_t line = 1;
    std::uint32_t line_start = 0;
    for (std::uint32_t i = 0; i < offset && i < src_.size(); ++i) {
      if (src_[i] == '\n') {
        ++line;
        line_start = i + 1;
      }
    }
    const std::uint32_t col = offset - line_start + 1; // 1-based

    std::uint32_t line_end = line_start;
    while (line_end < src_.size() && src_[line_end] != '\n')
      ++line_end;
    const std::string_view text =
        src_.substr(line_start, line_end - line_start);

    std::fprintf(stderr, "%.*s:%u:%u: %s: %.*s\n",
                 static_cast<int>(path_.size()), path_.data(), line, col, label,
                 static_cast<int>(msg.size()), msg.data());
    std::fprintf(stderr, "    %.*s\n    ", static_cast<int>(text.size()),
                 text.data());
    // Copy tabs from the source line so the caret lines up.
    for (std::uint32_t i = line_start; i < offset && i < line_end; ++i) {
      std::fputc(src_[i] == '\t' ? '\t' : ' ', stderr);
    }
    std::fputs("^\n", stderr);
  }
};
