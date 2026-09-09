#!/usr/bin/env bash
# Resolve which repository, ref and commit SHA to build.
#
# Inputs (environment):
#   INPUT_REPOSITORY            owner/repo (required)
#   INPUT_REF                   branch, tag, SHA or "" (default branch / event SHA)
#   INPUT_TOKEN                 token for the GitHub API (optional for public repos)
#   INPUT_DEPENDENCY_OVERRIDES  free text (typically the PR body) scanned for
#                               "Depends on <url>" lines that swap the ref
#   GITHUB_API_URL, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_SHA
#
# Outputs (GITHUB_OUTPUT):
#   repository, repo-name, ref, sha, ref-overridden, override-source
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${INPUT_REPOSITORY:?INPUT_REPOSITORY is required}"
INPUT_REF="$(trim "${INPUT_REF:-}")"
INPUT_TOKEN="${INPUT_TOKEN:-}"
INPUT_DEPENDENCY_OVERRIDES="${INPUT_DEPENDENCY_OVERRIDES:-}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

repository="${INPUT_REPOSITORY%/}"
repository="${repository%.git}"
repo="$(repo_key "$repository")"
name="$(repo_name "$repository")"
server_host="${GITHUB_SERVER_URL#*://}"
server_host="${server_host%/}"

# api <path>: GET $GITHUB_API_URL/<path>, print the body, fail loudly on non-2xx.
api() {
  local path="$1" body status
  body="$(mktemp)"
  local -a auth=()
  [ -n "$INPUT_TOKEN" ] && auth=(-H "Authorization: token $INPUT_TOKEN")
  status="$(curl -sS -o "$body" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' "${auth[@]}" \
    "$GITHUB_API_URL/$path")" || { rm -f "$body"; die "GitHub API request failed: $path"; }
  if [[ "$status" != 2* ]]; then
    local msg
    msg="$(jq -r '.message // empty' "$body" 2>/dev/null || true)"
    rm -f "$body"
    case "$status" in
      403|429) die "GitHub API $path returned HTTP $status (${msg:-no message}). Check the token's access or the API rate limit." ;;
      404)     die "GitHub API $path returned HTTP 404 (${msg:-not found}). Does the token have access to $repository and does the ref exist?" ;;
      *)       die "GitHub API $path returned HTTP $status (${msg:-no message})." ;;
    esac
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
      pr_json="$(api "repos/$repository/pulls/$override_value")"
      sha="$(jq -r '.head.sha // empty' <<< "$pr_json")"
      [ -n "$sha" ] || die "Pull request $repository#$override_value has no head commit"
      ref="refs/pull/$override_value/head"
      pr_state="$(jq -r '.state // empty' <<< "$pr_json")"
      pr_merged="$(jq -r '.merged // false' <<< "$pr_json")"
      pr_head="$(jq -r '.head.label // .head.ref // empty' <<< "$pr_json")"
      if [ "$pr_merged" = true ]; then
        warn "$repository#$override_value ($pr_head) is already merged; the 'Depends on' line can probably be removed"
      elif [ "$pr_state" = closed ]; then
        warn "$repository#$override_value ($pr_head) is closed without being merged"
      fi
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
