#!/usr/bin/env bash
# Shared helpers for the quavon-dev macOS self-hosted runner tooling.
# Sourced by every script in bin/. Contains no side effects beyond defining
# functions and read-only constants, so it is safe to source from tests.

GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITHUB_HOST="${GITHUB_HOST:-https://github.com}"
RUNNER_RELEASES_URL="${RUNNER_RELEASES_URL:-https://github.com/actions/runner/releases/download}"
API_VERSION_HEADER="X-GitHub-Api-Version: 2022-11-28"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_OFF=''
fi

log()   { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*" >&2; }
ok()    { printf '%s ok %s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn()  { printf '%swarn%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()   { printf '%sfail%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
debug() { [ "${VERBOSE:-0}" = "1" ] && printf '%s  . %s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; return 0; }
die()   { err "$*"; exit 1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

confirm() {
  # confirm <prompt>  -> 0 on yes. Auto-yes when ASSUME_YES=1.
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local reply=''
  printf '%s [y/N] ' "$1" >&2
  read -r reply || return 1
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested in tests/)
# ---------------------------------------------------------------------------

detect_arch() {
  # detect_arch <machine>  -- maps `uname -m` onto the runner asset architecture.
  case "$1" in
    x86_64|x64|amd64) printf 'x64' ;;
    arm64|aarch64)    printf 'arm64' ;;
    *)                return 1 ;;
  esac
}

runner_asset_name() {
  # runner_asset_name <arch> <version>
  printf 'actions-runner-osx-%s-%s.tar.gz' "$1" "$2"
}

runner_asset_url() {
  # runner_asset_url <arch> <version>
  printf '%s/v%s/%s' "$RUNNER_RELEASES_URL" "$2" "$(runner_asset_name "$1" "$2")"
}

strip_v() {
  printf '%s' "${1#v}"
}

sha_from_release_body() {
  # sha_from_release_body <arch>  -- reads the release body on stdin.
  # Release notes embed markers: <!-- BEGIN SHA osx-x64 -->abc...<!-- END SHA osx-x64 -->
  local arch="$1"
  tr -d '\n' \
    | sed -n "s/.*<!-- BEGIN SHA osx-${arch} -->\([0-9a-f]\{64\}\)<!-- END SHA osx-${arch} -->.*/\1/p"
}

runner_name_for_index() {
  # runner_name_for_index <base> <index> <count>
  # Single runner keeps the bare hostname; multiples get a -N suffix.
  local base="$1" index="$2" count="$3"
  if [ "$count" -le 1 ]; then
    printf '%s' "$base"
  else
    printf '%s-%s' "$base" "$index"
  fi
}

sanitize_name() {
  # GitHub runner names allow no whitespace; normalise to a safe slug.
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//'
}

default_runner_basename() {
  sanitize_name "$(hostname -s 2>/dev/null || printf 'macos-runner')"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

repo_root() {
  # Directory containing this library's parent (the checkout root).
  local src="${BASH_SOURCE[0]}"
  cd "$(dirname "$src")/.." && pwd
}

load_env() {
  # Sources the env file (ENV_FILE, default <repo>/.env) and applies defaults.
  local env_file="${ENV_FILE:-$(repo_root)/.env}"
  if [ -f "$env_file" ]; then
    local perms
    perms="$(stat -f '%OLp' "$env_file" 2>/dev/null || stat -c '%a' "$env_file" 2>/dev/null || echo '')"
    case "$perms" in
      600|400) : ;;
      '') warn "could not check permissions of $env_file" ;;
      *) warn "$env_file is mode $perms; it holds a token. Run: chmod 600 $env_file" ;;
    esac
    # shellcheck disable=SC1090
    . "$env_file"
    debug "loaded $env_file"
  else
    debug "no env file at $env_file (relying on the environment)"
  fi

  GITHUB_ORG="${GITHUB_ORG:-quavon-dev}"
  RUNNER_BASE_DIR="${RUNNER_BASE_DIR:-$HOME/actions-runners}"
  RUNNER_VERSION="${RUNNER_VERSION:-latest}"
  RUNNER_LABELS="${RUNNER_LABELS:-}"
  RUNNER_GROUP="${RUNNER_GROUP:-Default}"
  RUNNER_COUNT="${RUNNER_COUNT:-1}"
  RUNNER_WORK_DIR="${RUNNER_WORK_DIR:-_work}"
  RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-$(default_runner_basename)}"
  RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-false}"
}

github_token() {
  # Resolves the PAT: explicit env first, then the gh CLI as a fallback.
  if [ -n "${GITHUB_PAT:-}" ]; then
    printf '%s' "$GITHUB_PAT"
    return 0
  fi
  if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    gh auth token
    return 0
  fi
  die "no GitHub token. Set GITHUB_PAT in .env (scope: admin:org) or run 'gh auth login'."
}

api() {
  # api <method> <path> [body] -- returns the response body, fails on HTTP >= 400.
  local method="$1" path="$2" body="${3:-}"
  local token response status
  token="$(github_token)"

  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  local -a args=(
    -sS -o "$tmp" -w '%{http_code}'
    -X "$method"
    -H "Authorization: Bearer $token"
    -H "Accept: application/vnd.github+json"
    -H "$API_VERSION_HEADER"
  )
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi

  status="$(curl "${args[@]}" "${GITHUB_API}${path}")" || die "curl failed for $method $path"
  response="$(cat "$tmp")"

  if [ "$status" -ge 400 ]; then
    local message
    message="$(json_field "$response" message)"
    die "GitHub API $method $path -> HTTP $status${message:+: $message}"
  fi
  printf '%s' "$response"
}

json_field() {
  # json_field <json> <key> -- minimal string-value extractor (jq when present).
  local json="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null && return 0
  fi
  printf '%s' "$json" \
    | tr -d '\n' \
    | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

registration_token() {
  json_field "$(api POST "/orgs/${GITHUB_ORG}/actions/runners/registration-token")" token
}

remove_token() {
  json_field "$(api POST "/orgs/${GITHUB_ORG}/actions/runners/remove-token")" token
}

resolve_runner_version() {
  # Echoes the version to install; "latest" hits the releases API.
  local requested="${1:-latest}"
  if [ "$requested" != "latest" ]; then
    strip_v "$requested"
    return 0
  fi
  local body tag
  body="$(curl -sSL -H "Accept: application/vnd.github+json" -H "$API_VERSION_HEADER" \
    "${GITHUB_API}/repos/actions/runner/releases/latest")" \
    || die "could not reach the actions/runner releases API"
  tag="$(json_field "$body" tag_name)"
  [ -n "$tag" ] || die "could not resolve the latest actions/runner release"
  strip_v "$tag"
}

expected_sha256() {
  # expected_sha256 <arch> <version>
  local arch="$1" version="$2" body
  body="$(curl -sSL -H "Accept: application/vnd.github+json" -H "$API_VERSION_HEADER" \
    "${GITHUB_API}/repos/actions/runner/releases/tags/v${version}")"
  printf '%s' "$body" | sha_from_release_body "$arch"
}

verify_sha256() {
  # verify_sha256 <file> <expected>
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die "checksum mismatch for $file (expected $expected, got $actual)"
  ok "checksum verified: $(basename "$file")"
}

service_label() {
  # The launchd label the runner's own svc.sh generates.
  printf 'actions.runner.%s.%s' "$1" "$2"
}

runner_dirs() {
  # Lists configured runner directories under RUNNER_BASE_DIR.
  local d
  for d in "$RUNNER_BASE_DIR"/*/; do
    [ -f "${d}.runner" ] && printf '%s\n' "${d%/}"
  done
}
