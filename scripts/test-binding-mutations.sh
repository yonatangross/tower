#!/usr/bin/env bash
# Runs on macos-15 in CI. Every GH-52 regression is deliberately broken once,
# then must reach and fail its named XCTest before the source is restored.
set -euo pipefail

cd "$(dirname "$0")/.."
mutation_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tower-binding-mutations.XXXXXX")"
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

swift test --filter BindingLimitTests

core=Sources/Tower/Core.swift
ui=Sources/Tower/AppUI.swift

mutate fable-precedence "$core" \
  '(value.pct ?? 0) >= 100' \
  '(value.pct ?? 0) >= 101' \
  testFableAtOneHundredWinsAndNamesAlternateModels 'Fable cap takes precedence'

mutate seven-day-precedence "$core" \
  'return BindingQuota(limit: .sevenDay, percent: pct,
                                resetsAt: weeklyResetsAt, didReset: weekly.reset)' \
  'return BindingQuota(limit: .fiveHour, percent: pct,
                                resetsAt: weeklyResetsAt, didReset: weekly.reset)' \
  testNamedCappedSeatsChooseTheirActualBindingAggregate 'must name the capped window'

mutate five-hour-precedence "$core" \
  'return BindingQuota(limit: .fiveHour, percent: pct,
                                resetsAt: fiveHourResetsAt, didReset: fiveHour.reset)' \
  'return BindingQuota(limit: .sevenDay, percent: pct,
                                resetsAt: fiveHourResetsAt, didReset: fiveHour.reset)' \
  testNamedCappedSeatsChooseTheirActualBindingAggregate 'must name the capped window'

mutate fable-reset "$core" \
  'resetsAt: fable.resetsAt, didReset: value.reset)' \
  'resetsAt: weeklyResetsAt, didReset: value.reset)' \
  testFableAtOneHundredWinsAndNamesAlternateModels 'Fable label must keep the Fable reset'

mutate alternate-model-room "$core" \
  'return fiveCapped || weeklyCapped ? "none" : "Opus / Sonnet"' \
  'return "none"' \
  testFableAtOneHundredWinsAndNamesAlternateModels 'Fable-only cap leaves alternate models usable'

mutate non-capped-fallback "$core" \
  'where weeklyPct >= fiveHourPct:' \
  'where weeklyPct < fiveHourPct:' \
  testNonCappedFallbackIgnoresFableAndHandlesMissingAndExpiredWindows 'Non-capped fallback uses the tighter aggregate'

mutate cursor-billing-label "$core" \
  'case .sevenDay: return kind.primaryWindowLabel' \
  'case .sevenDay: return "7d"' \
  testCursorBindingUsesBillingMonthInActiveAndDrawerLabels 'Cursor binding label uses billing month'

mutate stale-marker "$core" \
  'guard isRecommendable(now: now) else { return nil }' \
  'guard true else { return nil }' \
  testDisclosedSeatRendersAllThreeWindowsWithOnlyFableMarked 'Stale readings have no current binding quota'

mutate missing-fable "$ui" \
  'didReset: false, trust: .unknown, isBinding: false))' \
  'didReset: false, trust: .live, isBinding: false))' \
  testDisclosedSeatRendersAllThreeWindowsWithOnlyFableMarked 'Missing Fable reading stays unknown'

mutate binding-reset-ownership "$ui" \
  'guard let reset = binding.resetsAt else { return "reset unknown" }' \
  'guard let reset = account.weeklyResetsAt ?? binding.resetsAt else { return "reset unknown" }' \
  testBindingWithoutResetDoesNotBorrowAggregateReset 'Binding without reset must not borrow an aggregate reset'

if [ "$mutation_count" -eq 0 ]; then
  echo 'FAIL: no binding mutations ran' >&2
  exit 1
fi
echo "Binding mutation proof: $mutation_count mutations failed as expected; source restored"
