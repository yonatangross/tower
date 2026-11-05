#!/usr/bin/env bash
# Runs on macos-15 in CI. Each mutation must compile, reach its named XCTest,
# and fail the specified assertion. Always restore production source afterwards.
set -euo pipefail

cd "$(dirname "$0")/.."
mutation_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tower-retention-mutations.XXXXXX")"
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

# Prove the unmodified tests pass before deliberately breaking their guards.
swift test --filter 'AccountRefreshTests|AccountRetentionTests|KeychainReadCacheTests'
bash scripts/test-retention-arbiter.sh

# Guard mutations are listed below beside the regression that detects them.
vault=Sources/Tower/AccountRefresh.swift
core=Sources/Tower/Core.swift

mutate inner-preference "$vault" \
  'guard retentionEnabled() else { return nil }' \
  'guard true else { return nil }' \
  testArbiterPreferenceFlipWithoutGenerationAdvance 'T1 preference-only flip blocks capture'

mutate capture "$vault" \
  'return writeSeat(
                service: service, account: email, label: Self.ownershipMarker, data: data)' \
  'return nil' \
  testObservedLoginsSurviveRestartAndRefreshAllSix 'retained items'

mutate default-on "$vault" \
  'guard defaults.object(forKey: preferenceKey) != nil else { return true }' \
  'guard defaults.object(forKey: preferenceKey) != nil else { return false }' \
  testRetentionDefaultsOnAndPersistsOffPreference 'retention defaults on'

mutate off-capture "$vault" \
  'guard state.generation == observation.generation else { return nil }' \
  'guard true else { return nil }' \
  testOffRejectsCaptureEvenForObservationStartedWhileOn 'off blocks capture'

mutate while-off-observation "$vault" \
  'guard retentionEnabled() else {
            return .success(ClaudeSeatObservation(generation: -1, ticket: -1))
        }' \
  'guard true else {
            return .success(ClaudeSeatObservation(generation: -1, ticket: -1))
        }' \
  testObservationStartedWhileOffCannotCaptureAfterEnable 'while-off observation stays fenced after enable'

# off-capture removes the capture-side generation check; forget-fence removes the
# Forget-side generation advance, so the two halves of the fence die separately.
mutate forget-fence "$vault" \
  'state.generation += 1' \
  'state.generation += 0' \
  testForgetFencesInflightObservationAcrossRestart 'Forget fences inflight capture'

mutate observation-order "$vault" \
  'guard (previous?.observationTicket ?? 0) < observation.ticket else { return nil }' \
  'guard true else { return nil }' \
  testOlderObservationCannotOverwriteNewerSeat 'latest observation wins'

mutate ownership "$vault" \
  'guard validOwnership(record), keep(ClaudeCredential(' \
  'guard true, keep(ClaudeCredential(' \
  testForgetDeletesCorruptOwnedItemsAndPreservesForeignItems 'foreign label preserved'

mutate payload-identity "$vault" \
  'record.account == payload.email,
              record.service == Self.service(for: payload.email),' \
  'true,
              true,' \
  testPayloadCarriesAccessTokenAndMatchingIdentity 'mismatched payload rejected'

mutate disable-preference "$vault" \
  'if let setRetentionAfterSuccess { setRetentionEnabled(setRetentionAfterSuccess) }' \
  'if let setRetentionAfterSuccess { setRetentionEnabled(!setRetentionAfterSuccess) }' \
  testDisableDeletesOwnedSeatsBeforePersistingOffAndCanEnableAgain 'disable persists off'

mutate disable-failure "$vault" \
  'guard firstError == nil else { return firstError }' \
  'guard true else { return firstError }' \
  testDisableFailureKeepsPreferenceOnAndReportsError 'failed disable keeps preference on'

mutate suppress-unchanged "$vault" \
  'guard state.suppressedTokenDigest != digest else { return nil }' \
  'guard true else { return nil }' \
  testForgetDuringProfileCannotResurrectToken 'unchanged login stays forgotten after restart'

mutate corrupt-state "$vault" \
  'return .failure(ClaudeSeatVaultError("could not read retention state: \(error.localizedDescription)"))' \
  'return .success(ClaudeSeatVaultState())' \
  testCorruptStateCannotResetForgetFence 'corrupt state fails closed'

mutate profile-before-usage "$core" \
  'try onVerified(credential, email)' \
  '// mutation skips capture before usage' \
  testVerifiedLoginIsRetainedBeforeUsageFailure 'capture precedes usage'

mutate unverified-profile "$core" \
  'guard let email = resolvedEmail, !email.isEmpty else {' \
  'guard let email = resolvedEmail ?? Optional("fixture@example.test"), !email.isEmpty else {' \
  testUnverifiedProfileDoesNotCaptureOrFetchUsage 'unverified identity not retained'

mutate fresh-expiry "$core" \
  'guard !credential.isExpired(now: clock()) else { throw ClaudeCredentialExpired() }
        if credential.service.hasPrefix(ClaudeSeatVault.ownedServicePrefix),' \
  'guard true else { throw ClaudeCredentialExpired() }
        if credential.service.hasPrefix(ClaudeSeatVault.ownedServicePrefix),' \
  testExpiryIsRecheckedAfterProfileAwait 'expired during profile skips usage'

mutate retained-identity "$core" \
  'credential.emailHint != email {' \
  'false {' \
  testRetainedCredentialCannotChangeVerifiedIdentity 'retained identity mismatch skips usage'

mutate retained-expiry "$vault" \
  'return expiresAt <= now' \
  'return false' \
  testExpiredRetainedSeatNeverCallsNetworkOrRanksAndZerosBothCaches 'expired retained seat makes no network requests'

# Swift closure arguments are intentional literal mutation targets.
# shellcheck disable=SC2016
mutate retirement "$vault" \
  'where: { emails.contains($0.emailHint ?? "") },' \
  'where: { _ in false },' \
  testRetirementDeletesOnlyTheRetiredSeat 'retired seat removed'

mutate write-error "$vault" \
  'return writeSeat(
                service: service, account: email, label: Self.ownershipMarker, data: data)' \
  '_ = writeSeat(
                service: service, account: email, label: Self.ownershipMarker, data: data)
            return nil' \
  testWriteAndRemovalFailuresAreVisible 'write failure visible'

# Swift dollar-zero arguments remain literal in these source replacements.
# shellcheck disable=SC2016
mutate read-failure "$vault" \
  'case .success(.failure(let error)): return .failure(error)' \
  'case .success(.failure): return .success(ClaudeSeatRoster(credentials: activeCredentials, unreadable: []))' \
  testReadFailurePreservesPreviouslyAvailableRoster 'read failure reaches refresh result'

mutate off-read-bypass "$vault" \
  'guard retentionEnabled() else {
            return .success(ClaudeSeatRoster(credentials: activeCredentials, unreadable: []))
        }' \
  'guard true else {
            return .success(ClaudeSeatRoster(credentials: activeCredentials, unreadable: []))
        }' \
  testOffDoesNotDependOnRetentionStateOrKeychain 'off bypasses retention failure'

# An owned item this build cannot read is the fallback case. Each mutant below removes one
# half of that design: the fallback itself, its log line, the panel text, the exact delete
# before the re-create, and the needs-login prefix that keeps the row out of ranking.
mutate unreadable-fallback "$vault" \
  'return .success((readout.records.compactMap(validCredential), unreadable))' \
  'return unreadable.isEmpty ? .success((readout.records.compactMap(validCredential), unreadable)) : .failure(ClaudeSeatVaultError("Keychain read failed (\(unreadable[0].status))"))' \
  testUnreadableOwnedItemFallsBackToCLICredentialAndNamesItself 'unreadable owned item does not fail the refresh'

mutate unreadable-log "$vault" \
  'for item in unreadable where launch.firstReport(item) { log(item.fallbackLogLine) }' \
  'for item in unreadable where launch.firstReport(item) { _ = item.fallbackLogLine }' \
  testUnreadableOwnedItemFallsBackToCLICredentialAndNamesItself 'fallback logs exactly one line naming the item and status'

mutate unreadable-panel "$vault" \
  'snapshot.lastError = item.panelMessage' \
  'snapshot.lastError = "needs login"' \
  testUnreadableOwnedItemFallsBackToCLICredentialAndNamesItself 'panel names the unreadable item'

mutate unreadable-needs-login "$core" \
  'var needsLogin: Bool { kind == .claude && lastError?.hasPrefix(Self.needsLoginText) == true }' \
  'var needsLogin: Bool { kind == .claude && lastError == Self.needsLoginText }' \
  testUnreadableOwnedItemFallsBackToCLICredentialAndNamesItself 'unreadable seat cannot rank'

mutate unreadable-recreate "$vault" \
  'if Self.recreateSteps(writesBesideLegacyItems: keychain.writesBesideLegacyItems)
                    .contains(.delete),
                   let error = removeSeat(
                    service: unreadable.service, account: unreadable.account, label: unreadable.label) {
                    log(unreadable.recreateFailedLogLine(error))
                    return error
                }' \
  '_ = unreadable.service' \
  testUnreadableOwnedItemIsRecreatedUnderTheCurrentSignerAfterFallback 're-create does not fail the refresh'

# #68: the refresh loop reads seat items once per launch and re-creates a refused active
# item once. Each mutant removes one half: the launch copy, which statuses it may keep, the
# vault's own writes reaching it, the once-per-token re-create, its failure log, the once-per-
# launch fallback log, and the counter the measurement reads.
# #80: the storm fix caches every readout and answers from it inside the backoff, so
# the once-per-launch guard is the readDue early-return itself. The first mutant kills
# that early return and every refresh re-reads; the second kills the 60 second backoff
# so a kept failure is re-asked at once; the third answers retries with .allowed, so
# the dialog the suppression exists to prevent comes back.
mutate launch-cache "$vault" \
  'if !fresh && !launch.readDue(now: now(), backoff: Self.readRetryBackoff) {' \
  'if !fresh && false {' \
  testRefreshLoopReadsSeatItemsOncePerLaunch 'one listing plus one read per owned item, once per launch'

mutate launch-cache-backoff "$vault" \
  '!launch.readDue(now: now(), backoff: Self.readRetryBackoff)' \
  '!launch.readDue(now: now(), backoff: 0)' \
  testStatusOtherThanASignerRefusalBacksOffThenRetriesSilently 'the decode status is kept; nothing is re-asked inside the backoff'

mutate suppressed-retry "$vault" \
  'let interaction = fresh ? .suppressed : launch.interactionForNextAttempt' \
  'let interaction = fresh ? ClaudeSeatReadInteraction.suppressed : ClaudeSeatReadInteraction.allowed' \
  testStatusOtherThanASignerRefusalBacksOffThenRetriesSilently 'the retry never shows a dialog'

mutate launch-cache-write "$vault" \
  'launch.applyWrite(ClaudeSeatKeychainRecord(service: service, account: account, label: label, data: data))' \
  '_ = data' \
  testRefusedActiveSeatIsRecreatedOnceFromTheCLICredential 're-created item holds the CLI credential'

mutate recreate-once "$vault" \
  'guard previous != nil || !launch.attemptedRecreate(service: service, tokenDigest: digest)' \
  'guard true' \
  testFailedRecreateIsNotRetriedInTheRefreshLoop 'failed re-create attempted once per launch'

mutate recreate-failure-log "$vault" \
  'label: unreadable.label) {
                    log(unreadable.recreateFailedLogLine(error))' \
  'label: unreadable.label) {
                    _ = unreadable.recreateFailedLogLine(error)' \
  testFailedRecreateIsNotRetriedInTheRefreshLoop 'failed re-create logs one line'

mutate fallback-log-once "$vault" \
  'for item in unreadable where launch.firstReport(item) {' \
  'for item in unreadable {' \
  testRefusedActiveSeatIsRecreatedOnceFromTheCLICredential 'refused inactive seat logs once per launch'

mutate recreate-signer-refusal-only "$vault" \
  'guard unreadable.isSignerRefusal else { return nil }' \
  'guard true else { return nil }' \
  testActiveSeatWithAnotherStatusIsNeitherDeletedNorOverwritten 'a status other than a signer refusal is never re-created'

mutate forget-fresh-read "$vault" \
  'setRetentionAfterSuccess: nil,
            freshRead: true)' \
  'setRetentionAfterSuccess: nil,
            freshRead: false)' \
  testForgetAllReadsTheKeychainFreshNotTheLaunchCopy 'Forget removes an item written after the launch read'

mutate disable-fresh-read "$vault" \
  'setRetentionAfterSuccess: false,
            freshRead: true)' \
  'setRetentionAfterSuccess: false,
            freshRead: false)' \
  testDisableReadsTheKeychainFreshNotTheLaunchCopy 'disable removes an item written after the launch read'

mutate keychain-counter "$vault" \
  'counter.recordCopyMatching("item", status: status)' \
  '_ = status' \
  testRefreshLoopReadsSeatItemsOncePerLaunch 'one listing plus one read per owned item, once per launch'

mutate off-retirement "$vault" \
  'guard retentionEnabled(), !emails.isEmpty else { return nil }' \
  'guard !emails.isEmpty else { return nil }' \
  testOffDoesNotDependOnRetentionStateOrKeychain 'off retirement bypasses retention failure'

mutate retirement-during-profile "$core" \
  'guard !store.retiredEmails.contains(email) else {' \
  'guard true else {' \
  testRetirementDuringProfileCannotRecreateAccount 'retired during profile not captured'

mutate verified-reactivation "$core" \
  'if retirementAtProfileStart.emails.contains(email) {' \
  'if false {' \
  testVerifiedActiveLoginReactivatesRetiredAccountAndMirrorsRealUsageAfterRestart 'retired account is removed from retirement list'

mutate reactivation-revision-fence "$core" \
  'guard snapshot.revision.isReliable,
                  retirementRevisionUnlocked() == snapshot.revision
            else {' \
  'guard true else {' \
  testRetirementRewrittenDuringProfileKeepsPreexistingRetirement 'retirement rewritten during profile stays retired'

mutate reactivation-usage-unknown "$vault" \
  'snapshot.lastError = failure.message' \
  'snapshot.fiveHourPct = 0
            snapshot.lastError = failure.message' \
  testReactivatedLoginLeavesUsageUnknownWhenUsageFails 'usage failure remains unknown'

mutate mock-ownership Tests/TowerTests/AccountRetentionTests.swift \
  'record.service.hasPrefix(ClaudeSeatVault.ownedServicePrefix)
                && record.label == ClaudeSeatVault.ownershipMarker
                && record.service == ClaudeSeatVault.service(for: record.account)' \
  'record.label == ClaudeSeatVault.ownershipMarker' \
  testForgetDeletesCorruptOwnedItemsAndPreservesForeignItems 'mock counts only owned namespace'

if [ "$mutation_count" -eq 0 ]; then
  echo "FAIL: no retention mutations ran" >&2
  exit 1
fi
echo "Retention mutation proof: $mutation_count mutations failed as expected; source restored"
