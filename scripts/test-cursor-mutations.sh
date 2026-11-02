#!/usr/bin/env bash
# Runs on macos-15 in CI. Each Cursor regression is deliberately broken once,
# then must reach and fail its named XCTest before the source is restored.
set -euo pipefail

cd "$(dirname "$0")/.."
mutation_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tower-cursor-mutations.XXXXXX")"
mutation_source=""
mutation_count=0

restore_source() {
  if [ -n "$mutation_source" ]; then
    cp "$mutation_tmp/original" "$mutation_source"
    mutation_source=""
  fi
}

cleanup() {
  restore_source
  rm -rf "$mutation_tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mutate() {
  local name="$1" source="$2" before="$3" after="$4" test="$5" assertion="$6"
  cp "$source" "$mutation_tmp/original"
  mutation_source="$source"
  MUTATION_BEFORE="$before" MUTATION_AFTER="$after" perl -0777 -i -pe '
    BEGIN { $before = $ENV{MUTATION_BEFORE}; $after = $ENV{MUTATION_AFTER}; }
    $count = s/\Q$before\E/$after/g;
    die "Expected one mutation target, found $count\n" unless $count == 1;
  ' "$source"

  local status=0
  swift test --filter "$test" > "$mutation_tmp/test.log" 2>&1 || status=$?
  restore_source
  if [ "$status" -eq 0 ] ||
      ! grep -F " $test]' started." "$mutation_tmp/test.log" >/dev/null ||
      ! grep -F " $test]' failed" "$mutation_tmp/test.log" >/dev/null ||
      ! grep -F "$assertion" "$mutation_tmp/test.log" >/dev/null; then
    cat "$mutation_tmp/test.log"
    echo "FAIL: mutation $name did not reach the expected failing assertion" >&2
    exit 1
  fi
  mutation_count=$((mutation_count + 1))
  echo "MUTATION RED: $name; $test; source restored"
  grep -F "$assertion" "$mutation_tmp/test.log"
}

swift test --filter 'CursorUsageSummaryTests|CursorPoolDisplayTests|QuotaMirrorPctTests'

providers=Sources/Tower/Providers.swift
ui=Sources/Tower/AppUI.swift
core=Sources/Tower/Core.swift

mutate tighter-pool "$providers" \
  'return max(cursorModelsPct, otherModelsPct)' \
  'return min(cursorModelsPct, otherModelsPct)' \
  testDashboardPoolReadingUsesTighterPoolAndClearsDollarBalance \
  'ranker takes the tighter dashboard pool'

mutate invalid-pool "$providers" \
  'guard let value, value.isFinite, (0...100).contains(value) else { return nil }' \
  'guard let value else { return nil }' \
  testMissingOrInvalidDashboardPoolStaysUnknown \
  'unreadable pool never becomes a synthetic percentage'

mutate no-dollar-balance "$providers" \
  '// preserve the old synthetic dollars when a fresh dashboard reading arrives.
        snap.creditBalance = nil' \
  '// preserve the old synthetic dollars when a fresh dashboard reading arrives.
        snap.creditBalance = "$0.00 used"' \
  testDashboardPoolReadingUsesTighterPoolAndClearsDollarBalance \
  'removes derived dollar balance'

mutate legacy-cost-migration "$core" \
  'if snapshot.kind == .cursor, snapshot.creditBalance != nil {' \
  'if false {' \
  testLegacyCursorCostCannotSurviveLoadAndMirrorAsQuota \
  'legacy cost ratio is not a dashboard quota'

mutate cursor-named-pools "$ui" \
  'if account.kind == .cursor {
            return ["Cursor Models", "Other Models"].map { label in' \
  'if false {
            return ["Cursor Models", "Other Models"].map { label in' \
  testCursorShowsBothNamedPoolsIncludingZeroAndUnknown \
  'Cursor displays two named dashboard pools'

mutate cursor-own-meters "$ui" \
  'pct: scope?.percent, resetsAt: scope?.resetsAt, now: now)' \
  'pct: account.weeklyPct, resetsAt: scope?.resetsAt, now: now)' \
  testCursorDashboardPercentagesUseTheirOwnMeters \
  'dashboard pools keep distinct percentages'

if [ "$mutation_count" -eq 0 ]; then
  echo 'FAIL: no Cursor mutations ran' >&2
  exit 1
fi
echo "Cursor mutation proof: $mutation_count mutations failed as expected; source restored"
