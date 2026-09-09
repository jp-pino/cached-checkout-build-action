#!/usr/bin/env bash
# Resolve which repository, ref and commit SHA to build.
#
# Inputs (environment):
#   INPUT_REPOSITORY            owner/repo (required)
#   INPUT_REF                   branch, tag, SHA or "" (default branch / event SHA)
#   INPUT_TOKEN                 token for the GitHub API (optional for public repos)
#   INPUT_GITHUB_TOKEN          token for the repository running the workflow,
#                               used for the "auto" pull request lookup (falls
#                               back to INPUT_TOKEN when refused)
#   INPUT_DEPENDENCY_OVERRIDES  free text (typically the PR body) scanned for
#                               "Depends on <url>" lines that swap the ref, or
#                               "auto" to take the description of the pull
#                               request in the event payload or, outside
#                               pull_request events, of the open pull request
#                               for the current branch
#   GITHUB_API_URL, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_SHA,
#   GITHUB_EVENT_PATH, GITHUB_HEAD_REF, GITHUB_REF
#   CACHED_BUILD_DEPENDENCY_OVERRIDES, CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE
#                               the "auto" lookup done by an earlier step
#
# Outputs (GITHUB_OUTPUT):
#   repository, repo-name, ref, sha, ref-overridden, override-source
#
# Environment (GITHUB_ENV, only with "auto"):
#   CACHED_BUILD_DEPENDENCY_OVERRIDES, CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${INPUT_REPOSITORY:?INPUT_REPOSITORY is required}"
INPUT_REF="$(trim "${INPUT_REF:-}")"
INPUT_TOKEN="${INPUT_TOKEN:-}"
INPUT_GITHUB_TOKEN="${INPUT_GITHUB_TOKEN:-}"
INPUT_DEPENDENCY_OVERRIDES="${INPUT_DEPENDENCY_OVERRIDES:-}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

repository="${INPUT_REPOSITORY%/}"
repository="${repository%.git}"
repo="$(repo_key "$repository")"
name="$(repo_name "$repository")"
server_host="${GITHUB_SERVER_URL#*://}"
server_host="${server_host%/}"

# api_raw <path> <bodyfile> [token]: GET $GITHUB_API_URL/<path> into <bodyfile>
# and print the HTTP status ("000" when curl itself failed). Never exits.
api_raw() {
  local path="$1" body="$2" token="$INPUT_TOKEN" status
  if [ $# -ge 3 ]; then token="$3"; fi
  local -a auth=()
  [ -n "$token" ] && auth=(-H "Authorization: token $token")
  status="$(curl -sS -o "$body" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' "${auth[@]}" \
    "$GITHUB_API_URL/$path")" || status=000
  printf '%s' "$status"
}

# api_error <path> <bodyfile> <status>: one line explaining a failed request.
api_error() {
  local path="$1" body="$2" status="$3" msg
  msg="$(jq -r '.message // empty' "$body" 2>/dev/null || true)"
  case "$status" in
    000)     printf 'GitHub API request failed: %s' "$path" ;;
    403|429) printf 'GitHub API %s returned HTTP %s (%s). Check the token'"'"'s access or the API rate limit.' "$path" "$status" "${msg:-no message}" ;;
    404)     printf 'GitHub API %s returned HTTP 404 (%s). Does the token have access to %s and does the ref exist?' "$path" "${msg:-not found}" "$repository" ;;
    *)       printf 'GitHub API %s returned HTTP %s (%s).' "$path" "$status" "${msg:-no message}" ;;
  esac
}

# api <path>: GET $GITHUB_API_URL/<path>, print the body, fail loudly on non-2xx.
api() {
  local path="$1" body status
  body="$(mktemp)"
  status="$(api_raw "$path" "$body")"
  if [[ "$status" != 2* ]]; then
    local msg
    msg="$(api_error "$path" "$body" "$status")"
    rm -f "$body"
    die "$msg"
  fi
  cat "$body"
  rm -f "$body"
}

api_field() { # api_field <path> <jq expr>
  local value
  value="$(api "$1" | jq -r "$2")"
  if [ -z "$value" ] || [ "$value" = null ]; then die "GitHub API $1 did not return $2"; fi
  printf '%s' "$value"
}

urlencode_ref() { printf '%s' "$1" | jq -sRr '@uri'; }

commit_sha() { # commit_sha <ref>
  local ref="$1"
  ref="${ref#refs/heads/}"
  ref="${ref#refs/tags/}"
  api_field "repos/$repository/commits/$(urlencode_ref "$ref")" '.sha'
}

is_full_sha() { [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]; }

# ---------------------------------------------------------------------------
# 0. dependency-overrides "auto": find the pull request description.
# ---------------------------------------------------------------------------
# pull_request events carry the description in the event payload. On other
# events (push, workflow_dispatch, ...) the open pull request whose head is the
# current branch is looked up through the API. Either way the result is stored
# in GITHUB_ENV, so a job that builds several repositories resolves it once.
if [ "$(lower "$(trim "$INPUT_DEPENDENCY_OVERRIDES")")" = auto ]; then
  overrides_from=""
  if [ -n "${CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE:-}" ]; then
    INPUT_DEPENDENCY_OVERRIDES="${CACHED_BUILD_DEPENDENCY_OVERRIDES:-}"
    overrides_from="$CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE"
  else
    INPUT_DEPENDENCY_OVERRIDES=""
    event_file="${GITHUB_EVENT_PATH:-}"
    branch="${GITHUB_HEAD_REF:-}"
    if [ -z "$branch" ] && [[ "${GITHUB_REF:-}" == refs/heads/* ]]; then branch="${GITHUB_REF#refs/heads/}"; fi
    if [ -n "$event_file" ] && [ -f "$event_file" ] && jq -e '.pull_request.number' "$event_file" >/dev/null 2>&1; then
      INPUT_DEPENDENCY_OVERRIDES="$(jq -r '.pull_request.body // empty' "$event_file")"
      overrides_from="the description of pull request #$(jq -r '.pull_request.number' "$event_file") (from the event)"
    elif [ -n "$branch" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
      owner="${GITHUB_REPOSITORY%%/*}"
      path="repos/$GITHUB_REPOSITORY/pulls?state=open&head=$(urlencode_ref "$owner:$branch")&per_page=5"
      body_file="$(mktemp)"
      # The workflow's own token can always see its own pull requests; the
      # dependency token is often scoped to other repositories, so it is only
      # the fallback.
      lookup_token="${INPUT_GITHUB_TOKEN:-$INPUT_TOKEN}"
      status="$(api_raw "$path" "$body_file" "$lookup_token")"
      if [[ "$status" != 2* ]] && [ -n "$INPUT_TOKEN" ] && [ "$INPUT_TOKEN" != "$lookup_token" ]; then
        status="$(api_raw "$path" "$body_file" "$INPUT_TOKEN")"
      fi
      if [[ "$status" == 2* ]]; then
        count="$(jq -r 'if type == "array" then length else 0 end' "$body_file")"
        if [ "$count" -gt 0 ]; then
          number="$(jq -r '.[0].number' "$body_file")"
          INPUT_DEPENDENCY_OVERRIDES="$(jq -r '.[0].body // empty' "$body_file")"
          overrides_from="the description of pull request #$number (open for branch '$branch')"
          if [ "$count" -gt 1 ]; then
            warn "Branch '$branch' has $count open pull requests ($(jq -r '[.[].number | "#\(.)"] | join(", ")' "$body_file")); dependency overrides come from #$number"
          fi
        else
          overrides_from="nothing: branch '$branch' has no open pull request"
        fi
      else
        warn "Could not look up the open pull request for branch '$branch'; dependency overrides are disabled for this job. $(api_error "$path" "$body_file" "$status") github-token (or token) needs pull-requests: read access to ${GITHUB_REPOSITORY}, or set dependency-overrides explicitly."
        overrides_from="nothing: the pull request lookup for branch '$branch' failed"
      fi
      rm -f "$body_file"
    else
      overrides_from="nothing: not running for a branch (${GITHUB_REF:-GITHUB_REF is unset})"
    fi
    set_env CACHED_BUILD_DEPENDENCY_OVERRIDES "$INPUT_DEPENDENCY_OVERRIDES"
    set_env CACHED_BUILD_DEPENDENCY_OVERRIDES_SOURCE "$overrides_from"
  fi
  log "dependency-overrides: $overrides_from"
fi

# ---------------------------------------------------------------------------
# 1. Scan the dependency-overrides text for "Depends on ..." lines.
# ---------------------------------------------------------------------------
override_kind="" override_value="" override_source=""

consider_token() { # consider_token <token> <line>
  local tok="$1" line="$2" owner="" rname="" kind="" value=""
  # Strip prose punctuation after the token, unwrap markdown links
  # "[text](url)" and angle brackets "<url>", then strip again.
  local trail_re="[]>).,;:!?\"']\$" trail_no_paren_re="[]>.,;:!?\"']\$"
  while [[ "$tok" =~ $trail_no_paren_re ]]; do tok="${tok%?}"; done
  if [[ "$tok" =~ \]\((.+)\)$ ]]; then tok="${BASH_REMATCH[1]}"; fi
  tok="${tok#<}"; tok="${tok#\(}"
  while [[ "$tok" =~ $trail_re ]]; do tok="${tok%?}"; done
  [ -n "$tok" ] || return 0

  local host_re
  host_re="$(printf '%s' "$server_host" | sed 's/[.[\*^$]/\\&/g')"
  if [[ "$tok" =~ ^(https?://)?(www\.)?${host_re}/([^/[:space:]]+)/([^/[:space:]]+)/(tree|pull|commit)/(.+)$ ]]; then
    owner="${BASH_REMATCH[3]}"; rname="${BASH_REMATCH[4]}"
    kind="${BASH_REMATCH[5]}"; value="${BASH_REMATCH[6]}"
  elif [[ "$tok" =~ ^([^/@#[:space:]]+)/([^/@#[:space:]]+)#([0-9]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"; rname="${BASH_REMATCH[2]}"
    kind=pull; value="${BASH_REMATCH[3]}"
  elif [[ "$tok" =~ ^([^/@#[:space:]]+)/([^/@#[:space:]]+)@(.+)$ ]]; then
    owner="${BASH_REMATCH[1]}"; rname="${BASH_REMATCH[2]}"
    kind=tree; value="${BASH_REMATCH[3]}"
  else
    return 0
  fi

  [ "$(repo_key "$owner/$rname")" = "$repo" ] || return 0

  case "$kind" in
    pull)
      [[ "$value" =~ ^([0-9]+) ]] || return 0
      value="${BASH_REMATCH[1]}"
      ;;
    commit)
      [[ "$value" =~ ^([0-9a-fA-F]{7,40}) ]] || return 0
      value="${BASH_REMATCH[1]}"
      ;;
    tree)
      value="${value%/}"
      [ -n "$value" ] || return 0
      ;;
  esac

  if [ -n "$override_kind" ]; then
    warn "Ignoring additional dependency override for $repository: '$line' (already using '$override_source')"
    return 0
  fi
  override_kind="$kind"; override_value="$value"; override_source="$line"
}

# Lines such as "Depends on <x>", "depends-on: <x>", "- **Depends on** <x>".
depends_re='^[-*_[:space:]]*[Dd][Ee][Pp][Ee][Nn][Dd][Ss][[:space:]_-]*[Oo][Nn][*_]*:?[[:space:]]+(.+)$'
if [ -n "$INPUT_DEPENDENCY_OVERRIDES" ]; then
  set -f # no globbing while word-splitting free text
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="$(trim "$raw")"
    if [[ "$line" =~ $depends_re ]]; then
      rest="${BASH_REMATCH[1]}"
      for tok in $rest; do
        consider_token "$tok" "$line"
      done
    fi
  done <<< "$INPUT_DEPENDENCY_OVERRIDES"
  set +f
fi

# ---------------------------------------------------------------------------
# 2. Resolve ref + sha.
# ---------------------------------------------------------------------------
ref="" sha="" overridden=false

if [ -n "$override_kind" ]; then
  overridden=true
  case "$override_kind" in
    pull)
      ref="refs/pull/$override_value/head"
      pr_path="repos/$repository/pulls/$override_value"
      pr_body="$(mktemp)"
      status="$(api_raw "$pr_path" "$pr_body")"
      if [[ "$status" == 2* ]]; then
        sha="$(jq -r '.head.sha // empty' "$pr_body")"
        [ -n "$sha" ] || die "Pull request $repository#$override_value has no head commit"
        pr_state="$(jq -r '.state // empty' "$pr_body")"
        pr_merged="$(jq -r '.merged // false' "$pr_body")"
        pr_head="$(jq -r '.head.label // .head.ref // empty' "$pr_body")"
        if [ "$pr_merged" = true ]; then
          warn "$repository#$override_value ($pr_head) is already merged; the 'Depends on' line can probably be removed"
        elif [ "$pr_state" = closed ]; then
          warn "$repository#$override_value ($pr_head) is closed without being merged"
        fi
      else
        # A token with only contents access (enough to clone) cannot read pull
        # requests, but it can read the pull request's git ref.
        pr_error="$(api_error "$pr_path" "$pr_body" "$status")"
        ref_path="repos/$repository/git/ref/pull/$override_value/head"
        status="$(api_raw "$ref_path" "$pr_body")"
        if [[ "$status" != 2* ]]; then
          die "$pr_error Reading the ref directly failed too: $(api_error "$ref_path" "$pr_body" "$status")"
        fi
        sha="$(jq -r '.object.sha // empty' "$pr_body")"
        [ -n "$sha" ] || die "GitHub API $ref_path did not return a commit"
        pr_head="pull/$override_value/head"
        log "Pull request $repository#$override_value could not be read ($pr_error), so its state is unknown; give the token pull-requests: read access to be warned when it is merged or closed."
      fi
      rm -f "$pr_body"
      notice "Dependency override: building $repository from pull request #$override_value ($pr_head @ ${sha:0:12}) because of '$override_source'"
      ;;
    commit)
      sha="$(commit_sha "$override_value")"
      ref="$sha"
      notice "Dependency override: building $repository at commit ${sha:0:12} because of '$override_source'"
      ;;
    tree)
      ref="$override_value"
      sha="$(commit_sha "$ref")"
      notice "Dependency override: building $repository from '$ref' (${sha:0:12}) because of '$override_source'"
      ;;
  esac
elif [ -z "$INPUT_REF" ]; then
  if [ "$(repo_key "${GITHUB_REPOSITORY:-}")" = "$repo" ] && [ -n "${GITHUB_SHA:-}" ]; then
    # Building the repository that triggered the workflow: use the event's commit.
    ref="$GITHUB_SHA"; sha="$GITHUB_SHA"
  else
    ref="$(api_field "repos/$repository" '.default_branch')"
    sha="$(commit_sha "$ref")"
  fi
elif is_full_sha "$INPUT_REF"; then
  ref="$INPUT_REF"; sha="$INPUT_REF"
else
  ref="$INPUT_REF"
  sha="$(commit_sha "$ref")"
fi

is_full_sha "$sha" || die "Could not resolve '$ref' of $repository to a commit SHA (got '$sha')"

log "repository: $repository"
log "ref:        $ref"
log "sha:        $sha"
set_output repository "$repository"
set_output repo-name "$name"
set_output ref "$ref"
set_output sha "$sha"
set_output ref-overridden "$overridden"
set_output override-source "$override_source"
