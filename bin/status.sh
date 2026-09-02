#!/usr/bin/env bash
#
# Shows the local runners on this host and how the org sees them.
#
# Usage: bin/status.sh [--base-dir <path>] [--no-remote]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

OPT_BASE_DIR=''
SHOW_REMOTE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir)  OPT_BASE_DIR="$2"; shift 2 ;;
    --no-remote) SHOW_REMOTE=0; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)   sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

load_env
RUNNER_BASE_DIR="${OPT_BASE_DIR:-$RUNNER_BASE_DIR}"

printf '\nLocal runners in %s\n' "$RUNNER_BASE_DIR" >&2
printf '%-28s %-10s %s\n' 'NAME' 'SERVICE' 'LABEL' >&2

found=0
for dir in "$RUNNER_BASE_DIR"/*/; do
  [ -f "${dir}.runner" ] || continue
  found=1
  name="$(basename "${dir%/}")"
  label="$(service_label "$GITHUB_ORG" "$name")"
  if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
    state='running'
  elif [ -f "${HOME}/Library/LaunchAgents/${label}.plist" ]; then
    state='stopped'
  else
    state='no-svc'
  fi
  printf '%-28s %-10s %s\n' "$name" "$state" "$label" >&2
done
[ "$found" -eq 1 ] || printf '(none)\n' >&2

[ "$SHOW_REMOTE" -eq 1 ] || exit 0

printf '\nOrg runners (%s)\n' "$GITHUB_ORG" >&2
response="$(api GET "/orgs/${GITHUB_ORG}/actions/runners?per_page=100")"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$response" | jq -r \
    '.runners[] | "\(.name)\t\(.status)\t\(if .busy then "busy" else "idle" end)\t\([.labels[].name] | join(","))"' \
    | awk -F'\t' '{printf "%-28s %-10s %-6s %s\n", $1, $2, $3, $4}' >&2
else
  warn "install jq for a full remote listing"
  printf '%s' "$response" | tr ',' '\n' | grep -E '"(name|status)"' >&2 || true
fi
