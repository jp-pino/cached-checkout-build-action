#!/usr/bin/env bash
# Copy the (restored or freshly built) install tree into INSTALL_PREFIX.
#
# Inputs (environment):
#   INSTALL_PATH      from fingerprint.sh
#   INSTALL_PREFIX    destination, default /usr/local
#   USE_SUDO          run as root via sudo (default true)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${INSTALL_PATH:?}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"

[ -d "$INSTALL_PATH" ] || die "Nothing to install: $INSTALL_PATH does not exist (the build produced no install tree?)"

log "Installing $INSTALL_PATH into $INSTALL_PREFIX"
run_privileged mkdir -p "$INSTALL_PREFIX"
run_privileged cp -a "$INSTALL_PATH/." "$INSTALL_PREFIX/"

# Refresh the dynamic linker cache so freshly installed shared libraries are
# found at runtime without LD_LIBRARY_PATH.
if [ "$(uname -s)" = Linux ] && command -v ldconfig >/dev/null 2>&1; then
  run_privileged ldconfig || warn "ldconfig failed; shared libraries in $INSTALL_PREFIX/lib may need LD_LIBRARY_PATH"
fi
