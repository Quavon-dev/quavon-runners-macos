#!/usr/bin/env bash
#
# Checks whether this machine is ready to host self-hosted runners, and
# reports anything that would make a runner flaky (sleep, no auto-login, ...).
#
# Usage: bin/doctor.sh
#
set -uo pipefail   # deliberately not -e: every check should run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

FAILURES=0
WARNINGS=0

pass() { ok "$*"; }
fail() { err "$*"; FAILURES=$((FAILURES + 1)); }
soft() { warn "$*"; WARNINGS=$((WARNINGS + 1)); }

load_env

log "system"
if [ "$(uname -s)" = "Darwin" ]; then
  pass "macOS $(sw_vers -productVersion) build $(sw_vers -buildVersion)"
else
  fail "not macOS (found $(uname -s))"
fi

if arch="$(detect_arch "$(uname -m)")"; then
  pass "architecture: ${arch} ($(uname -m))"
else
  fail "unsupported architecture: $(uname -m)"
fi

free_gb="$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "$free_gb" ] && [ "$free_gb" -lt 20 ] 2>/dev/null; then
  soft "only ${free_gb}G free in $HOME; builds fill a runner fast"
else
  pass "free disk: ${free_gb:-?}G"
fi

log "tooling"
for cmd in curl tar shasum git; do
  if command -v "$cmd" >/dev/null 2>&1; then pass "$cmd"; else fail "missing: $cmd"; fi
done
if command -v jq >/dev/null 2>&1; then
  pass "jq (optional)"
else
  soft "jq not installed (nicer status output)"
fi

if xcode-select -p >/dev/null 2>&1; then
  pass "Xcode Command Line Tools: $(xcode-select -p)"
else
  fail "Xcode Command Line Tools missing -> xcode-select --install"
fi

if command -v brew >/dev/null 2>&1; then
  pass "Homebrew $(brew --version | head -1)"
else
  soft "Homebrew not installed (optional)"
fi

log "configuration"
env_file="${ENV_FILE:-$(repo_root)/.env}"
if [ -f "$env_file" ]; then
  perms="$(stat -f '%OLp' "$env_file" 2>/dev/null)"
  case "$perms" in
    600|400) pass ".env present (mode ${perms})" ;;
    *) fail ".env is mode ${perms}; it holds a token -> chmod 600 ${env_file}" ;;
  esac
else
  soft "no .env (copy .env.example and fill it in, or export GITHUB_PAT)"
fi
pass "org: ${GITHUB_ORG}"
pass "base dir: ${RUNNER_BASE_DIR}"

log "github access"
if runners="$(api GET "/orgs/${GITHUB_ORG}/actions/runners?per_page=1" 2>&1)"; then
  count="$(json_field "$runners" total_count)"
  pass "token can read org runners (${count:-?} registered)"
else
  # `api` reports through err(); drop its prefix so the reason reads cleanly here.
  fail "cannot list runners for ${GITHUB_ORG}: $(printf '%s' "$runners" | sed 's/^[^ ]*fail[^ ]* //')"
  fail "the token needs the classic 'admin:org' scope, or fine-grained org permission 'Self-hosted runners: read & write'"
fi

log "host stability"
login_user="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)"
if [ -n "$login_user" ]; then
  pass "automatic login enabled for '${login_user}'"
else
  soft "automatic login is off; a launchd *user agent* only runs while someone is logged in (see docs/vm-setup.md)"
fi

sleep_state="$(pmset -g 2>/dev/null | awk '$1=="sleep" {print $2; exit}')"
if [ "${sleep_state:-}" = "0" ]; then
  pass "system sleep disabled"
else
  soft "system sleep is '${sleep_state:-unknown}' -> sudo pmset -a sleep 0 displaysleep 0 disablesleep 1"
fi

if pmset -g 2>/dev/null | grep -q 'standby.*1'; then
  soft "standby enabled; consider: sudo pmset -a standby 0"
fi

log "runners on this host"
"${SCRIPT_DIR}/status.sh" --no-remote

printf '\n' >&2
if [ "$FAILURES" -gt 0 ]; then
  err "${FAILURES} blocking issue(s), ${WARNINGS} warning(s)"
  exit 1
fi
ok "ready (${WARNINGS} warning(s))"
