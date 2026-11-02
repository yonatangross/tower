#!/usr/bin/env bash
# Runs on macos-15 in CI. Each keychain guard is broken once, its named test
# must fail, and the trap restores the production source on every exit path.
set -euo pipefail

cd "$(dirname "$0")/.."
mutation_tmp="$(mktemp -d "${TMPDIR:-/tmp}/tower-keychain-mutations.XXXXXX")"
mutation_source=""
mutation_count=0
test_filter="$(printf '%s%sfilter' - -)"

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
  swift test "$test_filter" "$test" > "$mutation_tmp/test.log" 2>&1 || status=$?
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

swift test "$test_filter" 'KeychainReadableMigrationTests|KeychainAccessTests'

vault=Sources/Tower/AccountRefresh.swift

mutate foreign-service "$vault" \
  'service == ClaudeSeatVault.service(for: account)' \
  'true' \
  testMatchingLabelWithForeignServiceIsNotReadOrChanged \
  'foreign marker item is never read'

mutate read-authorization "$vault" \
  'kSecACLAuthorizationDecrypt as String,' \
  'kSecACLAuthorizationEncrypt as String,' \
  testUnrelatedACLsDoNotSatisfyRequiredReadTrust \
  'unrelated ACL applications do not satisfy read trust'

mutate readable-migration "$vault" \
  'case .success(let snapshot) where snapshot.requiresRepair:' \
  'case .success(let snapshot) where false:' \
  testReadableLegacyItemReplacesAccessInPlace \
  'owned readable legacy access is replaced in place'

mutate in-place-failure "$vault" \
  'case .success(let access): return calls.setAccess(reference, access)' \
  'case .success: return errSecSuccess' \
  testFailedInPlaceMigrationRetainsPayload \
  'failed in place migration reports set access status'

mutate suppressed-migration "$vault" \
  'if itemInteraction == .allowed {' \
  'if true {' \
  testSuppressedReadDefersACLMutation \
  'suppressed read never changes ACL'

mutate denied-access-suppression "$vault" \
  'if unreadable.isInteractionDenial { itemInteraction = .suppressed }
                                continue' \
  'if false { itemInteraction = .suppressed }
                                continue' \
  testDeniedACLMutationSuppressesRemainingItemReads \
  'denied ACL mutation suppresses remaining item reads'

mutate security-tool-trust "$vault" \
  'switch trustedApplication(path: path) {' \
  'switch trustedApplication(path: securityToolPath) {' \
  testTrustedApplicationsTrustOnlyTheCurrentApplication \
  'SecAccess trusts the current application requirement'

mutate single-membership "$vault" \
  'return .success([tower])' \
  'return .success([tower, tower])' \
  testTrustedApplicationsTrustOnlyTheCurrentApplication \
  'only the current application is trusted'

mutate any-application-read "$vault" \
  'if readEntries.contains(where: { $0.applicationRequirements == nil }) { return false }' \
  'if false { return false }' \
  testAnyApplicationACLEntryNeedsNoRepair \
  'readable by all and needs no repair'

mutate unsigned-code "$vault" \
  'let validationStatus = SecStaticCodeCheckValidity(staticCode, [], nil)' \
  'let validationStatus = errSecSuccess' \
  testUnsignedCodeIsNotTrusted \
  'unsigned code must not be trusted'

if [ "$mutation_count" -eq 0 ]; then
  echo 'FAIL: no keychain mutations ran' >&2
  exit 1
fi
echo "Keychain mutation proof: $mutation_count mutations failed as expected; source restored"
