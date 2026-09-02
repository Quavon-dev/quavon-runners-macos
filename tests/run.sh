#!/usr/bin/env bash
#
# Dependency-free unit tests for the pure helpers in lib/common.sh.
# Run with: make test
#
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${TEST_DIR}/../lib/common.sh"

PASSED=0
FAILED=0

assert_eq() {
  # assert_eq <expected> <actual> <description>
  if [ "$1" = "$2" ]; then
    PASSED=$((PASSED + 1))
    printf '  ok   %s\n' "$3"
  else
    FAILED=$((FAILED + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$3" "$1" "$2"
  fi
}

assert_fails() {
  # assert_fails <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    FAILED=$((FAILED + 1))
    printf '  FAIL %s (expected a non-zero exit)\n' "$desc"
  else
    PASSED=$((PASSED + 1))
    printf '  ok   %s\n' "$desc"
  fi
}

printf 'detect_arch\n'
assert_eq 'x64'   "$(detect_arch x86_64)" 'x86_64 maps to x64'
assert_eq 'x64'   "$(detect_arch amd64)"  'amd64 maps to x64'
assert_eq 'arm64' "$(detect_arch arm64)"  'arm64 maps to arm64'
assert_eq 'arm64' "$(detect_arch aarch64)" 'aarch64 maps to arm64'
assert_fails 'unknown architecture fails' detect_arch riscv64

printf 'asset naming\n'
assert_eq 'actions-runner-osx-x64-2.337.0.tar.gz' \
  "$(runner_asset_name x64 2.337.0)" 'x64 asset name'
assert_eq 'https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-osx-arm64-2.337.0.tar.gz' \
  "$(runner_asset_url arm64 2.337.0)" 'arm64 asset url'
assert_eq '2.337.0' "$(strip_v v2.337.0)" 'strip the v prefix'
assert_eq '2.337.0' "$(strip_v 2.337.0)"  'plain version is unchanged'

printf 'checksum extraction\n'
BODY='- actions-runner-osx-x64-2.337.0.tar.gz <!-- BEGIN SHA osx-x64 -->d383f505d7ed041b1873ab68c35dd766fc093f2252330f95bb427be8f2c6dcfc<!-- END SHA osx-x64 -->
- actions-runner-osx-arm64-2.337.0.tar.gz <!-- BEGIN SHA osx-arm64 -->5a2cd92908a93d7276a194e1de6008099f3e7946f3f8e14aa7a1a7b4a31fdec2<!-- END SHA osx-arm64 -->'
assert_eq 'd383f505d7ed041b1873ab68c35dd766fc093f2252330f95bb427be8f2c6dcfc' \
  "$(printf '%s' "$BODY" | sha_from_release_body x64)" 'x64 checksum from the release body'
assert_eq '5a2cd92908a93d7276a194e1de6008099f3e7946f3f8e14aa7a1a7b4a31fdec2' \
  "$(printf '%s' "$BODY" | sha_from_release_body arm64)" 'arm64 checksum from the release body'
assert_eq '' "$(printf '%s' "$BODY" | sha_from_release_body ppc64)" 'missing architecture yields nothing'

printf 'runner naming\n'
assert_eq 'mac-vm-01'   "$(runner_name_for_index mac-vm-01 1 1)" 'a single runner keeps the bare name'
assert_eq 'mac-vm-01-1' "$(runner_name_for_index mac-vm-01 1 3)" 'multiple runners get an index suffix'
assert_eq 'mac-vm-01-3' "$(runner_name_for_index mac-vm-01 3 3)" 'the last index is suffixed too'
assert_eq 'quavon-mac-1' "$(sanitize_name 'Quavon Mac 1')" 'names are lowercased and slugified'
assert_eq 'a.b-c_d'      "$(sanitize_name 'a.b-c_d')"      'dots, dashes and underscores survive'
assert_eq 'x-y'          "$(sanitize_name '--x///y--')"    'leading, trailing and repeated dashes collapse'

printf 'json parsing\n'
JSON='{"token":"AABBCC","expires_at":"2026-09-02T14:00:00Z","message":null}'
assert_eq 'AABBCC' "$(json_field "$JSON" token)" 'extract a token'
assert_eq '2026-09-02T14:00:00Z' "$(json_field "$JSON" expires_at)" 'extract a timestamp'
assert_eq '' "$(json_field "$JSON" nope)" 'a missing key yields nothing'

printf 'service labels\n'
assert_eq 'actions.runner.quavon-dev.mac-vm-01' \
  "$(service_label quavon-dev mac-vm-01)" 'launchd label matches the runner svc.sh convention'

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
