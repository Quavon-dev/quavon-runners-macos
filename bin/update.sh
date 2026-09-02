#!/usr/bin/env bash
#
# Updates the runner binaries in place, keeping the existing registration.
# GitHub-hosted orgs normally auto-update runners; this is for pinned versions
# or when a runner has fallen too far behind to self-update.
#
# Usage: bin/update.sh [--version <v>] [--name <name>] [--base-dir <path>]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

OPT_VERSION=''
OPT_NAME=''
OPT_BASE_DIR=''

while [ $# -gt 0 ]; do
  case "$1" in
    --version)  OPT_VERSION="$2"; shift 2 ;;
    --name)     OPT_NAME="$2"; shift 2 ;;
    --base-dir) OPT_BASE_DIR="$2"; shift 2 ;;
    -y|--yes)   ASSUME_YES=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

load_env
RUNNER_BASE_DIR="${OPT_BASE_DIR:-$RUNNER_BASE_DIR}"
require_cmd curl tar shasum

ARCH="$(detect_arch "$(uname -m)")" || die "unsupported architecture: $(uname -m)"
VERSION="$(resolve_runner_version "${OPT_VERSION:-$RUNNER_VERSION}")"
log "target version ${VERSION} (${ARCH})"

CACHE_DIR="${RUNNER_BASE_DIR}/.cache"
mkdir -p "$CACHE_DIR"
TARBALL="${CACHE_DIR}/$(runner_asset_name "$ARCH" "$VERSION")"

if [ ! -f "$TARBALL" ]; then
  log "downloading $(basename "$TARBALL")"
  curl -fSL --retry 3 --retry-delay 2 -o "${TARBALL}.part" "$(runner_asset_url "$ARCH" "$VERSION")"
  mv "${TARBALL}.part" "$TARBALL"
fi

EXPECTED_SHA="$(expected_sha256 "$ARCH" "$VERSION")"
if [ -n "$EXPECTED_SHA" ]; then
  verify_sha256 "$TARBALL" "$EXPECTED_SHA"
else
  warn "no published checksum for v${VERSION}; skipping verification"
fi

update_one() {
  local dir="$1" name
  name="$(basename "$dir")"
  local label; label="$(service_label "$GITHUB_ORG" "$name")"
  local was_running=0

  if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
    was_running=1
    log "${name}: stopping"
    if [ -f "${HOME}/Library/LaunchAgents/${label}.plist" ] \
       && grep -q 'run-ephemeral.sh' "${HOME}/Library/LaunchAgents/${label}.plist" 2>/dev/null; then
      launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
    else
      (cd "$dir" && ./svc.sh stop >/dev/null 2>&1) || true
    fi
  fi

  # The tarball only carries the runner binaries; .runner/.credentials stay put.
  log "${name}: unpacking v${VERSION}"
  tar xzf "$TARBALL" -C "$dir"
  ok "${name}: updated"

  if [ "$was_running" -eq 1 ]; then
    log "${name}: starting"
    if [ -f "${HOME}/Library/LaunchAgents/${label}.plist" ] \
       && grep -q 'run-ephemeral.sh' "${HOME}/Library/LaunchAgents/${label}.plist" 2>/dev/null; then
      launchctl bootstrap "gui/$(id -u)" "${HOME}/Library/LaunchAgents/${label}.plist"
    else
      (cd "$dir" && ./svc.sh start >/dev/null)
    fi
    ok "${name}: running"
  fi
}

if [ -n "$OPT_NAME" ]; then
  dir="${RUNNER_BASE_DIR}/$(sanitize_name "$OPT_NAME")"
  [ -d "$dir" ] || die "no runner at ${dir}"
  update_one "$dir"
  exit 0
fi

dirs="$(runner_dirs || true)"
[ -n "$dirs" ] || die "no configured runners under ${RUNNER_BASE_DIR}"
printf '%s\n' "$dirs" | while IFS= read -r d; do
  if [ -n "$d" ]; then
    update_one "$d"
  fi
done
