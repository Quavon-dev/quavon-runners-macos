#!/usr/bin/env bash
#
# Installs one or more GitHub Actions self-hosted runners for the quavon-dev org
# on this macOS host. Runs the runner directly on the VM (no Docker) and keeps it
# alive through launchd.
#
# Usage: bin/install.sh [options]
#   --name <name>       Runner name (default: hostname, suffixed when count > 1)
#   --count <n>         Number of runners to install on this host (default: 1)
#   --labels <a,b,c>    Extra labels, appended to the auto-detected ones
#   --group <name>      Runner group (default: Default)
#   --version <v>       Runner version, e.g. 2.337.0 (default: latest)
#   --base-dir <path>   Where runners live (default: ~/actions-runners)
#   --ephemeral         One job per runner process, re-registering each time
#   --no-service        Configure only; do not install the launchd service
#   --force             Reconfigure runners that already exist
#   -y, --yes           Do not prompt
#   -v, --verbose       Verbose output
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${SCRIPT_DIR}/../lib/common.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPT_NAME=''
OPT_COUNT=''
OPT_LABELS=''
OPT_GROUP=''
OPT_VERSION=''
OPT_BASE_DIR=''
OPT_EPHEMERAL=''
INSTALL_SERVICE=1
FORCE=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)      OPT_NAME="$2"; shift 2 ;;
    --count)     OPT_COUNT="$2"; shift 2 ;;
    --labels)    OPT_LABELS="$2"; shift 2 ;;
    --group)     OPT_GROUP="$2"; shift 2 ;;
    --version)   OPT_VERSION="$2"; shift 2 ;;
    --base-dir)  OPT_BASE_DIR="$2"; shift 2 ;;
    --ephemeral) OPT_EPHEMERAL='true'; shift ;;
    --no-service) INSTALL_SERVICE=0; shift ;;
    --force)     FORCE=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)   usage 0 ;;
    *) err "unknown option: $1"; usage 1 ;;
  esac
done

load_env

RUNNER_NAME_PREFIX="${OPT_NAME:-$RUNNER_NAME_PREFIX}"
RUNNER_COUNT="${OPT_COUNT:-$RUNNER_COUNT}"
RUNNER_GROUP="${OPT_GROUP:-$RUNNER_GROUP}"
RUNNER_VERSION="${OPT_VERSION:-$RUNNER_VERSION}"
RUNNER_BASE_DIR="${OPT_BASE_DIR:-$RUNNER_BASE_DIR}"
RUNNER_EPHEMERAL="${OPT_EPHEMERAL:-$RUNNER_EPHEMERAL}"
if [ -n "$OPT_LABELS" ]; then
  RUNNER_LABELS="$OPT_LABELS"
fi

case "$RUNNER_COUNT" in
  ''|*[!0-9]*) die "--count must be a positive integer (got '$RUNNER_COUNT')" ;;
esac
[ "$RUNNER_COUNT" -ge 1 ] || die "--count must be >= 1"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

log "preflight"
require_cmd curl tar shasum sed awk

[ "$(uname -s)" = "Darwin" ] || die "this installer targets macOS (found $(uname -s))"

ARCH="$(detect_arch "$(uname -m)")" || die "unsupported architecture: $(uname -m)"
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
ok "macOS ${MACOS_VERSION} (${ARCH})"

xcode-select -p >/dev/null 2>&1 || warn "Xcode Command Line Tools missing. Install: xcode-select --install"

AUTO_LABELS="macOS,${ARCH},macos-${MACOS_MAJOR}"
LABELS="$AUTO_LABELS"
if [ -n "$RUNNER_LABELS" ]; then
  LABELS="${LABELS},${RUNNER_LABELS}"
fi

VERSION="$(resolve_runner_version "$RUNNER_VERSION")"
ok "runner version ${VERSION}"

# Fail fast on a bad or under-scoped token before touching the filesystem.
log "checking GitHub access to org '${GITHUB_ORG}'"
api GET "/orgs/${GITHUB_ORG}/actions/runners?per_page=1" >/dev/null
ok "token can manage runners for ${GITHUB_ORG}"

# ---------------------------------------------------------------------------
# Download (cached and checksum-verified once per version)
# ---------------------------------------------------------------------------

CACHE_DIR="${RUNNER_BASE_DIR}/.cache"
mkdir -p "$CACHE_DIR"
TARBALL="${CACHE_DIR}/$(runner_asset_name "$ARCH" "$VERSION")"

if [ ! -f "$TARBALL" ]; then
  log "downloading $(basename "$TARBALL")"
  curl -fSL --retry 3 --retry-delay 2 -o "${TARBALL}.part" "$(runner_asset_url "$ARCH" "$VERSION")" \
    || die "download failed"
  mv "${TARBALL}.part" "$TARBALL"
fi

EXPECTED_SHA="$(expected_sha256 "$ARCH" "$VERSION")"
if [ -n "$EXPECTED_SHA" ]; then
  verify_sha256 "$TARBALL" "$EXPECTED_SHA"
else
  warn "no published checksum found for v${VERSION}; skipping verification"
fi

# ---------------------------------------------------------------------------
# Install each runner
# ---------------------------------------------------------------------------

install_one() {
  local name="$1" dir="${RUNNER_BASE_DIR}/$1"

  if [ -f "${dir}/.runner" ] && [ "$FORCE" -eq 0 ]; then
    warn "${name}: already configured at ${dir} (use --force to reconfigure); skipping"
    return 0
  fi

  if [ -d "$dir" ] && [ "$FORCE" -eq 1 ]; then
    log "${name}: removing the existing installation"
    "${SCRIPT_DIR}/uninstall.sh" --name "$name" --base-dir "$RUNNER_BASE_DIR" --yes || true
  fi

  log "${name}: unpacking into ${dir}"
  mkdir -p "$dir"
  tar xzf "$TARBALL" -C "$dir"

  if [ "$RUNNER_EPHEMERAL" = "true" ]; then
    install_ephemeral "$name" "$dir"
    return 0
  fi

  log "${name}: registering with ${GITHUB_ORG}"
  local token
  token="$(registration_token)"
  (
    cd "$dir"
    ./config.sh \
      --unattended \
      --replace \
      --url "${GITHUB_HOST}/${GITHUB_ORG}" \
      --token "$token" \
      --name "$name" \
      --labels "$LABELS" \
      --runnergroup "$RUNNER_GROUP" \
      --work "$RUNNER_WORK_DIR"
  )
  ok "${name}: registered with labels ${LABELS}"

  if [ "$INSTALL_SERVICE" -eq 1 ]; then
    log "${name}: installing the launchd service"
    (cd "$dir" && ./svc.sh install >/dev/null && ./svc.sh start >/dev/null)
    ok "${name}: service running"
  else
    ok "${name}: configured; start it with 'cd ${dir} && ./run.sh'"
  fi
}

install_ephemeral() {
  # Ephemeral runners consume their registration on every job, so the launchd
  # job drives our own loop instead of the runner's svc.sh.
  local name="$1" dir="$2"
  local label plist
  label="$(service_label "$GITHUB_ORG" "$name")"
  plist="${HOME}/Library/LaunchAgents/${label}.plist"

  printf '%s\n' "$LABELS" > "${dir}/.quavon-labels"
  printf '%s\n' "$RUNNER_GROUP" > "${dir}/.quavon-group"

  if [ "$INSTALL_SERVICE" -eq 0 ]; then
    ok "${name}: ephemeral runner unpacked; start it with '${SCRIPT_DIR}/run-ephemeral.sh --name ${name}'"
    return 0
  fi

  mkdir -p "${HOME}/Library/LaunchAgents" "${dir}/_diag"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_DIR}/run-ephemeral.sh</string>
    <string>--name</string><string>${name}</string>
    <string>--base-dir</string><string>${RUNNER_BASE_DIR}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ENV_FILE</key><string>${REPO_ROOT}/.env</string>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>WorkingDirectory</key><string>${dir}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${dir}/_diag/ephemeral.out.log</string>
  <key>StandardErrorPath</key><string>${dir}/_diag/ephemeral.err.log</string>
</dict>
</plist>
PLIST

  launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  ok "${name}: ephemeral service running (label ${label})"
}

mkdir -p "$RUNNER_BASE_DIR"

i=1
while [ "$i" -le "$RUNNER_COUNT" ]; do
  name="$(sanitize_name "$(runner_name_for_index "$RUNNER_NAME_PREFIX" "$i" "$RUNNER_COUNT")")"
  install_one "$name"
  i=$((i + 1))
done

log "done"
"${SCRIPT_DIR}/status.sh" || true

if [ "$INSTALL_SERVICE" -eq 1 ]; then
  cat >&2 <<'NOTE'

Note: the runner service is a launchd *user agent*. It only runs while the user
is logged in, so a headless VM needs automatic login enabled:
  System Settings -> Users & Groups -> Automatic login -> this user
See docs/vm-setup.md for the full VM checklist.
NOTE
fi
