#!/usr/bin/env bash
# Runs on a cache miss before the checkout: remove any leftover source or
# install tree at the work directory. A previous build in the same job may have
# used the same directory (same fingerprint), and files created there by a
# sudo build are root-owned, which actions/checkout cannot clean up itself.
#
# Inputs (environment):
#   SOURCE_PATH, INSTALL_PATH   from fingerprint.sh
#   USE_SUDO                    remove as root via sudo (default true)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${SOURCE_PATH:?}" "${INSTALL_PATH:?}"

for dir in "$SOURCE_PATH" "$INSTALL_PATH"; do
  if [ -e "$dir" ]; then
    log "Removing leftover $dir"
    run_privileged rm -rf "$dir"
  fi
done
mkdir -p "$(dirname "$SOURCE_PATH")"
