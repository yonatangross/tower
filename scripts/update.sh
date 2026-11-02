#!/usr/bin/env bash

# Updates the installed Tower.app to the newest successful "Release Tower app"
# artifact on main, then reports the old and new build sha.
#
# install.sh owns the download, checksum verification, install and relaunch
# mechanics, so those cannot drift between the two scripts. The run and
# artifact LOOKUP below intentionally mirrors download_from_artifact in
# install.sh (keep the two in sync): update.sh needs the resolved artifact
# name up front to skip a pointless reinstall and relaunch when already
# current, before install.sh would recompute the same answer.
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "Usage: scripts/update.sh" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Tower"
# Forks set TOWER_REPOSITORY=<owner>/<repo> to install from their own builds.
REPOSITORY="${TOWER_REPOSITORY:-yonatangross/tower}"
WORKFLOW="release-app.yml"
# Same destination hook as install.sh: tests point it at a sandbox, unset
# means the real user destination. Keep in sync with DEST_DIR there.
DEST_DIR="${TOWER_TEST_INSTALLED:-$HOME/Applications}"
DEST="$DEST_DIR/$APP_NAME.app"
INSTALL="$ROOT/scripts/install.sh"

fail() {
  echo "$*" >&2
  exit 1
}

# CFBundleVersion is the build stamp build-app.sh writes: the short git sha,
# plus "-dirty" for uncommitted changes. Builds that predate stamping still
# read "1", and a missing bundle reports "not-installed" so the sha report
# stays honest instead of empty.
installed_sha() {
  local plist="$1/Contents/Info.plist"
  if [ ! -f "$plist" ]; then
    printf 'not-installed'
    return
  fi
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || printf 'unknown'
}

[ -x "$INSTALL" ] || fail "install.sh missing or not executable at $INSTALL"
command -v gh >/dev/null 2>&1 || fail "gh CLI is required (see README, gh auth status)."

old_sha="$(installed_sha "$DEST")"

run_id="$(gh api "repos/$REPOSITORY/actions/workflows/$WORKFLOW/runs?branch=main&event=push&status=success&per_page=1" -q '.workflow_runs[0].id // empty')"
[ -n "$run_id" ] || fail "No successful main release-app workflow run was found."

# first() inside the jq expression, NOT a trailing `| head -n 1`: head closes
# the pipe early, gh can die on SIGPIPE, and under pipefail that aborts the
# script with status 141 and no message the moment a run carries a second
# matching artifact.
artifact_name="$(gh api "repos/$REPOSITORY/actions/runs/$run_id/artifacts?per_page=100" -q 'first(.artifacts[] | select(.expired == false) | select(.name | startswith("tower-app-")) | .name) // empty')"
[ -n "$artifact_name" ] || fail "No unexpired Tower artifact was found for workflow run $run_id."

# The artifact name carries the full commit sha while the installed stamp is
# the short form, so a prefix match means the installed build IS this artifact
# and we can exit without needlessly reinstalling the menubar app. The length
# guard keeps a pre-stamp "1" (or any other short value) from prefix-matching
# a real sha, and a "-dirty" stamp can never prefix-match one either.
artifact_sha="${artifact_name#tower-app-}"
if [ "${#old_sha}" -ge 7 ]; then
  case "$artifact_sha" in
    "$old_sha"*)
      if pgrep -f "HQClaudeLimits" >/dev/null 2>&1; then
        echo "Already at $old_sha ($artifact_name). Nothing to do."
      else
        echo "Already at $old_sha, but the app is not running; relaunching."
        open "$DEST"
      fi
      exit 0
      ;;
  esac
fi

echo "==> installing $artifact_name over build $old_sha"
TOWER_INSTALL_FROM=artifact "$INSTALL"

new_sha="$(installed_sha "$DEST")"
echo ""
echo "Build sha: $old_sha -> $new_sha"
