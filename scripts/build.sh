#!/usr/bin/env bash
# Configure, build and install the checked-out sources into INSTALL_PATH.
#
# Inputs (environment):
#   SOURCE_PATH, INSTALL_PATH            from fingerprint.sh
#   BUILD_SHELL                          shell used for the build (bash, zsh, ...)
#   PRE_BUILD_COMMAND, CMAKE_FLAGS, BUILD_FLAGS
#   USE_SUDO                             run as root via sudo (default true)
#   BUILD_JOBS                           parallel jobs (default: online CPUs)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${SOURCE_PATH:?}" "${INSTALL_PATH:?}"
BUILD_SHELL="${BUILD_SHELL:-bash}"
export PRE_BUILD_COMMAND="${PRE_BUILD_COMMAND:-}"
export CMAKE_FLAGS="${CMAKE_FLAGS:-}"
export BUILD_FLAGS="${BUILD_FLAGS:-}"
export SOURCE_PATH INSTALL_PATH
export BUILD_JOBS="${BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

command -v "$BUILD_SHELL" >/dev/null 2>&1 || die "shell '$BUILD_SHELL' is not installed on this runner"

# The build script is written to a file and run by the requested shell so that
# a pre-build-command such as "source /opt/ros/jazzy/setup.zsh" runs in that
# shell. Flags are evaluated as shell text, so quoting works as on a command
# line: cmake-flags: -DFOO="a b".
script="$(mktemp)"
trap 'rm -f "$script"' EXIT
cat > "$script" <<'BUILD'
set -e
if [ -n "$PRE_BUILD_COMMAND" ]; then
  eval "$PRE_BUILD_COMMAND"
fi
mkdir -p "$SOURCE_PATH/build" "$INSTALL_PATH"
cd "$SOURCE_PATH/build"
eval "cmake -DCMAKE_INSTALL_PREFIX=\"\$INSTALL_PATH\" $CMAKE_FLAGS \"\$SOURCE_PATH\""
eval "cmake --build . --target install -j \"\$BUILD_JOBS\" $BUILD_FLAGS"
BUILD

log "Building $SOURCE_PATH with $BUILD_SHELL (-j $BUILD_JOBS) into $INSTALL_PATH"
run_privileged "$BUILD_SHELL" "$script"
