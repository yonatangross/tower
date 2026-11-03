#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016 is intentional everywhere in this file: mock bodies are written as
# single-quoted strings so their variables expand at mock runtime, not while
# write_mock generates the mock scripts.

# Focused offline tests for update.sh. Every app and GitHub side effect is
# redirected to temporary fixtures or a command mock, and the app destination
# is sandboxed by the same TOWER_TEST_INSTALLED hook install.sh honors.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tower-update-test.XXXXXX")"
PROJECT_ROOT="$TEST_ROOT/project"
MOCK_BIN="$TEST_ROOT/bin"
FIXTURES="$TEST_ROOT/fixtures"
INSTALLED="$TEST_ROOT/installed"
LOG="$TEST_ROOT/calls.log"
TOWER_TEST_NO_RUN=0
# The artifact the gh mock offers, and the short sha the unpacked bundle stamps.
ARTIFACT_SHA="f00dcafe"
NEW_SHA="f00dcaf"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$PROJECT_ROOT/scripts" "$MOCK_BIN" "$FIXTURES"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/update.sh" "$ROOT/scripts/sign-app.sh" "$PROJECT_ROOT/scripts/"
chmod +x "$PROJECT_ROOT/scripts/"*.sh

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_contains() {
  grep -F "$1" "$2" >/dev/null || fail "expected $2 to contain: $1"
}

assert_not_contains() {
  if [ -f "$2" ]; then
    ! grep -F "$1" "$2" >/dev/null || fail "expected $2 not to contain: $1"
  fi
}

assert_stdout_contains() {
  printf '%s' "$1" | grep -F "$2" >/dev/null || fail "expected output to contain: $2 (got: $1)"
}

write_mock() {
  local name="$1"
  shift
  printf '%s\n' '#!/usr/bin/env bash' "$@" > "$MOCK_BIN/$name"
  chmod +x "$MOCK_BIN/$name"
}

# rm, mkdir and cp pass through to the real binaries: every argument update.sh
# or the delegated install.sh can hand them resolves inside TEST_ROOT (the
# destination comes from TOWER_TEST_INSTALLED, the download dir under TMPDIR),
# so the suite exercises real filesystem behavior including replacing a
# pre-existing install.
write_mock pkill 'echo "pkill $*" >> "$TOWER_TEST_LOG"' 'exit 1'
write_mock open 'echo "open $*" >> "$TOWER_TEST_LOG"'
write_mock sleep 'echo "sleep $*" >> "$TOWER_TEST_LOG"'
write_mock pgrep \
  'echo "pgrep $*" >> "$TOWER_TEST_LOG"' \
  'if [ "${TOWER_TEST_NOT_RUNNING:-0}" = 1 ]; then exit 1; fi' \
  'exit 0'
write_mock find 'echo "find $*" >> "$TOWER_TEST_LOG"'
write_mock mkdir \
  'echo "mkdir $*" >> "$TOWER_TEST_LOG"' \
  '/bin/mkdir "$@"'
write_mock rm \
  'echo "rm $*" >> "$TOWER_TEST_LOG"' \
  '/bin/rm "$@"'
write_mock cp \
  'echo "cp $*" >> "$TOWER_TEST_LOG"' \
  '/bin/cp "$@"'
# Unpacks the fixture archive the way real ditto would: a runnable bundle whose
# Info.plist carries the build stamp the release build would have produced.
write_mock ditto \
  'echo "ditto $*" >> "$TOWER_TEST_LOG"' \
  'destination="${!#}"' \
  '/bin/mkdir -p "$destination/Tower.app/Contents/MacOS"' \
  'printf fixture > "$destination/Tower.app/Contents/MacOS/Tower"' \
  'printf "%s\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<plist version=\"1.0\"><dict>" "<key>CFBundleVersion</key><string>$TOWER_TEST_NEW_SHA</string>" "</dict></plist>" > "$destination/Tower.app/Contents/Info.plist"'
write_mock gh \
  'echo "gh $*" >> "$TOWER_TEST_LOG"' \
  'if [ "$1" = "api" ] && [ "${TOWER_TEST_NO_RUN:-0}" = 1 ] && printf "%s" "$2" | grep -F "/runs?" >/dev/null; then exit 0; fi' \
  'if [ "$1" = "api" ] && printf "%s" "$2" | grep -F "/runs?" >/dev/null; then echo "123"; exit 0; fi' \
  'if [ "$1" = "api" ] && [ "${TOWER_TEST_NO_ARTIFACT:-0}" = 1 ] && printf "%s" "$2" | grep -F "/artifacts?" >/dev/null; then exit 0; fi' \
  'if [ "$1" = "api" ] && printf "%s" "$2" | grep -F "/artifacts?" >/dev/null; then echo "tower-app-'"$ARTIFACT_SHA"'"; exit 0; fi' \
  'if [ "$1" = "run" ] && [ "$2" = "download" ]; then' \
  '  destination="${!#}"' \
  '  /bin/cp "$TOWER_TEST_FIXTURES/Tower.app.zip" "$destination/Tower.app.zip"' \
  '  /bin/cp "$TOWER_TEST_FIXTURES/Tower.app.zip.sha256" "$destination/Tower.app.zip.sha256"' \
  '  exit 0' \
  'fi' \
  'echo "unexpected gh invocation: $*" >&2' \
  'exit 64'

# install.sh re-signs a downloaded bundle (#121). The update tests run on a
# machine with no "Tower Dev" identity, so the bundle keeps its own signature.
write_mock security 'echo "security $*" >> "$TOWER_TEST_LOG"' 'echo "     0 valid identities found"'
write_mock codesign 'echo "codesign $*" >> "$TOWER_TEST_LOG"'

printf 'fixture archive\n' > "$FIXTURES/Tower.app.zip"
(cd "$FIXTURES" && shasum -a 256 Tower.app.zip > Tower.app.zip.sha256)

run_update() {
  : > "$LOG"
  PATH="$MOCK_BIN:$PATH" \
  TMPDIR="$TEST_ROOT" \
  TOWER_TEST_LOG="$LOG" \
  TOWER_TEST_FIXTURES="$FIXTURES" \
  TOWER_TEST_INSTALLED="$INSTALLED" \
  TOWER_TEST_NO_RUN="$TOWER_TEST_NO_RUN" \
  TOWER_TEST_NO_ARTIFACT="${TOWER_TEST_NO_ARTIFACT:-0}" \
  TOWER_TEST_NOT_RUNNING="${TOWER_TEST_NOT_RUNNING:-0}" \
  TOWER_TEST_NEW_SHA="$NEW_SHA" \
  "$PROJECT_ROOT/scripts/update.sh" "$@"
}

install_fake_app() {
  local sha="$1"
  mkdir -p "$INSTALLED/Tower.app/Contents/MacOS"
  printf binary > "$INSTALLED/Tower.app/Contents/MacOS/Tower"
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' \
    "  <key>CFBundleIdentifier</key><string>ai.yonyon.tower</string><key>CFBundleVersion</key><string>$sha</string>" \
    '</dict></plist>' \
    > "$INSTALLED/Tower.app/Contents/Info.plist"
}

test_installs_newer_artifact_and_reports_shas() {
  install_fake_app aaaaaaa
  out="$(run_update)"
  assert_contains 'gh api repos/yonatangross/tower/actions/workflows/release-app.yml/runs?' "$LOG"
  assert_contains ' -q .workflow_runs' "$LOG"
  assert_contains 'gh run download 123' "$LOG"
  assert_contains 'ditto -x -k' "$LOG"
  assert_contains 'pkill ' "$LOG"
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/Tower"
  assert_contains "<string>$NEW_SHA</string>" "$INSTALLED/Tower.app/Contents/Info.plist"
  assert_stdout_contains "$out" "Build sha: aaaaaaa -> $NEW_SHA"
  rm -rf "$INSTALLED"
}

test_skips_when_already_current() {
  install_fake_app "$NEW_SHA"
  out="$(run_update)"
  assert_contains 'gh api ' "$LOG"
  assert_not_contains 'ditto ' "$LOG"
  assert_not_contains 'pkill ' "$LOG"
  assert_stdout_contains "$out" "Already at $NEW_SHA"
  assert_contains "<string>$NEW_SHA</string>" "$INSTALLED/Tower.app/Contents/Info.plist"
  rm -rf "$INSTALLED"
}

test_current_but_not_running_relaunches() {
  install_fake_app "$NEW_SHA"
  TOWER_TEST_NOT_RUNNING=1
  out="$(run_update)"
  TOWER_TEST_NOT_RUNNING=0
  assert_contains "open $INSTALLED/Tower.app" "$LOG"
  assert_not_contains 'ditto ' "$LOG"
  assert_not_contains 'pkill ' "$LOG"
  assert_stdout_contains "$out" 'relaunching'
  rm -rf "$INSTALLED"
}

test_prestamp_build_does_not_skip() {
  install_fake_app 1
  out="$(run_update)"
  assert_contains 'ditto -x -k' "$LOG"
  assert_stdout_contains "$out" "Build sha: 1 -> $NEW_SHA"
  rm -rf "$INSTALLED"
}

test_installs_when_nothing_installed() {
  out="$(run_update)"
  assert_file "$INSTALLED/Tower.app/Contents/MacOS/Tower"
  assert_stdout_contains "$out" "Build sha: not-installed -> $NEW_SHA"
  rm -rf "$INSTALLED"
}

test_rejects_arguments() {
  if out="$(run_update extra 2>&1)"; then
    fail 'expected stray argv to be rejected'
  fi
  assert_stdout_contains "$out" 'Usage: scripts/update.sh'
  assert_not_contains 'gh ' "$LOG"
}

test_fails_when_no_unexpired_artifact() {
  install_fake_app aaaaaaa
  TOWER_TEST_NO_ARTIFACT=1
  if out="$(run_update 2>&1)"; then
    fail 'expected missing artifact to fail'
  fi
  TOWER_TEST_NO_ARTIFACT=0
  assert_stdout_contains "$out" 'No unexpired Tower artifact was found'
  assert_not_contains 'ditto ' "$LOG"
  assert_not_contains 'pkill ' "$LOG"
  rm -rf "$INSTALLED"
}

test_fails_when_no_successful_run() {
  install_fake_app aaaaaaa
  TOWER_TEST_NO_RUN=1
  if out="$(run_update 2>&1)"; then
    fail 'expected missing workflow run to fail'
  fi
  TOWER_TEST_NO_RUN=0
  assert_stdout_contains "$out" 'No successful main release-app workflow run was found.'
  assert_not_contains 'ditto ' "$LOG"
  assert_not_contains 'pkill ' "$LOG"
  assert_contains '<string>aaaaaaa</string>' "$INSTALLED/Tower.app/Contents/Info.plist"
  rm -rf "$INSTALLED"
}

test_installs_newer_artifact_and_reports_shas
test_skips_when_already_current
test_current_but_not_running_relaunches
test_prestamp_build_does_not_skip
test_installs_when_nothing_installed
test_rejects_arguments
test_fails_when_no_unexpired_artifact
test_fails_when_no_successful_run
echo 'PASS: update.sh lookup, skip, relaunch, delegate, and sha reporting'
