#!/usr/bin/env bash
# Tiny assertion helpers shared by the test files.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/../scripts" && pwd)"
export TESTS_DIR SCRIPTS_DIR
FAILED=0 PASSED=0

fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; PASSED=$((PASSED + 1)); }

assert_eq() { # assert_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then pass "$1"; else fail "$1: expected something other than '$2'"; fi
}
assert_contains() { # assert_contains <desc> <needle> <haystack>
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1: '$2' not found in: $3" ;; esac
}
assert_not_contains() {
  case "$3" in *"$2"*) fail "$1: '$2' unexpectedly found in: $3" ;; *) pass "$1" ;; esac
}
assert_file() { if [ -e "$2" ]; then pass "$1"; else fail "$1: $2 does not exist"; fi; }
assert_status() { assert_eq "$1" "$2" "$3"; }

# Read a key from a GITHUB_OUTPUT / GITHUB_ENV style file (supports heredocs).
output_value() { # output_value <file> <name>
  awk -v name="$2" '
    heredoc { if ($0 == delim) { heredoc = 0; exit } ; buf = buf (buf == "" ? "" : "\n") $0; next }
    index($0, name "<<") == 1 { heredoc = 1; delim = substr($0, length(name) + 3); next }
    index($0, name "=") == 1 { buf = substr($0, length(name) + 2); found = 1; exit }
    END { if (heredoc || found || buf != "") printf "%s", buf }
  ' "$1"
}

# Fresh temp dir per test case, wired up as GITHUB_OUTPUT / GITHUB_ENV.
new_case() {
  CASE_DIR="$(mktemp -d)"
  export GITHUB_OUTPUT="$CASE_DIR/output" GITHUB_ENV="$CASE_DIR/env"
  : > "$GITHUB_OUTPUT"; : > "$GITHUB_ENV"
}

report() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASSED" "$FAILED"
  [ "$FAILED" -eq 0 ]
}
