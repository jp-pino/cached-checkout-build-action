#!/usr/bin/env bash
# Tests for scripts/resolve-ref.sh against the mock GitHub API.
set -u
. "$(dirname "$0")/lib.sh"

export PATH="$TESTS_DIR/mock:$PATH"
export GITHUB_API_URL="https://api.github.com" GITHUB_SERVER_URL="https://github.com"
export INPUT_TOKEN="t0ken" INPUT_GITHUB_TOKEN="wf-token"
unset MOCK_API_DENY_TOKEN
unset GITHUB_REPOSITORY GITHUB_SHA GITHUB_REF GITHUB_HEAD_REF GITHUB_EVENT_PATH INPUT_REF INPUT_DEPENDENCY_OVERRIDES
unset CACHED_BUILD_DEPENDENCY_OVERRIDES CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE

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
env_out() { output_value "$GITHUB_ENV" "$1"; }
api_calls() { grep -c . "$MOCK_API_LOG" || true; }

# "auto" fixtures: the consumer repository p2_drone, branch rust_conversion.
DEPENDS_LINE='Depends on https://github.com/BluEye-Robotics/libblunux/pull/424'
LOOKUP_PATH='repos/BluEye-Robotics/p2_drone/pulls?state=open&head=BluEye-Robotics%3Arust_conversion&per_page=5'
lookup_file() { printf '%s' "$MOCK_API_DIR/$(printf '%s' "$LOOKUP_PATH" | sed 's#/#__#g')"; }
setup_pr_list() { # setup_pr_list <json array>
  printf '%s' "$1" > "$(lookup_file).json"
}
setup_event() { # setup_event <json> -> exports GITHUB_EVENT_PATH
  export GITHUB_EVENT_PATH="$CASE_DIR/event.json"
  printf '%s' "$1" > "$GITHUB_EVENT_PATH"
}

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

echo "# override: pull request unreadable (token without pull-requests access) -> git ref"
new_case; setup_api
echo '{"message":"Resource not accessible by personal access token"}' > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__pulls__424.json"
echo 403 > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__pulls__424.status"
echo "{\"ref\":\"refs/pull/424/head\",\"object\":{\"sha\":\"$SHA_PR\",\"type\":\"commit\"}}" \
  > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__git__ref__pull__424__head.json"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='Depends on https://github.com/BluEye-Robotics/libblunux/pull/424' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" refs/pull/424/head "$(out ref)"
assert_eq "sha from the git ref" "$SHA_PR" "$(out sha)"
assert_eq "overridden" true "$(out ref-overridden)"
assert_contains "git ref requested" "repos/BluEye-Robotics/libblunux/git/ref/pull/424/head" "$(cat "$MOCK_API_LOG")"
assert_contains "notice printed" "::notice::Dependency override: building BluEye-Robotics/libblunux from pull request #424 (pull/424/head @ ${SHA_PR:0:12})" "$OUT"
assert_contains "explains the missing state" "state is unknown" "$OUT"
assert_not_contains "no warning" "::warning::" "$OUT"

echo "# override: pull request and git ref both unreadable -> error names both"
new_case; setup_api
echo 403 > "$MOCK_API_DIR/repos__BluEye-Robotics__libblunux__pulls__424.status"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main \
INPUT_DEPENDENCY_OVERRIDES='Depends on https://github.com/BluEye-Robotics/libblunux/pull/424' run
assert_status "exits 1" 1 "$RC"
assert_contains "pull request error" "GitHub API repos/BluEye-Robotics/libblunux/pulls/424 returned HTTP 403" "$OUT"
assert_contains "git ref error" "Reading the ref directly failed too: GitHub API repos/BluEye-Robotics/libblunux/git/ref/pull/424/head returned HTTP 404" "$OUT"

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

echo "# auto: pull_request event -> description from the event payload, no lookup"
new_case; setup_api
setup_event "{\"action\":\"synchronize\",\"pull_request\":{\"number\":1074,\"body\":\"Some text.\\n\\n$DEPENDS_LINE\\n\"}}"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/pull/1074/merge GITHUB_HEAD_REF=rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" refs/pull/424/head "$(out ref)"
assert_eq "overridden" true "$(out ref-overridden)"
assert_eq "only the PR head was fetched" 1 "$(api_calls)"
assert_contains "says where the text came from" "pull request #1074 (from the event)" "$OUT"
assert_contains "text cached for later steps" "$DEPENDS_LINE" "$(env_out CACHED_BUILD_DEPENDENCY_OVERRIDES)"
assert_contains "source cached for later steps" "pull request #1074" "$(env_out CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE)"
unset GITHUB_EVENT_PATH

echo "# auto: pull_request event with an empty description -> nothing"
new_case; setup_api
setup_event '{"pull_request":{"number":1074,"body":null}}'
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_HEAD_REF=rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "ref kept" main "$(out ref)"
assert_eq "not overridden" false "$(out ref-overridden)"
assert_eq "no lookup" 1 "$(api_calls)"
unset GITHUB_EVENT_PATH

echo "# auto: push event -> open pull request for the branch is looked up"
new_case; setup_api
setup_event '{"ref":"refs/heads/rust_conversion","after":"0000000000000000000000000000000000000000"}'
setup_pr_list "[{\"number\":1074,\"body\":\"Stacked on #1073.\\n\\n$DEPENDS_LINE\\n\"}]"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" refs/pull/424/head "$(out ref)"
assert_eq "sha" "$SHA_PR" "$(out sha)"
assert_eq "overridden" true "$(out ref-overridden)"
assert_contains "lookup path" "$LOOKUP_PATH" "$(cat "$MOCK_API_LOG")"
assert_eq "lookup + PR head" 2 "$(api_calls)"
assert_contains "says which PR" "pull request #1074 (open for branch 'rust_conversion')" "$OUT"
assert_contains "text cached" "$DEPENDS_LINE" "$(env_out CACHED_BUILD_DEPENDENCY_OVERRIDES)"
assert_not_contains "no warning" "::warning::" "$OUT"
unset GITHUB_EVENT_PATH

echo "# auto: the lookup uses github-token, the dependency fetch uses token"
new_case; setup_api
setup_pr_list "[{\"number\":1074,\"body\":\"$DEPENDS_LINE\"}]"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "auth headers in order" $'Authorization: token wf-token\nAuthorization: token t0ken' "$(grep Authorization "$MOCK_API_HEADERS")"

echo "# auto: github-token refused -> retried with token"
new_case; setup_api
setup_pr_list "[{\"number\":1074,\"body\":\"$DEPENDS_LINE\"}]"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/rust_conversion MOCK_API_DENY_TOKEN=wf-token run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" refs/pull/424/head "$(out ref)"
assert_eq "lookup twice + PR head" 3 "$(api_calls)"
assert_not_contains "no warning" "::warning::" "$OUT"

echo "# auto: no github-token -> token is used directly, once"
new_case; setup_api
setup_pr_list "[{\"number\":1074,\"body\":\"$DEPENDS_LINE\"}]"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto INPUT_GITHUB_TOKEN='' \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/rust_conversion run
assert_eq "ref" refs/pull/424/head "$(out ref)"
assert_eq "lookup once + PR head" 2 "$(api_calls)"
assert_eq "dependency token used" 2 "$(grep -c 'Authorization: token t0ken' "$MOCK_API_HEADERS")"

echo "# auto: 'AUTO ' is accepted, GITHUB_HEAD_REF wins over GITHUB_REF"
new_case; setup_api
setup_pr_list "[{\"number\":1074,\"body\":\"$DEPENDS_LINE\"}]"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES='AUTO ' \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/other GITHUB_HEAD_REF=rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" refs/pull/424/head "$(out ref)"

echo "# auto: push with no open pull request -> nothing, outcome cached"
new_case; setup_api
setup_pr_list '[]'
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "ref kept" main "$(out ref)"
assert_eq "not overridden" false "$(out ref-overridden)"
assert_contains "explains" "no open pull request" "$OUT"
assert_eq "empty text cached" "" "$(env_out CACHED_BUILD_DEPENDENCY_OVERRIDES)"
assert_contains "outcome cached" "no open pull request" "$(env_out CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE)"

echo "# auto: several open pull requests -> first one, with a warning"
new_case; setup_api
setup_pr_list "[{\"number\":1074,\"body\":\"$DEPENDS_LINE\"},{\"number\":1070,\"body\":\"Depends on https://github.com/BluEye-Robotics/libblunux/pull/7\"}]"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "first PR used" refs/pull/424/head "$(out ref)"
assert_contains "warns" "::warning::Branch 'rust_conversion' has 2 open pull requests (#1074, #1070)" "$OUT"

echo "# auto: a later step reuses the cached lookup, no API call"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/rust_conversion \
CACHED_BUILD_DEPENDENCY_OVERRIDES="$DEPENDS_LINE" CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE='the description of pull request #1074 (open for branch '"'"'rust_conversion'"'"')' run
assert_status "exits 0" 0 "$RC"
assert_eq "ref" refs/pull/424/head "$(out ref)"
assert_eq "only the PR head was fetched" 1 "$(api_calls)"
assert_contains "repeats the source" "pull request #1074" "$OUT"
assert_eq "nothing re-written to GITHUB_ENV" "" "$(cat "$GITHUB_ENV")"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/rust_conversion \
CACHED_BUILD_DEPENDENCY_OVERRIDES='' CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE='nothing: branch has no open pull request' run
assert_eq "cached empty outcome -> no lookup" 1 "$(api_calls)"
assert_eq "not overridden" false "$(out ref-overridden)"

echo "# auto: lookup denied for both tokens -> warning, no override, outcome cached"
new_case; setup_api
setup_pr_list '{"message":"Resource not accessible by integration"}'
echo 403 > "$(lookup_file).status"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/heads/rust_conversion run
assert_status "exits 0" 0 "$RC"
assert_eq "ref kept" main "$(out ref)"
assert_contains "warns" "::warning::Could not look up the open pull request for branch 'rust_conversion'" "$OUT"
assert_contains "names the cause" "Resource not accessible by integration" "$OUT"
assert_contains "hints at the permission" "github-token (or token) needs pull-requests: read access to BluEye-Robotics/p2_drone" "$OUT"
assert_eq "both tokens tried, then no more" 3 "$(api_calls)"
assert_contains "outcome cached" "lookup for branch 'rust_conversion' failed" "$(env_out CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE)"

echo "# auto: tag push -> no lookup"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_REF=refs/tags/v1.0 run
assert_status "exits 0" 0 "$RC"
assert_eq "ref kept" main "$(out ref)"
assert_eq "no lookup" 1 "$(api_calls)"
assert_contains "explains" "not running for a branch (refs/tags/v1.0)" "$OUT"

echo "# auto: outside GitHub Actions -> no lookup, no error"
new_case; setup_api
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES=auto run
assert_status "exits 0" 0 "$RC"
assert_eq "ref kept" main "$(out ref)"
assert_eq "no lookup" 1 "$(api_calls)"

echo "# explicit '' disables even when the event carries a description"
new_case; setup_api
setup_event "{\"pull_request\":{\"number\":1074,\"body\":\"$DEPENDS_LINE\"}}"
INPUT_REPOSITORY=BluEye-Robotics/libblunux INPUT_REF=main INPUT_DEPENDENCY_OVERRIDES='' \
GITHUB_REPOSITORY=BluEye-Robotics/p2_drone GITHUB_HEAD_REF=rust_conversion run
assert_eq "not overridden" false "$(out ref-overridden)"
assert_eq "nothing written to GITHUB_ENV" "" "$(cat "$GITHUB_ENV")"
unset GITHUB_EVENT_PATH

report
