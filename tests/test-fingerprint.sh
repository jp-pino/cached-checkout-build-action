#!/usr/bin/env bash
# Tests for scripts/fingerprint.sh (pure, no network).
set -u
. "$(dirname "$0")/lib.sh"

export RUNNER_OS=Linux RUNNER_ARCH=X64
export REPOSITORY=BluEye-Robotics/libguestport REPO_NAME=libguestport REF=main
export SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
unset INPUT_CMAKE_FLAGS INPUT_BUILD_FLAGS INPUT_PRE_BUILD_COMMAND INPUT_SUBMODULES INPUT_CACHE_KEY_EXTRA INPUT_DEPENDS_ON CACHED_BUILD_REGISTRY

run() { OUT="$("$SCRIPTS_DIR/fingerprint.sh" 2>&1)"; RC=$?; }
out() { output_value "$GITHUB_OUTPUT" "$1"; }
envv() { output_value "$GITHUB_ENV" "$1"; }
FP_PROTO=1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
FP_BLUNUX=fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321
REG_PROTO="blueye-robotics/protocoldefinitions	bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb	$FP_PROTO"
REG_BLUNUX="blueye-robotics/libblunux	cccccccccccccccccccccccccccccccccccccccc	$FP_BLUNUX"

echo "# no dependencies"
new_case; export GITHUB_WORKSPACE="$CASE_DIR/ws"
run
assert_status "exits 0" 0 "$RC"
fp0="$(out fingerprint)"
if [[ "$fp0" =~ ^[0-9a-f]{64}$ ]]; then pass "fingerprint is sha256 hex"; else fail "fingerprint: $fp0"; fi
assert_eq "cache key" "cached-build-Linux-X64-libguestport-aaaaaaaaaaaa-$fp0" "$(out cache-key)"
assert_eq "work dir" "$GITHUB_WORKSPACE/.cached-checkout-build/libguestport-${fp0:0:12}" "$(out work-dir)"
assert_eq "source path" "$(out work-dir)/git" "$(out source-path)"
assert_eq "checkout path is workspace-relative" ".cached-checkout-build/libguestport-${fp0:0:12}/git" "$(out checkout-path)"
assert_eq "install path" "$(out work-dir)/cache" "$(out install-path)"
assert_eq "registry created" "blueye-robotics/libguestport	$SHA	$fp0" "$(envv CACHED_BUILD_REGISTRY)"
assert_eq "no dependencies output" "" "$(out dependencies)"

echo "# deterministic, and sensitive to every input"
new_case; run; assert_eq "same inputs -> same fingerprint" "$fp0" "$(out fingerprint)"
new_case; SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb run; assert_ne "sha changes it" "$fp0" "$(out fingerprint)"
new_case; INPUT_CMAKE_FLAGS=-DENABLE_TRITECH=OFF run; assert_ne "cmake-flags change it" "$fp0" "$(out fingerprint)"
new_case; INPUT_BUILD_FLAGS=--verbose run; assert_ne "build-flags change it" "$fp0" "$(out fingerprint)"
new_case; INPUT_PRE_BUILD_COMMAND='source /opt/ros/jazzy/setup.zsh' run; assert_ne "pre-build-command changes it" "$fp0" "$(out fingerprint)"
new_case; INPUT_SUBMODULES=true run; assert_ne "submodules change it" "$fp0" "$(out fingerprint)"
new_case; INPUT_CACHE_KEY_EXTRA=v2 run; assert_ne "cache-key-extra changes it" "$fp0" "$(out fingerprint)"
new_case; REPOSITORY=blueye-robotics/LIBGUESTPORT run; assert_eq "repository case does not change it" "$fp0" "$(out fingerprint)"
new_case; RUNNER_OS=macOS run; assert_eq "runner OS is not part of the fingerprint" "$fp0" "$(out fingerprint)"
assert_contains "...but is part of the cache key" "cached-build-macOS-" "$(out cache-key)"

echo "# depends-on resolves from the registry"
new_case; CACHED_BUILD_REGISTRY="$REG_PROTO"$'\n'"$REG_BLUNUX" INPUT_DEPENDS_ON='BluEye-Robotics/ProtocolDefinitions, libblunux' run
assert_status "exits 0" 0 "$RC"
fp_deps="$(out fingerprint)"
assert_ne "dependencies change the fingerprint" "$fp0" "$fp_deps"
assert_eq "dependencies listed (sorted)" "$REG_BLUNUX"$'\n'"$REG_PROTO" "$(out dependencies)"
assert_contains "dependencies logged" "blueye-robotics/libblunux @ cccccccccccc" "$OUT"
assert_eq "registry appended" "$REG_PROTO"$'\n'"$REG_BLUNUX"$'\n'"blueye-robotics/libguestport	$SHA	$fp_deps" "$(envv CACHED_BUILD_REGISTRY)"

echo "# order and separators do not matter"
new_case; CACHED_BUILD_REGISTRY="$REG_PROTO"$'\n'"$REG_BLUNUX" INPUT_DEPENDS_ON=$'libblunux\nprotocoldefinitions' run
assert_eq "newline separated, reversed order" "$fp_deps" "$(out fingerprint)"
new_case; CACHED_BUILD_REGISTRY="$REG_PROTO"$'\n'"$REG_BLUNUX" INPUT_DEPENDS_ON='all' run
assert_eq "'all' equals listing both" "$fp_deps" "$(out fingerprint)"
new_case; CACHED_BUILD_REGISTRY="$REG_PROTO"$'\n'"$REG_BLUNUX" INPUT_DEPENDS_ON='libblunux, ALL ,libblunux' run
assert_eq "duplicates collapse" "$fp_deps" "$(out fingerprint)"

echo "# a dependency rebuilt at a new ref changes this fingerprint"
REG_BLUNUX2="blueye-robotics/libblunux	dddddddddddddddddddddddddddddddddddddddd	0000000000000000000000000000000000000000000000000000000000000000"
new_case; CACHED_BUILD_REGISTRY="$REG_PROTO"$'\n'"$REG_BLUNUX2" INPUT_DEPENDS_ON='protocoldefinitions,libblunux' run
assert_ne "fingerprint differs" "$fp_deps" "$(out fingerprint)"
new_case; CACHED_BUILD_REGISTRY="$REG_PROTO"$'\n'"$REG_BLUNUX"$'\n'"$REG_BLUNUX2" INPUT_DEPENDS_ON='libblunux' run
assert_contains "last registration of a repo wins" "dddddddddddd" "$(out dependencies)"
assert_not_contains "older registration ignored" "cccccccccccc" "$(out dependencies)"

echo "# subset of dependencies: only the listed ones matter"
new_case; CACHED_BUILD_REGISTRY="$REG_PROTO"$'\n'"$REG_BLUNUX" INPUT_DEPENDS_ON='protocoldefinitions' run
fp_proto_only="$(out fingerprint)"
new_case; CACHED_BUILD_REGISTRY="$REG_PROTO"$'\n'"$REG_BLUNUX2" INPUT_DEPENDS_ON='protocoldefinitions' run
assert_eq "unrelated rebuild does not change it" "$fp_proto_only" "$(out fingerprint)"

echo "# unknown dependency fails with a helpful message"
new_case; CACHED_BUILD_REGISTRY="$REG_PROTO" INPUT_DEPENDS_ON='tyndall' run
assert_status "exits 1" 1 "$RC"
assert_contains "names the missing dependency" "'tyndall' has not been built earlier" "$OUT"
assert_contains "lists what is registered" "blueye-robotics/protocoldefinitions" "$OUT"
new_case; INPUT_DEPENDS_ON='tyndall' run
assert_status "exits 1 with empty registry" 1 "$RC"
assert_contains "says none registered" "Registered so far: none" "$OUT"

echo "# ref with slashes gives a safe directory name"
new_case; REPO_NAME='weird name/x' run
assert_contains "sanitised" "/.cached-checkout-build/weird-name-x-" "$(out work-dir)"

report
