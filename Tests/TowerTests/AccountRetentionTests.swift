import Foundation
import XCTest
@testable import Tower

final class MockSeatKeychain: ClaudeSeatKeychain {
    var items: [ClaudeSeatKeychainRecord] = []
    /// Owned items whose attributes list but whose data refuses this signer, like an item an
    /// earlier ad-hoc build wrote. Updating one in place fails the way the item ACL would;
    /// only an exact delete clears it.
    var unreadable: [ClaudeSeatUnreadableItem] = []
    var removed: [String] = []
    var readError: String?
    var writeError: String?
    var removeError: String?
    /// The interaction each readSeats call ran with, in order.
    var interactions: [ClaudeSeatReadInteraction] = []

    func readSeats(interaction: ClaudeSeatReadInteraction) -> Result<ClaudeSeatKeychainReadout, ClaudeSeatVaultError> {
        interactions.append(interaction)
        if let readError { return .failure(ClaudeSeatVaultError(readError)) }
        return .success(ClaudeSeatKeychainReadout(records: items, unreadable: unreadable))
    }

    func writeSeat(service: String, account: String, label: String, data: Data) -> String? {
        if let writeError { return writeError }
        if let refused = unreadable.first(where: {
            $0.service == service && $0.account == account && $0.label == label
        }) {
            return "Keychain write failed (\(refused.status))"
        }
        items.removeAll { $0.service == service && $0.account == account && $0.label == label }
        items.append(.init(service: service, account: account, label: label, data: data))
        return nil
    }

    func removeSeat(service: String, account: String, label: String) -> String? {
        if let removeError { return removeError }
        removed.append("\(service)|\(account)|\(label)")
        unreadable.removeAll { $0.service == service && $0.account == account && $0.label == label }
        items.removeAll { $0.service == service && $0.account == account && $0.label == label }
        return nil
    }

    var ownedItemCount: Int {
        items.filter { record in
            record.service.hasPrefix(ClaudeSeatVault.ownedServicePrefix)
                && record.label == ClaudeSeatVault.ownershipMarker
                && record.service == ClaudeSeatVault.service(for: record.account)
        }.count
    }

    func vault(in dir: URL, enabled: @escaping () -> Bool = { true },
               setEnabled: @escaping (Bool) -> Void = { _ in },
               log: @escaping (String) -> Void = { _ in }) -> ClaudeSeatVault {
        ClaudeSeatVault(keychain: self,
                        lockURL: dir.appendingPathComponent("seat.lock"),
                        stateURL: dir.appendingPathComponent("seat-state.plist"),
                        retentionEnabled: enabled, setRetentionEnabled: setEnabled, log: log)
    }
}

final class AccountRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func credential(_ token: String = "fixture-access", email: String = "one@example.test",
                            expiresIn: TimeInterval = 3600) -> ClaudeCredential {
        ClaudeCredential(service: Keychain.defaultService, accessToken: token,
                         subscriptionType: "max", rateLimitTier: "fixture-tier",
                         expiresAt: now.addingTimeInterval(expiresIn), emailHint: email)
    }

    private func capture(_ credential: ClaudeCredential, in vault: ClaudeSeatVault) -> String? {
        vault.captureVerifiedLogin(credential, email: credential.emailHint!,
                                   observation: vault.beginObservation(), now: now)
    }

    private func usage() -> UsageResponse {
        UsageResponse(five_hour: UsageWindow(utilization: 21, resets_at: nil),
                      seven_day: UsageWindow(utilization: 32, resets_at: nil),
                      seven_day_opus: nil, seven_day_sonnet: nil, limits: nil)
    }

    func testVerifiedLoginIsRetainedBeforeUsageFailure() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let store = Store(dir: dir, now: { self.now })
        var countDuringUsage = -1
        let result = await Refresher.refreshLoggedInAccount(
            credential(email: "stale-hint@example.test"), store: store, vault: vault,
            profile: { _ in "verified@example.test" }, usage: { _ in
                countDuringUsage = keychain.ownedItemCount
                throw ClaudeSeatVaultError("fixture usage failure")
            }, clock: { self.now })
        XCTAssertEqual(countDuringUsage, 1, "capture precedes usage")
        XCTAssertEqual(vault.credentials(active: nil).compactMap(\.emailHint), ["verified@example.test"],
                       "verified identity owns token")
        XCTAssertTrue(result.failureText?.contains("fixture usage failure") == true)
        XCTAssertNil(result.accounts["stale-hint@example.test"], "unverified hint never attributed")
    }

    func testUnverifiedProfileDoesNotCaptureOrFetchUsage() async throws {
        let keychain = MockSeatKeychain()
        let store = Store(dir: dir, now: { self.now })
        var usageCalls = 0
        let result = await Refresher.refreshLoggedInAccount(
            credential(), store: store, vault: keychain.vault(in: dir),
            profile: { _ in nil }, usage: { _ in usageCalls += 1; return self.usage() },
            clock: { self.now })
        XCTAssertEqual(keychain.ownedItemCount, 0, "unverified identity not retained")
        XCTAssertEqual(usageCalls, 0, "unverified identity skips usage")
        XCTAssertNotNil(result.failureText)
    }

    func testExpiryIsRecheckedAfterProfileAwait() async throws {
        let keychain = MockSeatKeychain()
        let store = Store(dir: dir, now: { self.now })
        var clock = now
        var usageCalls = 0
        let result = await Refresher.refreshLoggedInAccount(
            credential(expiresIn: 1), store: store, vault: keychain.vault(in: dir),
            profile: { _ in clock = self.now.addingTimeInterval(2); return "one@example.test" },
            usage: { _ in usageCalls += 1; return self.usage() }, clock: { clock })
        XCTAssertEqual(keychain.ownedItemCount, 0, "expired during profile not retained")
        XCTAssertEqual(usageCalls, 0, "expired during profile skips usage")
        XCTAssertEqual(result.accounts["one@example.test"]?.lastError, "needs login")
    }

    func testForgetDuringProfileCannotResurrectToken() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let store = Store(dir: dir, now: { self.now })
        _ = await Refresher.refreshLoggedInAccount(
            credential(), store: store, vault: vault,
            profile: { _ in
                XCTAssertNil(vault.forgetAll(suppressing: self.credential()))
                return "one@example.test"
            }, usage: { _ in self.usage() }, clock: { self.now })
        XCTAssertEqual(keychain.ownedItemCount, 0, "Forget during profile fences capture")
        XCTAssertNil(capture(credential(), in: keychain.vault(in: dir)))
        XCTAssertEqual(keychain.ownedItemCount, 0, "unchanged login stays forgotten after restart")
        XCTAssertNil(capture(credential("fixture-new-login"), in: vault))
        XCTAssertEqual(keychain.ownedItemCount, 1, "new login can be retained")
    }

    func testExpiredRetainedSeatNeverCallsNetworkOrRanksAndZerosBothCaches() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        XCTAssertNil(capture(credential(expiresIn: 1), in: vault))
        let later = now.addingTimeInterval(2)
        let mirror = dir.appendingPathComponent("mirror.json")
        let store = Store(dir: dir, mirror: mirror, now: { later })
        let row = AccountSnapshot(email: "one@example.test", nickname: "one", plan: "max",
                                  fiveHourPct: 88, fiveHourResetsAt: now,
                                  weeklyPct: 99, weeklyResetsAt: now, capturedAt: now)
        XCTAssertNil(store.save([row.email: row]))
        var requests = 0
        let result = await Refresher.refreshLoggedInAccount(
            nil, store: store, vault: vault,
            profile: { _ in requests += 1; return "one@example.test" },
            usage: { _ in requests += 1; return self.usage() }, clock: { later })
        XCTAssertEqual(requests, 0, "expired retained seat makes no network requests")
        let expired = try XCTUnwrap(result.accounts[row.email])
        XCTAssertEqual(expired.lastError, "needs login")
        XCTAssertFalse(expired.isRecommendable(now: later), "expired retained seat cannot rank")
        XCTAssertEqual(expired.fiveHourPct, 0)
        XCTAssertEqual(expired.weeklyPct, 0)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("accounts.json")),
                       try Data(contentsOf: mirror), "both expired caches match")
    }

    func testRetentionDefaultsOnAndPersistsOffPreference() throws {
        let name = "TowerRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(ClaudeSeatRetention.isEnabled(defaults: defaults), "retention defaults on")
        ClaudeSeatRetention.setEnabled(false, defaults: defaults)
        XCTAssertFalse(ClaudeSeatRetention.isEnabled(defaults: defaults), "off preference persists")
        ClaudeSeatRetention.setEnabled(true, defaults: defaults)
        XCTAssertTrue(ClaudeSeatRetention.isEnabled(defaults: defaults))
    }

    func testOffRejectsCaptureEvenForObservationStartedWhileOn() throws {
        let keychain = MockSeatKeychain()
        var enabled = true
        let vault = keychain.vault(in: dir, enabled: { enabled }, setEnabled: { enabled = $0 })
        let observation = vault.beginObservation()
        XCTAssertNil(vault.disableAndForget(suppressing: nil))
        XCTAssertFalse(enabled)
        // Reenable before delivering the old observation so only the persistent fence
        // can reject it; a preference early exit cannot make this test pass.
        vault.enableRetention()
        XCTAssertTrue(enabled)
        XCTAssertNil(vault.captureVerifiedLogin(credential(), email: "one@example.test",
                                                observation: observation, now: now))
        XCTAssertEqual(keychain.ownedItemCount, 0, "off blocks capture")
    }

    func testArbiterPreferenceFlipWithoutGenerationAdvance() throws {
        let keychain = MockSeatKeychain()
        var armed = false
        var enabled = true
        var evaluations = 0
        let vault = keychain.vault(in: dir, enabled: {
            guard armed else { return enabled }
            evaluations += 1
            let observed = enabled
            if evaluations == 1 { enabled = false }
            return observed
        })
        let observation = vault.beginObservation()
        armed = true
        XCTAssertNil(vault.captureVerifiedLogin(credential(), email: "one@example.test",
                                                observation: observation, now: now))
        XCTAssertEqual(keychain.ownedItemCount, 0, "T1 preference-only flip blocks capture")
    }

    func testObservationStartedWhileOffCannotCaptureAfterEnable() throws {
        let keychain = MockSeatKeychain()
        var enabled = false
        let vault = keychain.vault(in: dir, enabled: { enabled }, setEnabled: { enabled = $0 })
        let observation = vault.beginObservation()
        vault.enableRetention()
        XCTAssertNil(vault.captureVerifiedLogin(credential(), email: "one@example.test",
                                                observation: observation, now: now))
        XCTAssertEqual(keychain.ownedItemCount, 0, "while-off observation stays fenced after enable")
    }

    func testDisableDeletesOwnedSeatsBeforePersistingOffAndCanEnableAgain() throws {
        let keychain = MockSeatKeychain()
        var enabled = true
        var countAtPreferenceChange = -1
        let vault = keychain.vault(in: dir, enabled: { enabled }, setEnabled: {
            countAtPreferenceChange = keychain.ownedItemCount
            enabled = $0
        })
        XCTAssertNil(capture(credential(), in: vault))
        XCTAssertNil(vault.disableAndForget(suppressing: credential()))
        XCTAssertFalse(enabled, "disable persists off")
        XCTAssertEqual(countAtPreferenceChange, 0, "delete before disabling")
        XCTAssertEqual(keychain.ownedItemCount, 0, "disable deletes owned seats")
        vault.enableRetention()
        XCTAssertTrue(enabled, "enable persists on")
        XCTAssertNil(capture(credential(), in: vault))
        XCTAssertEqual(keychain.ownedItemCount, 0, "enable does not undo Forget suppression")
    }

    func testDisableFailureKeepsPreferenceOnAndReportsError() throws {
        let keychain = MockSeatKeychain()
        var enabled = true
        let vault = keychain.vault(in: dir, enabled: { enabled }, setEnabled: { enabled = $0 })
        XCTAssertNil(capture(credential(), in: vault))
        keychain.removeError = "fixture denied"
        XCTAssertEqual(vault.disableAndForget(suppressing: credential()), "fixture denied")
        XCTAssertTrue(enabled, "failed disable keeps preference on")
    }

    func testCorruptStateCannotResetForgetFence() throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let observation = vault.beginObservation()
        try Data("corrupt".utf8).write(to: dir.appendingPathComponent("seat-state.plist"))
        XCTAssertNotNil(vault.captureVerifiedLogin(credential(), email: "one@example.test",
                                                   observation: observation, now: now),
                        "corrupt state fails closed")
        XCTAssertEqual(keychain.ownedItemCount, 0)
    }

    func testOffDoesNotDependOnRetentionStateOrKeychain() async throws {
        let keychain = MockSeatKeychain()
        keychain.readError = "fixture denied"
        let vault = keychain.vault(in: dir, enabled: { false })
        try Data("corrupt".utf8).write(to: dir.appendingPathComponent("seat-state.plist"))
        let store = Store(dir: dir, now: { self.now })
        var usageCalls = 0
        let result = await Refresher.refreshLoggedInAccount(
            credential(), store: store, vault: vault, profile: { _ in "one@example.test" },
            usage: { _ in usageCalls += 1; return self.usage() }, clock: { self.now })
        XCTAssertNil(result.failureText, "off bypasses retention failure")
        XCTAssertNil(result.saveError)
        XCTAssertEqual(usageCalls, 1, "off still fetches live usage")
        XCTAssertEqual(keychain.ownedItemCount, 0)
        XCTAssertNil(vault.forgetRetired(["one@example.test"]), "off retirement bypasses retention failure")
    }

    func testReadFailurePreservesPreviouslyAvailableRoster() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let store = Store(dir: dir, now: { self.now })
        let row = AccountSnapshot(email: "one@example.test", nickname: "one", plan: "max",
                                  fiveHourPct: 20, fiveHourResetsAt: now.addingTimeInterval(3600),
                                  weeklyPct: 30, weeklyResetsAt: now.addingTimeInterval(3600), capturedAt: now)
        XCTAssertNil(store.save([row.email: row]))
        keychain.readError = "fixture read denied"
        let result = await Refresher.refreshLoggedInAccount(
            nil, store: store, vault: vault, profile: { _ in "one@example.test" },
            usage: { _ in self.usage() }, clock: { self.now })
        XCTAssertTrue(result.failureText?.contains("fixture read denied") == true,
                      "read failure reaches refresh result")
        XCTAssertNil(result.accounts[row.email]?.lastError, "read failure preserves availability")
        XCTAssertNil(store.load()[row.email]?.lastError, "read failure preserves persisted availability")
        XCTAssertEqual(result.accounts[row.email]?.fiveHourPct, 20)
    }

    func testRetirementDuringProfileCannotRecreateAccount() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let store = Store(dir: dir, now: { self.now })
        let result = await Refresher.refreshLoggedInAccount(
            credential(), store: store, vault: vault, profile: { _ in
                try JSONEncoder().encode(["one@example.test"]).write(to: store.retiredFile)
                return "one@example.test"
            }, usage: { _ in self.usage() }, clock: { self.now })
        XCTAssertEqual(keychain.ownedItemCount, 0, "retired during profile not captured")
        XCTAssertNil(result.accounts["one@example.test"], "retired during profile not restored")
        XCTAssertEqual(result.failureText,
                       "Claude login changed while Tower was verifying it. Run /login in Claude Code, then refresh Tower.")
    }

    func testRetirementRewrittenDuringProfileKeepsPreexistingRetirement() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let store = Store(dir: dir, now: { self.now })
        try JSONEncoder().encode(["one@example.test"]).write(to: store.retiredFile, options: .atomic)
        let result = await Refresher.refreshLoggedInAccount(
            credential(), store: store, vault: vault, profile: { _ in
                // Same contents, new file identity: the second explicit retirement wins.
                try JSONEncoder().encode(["one@example.test"])
                    .write(to: store.retiredFile, options: .atomic)
                return "one@example.test"
            }, usage: { _ in self.usage() }, clock: { self.now })

        XCTAssertTrue(store.retiredEmails.contains("one@example.test"),
                      "retirement rewritten during profile stays retired")
        XCTAssertEqual(keychain.ownedItemCount, 0, "rewritten retirement is not captured")
        XCTAssertNil(result.accounts["one@example.test"], "rewritten retirement is not restored")
        XCTAssertEqual(result.failureText,
                       "Claude login changed while Tower was verifying it. Run /login in Claude Code, then refresh Tower.")
    }

    func testVerifiedActiveLoginReactivatesRetiredAccountAndMirrorsRealUsageAfterRestart() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        let store = Store(dir: dir, mirror: mirror, now: { self.now })
        try JSONEncoder().encode(["one@example.test"]).write(to: store.retiredFile)

        let result = await Refresher.refreshLoggedInAccount(
            credential(), store: store, vault: vault,
            profile: { _ in "one@example.test" }, usage: { _ in self.usage() },
            clock: { self.now })

        XCTAssertFalse(store.retiredEmails.contains("one@example.test"),
                       "retired account is removed from retirement list")
        XCTAssertNil(result.failureText)
        let row = try XCTUnwrap(result.accounts["one@example.test"])
        XCTAssertEqual(row.fiveHourPct, 21)
        XCTAssertEqual(row.weeklyPct, 32)
        XCTAssertNil(row.lastError)
        XCTAssertEqual(keychain.ownedItemCount, 1, "verified active login is retained")

        let cached = try Data(contentsOf: dir.appendingPathComponent("accounts.json"))
        XCTAssertEqual(cached, try Data(contentsOf: mirror), "reactivated row reaches quota mirror")
        let restarted = Store(dir: dir, mirror: mirror, now: { self.now })
        XCTAssertEqual(restarted.load()["one@example.test"]?.fiveHourPct, 21,
                       "restart preserves real five hour usage")
        XCTAssertEqual(restarted.load()["one@example.test"]?.weeklyPct, 32,
                       "restart preserves real seven day usage")
    }

    func testReactivatedLoginLeavesUsageUnknownWhenUsageFails() async throws {
        let store = Store(dir: dir, now: { self.now })
        try JSONEncoder().encode(["one@example.test"]).write(to: store.retiredFile)
        let result = await Refresher.refreshLoggedInAccount(
            credential(), store: store, vault: MockSeatKeychain().vault(in: dir),
            profile: { _ in "one@example.test" },
            usage: { _ in throw ClaudeSeatVaultError("fixture usage failure") },
            clock: { self.now })

        XCTAssertFalse(store.retiredEmails.contains("one@example.test"),
                       "verified login clears prior retirement before usage")
        let row = try XCTUnwrap(result.accounts["one@example.test"])
        XCTAssertNil(row.fiveHourPct, "usage failure remains unknown")
        XCTAssertNil(row.weeklyPct, "usage failure remains unknown")
        XCTAssertEqual(row.lastError, "usage fetch: fixture usage failure")
    }

    func testUnverifiedOrRetainedCredentialCannotReactivateRetiredAccount() async throws {
        let email = "one@example.test"
        let unverifiedStore = Store(dir: dir, now: { self.now })
        try JSONEncoder().encode([email]).write(to: unverifiedStore.retiredFile)
        var usageCalls = 0
        _ = await Refresher.refreshLoggedInAccount(
            credential(), store: unverifiedStore, vault: MockSeatKeychain().vault(in: dir),
            profile: { _ in nil }, usage: { _ in usageCalls += 1; return self.usage() },
            clock: { self.now })
        XCTAssertTrue(unverifiedStore.retiredEmails.contains(email),
                      "unverified profile keeps retirement")
        XCTAssertEqual(usageCalls, 0, "unverified profile does not fetch usage")

        let inactiveDir = dir.appendingPathComponent("inactive")
        try FileManager.default.createDirectory(at: inactiveDir, withIntermediateDirectories: true)
        let inactiveKeychain = MockSeatKeychain()
        let inactiveVault = inactiveKeychain.vault(in: inactiveDir)
        XCTAssertNil(capture(credential(), in: inactiveVault))
        let inactiveStore = Store(dir: inactiveDir, now: { self.now })
        try JSONEncoder().encode([email]).write(to: inactiveStore.retiredFile)
        var inactiveUsageCalls = 0
        _ = await Refresher.refreshLoggedInAccount(
            nil, store: inactiveStore, vault: inactiveVault,
            profile: { _ in "one@example.test" },
            usage: { _ in inactiveUsageCalls += 1; return self.usage() }, clock: { self.now })
        XCTAssertTrue(inactiveStore.retiredEmails.contains(email),
                      "retained credential keeps retirement")
        XCTAssertEqual(inactiveUsageCalls, 0, "retained credential does not fetch usage")
    }

    func testRetainedCredentialCannotChangeVerifiedIdentity() async throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        XCTAssertNil(capture(credential(), in: vault))
        let store = Store(dir: dir, now: { self.now })
        var usageCalls = 0
        let result = await Refresher.refreshLoggedInAccount(
            nil, store: store, vault: vault, profile: { _ in "wrong@example.test" },
            usage: { _ in usageCalls += 1; return self.usage() }, clock: { self.now })
        XCTAssertEqual(usageCalls, 0, "retained identity mismatch skips usage")
        XCTAssertNil(result.accounts["wrong@example.test"], "retained identity cannot cross seats")
    }

    func testForgetFencesInflightObservationAcrossRestart() throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let observation = vault.beginObservation()
        XCTAssertNil(vault.forgetAll())
        let restarted = keychain.vault(in: dir)
        XCTAssertNil(restarted.captureVerifiedLogin(credential(), email: "one@example.test",
                                                    observation: observation, now: now))
        XCTAssertEqual(keychain.ownedItemCount, 0, "Forget fences inflight capture")
    }

    func testOlderObservationCannotOverwriteNewerSeat() throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let older = vault.beginObservation()
        let newer = vault.beginObservation()
        XCTAssertNil(vault.captureVerifiedLogin(credential("new"), email: "one@example.test",
                                                observation: newer, now: now))
        XCTAssertNil(vault.captureVerifiedLogin(credential("old"), email: "one@example.test",
                                                observation: older, now: now))
        XCTAssertEqual(vault.credentials(active: nil).map(\.accessToken), ["new"],
                       "latest observation wins")
    }

    func testForgetDeletesCorruptOwnedItemsAndPreservesForeignItems() throws {
        let keychain = MockSeatKeychain()
        let owned = ClaudeSeatKeychainRecord(service: ClaudeSeatVault.service(for: "one@example.test"),
                                            account: "one@example.test", label: ClaudeSeatVault.ownershipMarker,
                                            data: Data("corrupt".utf8))
        let foreignLabel = ClaudeSeatKeychainRecord(service: ClaudeSeatVault.service(for: "two@example.test"),
                                                   account: "two@example.test", label: "another app",
                                                   data: Data())
        let foreignService = ClaudeSeatKeychainRecord(service: Keychain.defaultService,
                                                     account: "one@example.test", label: ClaudeSeatVault.ownershipMarker,
                                                     data: Data())
        keychain.items = [owned, foreignLabel, foreignService]
        XCTAssertEqual(keychain.ownedItemCount, 1, "mock counts only owned namespace")
        XCTAssertNil(keychain.vault(in: dir).forgetAll())
        XCTAssertEqual(keychain.ownedItemCount, 0, "mock excludes foreign items after Forget")
        XCTAssertFalse(keychain.items.contains { $0.service == owned.service }, "corrupt owned item deleted")
        XCTAssertTrue(keychain.items.contains { $0.service == foreignLabel.service }, "foreign label preserved")
        XCTAssertTrue(keychain.items.contains { $0.service == foreignService.service }, "foreign service preserved")
    }

    /// The seat keeps the access token and its identity, and never a refresh token.
    func testPayloadCarriesAccessTokenAndMatchingIdentity() throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        XCTAssertNil(capture(credential(), in: vault))
        let record = try XCTUnwrap(keychain.items.first)
        let payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: record.data, format: nil) as? [String: Any])
        XCTAssertEqual(payload["accessToken"] as? String, "fixture-access", "access token retained")
        XCTAssertNil(payload["refreshToken"], "no refresh token is ever written")
        XCTAssertNil(payload["scopes"], "no scopes are written")
        XCTAssertEqual(record.service, "Tower-seat-one@example.test")
        XCTAssertEqual(record.account, "one@example.test")
        keychain.items = [.init(service: ClaudeSeatVault.service(for: "wrong@example.test"),
                                account: "wrong@example.test", label: record.label, data: record.data)]
        // A new vault is a new launch: the mismatched item is what the Keychain now holds.
        XCTAssertTrue(keychain.vault(in: dir).credentials(active: nil).isEmpty, "mismatched payload rejected")
    }

    /// An item written by an older build may still carry a refresh token. It decodes as a
    /// seat, and the token is dropped on read: nothing in this build can present it.
    func testOlderSeatItemWithARefreshTokenStillDecodes() throws {
        let keychain = MockSeatKeychain()
        XCTAssertNil(capture(credential(), in: keychain.vault(in: dir)))
        let record = try XCTUnwrap(keychain.items.first)
        var payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: record.data, format: nil) as? [String: Any])
        payload["refreshToken"] = "fixture-older-refresh"
        payload["scopes"] = ["user:profile"]
        let older = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        keychain.items = [.init(service: record.service, account: record.account, label: record.label, data: older)]
        let seat = try XCTUnwrap(keychain.vault(in: dir).credentials(active: nil).first)
        XCTAssertEqual(seat.accessToken, "fixture-access")
    }

    func testWriteAndRemovalFailuresAreVisible() throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        keychain.writeError = "fixture write denied"
        XCTAssertEqual(capture(credential(), in: vault), "fixture write denied", "write failure visible")
        keychain.writeError = nil
        XCTAssertNil(capture(credential(), in: vault))
        keychain.removeError = "fixture remove denied"
        XCTAssertEqual(vault.forgetAll(), "fixture remove denied", "remove failure visible")
        keychain.readError = "fixture read denied"
        XCTAssertEqual(vault.forgetAll(), "fixture read denied", "read failure visible")
    }

    // MARK: - Owned items this build cannot read (#45)

    private func unreadableItem(_ email: String, status: OSStatus) -> ClaudeSeatUnreadableItem {
        ClaudeSeatUnreadableItem(service: ClaudeSeatVault.service(for: email), account: email,
                                 label: ClaudeSeatVault.ownershipMarker, status: status)
    }

    /// The operator-visible shape from #40: one owned item the current signer cannot read
    /// took the whole roster down, every account read needs login, and the panel named
    /// nothing. The roster must come from the CLI credential plus the readable items, the
    /// row for the unreadable seat must name the item and the status, and the fallback must
    /// log exactly one line so a reviewer can count how often it fires.
    func testUnreadableOwnedItemFallsBackToCLICredentialAndNamesItself() async throws {
        let keychain = MockSeatKeychain()
        XCTAssertNil(capture(credential("two", email: "two@example.test"), in: keychain.vault(in: dir)))
        keychain.unreadable = [unreadableItem("three@example.test", status: -50)]
        var lines: [String] = []
        let vault = keychain.vault(in: dir, log: { lines.append($0) })
        let store = Store(dir: dir, now: { self.now })
        let result = await Refresher.refreshLoggedInAccount(
            credential("one"), store: store, vault: vault,
            profile: { token in token == "one" ? "one@example.test" : "two@example.test" },
            usage: { _ in self.usage() }, clock: { self.now })
        XCTAssertNil(result.failureText, "unreadable owned item does not fail the refresh")
        XCTAssertNil(result.accounts["one@example.test"]?.lastError, "CLI credential still serves the active seat")
        XCTAssertNil(result.accounts["two@example.test"]?.lastError, "readable retained seat still serves")
        let three = try XCTUnwrap(result.accounts["three@example.test"], "unreadable seat stays listed")
        XCTAssertTrue(three.needsLogin, "unreadable seat cannot rank")
        XCTAssertTrue(three.lastError?.contains("Tower-seat-three@example.test") == true,
                      "panel names the unreadable item")
        XCTAssertTrue(three.lastError?.contains("(-50)") == true, "panel names the status")
        let fallbackLines = lines.filter {
            $0.contains("service=Tower-seat-three@example.test") && $0.contains("account=three@example.test")
                && $0.contains("label=\(ClaudeSeatVault.ownershipMarker)") && $0.contains("status=-50")
        }
        XCTAssertEqual(fallbackLines.count, 1, "fallback logs exactly one line naming the item and status")
        XCTAssertEqual(keychain.ownedItemCount, 2, "active and readable seats retained")
    }

    /// After the fallback, the next verified login of that seat must not update the
    /// unreadable item in place (the old signer still owns it). It deletes that exact item
    /// and writes a fresh one the current signer can read back.
    func testUnreadableOwnedItemIsRecreatedUnderTheCurrentSignerAfterFallback() async throws {
        let keychain = MockSeatKeychain()
        let stale = unreadableItem("one@example.test", status: errSecAuthFailed)
        keychain.unreadable = [stale]
        var lines: [String] = []
        let vault = keychain.vault(in: dir, log: { lines.append($0) })
        let store = Store(dir: dir, now: { self.now })
        let result = await Refresher.refreshLoggedInAccount(
            credential("fresh"), store: store, vault: vault, profile: { _ in "one@example.test" },
            usage: { _ in self.usage() }, clock: { self.now })
        XCTAssertNil(result.failureText, "re-create does not fail the refresh")
        XCTAssertNil(result.accounts["one@example.test"]?.lastError, "verified login clears the unreadable row")
        XCTAssertEqual(keychain.removed, ["\(stale.service)|\(stale.account)|\(stale.label)"],
                       "unreadable item deleted by its exact service, account and label")
        XCTAssertTrue(keychain.unreadable.isEmpty)
        XCTAssertEqual(keychain.ownedItemCount, 1, "owned item re-created")
        XCTAssertEqual(vault.credentials(active: nil).map(\.accessToken), ["fresh"],
                       "re-created item holds the verified token")
        XCTAssertEqual(lines.filter { $0.contains("status=-25293") }.count, 2,
                       "fallback and re-create each log one line")
    }

    /// #68 review: Forget and disable are the operator's word. They must see the Keychain as
    /// it is now, not this launch's copy, or an item another Tower process wrote after the
    /// launch read survives an explicit Forget.
    private func ownedItemBehindTheLaunchCopy(_ keychain: MockSeatKeychain, in vault: ClaudeSeatVault) {
        XCTAssertNil(capture(credential("one"), in: vault))
        XCTAssertEqual(vault.credentials(active: nil).count, 1, "launch copy holds one seat")
        keychain.items.append(.init(service: ClaudeSeatVault.service(for: "two@example.test"),
                                    account: "two@example.test", label: ClaudeSeatVault.ownershipMarker,
                                    data: Data()))
        XCTAssertEqual(keychain.ownedItemCount, 2)
    }

    func testForgetAllReadsTheKeychainFreshNotTheLaunchCopy() throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        ownedItemBehindTheLaunchCopy(keychain, in: vault)
        XCTAssertNil(vault.forgetAll())
        XCTAssertEqual(keychain.ownedItemCount, 0, "Forget removes an item written after the launch read")
    }

    func testDisableReadsTheKeychainFreshNotTheLaunchCopy() throws {
        let keychain = MockSeatKeychain()
        var enabled = true
        let vault = keychain.vault(in: dir, enabled: { enabled }, setEnabled: { enabled = $0 })
        ownedItemBehindTheLaunchCopy(keychain, in: vault)
        XCTAssertNil(vault.disableAndForget(suppressing: nil))
        XCTAssertEqual(keychain.ownedItemCount, 0, "disable removes an item written after the launch read")
    }

    func testRetirementDeletesOnlyTheRetiredSeat() throws {
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        XCTAssertNil(capture(credential("one"), in: vault))
        XCTAssertNil(capture(credential("two", email: "two@example.test"), in: vault))
        XCTAssertNil(vault.forgetRetired(["one@example.test"]))
        XCTAssertEqual(vault.credentials(active: nil).compactMap(\.emailHint), ["two@example.test"],
                       "retired seat removed")
    }
}
