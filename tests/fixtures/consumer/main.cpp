#include <fmt/core.h>
#include <spdlog/spdlog.h>
#include <spdlog/version.h>

int main() {
  spdlog::info("fmt {} / spdlog {}.{}.{}", FMT_VERSION, SPDLOG_VER_MAJOR, SPDLOG_VER_MINOR, SPDLOG_VER_PATCH);
  fmt::print("FMT_VERSION={}\n", FMT_VERSION);
  return 0;
}
