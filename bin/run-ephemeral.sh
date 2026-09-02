#!/usr/bin/env bash
#
# Runs one ephemeral runner cycle: register, take exactly one job, exit.
# launchd (KeepAlive) restarts this script, which re-registers a fresh runner —
# so every job gets a clean registration without a reusable token on disk.
#
# Usage: bin/run-ephemeral.sh --name <name> [--base-dir <path>] [--loop]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

NAME=''
OPT_BASE_DIR=''
LOOP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name)     NAME="$2"; shift 2 ;;
    --base-dir) OPT_BASE_DIR="$2"; shift 2 ;;
    --loop)     LOOP=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

load_env
RUNNER_BASE_DIR="${OPT_BASE_DIR:-$RUNNER_BASE_DIR}"
[ -n "$NAME" ] || die "--name is required"

DIR="${RUNNER_BASE_DIR}/$(sanitize_name "$NAME")"
[ -x "${DIR}/config.sh" ] || die "no runner installation at ${DIR}"

LABELS="$(cat "${DIR}/.quavon-labels" 2>/dev/null || printf 'macOS')"
GROUP="$(cat "${DIR}/.quavon-group" 2>/dev/null || printf '%s' "$RUNNER_GROUP")"

cleanup_registration() {
  [ -f "${DIR}/.runner" ] || return 0
  local token
  token="$(remove_token 2>/dev/null || true)"
  [ -n "$token" ] || return 0
  (cd "$DIR" && ./config.sh remove --token "$token" >/dev/null 2>&1) || true
}

cycle() {
  cleanup_registration

  local token
  token="$(registration_token)"
  (
    cd "$DIR"
    ./config.sh \
      --unattended \
      --ephemeral \
      --replace \
      --url "${GITHUB_HOST}/${GITHUB_ORG}" \
      --token "$token" \
      --name "$NAME" \
      --labels "$LABELS" \
      --runnergroup "$GROUP" \
      --work "$RUNNER_WORK_DIR"
  )
  log "${NAME}: waiting for one job"
  (cd "$DIR" && ./run.sh)
}

trap cleanup_registration EXIT INT TERM

if [ "$LOOP" -eq 1 ]; then
  while true; do
    cycle
    sleep "${EPHEMERAL_SLEEP:-5}"
  done
else
  cycle
fi
