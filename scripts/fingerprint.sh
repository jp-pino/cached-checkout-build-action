#!/usr/bin/env bash
# Compute the build fingerprint and cache key, resolve "depends-on" against the
# builds registered earlier in this job, and register this build.
#
# Inputs (environment):
#   REPOSITORY, REPO_NAME, REF, SHA        from resolve-ref.sh
#   INPUT_CMAKE_FLAGS, INPUT_BUILD_FLAGS, INPUT_PRE_BUILD_COMMAND,
#   INPUT_SUBMODULES, INPUT_CACHE_KEY_EXTRA, INPUT_DEPENDS_ON
#   CACHED_BUILD_REGISTRY                  builds registered so far (may be empty)
#   RUNNER_OS, RUNNER_ARCH, GITHUB_WORKSPACE
#
# Outputs (GITHUB_OUTPUT):
#   fingerprint, cache-key, work-dir, source-path, checkout-path (relative to
#   the workspace, for actions/checkout), install-path, dependencies
# Environment (GITHUB_ENV):
#   CACHED_BUILD_REGISTRY  appended with "<owner/repo>\t<sha>\t<fingerprint>"
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${REPOSITORY:?}" "${REPO_NAME:?}" "${REF:?}" "${SHA:?}"
: "${RUNNER_OS:?}" "${RUNNER_ARCH:?}" "${GITHUB_WORKSPACE:?}"
registry="${CACHED_BUILD_REGISTRY:-}"
repo="$(repo_key "$REPOSITORY")"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# registry_lookup <name>: print the last registry line whose repo matches
# <name>, either as "owner/repo" or as a bare "repo" name.
registry_lookup() {
  local want line entry_repo match=""
  want="$(repo_key "$1")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    entry_repo="${line%%	*}"
    if [ "$entry_repo" = "$want" ] || [ "${entry_repo##*/}" = "$want" ]; then
      match="$line"
    fi
  done <<< "$registry"
  printf '%s' "$match"
}

# registry_all: every registered repo, last entry per repo.
registry_all() {
  local line entry_repo seen=""
  # Iterate newest-first so the last registration of each repo wins.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    entry_repo="${line%%	*}"
    case "$seen" in *"|$entry_repo|"*) continue ;; esac
    seen="$seen|$entry_repo|"
    printf '%s\n' "$line"
  done < <(printf '%s\n' "$registry" | sed '1!G;h;$!d')
}

# Resolve depends-on into "repo<TAB>sha<TAB>fingerprint" lines.
deps=""
for raw in $(printf '%s' "${INPUT_DEPENDS_ON:-}" | tr ',' '\n'); do
  dep="$(trim "$raw")"
  [ -n "$dep" ] || continue
  if [ "$(lower "$dep")" = all ]; then
    deps="$deps$(registry_all)"$'\n'
    continue
  fi
  entry="$(registry_lookup "$dep")"
  if [ -z "$entry" ]; then
    registered="$(printf '%s\n' "$registry" | cut -f1 | grep -v '^$' | sort -u | tr '\n' ' ' || true)"
    die "depends-on: '$dep' has not been built earlier in this job by cached-checkout-build-action. Registered so far: ${registered:-none}. Make sure the dependency step runs before this one."
  fi
  deps="$deps$entry"$'\n'
done
# Dedupe (last wins) and sort so the order of depends-on does not matter.
deps="$(printf '%s' "$deps" | awk -F'\t' 'NF { seen[$1]=$0 } END { for (k in seen) print seen[k] }' | sort)"

# ---------------------------------------------------------------------------
# Fingerprint: everything that changes the produced artifacts.
# ---------------------------------------------------------------------------
manifest() {
  printf 'repository\0%s\0' "$repo"
  printf 'sha\0%s\0' "$SHA"
  printf 'submodules\0%s\0' "${INPUT_SUBMODULES:-}"
  printf 'cmake-flags\0%s\0' "${INPUT_CMAKE_FLAGS:-}"
  printf 'build-flags\0%s\0' "${INPUT_BUILD_FLAGS:-}"
  printf 'pre-build-command\0%s\0' "${INPUT_PRE_BUILD_COMMAND:-}"
  printf 'extra\0%s\0' "${INPUT_CACHE_KEY_EXTRA:-}"
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'dependency\0%s\0%s\0' "${line%%	*}" "${line##*	}"
  done <<< "$deps"
}
fingerprint="$(manifest | sha256)"

cache_key="cached-build-${RUNNER_OS}-${RUNNER_ARCH}-$(safe_name "$REPO_NAME")-${SHA:0:12}-${fingerprint}"
work_dir_rel=".cached-checkout-build/$(safe_name "$REPO_NAME")-${fingerprint:0:12}"
work_dir="${GITHUB_WORKSPACE}/${work_dir_rel}"

log "fingerprint: $fingerprint"
log "cache key:   $cache_key"
if [ -n "$deps" ]; then
  log "dependencies:"
  while IFS=$'\t' read -r d_repo d_sha d_fp; do
    [ -n "$d_repo" ] && log "  $d_repo @ ${d_sha:0:12} (fingerprint ${d_fp:0:12})"
  done <<< "$deps"
fi

set_output fingerprint "$fingerprint"
set_output cache-key "$cache_key"
set_output work-dir "$work_dir"
set_output source-path "$work_dir/git"
set_output checkout-path "$work_dir_rel/git"
set_output install-path "$work_dir/cache"
set_output dependencies "$deps"

entry="$(printf '%s\t%s\t%s' "$repo" "$SHA" "$fingerprint")"
if [ -n "$registry" ]; then
  set_env CACHED_BUILD_REGISTRY "$registry"$'\n'"$entry"
else
  set_env CACHED_BUILD_REGISTRY "$entry"
fi
