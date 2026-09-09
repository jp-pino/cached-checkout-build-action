#!/usr/bin/env bash
# Run every tests/test-*.sh; exit non-zero if any fails.
set -u
cd "$(dirname "$0")" || exit 1
status=0
for t in test-*.sh; do
  echo "=== $t"
  bash "$t" || status=1
  echo
done
if [ "$status" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit "$status"
