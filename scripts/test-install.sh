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
write_mock rm 'echo "rm $*" >> "$TOWER_TEST_LOG"' 'if [ "${TOWER_TEST_REAL_RM:-0}" = 1 ]; then /bin/rm "$@"; fi'
write_mock find 'echo "find $*" >> "$TOWER_TEST_LOG"'
write_mock cp \
  'echo "cp $*" >> "$TOWER_TEST_LOG"' \
  '/bin/cp "$@"'
write_mock ditto \
  'echo "ditto $*" >> "$TOWER_TEST_LOG"' \
  'destination="${!#}"' \
  '/bin/mkdir -p "$destination/Tower.app/Contents/MacOS"' \
  'printf fixture > "$destination/Tower.app/Contents/MacOS/Tower"'
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
  printf local > "$PROJECT_ROOT/dist/Tower.app/Contents/MacOS/Tower"
}

test_default_uses_local_bundle() {
  prepare_local_bundle
  run_install
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/Tower"
  assert_not_contains 'gh ' "$LOG"
  rm -rf "$PROJECT_ROOT/dist" "$INSTALLED"
}

test_artifact_uses_successful_main_run_and_verifies_before_install() {
  run_install --from-artifact
  assert_contains 'gh api repos/yonatangross/tower/actions/workflows/release-app.yml/runs?branch=main&event=push&status=success&per_page=1' "$LOG"
  assert_contains 'gh run download 123 --repo yonatangross/tower --name tower-app-deadbeef --dir' "$LOG"
  assert_contains 'ditto -x -k' "$LOG"
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/Tower"
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
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/Tower"
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
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/Tower"
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

# v0.1 rename: a pre-v0.1 install runs HQClaudeLimits under the old bundle id.
legacy_install() {
  mkdir -p "$INSTALLED/Tower.app/Contents/MacOS"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "legacy $*" >> "$TOWER_TEST_LOG"' \
    'if [ "$#" = 1 ]; then echo "start at login: ${TOWER_TEST_LEGACY_LOGIN:-disabled}"; fi' \
    > "$INSTALLED/Tower.app/Contents/MacOS/HQClaudeLimits"
  chmod +x "$INSTALLED/Tower.app/Contents/MacOS/HQClaudeLimits"
  plutil -create xml1 "$INSTALLED/Tower.app/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string ai.yonatan-hq.claude-limits "$INSTALLED/Tower.app/Contents/Info.plist"
}

# The new build in these tests is a script, so `login-item on` is recorded, not run.
prepare_scripted_bundle() {
  mkdir -p "$PROJECT_ROOT/dist/Tower.app/Contents/MacOS"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "tower $*" >> "$TOWER_TEST_LOG"' \
    > "$PROJECT_ROOT/dist/Tower.app/Contents/MacOS/Tower"
  chmod +x "$PROJECT_ROOT/dist/Tower.app/Contents/MacOS/Tower"
}

test_legacy_login_item_moves_to_the_new_id() {
  legacy_install
  prepare_scripted_bundle
  TOWER_TEST_REAL_RM=1 TOWER_TEST_LEGACY_LOGIN=ENABLED run_install
  assert_contains 'legacy login-item off' "$LOG"
  assert_contains 'tower login-item on' "$LOG"
  off_line="$(grep -n '^legacy login-item off' "$LOG" | cut -d: -f1)"
  on_line="$(grep -n '^tower login-item on' "$LOG" | cut -d: -f1)"
  [ "$off_line" -lt "$on_line" ] || fail "expected the old item off before the new one on"
  rm -rf "$PROJECT_ROOT/dist" "$INSTALLED"
}

test_legacy_login_item_left_off_stays_off() {
  legacy_install
  prepare_scripted_bundle
  TOWER_TEST_REAL_RM=1 run_install
  assert_contains 'legacy login-item' "$LOG"
  assert_not_contains 'legacy login-item off' "$LOG"
  assert_not_contains 'tower login-item on' "$LOG"
  rm -rf "$PROJECT_ROOT/dist" "$INSTALLED"
}

test_foreign_tower_app_is_never_replaced() {
  mkdir -p "$INSTALLED/Tower.app/Contents/MacOS"
  plutil -create xml1 "$INSTALLED/Tower.app/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string com.example.git-client "$INSTALLED/Tower.app/Contents/Info.plist"
  prepare_local_bundle
  if run_install; then
    fail 'expected a foreign Tower.app to stop the install'
  fi
  assert_not_contains 'pkill ' "$LOG"
  assert_not_contains 'rm ' "$LOG"
  rm -rf "$PROJECT_ROOT/dist" "$INSTALLED"
}

test_process_match_is_anchored_to_the_install_path() {
  prepare_local_bundle
  run_install
  assert_contains "pkill -f $INSTALLED/Tower.app/Contents/MacOS/(Tower|HQClaudeLimits)( |\$)" "$LOG"
  assert_contains "pgrep -f $INSTALLED/Tower.app/Contents/MacOS/Tower( |\$)" "$LOG"
  assert_not_contains 'pkill -f Tower' "$LOG"
  rm -rf "$PROJECT_ROOT/dist" "$INSTALLED"
}

test_legacy_cli_link_is_repointed() {
  local link="$TEST_ROOT/link/tower" other="$TEST_ROOT/link/other"
  mkdir -p "$TEST_ROOT/link"
  ln -s "$INSTALLED/Tower.app/Contents/MacOS/HQClaudeLimits" "$link"
  ln -s /usr/bin/true "$other"
  prepare_local_bundle
  TOWER_TEST_LINK="$link" run_install
  [ "$(readlink "$link")" = "$INSTALLED/Tower.app/Contents/MacOS/Tower" ] || fail "link not repointed: $(readlink "$link")"
  TOWER_TEST_LINK="$other" run_install
  [ "$(readlink "$other")" = /usr/bin/true ] || fail "an unrelated link was changed"
  rm -rf "$PROJECT_ROOT/dist" "$INSTALLED" "$TEST_ROOT/link"
}

test_default_uses_local_bundle
test_legacy_login_item_moves_to_the_new_id
test_legacy_login_item_left_off_stays_off
test_foreign_tower_app_is_never_replaced
test_process_match_is_anchored_to_the_install_path
test_legacy_cli_link_is_repointed
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
