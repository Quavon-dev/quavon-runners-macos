#!/usr/bin/env bash
#
# Stops, deregisters and removes self-hosted runners from this host.
#
# Usage: bin/uninstall.sh [options]
#   --name <name>      Remove a single runner (default: every runner found)
#   --all              Remove every runner under the base directory
#   --base-dir <path>  Where runners live (default: ~/actions-runners)
#   --keep-files       Deregister and stop, but leave the directory in place
#   -y, --yes          Do not prompt
#   -v, --verbose      Verbose output
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

OPT_NAME=''
OPT_BASE_DIR=''
KEEP_FILES=0
ALL=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)     OPT_NAME="$2"; shift 2 ;;
    --base-dir) OPT_BASE_DIR="$2"; shift 2 ;;
    --all)      ALL=1; shift ;;
    --keep-files) KEEP_FILES=1; shift ;;
    -y|--yes)   ASSUME_YES=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)  usage 0 ;;
    *) err "unknown option: $1"; usage 1 ;;
  esac
done

load_env
RUNNER_BASE_DIR="${OPT_BASE_DIR:-$RUNNER_BASE_DIR}"

remove_one() {
  local dir="$1" name
  name="$(basename "$dir")"
  [ -d "$dir" ] || { warn "${name}: no such directory ${dir}"; return 0; }

  local label plist
  label="$(service_label "$GITHUB_ORG" "$name")"

  # Our ephemeral agent, if this runner used one.
  plist="${HOME}/Library/LaunchAgents/${label}.plist"
  if [ -f "$plist" ] && grep -q 'run-ephemeral.sh' "$plist" 2>/dev/null; then
    log "${name}: stopping the ephemeral service"
    launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
    rm -f "$plist"
  elif [ -f "${dir}/svc.sh" ]; then
    log "${name}: stopping the launchd service"
    (
      cd "$dir" || exit 0
      ./svc.sh stop >/dev/null 2>&1 || true
      ./svc.sh uninstall >/dev/null 2>&1 || true
    )
  fi

  if [ -f "${dir}/.runner" ]; then
    log "${name}: deregistering from ${GITHUB_ORG}"
    local token
    token="$(remove_token)"
    (cd "$dir" && ./config.sh remove --token "$token" >/dev/null) \
      || warn "${name}: deregistration failed; remove it manually in the org runner settings"
  fi

  if [ "$KEEP_FILES" -eq 1 ]; then
    ok "${name}: stopped and deregistered (files kept at ${dir})"
    return 0
  fi

  rm -rf "$dir"
  ok "${name}: removed"
}

if [ -n "$OPT_NAME" ]; then
  remove_one "${RUNNER_BASE_DIR}/$(sanitize_name "$OPT_NAME")"
  exit 0
fi

dirs="$(runner_dirs || true)"
if [ -z "$dirs" ]; then
  warn "no configured runners under ${RUNNER_BASE_DIR}"
  exit 0
fi

if [ "$ALL" -eq 0 ]; then
  printf '%s\n' "$dirs" >&2
  confirm "Remove all the runners listed above?" || die "aborted"
fi

printf '%s\n' "$dirs" | while IFS= read -r d; do
  if [ -n "$d" ]; then
    remove_one "$d"
  fi
done
