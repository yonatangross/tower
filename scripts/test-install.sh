#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016 is intentional everywhere in this file: mock bodies are written as
# single-quoted strings so their variables expand at mock runtime, not while
# write_mock and write_mock_dry generate the mock scripts.

# Focused offline tests for install.sh. Every app and GitHub side effect is
# redirected to temporary fixtures or a command mock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tower-install-test.XXXXXX")"
PROJECT_ROOT="$TEST_ROOT/project"
MOCK_BIN="$TEST_ROOT/bin"
MOCK_BIN_DRY="$TEST_ROOT/bin-dry"
FIXTURES="$TEST_ROOT/fixtures"
INSTALLED="$TEST_ROOT/installed"
LOG="$TEST_ROOT/calls.log"
TOWER_TEST_NO_RUN=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$PROJECT_ROOT/scripts" "$MOCK_BIN" "$MOCK_BIN_DRY" "$FIXTURES"
cp "$ROOT/scripts/install.sh" "$PROJECT_ROOT/scripts/install.sh"
cp "$ROOT/scripts/sign-app.sh" "$PROJECT_ROOT/scripts/sign-app.sh"
chmod +x "$PROJECT_ROOT/scripts/install.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_not_file() {
  [ ! -e "$1" ] || fail "unexpected path: $1"
}

assert_contains() {
  grep -F "$1" "$2" >/dev/null || fail "expected $2 to contain: $1"
}

assert_not_contains() {
  if [ -f "$2" ]; then
    ! grep -F "$1" "$2" >/dev/null || fail "expected $2 not to contain: $1"
  fi
}

write_mock() {
  local name="$1"
  shift
  printf '%s\n' '#!/usr/bin/env bash' "$@" > "$MOCK_BIN/$name"
  chmod +x "$MOCK_BIN/$name"
}

# Dry-run loggers shadow the destination commands in run_install_dry: they
# record the exact arguments install.sh resolved and touch nothing on disk.
write_mock_dry() {
  local name="$1"
  shift
  printf '%s\n' '#!/usr/bin/env bash' "$@" > "$MOCK_BIN_DRY/$name"
  chmod +x "$MOCK_BIN_DRY/$name"
}

write_mock_dry mkdir 'echo "mkdir $*" >> "$TOWER_TEST_LOG"'
write_mock_dry rm 'echo "rm $*" >> "$TOWER_TEST_LOG"'
write_mock_dry cp 'echo "cp $*" >> "$TOWER_TEST_LOG"'
write_mock_dry find 'echo "find $*" >> "$TOWER_TEST_LOG"'

# mkdir and cp pass through to the real binaries: every argument install.sh can
# hand them resolves inside TEST_ROOT (DEST_DIR comes from TOWER_TEST_INSTALLED,
# DOWNLOAD_DIR lives under TMPDIR), so the suite exercises real filesystem
# behavior and the sandboxing rests on the destination hook, not on pretending.
write_mock pkill 'echo "pkill $*" >> "$TOWER_TEST_LOG"' 'exit 1'
write_mock open 'echo "open $*" >> "$TOWER_TEST_LOG"'
write_mock sleep 'echo "sleep $*" >> "$TOWER_TEST_LOG"'
write_mock pgrep 'echo "pgrep $*" >> "$TOWER_TEST_LOG"' 'exit 0'
write_mock mkdir \
  'echo "mkdir $*" >> "$TOWER_TEST_LOG"' \
  '/bin/mkdir "$@"'
write_mock rm 'echo "rm $*" >> "$TOWER_TEST_LOG"'
write_mock find 'echo "find $*" >> "$TOWER_TEST_LOG"'
write_mock cp \
  'echo "cp $*" >> "$TOWER_TEST_LOG"' \
  '/bin/cp "$@"'
write_mock ditto \
  'echo "ditto $*" >> "$TOWER_TEST_LOG"' \
  'destination="${!#}"' \
  '/bin/mkdir -p "$destination/Tower.app/Contents/MacOS"' \
  'printf fixture > "$destination/Tower.app/Contents/MacOS/HQClaudeLimits"'
write_mock gh \
  'echo "gh $*" >> "$TOWER_TEST_LOG"' \
  'if [ "$1" = "api" ] && [ "${TOWER_TEST_NO_RUN:-0}" = 1 ] && printf "%s" "$2" | grep -F "/runs?" >/dev/null; then exit 0; fi' \
  'if [ "$1" = "api" ] && printf "%s" "$2" | grep -F "/runs?" >/dev/null; then echo "123"; exit 0; fi' \
  'if [ "$1" = "api" ] && printf "%s" "$2" | grep -F "/artifacts?" >/dev/null; then echo "tower-app-deadbeef"; exit 0; fi' \
  'if [ "$1" = "run" ] && [ "$2" = "download" ]; then' \
  '  destination="${!#}"' \
  '  /bin/cp "$TOWER_TEST_FIXTURES/Tower.app.zip" "$destination/Tower.app.zip"' \
  '  /bin/cp "$TOWER_TEST_FIXTURES/Tower.app.zip.sha256" "$destination/Tower.app.zip.sha256"' \
  '  exit 0' \
  'fi' \
  'if [ "$1" = "release" ] && [ "$2" = "download" ]; then' \
  '  destination="${!#}"' \
  '  /bin/cp "$TOWER_TEST_FIXTURES/Tower.app.zip" "$destination/Tower.app.zip"' \
  '  /bin/cp "$TOWER_TEST_FIXTURES/Tower.app.zip.sha256" "$destination/Tower.app.zip.sha256"' \
  '  exit 0' \
  'fi' \
  'echo "unexpected gh invocation: $*" >&2' \
  'exit 64'

# #121 signing. TOWER_TEST_IDENTITY=1 makes this machine hold a "Tower Dev"
# identity; codesign only records what install.sh asked of it.
write_mock security \
  'echo "security $*" >> "$TOWER_TEST_LOG"' \
  'if [ "${TOWER_TEST_IDENTITY:-0}" = 1 ]; then' \
  '  echo "  1) F77E22A019796AD04615E525A9BD0A1598CD9382 \"Tower Dev\""' \
  '  echo "     1 valid identities found"' \
  'else' \
  '  echo "     0 valid identities found"' \
  'fi'
write_mock codesign 'echo "codesign $*" >> "$TOWER_TEST_LOG"'

printf 'fixture archive\n' > "$FIXTURES/Tower.app.zip"
(cd "$FIXTURES" && shasum -a 256 Tower.app.zip > Tower.app.zip.sha256)

run_install() {
  : > "$LOG"
  PATH="$MOCK_BIN:$PATH" \
  TMPDIR="$TEST_ROOT" \
  TOWER_TEST_LOG="$LOG" \
  TOWER_TEST_FIXTURES="$FIXTURES" \
  TOWER_TEST_INSTALLED="$INSTALLED" \
  TOWER_TEST_NO_RUN="$TOWER_TEST_NO_RUN" \
  TOWER_INSTALL_FROM="${TOWER_INSTALL_FROM:-}" \
  TOWER_TEST_IDENTITY="${TOWER_TEST_IDENTITY:-0}" \
  "$PROJECT_ROOT/scripts/install.sh" "$@"
}

# Mirrors run_install so future dry tests can forward flags; the current dry
# test runs it with no arguments.
# shellcheck disable=SC2120
run_install_dry() {
  : > "$LOG"
  PATH="$MOCK_BIN_DRY:$MOCK_BIN:$PATH" \
  TMPDIR="$TEST_ROOT" \
  TOWER_TEST_LOG="$LOG" \
  TOWER_TEST_FIXTURES="$FIXTURES" \
  TOWER_TEST_INSTALLED="$INSTALLED" \
  TOWER_TEST_NO_RUN="$TOWER_TEST_NO_RUN" \
  TOWER_INSTALL_FROM="${TOWER_INSTALL_FROM:-}" \
  "$PROJECT_ROOT/scripts/install.sh" "$@"
}

prepare_local_bundle() {
  mkdir -p "$PROJECT_ROOT/dist/Tower.app/Contents/MacOS"
  printf local > "$PROJECT_ROOT/dist/Tower.app/Contents/MacOS/HQClaudeLimits"
}

test_default_uses_local_bundle() {
  prepare_local_bundle
  run_install
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/HQClaudeLimits"
  assert_not_contains 'gh ' "$LOG"
  rm -rf "$PROJECT_ROOT/dist" "$INSTALLED"
}

test_artifact_uses_successful_main_run_and_verifies_before_install() {
  run_install --from-artifact
  assert_contains 'gh api repos/yonatangross/tower/actions/workflows/release-app.yml/runs?branch=main&event=push&status=success&per_page=1' "$LOG"
  assert_contains 'gh run download 123 --repo yonatangross/tower --name tower-app-deadbeef --dir' "$LOG"
  assert_contains 'ditto -x -k' "$LOG"
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/HQClaudeLimits"
  rm -rf "$INSTALLED"
}

test_artifact_rejects_missing_successful_main_run() {
  TOWER_TEST_NO_RUN=1
  if run_install --from-artifact; then
    fail 'expected missing workflow run to fail'
  fi
  TOWER_TEST_NO_RUN=0
  assert_not_contains 'ditto ' "$LOG"
  assert_not_contains 'pkill ' "$LOG"
}

test_release_downloads_requested_tag() {
  run_install --from-release v1.2.3
  assert_contains 'gh release download v1.2.3 --repo yonatangross/tower --pattern Tower.app.zip --pattern Tower.app.zip.sha256 --dir' "$LOG"
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/HQClaudeLimits"
  rm -rf "$INSTALLED"
}

test_dest_hook_survives_dropped_destination_mocks() {
  prepare_local_bundle
  run_install_dry
  # The dry-run log records the exact paths install.sh itself passed to rm,
  # cp and find, so install.sh must resolve the destination from
  # TOWER_TEST_INSTALLED. Nothing here touches the real home directory.
  assert_contains "rm -rf $INSTALLED/Tower.app" "$LOG"
  assert_not_contains "$HOME/Applications" "$LOG"
}

test_bad_checksum_stops_before_app_processes() {
  printf tampered >> "$FIXTURES/Tower.app.zip"
  if run_install --from-artifact; then
    fail 'expected checksum mismatch to fail'
  fi
  assert_not_contains 'ditto ' "$LOG"
  assert_not_contains 'pkill ' "$LOG"
}

test_env_install_from_artifact_matches_flag() {
  TOWER_INSTALL_FROM=artifact
  run_install
  TOWER_INSTALL_FROM=""
  assert_contains 'gh api repos/yonatangross/tower/actions/workflows/release-app.yml/runs?' "$LOG"
  assert_contains 'gh run download 123' "$LOG"
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/HQClaudeLimits"
  rm -rf "$INSTALLED"
}

test_env_install_from_rejects_unknown_source() {
  TOWER_INSTALL_FROM=bogus
  if run_install; then
    fail 'expected unknown TOWER_INSTALL_FROM to fail'
  fi
  TOWER_INSTALL_FROM=""
  assert_not_contains 'gh ' "$LOG"
  assert_not_contains 'ditto ' "$LOG"
}

test_artifact_is_resigned_with_tower_dev() {
  TOWER_TEST_IDENTITY=1
  run_install --from-artifact
  TOWER_TEST_IDENTITY=0
  assert_contains "codesign --force --timestamp=none --sign F77E22A019796AD04615E525A9BD0A1598CD9382 $INSTALLED/Tower.app" "$LOG"
  # Signed before it first runs, so the first launch already carries the stable requirement.
  sign_line="$(grep -n '^codesign ' "$LOG" | head -1 | cut -d: -f1)"
  open_line="$(grep -n '^open ' "$LOG" | head -1 | cut -d: -f1)"
  [ "$sign_line" -lt "$open_line" ] || fail "expected codesign before open (codesign $sign_line, open $open_line)"
  rm -rf "$INSTALLED"
}

test_artifact_keeps_its_signature_without_identity() {
  run_install --from-artifact
  assert_contains 'security find-identity -v -p codesigning' "$LOG"
  assert_not_contains 'codesign ' "$LOG"
  rm -rf "$INSTALLED"
}

test_local_bundle_is_not_resigned() {
  prepare_local_bundle
  TOWER_TEST_IDENTITY=1
  run_install
  TOWER_TEST_IDENTITY=0
  assert_not_contains 'codesign ' "$LOG"
  rm -rf "$PROJECT_ROOT/dist" "$INSTALLED"
}

test_default_uses_local_bundle
test_artifact_uses_successful_main_run_and_verifies_before_install
test_artifact_is_resigned_with_tower_dev
test_artifact_keeps_its_signature_without_identity
test_local_bundle_is_not_resigned
test_artifact_rejects_missing_successful_main_run
test_release_downloads_requested_tag
test_env_install_from_artifact_matches_flag
test_env_install_from_rejects_unknown_source
test_bad_checksum_stops_before_app_processes
test_dest_hook_survives_dropped_destination_mocks
echo 'PASS: install.sh artifact, release, checksum, env source, signing, and default behavior'
