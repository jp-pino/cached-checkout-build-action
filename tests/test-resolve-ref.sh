#!/usr/bin/env bash
# Tests for scripts/resolve-ref.sh against the mock GitHub API.
set -u
. "$(dirname "$0")/lib.sh"

export PATH="$TESTS_DIR/mock:$PATH"
export GITHUB_API_URL="https://api.github.com" GITHUB_SERVER_URL="https://github.com"
export INPUT_TOKEN="t0ken"
unset GITHUB_REPOSITORY GITHUB_SHA INPUT_REF INPUT_DEPENDENCY_OVERRIDES

SHA_MAIN=1111111111111111111111111111111111111111
SHA_FEAT=2222222222222222222222222222222222222222
SHA_PR=3333333333333333333333333333333333333333
SHA_COMMIT=4444444444444444444444444444444444444444

setup_api() {
  export MOCK_API_DIR="$CASE_DIR/api" MOCK_API_LOG="$CASE_DIR/api.log" MOCK_API_HEADERS="$CASE_DIR/headers"
  mkdir -p "$MOCK_API_DIR"
  : > "$MOCK_API_LOG"
  echo '{"name":"libblunux","default_branch":"main"}' > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux.json"
  echo "{\"sha\":\"$SHA_MAIN\"}" > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__commits__main.json"
  echo "{\"sha\":\"$SHA_FEAT\"}" > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__commits__rust_conversion.json"
  echo "{\"sha\":\"$SHA_FEAT\"}" > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__commits__feature%2Fnested%2Fbranch.json"
  echo "{\"sha\":\"$SHA_COMMIT\"}" > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__commits__4444444.json"
  echo "{\"state\":\"open\",\"merged\":false,\"head\":{\"sha\":\"$SHA_PR\",\"ref\":\"rust_conversion\",\"label\":\"BluEye-Robotics:rust_conversion\"}}" \
    > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__pulls__424.json"
  echo "{\"state\":\"closed\",\"merged\":true,\"head\":{\"sha\":\"$SHA_PR\",\"ref\":\"old\",\"label\":\"BluEye-Robotics:old\"}}" \
    > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__pulls__7.json"
  echo '{"message":"API rate limit exceeded"}' > "$MOCK_API_DIR/repos__BluEye-Robotics__ratelimited.json"
  echo 403 > "$MOCK_API_DIR/repos__BluEye-Robotics__ratelimited.status"
}

run() { # run -> sets RC, OUT
  OUT="$("$SCRIPTS_DIR/resolve-ref.sh" 2>&1)"; RC=$?
}
out() { output_value "$GITHUB_OUTPUT" "$1"; }
api_calls() { grep -c . "$MOCK_API_LOG" || true; }

echo "# explicit branch ref"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" rust_conversion "$(out ref)"
assert_eq "sha" "$SHA_FEAT" "$(out sha)"
assert_eq "repo-name" libblunux "$(out repo-name)"
assert_eq "repository" BluEye-Robotics/libblunux "$(out repository)"
assert_eq "not overridden" false "$(out ref-overridden)"
assert_eq "one API call" 1 "$(api_calls)"
assert_contains "token header sent" "Authorization: token t0ken" "$(cat "$MOCK_API_HEADERS")"

echo "# refs/heads/ prefix is stripped for the API"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=refs/heads/rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "sha" "$SHA_FEAT" "$(out sha)"
assert_eq "ref kept as given" refs/heads/rust_conversion "$(out ref)"

echo "# branch with slashes is URL-encoded"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=feature/nested/branch run
assert_status "exits 0" 0 "$RC"
assert_eq "sha" "$SHA_FEAT" "$(out sha)"

echo "# empty ref -> default branch"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF='' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" main "$(out ref)"
assert_eq "sha" "$SHA_MAIN" "$(out sha)"
assert_eq "two API calls" 2 "$(api_calls)"

echo "# empty ref for the triggering repository -> event SHA, no API"
new_case; setup_api
INPUT_REPOSITORY=blueye-robotics/libblunux INPUT_REF='' GITHUB_REPOSITORY=BluEye-Robotics/libblunux GITHUB_SHA=$SHA_COMMIT run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" "$SHA_COMMIT" "$(out ref)"
assert_eq "sha" "$SHA_COMMIT" "$(out sha)"
assert_eq "no API calls" 0 "$(api_calls)"

echo "# full SHA ref -> no API"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=$SHA_COMMIT run
assert_status "exits 0" 0 "$RC"
assert_eq "sha" "$SHA_COMMIT" "$(out sha)"
assert_eq "no API calls" 0 "$(api_calls)"

echo "# trailing .git and slash are tolerated"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux.git INPUT_REF=main run
assert_status "exits 0" 0 "$RC"
assert_eq "repository" BluEye-Robotics/libblunux "$(out repository)"
assert_eq "repo-name" libblunux "$(out repo-name)"

echo "# unknown ref -> clear error"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=does-not-exist run
assert_status "exits 1" 1 "$RC"
assert_contains "mentions 404" "HTTP 404" "$OUT"
assert_contains "mentions the repo" "BluEye-Robotics/libblunux" "$OUT"

echo "# rate limit -> clear error"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/ratelimited INPUT_REF='' run
assert_status "exits 1" 1 "$RC"
assert_contains "mentions rate limit" "rate limit" "$OUT"

echo "# override: tree URL"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES=$'Some description.\n\nDepends on https://github.com/BluEye-Robotics/libblunux/tree/rust_conversion\n' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref swapped" rust_conversion "$(out ref)"
assert_eq "sha" "$SHA_FEAT" "$(out sha)"
assert_eq "overridden" true "$(out ref-overridden)"
assert_contains "source line" "Depends on https://github.com/BluEye-Robotics/libblunux/tree/rust_conversion" "$(out override-source)"
assert_contains "notice printed" "::notice::Dependency override" "$OUT"

echo "# override: tree URL with nested branch"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='Depends on https://github.com/BluEye-Robotics/libblunux/tree/feature/nested/branch' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" feature/nested/branch "$(out ref)"

echo "# override: pull request URL -> refs/pull/N/head"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='Depends on https://github.com/BluEye-Robotics/libblunux/pull/424' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" refs/pull/424/head "$(out ref)"
assert_eq "sha" "$SHA_PR" "$(out sha)"
assert_eq "overridden" true "$(out ref-overridden)"
assert_contains "notice names the PR" "pull request #424" "$OUT"

echo "# override: pull request URL with /files suffix, markdown link, trailing period"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='- **Depends on**: [libblunux#424](https://github.com/BluEye-Robotics/libblunux/pull/424/files).' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" refs/pull/424/head "$(out ref)"

echo "# override: merged PR still resolves but warns"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='Depends on <https://github.com/BluEye-Robotics/libblunux/pull/7>' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" refs/pull/7/head "$(out ref)"
assert_contains "warns about merged" "::warning::" "$OUT"
assert_contains "says merged" "already merged" "$OUT"

echo "# override: commit URL (short sha expanded)"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='depends-on: https://github.com/BluEye-Robotics/libblunux/commit/4444444' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref is the full sha" "$SHA_COMMIT" "$(out ref)"
assert_eq "sha" "$SHA_COMMIT" "$(out sha)"

echo "# override: shorthand owner/repo#N and owner/repo@ref"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='Depends on BluEye-Robotics/libblunux#424' run
assert_eq "#N -> pull head" refs/pull/424/head "$(out ref)"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='Depends on blueye-robotics/LIBBLUNUX@rust_conversion' run
assert_eq "@ref -> branch (case-insensitive repo match)" rust_conversion "$(out ref)"

echo "# override: other repositories are ignored"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES=$'Depends on https://github.com/BluEye-Robotics/tyndall/pull/12\nDepends on https://github.com/SomeoneElse/libblunux/tree/evil' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref unchanged" main "$(out ref)"
assert_eq "not overridden" false "$(out ref-overridden)"

echo "# override: URL without 'Depends on' is ignored"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES=$'See https://github.com/BluEye-Robotics/libblunux/pull/424 for context.\nIndependent of https://github.com/BluEye-Robotics/libblunux/tree/rust_conversion' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref unchanged" main "$(out ref)"
assert_eq "not overridden" false "$(out ref-overridden)"

echo "# override: first matching line wins, later ones warn"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES=$'Depends on https://github.com/BluEye-Robotics/libblunux/tree/rust_conversion\r\nDepends on https://github.com/BluEye-Robotics/libblunux/pull/424\r\n' run
assert_status "exits 0" 0 "$RC"
assert_eq "first wins (CRLF tolerated)" rust_conversion "$(out ref)"
assert_contains "warns about the second" "Ignoring additional dependency override" "$OUT"

echo "# override: globs in the description are not expanded"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='Depends on * https://github.com/BluEye-Robotics/libblunux/pull/424' run
assert_eq "ref" refs/pull/424/head "$(out ref)"

report
