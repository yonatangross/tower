#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
arbiter_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tower-retention-arbiter.XXXXXX")"
source_file=Sources/Tower/AccountRefresh.swift
cp "$source_file" "$arbiter_tmp/original"
cleanup() {
  cp "$arbiter_tmp/original" "$source_file"
  rm -rf "$arbiter_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

probe() {
  local build="$1" row="$2" method="$3" expected="$4" assertion="$5"
  local status=0 outcome
  swift test --filter "$method" > "$arbiter_tmp/test.log" 2>&1 || status=$?
  cat "$arbiter_tmp/test.log"
  if ! grep -F " $method]' started." "$arbiter_tmp/test.log" >/dev/null; then
    echo "ARBITER ERROR: $build $row did not execute" >&2
    exit 1
  fi
  if [ "$status" -eq 0 ]; then
    outcome=PASS
  elif grep -F " $method]' failed" "$arbiter_tmp/test.log" >/dev/null &&
       grep -F "$assertion" "$arbiter_tmp/test.log" >/dev/null; then
    outcome=FAIL
  else
    echo "ARBITER ERROR: $build $row failed outside the expected assertion" >&2
    exit 1
  fi
  echo "ARBITER $row $build $outcome"
  [ "$outcome" = "$expected" ]
}

for build in B0 B1 B2 B3; do
  cp "$arbiter_tmp/original" "$source_file"
  if [ "$build" = B1 ]; then
    perl -0777 -i -pe 's/guard retentionEnabled\(\) else \{ return nil \}/guard true else { return nil }/g == 1 or die "inner guard target not unique\n"' "$source_file"
  elif [ "$build" = B2 ]; then
    perl -0777 -i -pe 's/guard state\.generation == observation\.generation else \{ return nil \}/guard true else { return nil }/g == 1 or die "fence target not unique\n"' "$source_file"
  elif [ "$build" = B3 ]; then
    perl -0777 -i -pe 's/guard retentionEnabled\(\) else \{\n            return \.success\(ClaudeSeatObservation\(generation: -1, ticket: -1\)\)/guard true else {\n            return .success(ClaudeSeatObservation(generation: -1, ticket: -1))/g == 1 or die "sentinel target not unique\n"' "$source_file"
  fi
  expected=PASS
  if [ "$build" = B1 ]; then expected=FAIL; fi
  probe "$build" T1 testArbiterPreferenceFlipWithoutGenerationAdvance "$expected" 'T1 preference-only flip blocks capture'
  expected=PASS
  if [ "$build" = B2 ]; then expected=FAIL; fi
  probe "$build" T2 testOffRejectsCaptureEvenForObservationStartedWhileOn "$expected" 'off blocks capture'
  expected=PASS
  if [ "$build" = B3 ]; then expected=FAIL; fi
  probe "$build" T3 testObservationStartedWhileOffCannotCaptureAfterEnable "$expected" 'while-off observation stays fenced after enable'
done
echo 'Arbiter grid complete; source restored on exit'
