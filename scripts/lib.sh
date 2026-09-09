#!/usr/bin/env bash
# Shared helpers for the cached-checkout-build-action scripts.
# Sourced, not executed. Works on bash 3.2+ (macOS) and bash 5 (runners).

# Write a step output, using the heredoc form when the value spans lines.
set_output() {
  local name="$1" value="$2" out="${GITHUB_OUTPUT:-/dev/stdout}"
  if [[ "$value" == *$'\n'* ]]; then
    local delim
    delim="ccb_$(date +%s)_$RANDOM"
    printf '%s<<%s\n%s\n%s\n' "$name" "$delim" "$value" "$delim" >> "$out"
  else
    printf '%s=%s\n' "$name" "$value" >> "$out"
  fi
}

# Write a job-wide environment variable (visible to all later steps).
set_env() {
  local name="$1" value="$2" out="${GITHUB_ENV:-/dev/stdout}"
  local delim
  delim="ccb_$(date +%s)_$RANDOM"
  printf '%s<<%s\n%s\n%s\n' "$name" "$delim" "$value" "$delim" >> "$out"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Trim leading/trailing whitespace (including CR from CRLF text).
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Normalise an "owner/repo" string: strip the server URL, a trailing ".git"
# and slashes, then lowercase. Used for every repository comparison.
repo_key() {
  local r="$1"
  r="${r#"${GITHUB_SERVER_URL:-https://github.com}"/}"
  r="${r%/}"
  r="${r%.git}"
  lower "$r"
}

# Basename of an "owner/repo" string, keeping the caller's spelling.
repo_name() {
  local r="$1"
  r="${r%/}"
  r="${r%.git}"
  printf '%s' "${r##*/}"
}

# Replace anything that is not [A-Za-z0-9._-] with "-", so a ref such as
# "feature/foo" or "refs/pull/12/head" can be used as a directory name.
safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

log()    { printf '%s\n' "$*"; }
notice() { printf '::notice::%s\n' "$*"; }
warn()   { printf '::warning::%s\n' "$*"; }
die()    { printf '::error::%s\n' "$*" >&2; exit 1; }

# Run a command as root. Runs directly when already root; via sudo otherwise,
# passing the complete current environment explicitly (sudo would otherwise
# reset it, and "secure_path" would override PATH even with sudo -E).
run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    warn "sudo is not available and the current user is not root; running unprivileged: $*"
    "$@"
    return
  fi
  local -a envs=()
  local e
  while IFS= read -r -d '' e; do
    envs+=("$e")
  done < <(env -0)
  sudo env -i "${envs[@]}" "$@"
}

# Run a command either as root (USE_SUDO=true, the default) or as-is.
run_privileged() {
  case "$(lower "${USE_SUDO:-true}")" in
    false|no|0|'') "$@" ;;
    *) run_as_root "$@" ;;
  esac
}
