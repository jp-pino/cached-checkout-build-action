#!/usr/bin/env bash
# Tests for scripts/build.sh and scripts/install.sh using the hello fixture.
set -u
. "$(dirname "$0")/lib.sh"
command -v cmake >/dev/null 2>&1 || { echo "cmake not installed; skipping"; exit 0; }

export USE_SUDO=false
unset PRE_BUILD_COMMAND CMAKE_FLAGS BUILD_FLAGS BUILD_SHELL

setup_src() {
  export SOURCE_PATH="$CASE_DIR/work/git" INSTALL_PATH="$CASE_DIR/work/cache" INSTALL_PREFIX="$CASE_DIR/prefix"
  mkdir -p "$SOURCE_PATH"
  cp -R "$TESTS_DIR/fixtures/hello/." "$SOURCE_PATH/"
}
run_build()   { OUT="$("$SCRIPTS_DIR/build.sh" 2>&1)"; RC=$?; }
run_install() { OUT="$("$SCRIPTS_DIR/install.sh" 2>&1)"; RC=$?; }

echo "# plain build + install"
new_case; setup_src
run_build
assert_status "build exits 0" 0 "$RC"
assert_file "installed header" "$INSTALL_PATH/include/hello/hello.h"
assert_eq "default message" "default message" "$(cat "$INSTALL_PATH/share/hello/hello.txt")"
run_install
assert_status "install exits 0" 0 "$RC"
assert_file "copied to prefix" "$INSTALL_PREFIX/include/hello/hello.h"
assert_file "copied to prefix (share)" "$INSTALL_PREFIX/share/hello/hello.txt"

echo "# cmake-flags with quoted values, pre-build-command, build-flags"
new_case; setup_src
# shellcheck disable=SC2016 # the command is evaluated by the build shell
CMAKE_FLAGS='-DHELLO_MESSAGE="hello world"' PRE_BUILD_COMMAND='export HELLO_PREBUILD_MARKER=prebuilt-$(echo ok)' BUILD_FLAGS='--verbose' run_build
assert_status "build exits 0" 0 "$RC"
assert_eq "quoted flag value preserved" "hello world" "$(cat "$INSTALL_PATH/share/hello/hello.txt")"
assert_eq "pre-build-command ran in the build shell" "prebuilt-ok" "$(cat "$INSTALL_PATH/share/hello/marker.txt")"

echo "# failing pre-build-command fails the build"
new_case; setup_src
PRE_BUILD_COMMAND='false' run_build
assert_status "build exits non-zero" 1 "$RC"

echo "# unknown shell is reported"
new_case; setup_src
BUILD_SHELL=no-such-shell run_build
assert_status "exits 1" 1 "$RC"
assert_contains "error names the shell" "no-such-shell" "$OUT"

if command -v zsh >/dev/null 2>&1; then
  echo "# zsh build shell"
  new_case; setup_src
  # shellcheck disable=SC2016 # the command is evaluated by zsh
  BUILD_SHELL=zsh CMAKE_FLAGS='-DHELLO_MESSAGE="from zsh"' PRE_BUILD_COMMAND='export HELLO_PREBUILD_MARKER=$ZSH_VERSION' run_build
  assert_status "build exits 0" 0 "$RC"
  assert_eq "flags split correctly under zsh" "from zsh" "$(cat "$INSTALL_PATH/share/hello/hello.txt")"
  if [ -n "$(cat "$INSTALL_PATH/share/hello/marker.txt")" ]; then pass "pre-build-command ran under zsh"; else fail "ZSH_VERSION marker empty"; fi
else
  echo "# zsh not installed; skipping zsh case"
fi

echo "# prepare removes leftovers from an earlier build"
new_case; setup_src
mkdir -p "$SOURCE_PATH/build" "$INSTALL_PATH/include"
touch "$SOURCE_PATH/build/CMakeCache.txt" "$INSTALL_PATH/include/stale.h"
OUT="$("$SCRIPTS_DIR/prepare.sh" 2>&1)"; RC=$?
assert_status "prepare exits 0" 0 "$RC"
if [ ! -e "$SOURCE_PATH" ]; then pass "source tree removed"; else fail "source tree still exists"; fi
if [ ! -e "$INSTALL_PATH" ]; then pass "install tree removed"; else fail "install tree still exists"; fi
assert_file "parent directory exists for the checkout" "$(dirname "$SOURCE_PATH")"
assert_contains "logs what it removed" "Removing leftover $SOURCE_PATH" "$OUT"
new_case; export SOURCE_PATH="$CASE_DIR/none/git" INSTALL_PATH="$CASE_DIR/none/cache"
OUT="$("$SCRIPTS_DIR/prepare.sh" 2>&1)"; RC=$?
assert_status "prepare with nothing to remove exits 0" 0 "$RC"
assert_not_contains "nothing logged" "Removing" "$OUT"

echo "# install without a build tree fails clearly"
new_case; export INSTALL_PATH="$CASE_DIR/missing" INSTALL_PREFIX="$CASE_DIR/prefix"
run_install
assert_status "exits 1" 1 "$RC"
assert_contains "explains" "Nothing to install" "$OUT"

report
