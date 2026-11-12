#!/usr/bin/env bash
# Offline tests for install-private-lanes.sh: the step that puts the floor's private-lanes
# list where the lane-cost recorder reads it, and the readback that fails loudly when it is
# missing, unreadable, or does not name the lane it must protect. Every path is a temp dir.
# Each command under test runs with "|| code=$?" so set -e never hides a non-zero exit.
set -euo pipefail

# Run from the repo root: bash scripts/test-private-lanes.sh
if [ ! -x ./scripts/install-private-lanes.sh ]; then
  echo "run this from the repo root (scripts/install-private-lanes.sh not found here)" >&2
  exit 2
fi
T="$(mktemp -d "${TMPDIR:-/tmp}/tower-private-lanes-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

expect_exit() { # name want-code got-code
  if [ "$3" -eq "$2" ]; then pass "$1"; else fail "$1 (wanted exit $2, got $3)"; fi
}
expect_in() { # name needle haystack
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (missing '$2' in: $3)" ;; esac
}

GOOD="$T/source-good.json"
cat >"$GOOD" <<'EOF'
{"_comment":"x","private_lanes":["~/.floor/desks/personal-desk"],"store_hosts":["a.example"]}
EOF
H1="$T/home1"
mkdir -p "$H1"

# 1. check on a Mac with no file: distinct loud non-pass (3), naming the path and the fix
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H1" 2>&1) || code=$?
expect_exit "check: missing file exits 3" 3 "$code"
expect_in "check: missing file names the path" "$H1/.floor/private-lanes.json" "$out"
expect_in "check: missing file names the fix" "--from" "$out"

# 2. install from a valid source, then a SEPARATE read from disk
code=0
out=$(./scripts/install-private-lanes.sh --from "$GOOD" --home "$H1" 2>&1) || code=$?
expect_exit "install: valid source exits 0" 0 "$code"
if cmp -s "$GOOD" "$H1/.floor/private-lanes.json"; then pass "install: the installed bytes equal the source"; else fail "install: the installed bytes differ from the source"; fi
# the list names a private lane: owner-only file, and an owner-only folder when the install made it
file_mode=$(stat -f '%Lp' "$H1/.floor/private-lanes.json")
dir_mode=$(stat -f '%Lp' "$H1/.floor")
if [ "$file_mode" = "600" ]; then pass "install: the file is owner-only (600)"; else fail "install: file mode is $file_mode, wanted 600"; fi
if [ "$dir_mode" = "700" ]; then pass "install: a folder the install created is owner-only (700)"; else fail "install: folder mode is $dir_mode, wanted 700"; fi
# an existing folder is not re-moded: the install owns its file, not the shared folder
H4="$T/home4"
mkdir -p "$H4/.floor"
chmod 755 "$H4/.floor"
code=0
out=$(./scripts/install-private-lanes.sh --from "$GOOD" --home "$H4" 2>&1) || code=$?
expect_exit "install: into an existing folder exits 0" 0 "$code"
existing_mode=$(stat -f '%Lp' "$H4/.floor")
if [ "$existing_mode" = "755" ]; then pass "install: an existing folder keeps its mode"; else fail "install: existing folder mode changed to $existing_mode"; fi
file_mode=$(stat -f '%Lp' "$H4/.floor/private-lanes.json")
if [ "$file_mode" = "600" ]; then pass "install: the file is 600 in an existing folder too"; else fail "install: file mode is $file_mode in an existing folder, wanted 600"; fi
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H1" --expect "~/.floor/desks/personal-desk" 2>&1) || code=$?
expect_exit "check: installed file names the private lane" 0 "$code"
expect_in "check: prints the folders it read back" "personal-desk" "$out"

# 3. the readback refuses a list that does not name the lane it must protect (a check proves reach)
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H1" --expect "~/.floor/desks/other-lane" 2>&1) || code=$?
expect_exit "check: expected lane absent exits 5" 5 "$code"
expect_in "check: says which lane is absent" "other-lane" "$out"

# 4. unreadable and wrong-shaped files are 4, not 0 and not 3
H2="$T/home2"
mkdir -p "$H2/.floor"
echo "{ not json" >"$H2/.floor/private-lanes.json"
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H2" 2>&1) || code=$?
expect_exit "check: malformed JSON exits 4" 4 "$code"
echo '{"private_lanes":"~/x"}' >"$H2/.floor/private-lanes.json"
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H2" 2>&1) || code=$?
expect_exit "check: a list that is not a list exits 4" 4 "$code"
echo '{"private_lanes":[1,2]}' >"$H2/.floor/private-lanes.json"
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H2" 2>&1) || code=$?
expect_exit "check: a list of non-strings exits 4" 4 "$code"
: >"$H2/.floor/private-lanes.json"
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H2" 2>&1) || code=$?
expect_exit "check: an empty file exits 4" 4 "$code"

# 5. a bad source installs nothing and fails, and a good install replaces a bad existing file
H3="$T/home3"
mkdir -p "$H3"
code=0
out=$(./scripts/install-private-lanes.sh --from "$T/no-such-file.json" --home "$H3" 2>&1) || code=$?
expect_exit "install: missing source exits 2" 2 "$code"
echo "{ not json" >"$T/source-bad.json"
code=0
out=$(./scripts/install-private-lanes.sh --from "$T/source-bad.json" --home "$H3" 2>&1) || code=$?
expect_exit "install: malformed source exits 4" 4 "$code"
if [ ! -e "$H3/.floor/private-lanes.json" ]; then pass "install: a bad source leaves no file behind"; else fail "install: a bad source left a file behind"; fi
code=0
out=$(./scripts/install-private-lanes.sh --from "$GOOD" --home "$H2" 2>&1) || code=$?
expect_exit "install: replaces an unreadable file" 0 "$code"
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H2" 2>&1) || code=$?
expect_exit "check: after the replace the file reads back" 0 "$code"

# 6. no partial file: the install writes beside the target and moves it into place
leftovers="$(ls -A "$H1/.floor" 2>/dev/null || true)"
case "$leftovers" in *tmp*) fail "install: left a temp file behind" ;; *) pass "install: no temp file left behind" ;; esac

# 6b. a copy of a privacy list goes stale: --against compares the installed list with the source
#     and exits 6 on drift, 0 when they name the same folders (key order and extra keys do not matter)
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H1" --against "$GOOD" 2>&1) || code=$?
expect_exit "drift: the installed copy matches its source" 0 "$code"
cat >"$T/source-drifted.json" <<'EOF'
{"private_lanes":["~/.floor/desks/personal-desk","~/.floor/desks/new-private-lane"]}
EOF
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H1" --against "$T/source-drifted.json" 2>&1) || code=$?
expect_exit "drift: a source with another lane exits 6" 6 "$code"
expect_in "drift: names the lane the copy is missing" "new-private-lane" "$out"
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H1" --against "$T/no-such-source.json" 2>&1) || code=$?
expect_exit "drift: an unreadable source exits 4, not a pass" 4 "$code"
cat >"$T/source-reordered.json" <<'EOF'
{"store_hosts":[],"private_lanes":["~/.floor/desks/personal-desk"]}
EOF
code=0
out=$(./scripts/install-private-lanes.sh --check --home "$H1" --against "$T/source-reordered.json" 2>&1) || code=$?
expect_exit "drift: key order and other keys do not count as drift" 0 "$code"

# 7. unknown flag and no mode are errors, never a silent success
code=0
out=$(./scripts/install-private-lanes.sh --bogus 2>&1) || code=$?
expect_exit "unknown flag exits 2" 2 "$code"
code=0
out=$(./scripts/install-private-lanes.sh --home "$H1" 2>&1) || code=$?
expect_exit "no mode exits 2" 2 "$code"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"
exit 1
