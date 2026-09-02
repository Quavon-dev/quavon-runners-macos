#!/usr/bin/env bash
#
# One-shot setup for a fresh macOS VM:
#   git clone git@github.com:quavon-dev/quavon-runners-macos.git
#   cd quavon-runners-macos && ./bootstrap.sh
#
# Creates .env if it is missing (prompting for the token), runs the health
# checks, then installs and starts the runner(s). Any flag is passed through to
# bin/install.sh, e.g. ./bootstrap.sh --count 2 --labels sonoma,xcode-15
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

if [ ! -f "$ENV_FILE" ]; then
  log "no .env found; creating one"
  cp "${SCRIPT_DIR}/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  org=''
  printf 'GitHub organisation [quavon-dev]: ' >&2
  read -r org || true
  org="${org:-quavon-dev}"

  token=''
  if [ -n "${GITHUB_PAT:-}" ]; then
    token="$GITHUB_PAT"
    ok "using GITHUB_PAT from the environment"
  elif command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    ok "using the token from the gh CLI"
  else
    printf 'GitHub PAT (admin:org, input hidden): ' >&2
    stty -echo 2>/dev/null || true
    read -r token || true
    stty echo 2>/dev/null || true
    printf '\n' >&2
    [ -n "$token" ] || die "a token is required (or run 'gh auth login' first)"
  fi

  # Rewrite only the two keys we collected; keep the rest of the template.
  tmp="$(mktemp)"
  sed -e "s|^GITHUB_ORG=.*|GITHUB_ORG=${org}|" \
      -e "s|^GITHUB_PAT=.*|GITHUB_PAT=${token}|" "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "wrote ${ENV_FILE} (mode 600)"
  warn "edit ${ENV_FILE} to set labels, runner count or a pinned version"
fi

export ENV_FILE

log "running health checks"
"${SCRIPT_DIR}/bin/doctor.sh" || die "doctor found blocking issues; fix them and re-run"

log "installing runner(s)"
exec "${SCRIPT_DIR}/bin/install.sh" "$@"
