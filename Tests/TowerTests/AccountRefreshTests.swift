import Foundation
import XCTest
@testable import Tower

final class AccountRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func credential(_ name: String, expiresIn: TimeInterval? = 3600) -> ClaudeCredential {
        ClaudeCredential(
            service: "Claude Code-credentials-\(name)", accessToken: "fixture-\(name)",
            subscriptionType: "max", rateLimitTier: nil,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) }, emailHint: "\(name)@example.test")
    }

    private func reading(_ name: String, pct: Double) -> ClaudeFetch {
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(7200))
        return ClaudeFetch(email: "\(name)@example.test", usage: UsageResponse(
            five_hour: UsageWindow(utilization: pct, resets_at: reset),
            seven_day: UsageWindow(utilization: pct / 2, resets_at: reset),
            seven_day_opus: nil, seven_day_sonnet: nil, limits: nil))
    }

    func testObservedLoginsSurviveRestartAndRefreshAllSix() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir, now: { self.now })
        let keychain = MockSeatKeychain()
        let vault = keychain.vault(in: dir)
        let logins = (1...6).map { seat in
            ClaudeCredential(
                service: Keychain.defaultService, accessToken: "fixture-seat-\(seat)",
                subscriptionType: "max", rateLimitTier: nil,
                expiresAt: now.addingTimeInterval(3600), emailHint: "seat\(seat)@example.test")
        }

        for (index, login) in logins.enumerated() {
            let captured = await Refresher.refreshLoggedInAccount(
                login, store: store, vault: vault,
                fetch: { _ in self.reading("seat\(index + 1)", pct: Double(index + 1)) }, now: now)
            XCTAssertNil(captured.saveError)
        }

        XCTAssertEqual(keychain.ownedItemCount, 6, "retained items")

        let restartedVault = keychain.vault(in: dir)
        var fetched: [String] = []
        let refreshed = await Refresher.refreshClaudeRoster(
            store: store,
            credentials: {
                restartedVault.credentials(active: logins.last)
            },
            fetch: { credential in
                fetched.append(credential.accessToken)
                let seat = String(credential.accessToken.dropFirst("fixture-seat-".count))
                return self.reading("seat\(seat)", pct: 50)
            }, now: now)
        XCTAssertEqual(fetched.count, 6)
        XCTAssertEqual(refreshed.attemptedServices.count, 6)
    }

    func testLoginChangesFetchTheChangedProfileAndRetainEarlierCredentials() {
        var tracker = ClaudeLoginTracker()
        let first = credential("first")
        let second = credential("second")
        XCTAssertTrue(tracker.changes(in: [first]).isEmpty)
        XCTAssertTrue(tracker.changes(in: [first]).isEmpty)
        let queued = tracker.changes(in: [first, second])
        XCTAssertEqual(queued.map(\.service), [second.service])
        let relogin = ClaudeCredential(
            service: second.service, accessToken: "fixture-second-new-login",
            subscriptionType: second.subscriptionType, rateLimitTier: nil,
            expiresAt: now.addingTimeInterval(7200), emailHint: second.emailHint)
        XCTAssertEqual(tracker.changes(in: [first, relogin]).map(\.accessToken), [relogin.accessToken])
        XCTAssertEqual(queued.map(\.accessToken), [second.accessToken])
        XCTAssertTrue(tracker.changes(in: [first, relogin]).isEmpty)
    }

    func testConfigIdentityChangeRetriggersDefaultCredentialWithoutTokenChange() {
        var tracker = ClaudeLoginTracker()
        let active = ClaudeCredential(
            service: Keychain.defaultService, accessToken: "same-token",
            subscriptionType: "max", rateLimitTier: nil,
            expiresAt: now.addingTimeInterval(3600), emailHint: "ana@example.test")
        let first = ClaudeConfigIdentity(email: "ana@example.test", modifiedAt: 100, readable: true)
        let switched = ClaudeConfigIdentity(email: "ben@example.test", modifiedAt: 200, readable: true)
        XCTAssertTrue(tracker.observe(credentials: [active], identity: first)
            .changedCredentials.isEmpty)
        let after = tracker.observe(credentials: [active], identity: switched)
        XCTAssertTrue(after.identityChanged)
        XCTAssertFalse(after.watchDegraded)
        XCTAssertEqual(after.changedCredentials.map(\.accessToken), ["same-token"])
        XCTAssertTrue(tracker.observe(credentials: [active], identity: switched)
            .changedCredentials.isEmpty)
        let touched = ClaudeConfigIdentity(email: "ben@example.test", modifiedAt: 999, readable: true)
        XCTAssertTrue(tracker.observe(credentials: [active], identity: touched)
            .changedCredentials.isEmpty)
        XCTAssertFalse(tracker.observe(credentials: [active], identity: touched).identityChanged)
    }

    func testUnreadableConfigAfterAKnownIdentityIsDegradedNotSilent() {
        var tracker = ClaudeLoginTracker()
        let active = ClaudeCredential(
            service: Keychain.defaultService, accessToken: "same-token",
            subscriptionType: "max", rateLimitTier: nil,
            expiresAt: now.addingTimeInterval(3600), emailHint: "ana@example.test")
        let first = ClaudeConfigIdentity(email: "ana@example.test", modifiedAt: 100, readable: true)
        let gone = ClaudeConfigIdentity(email: nil, modifiedAt: nil, readable: false)
        _ = tracker.observe(credentials: [active], identity: first)
        let after = tracker.observe(credentials: [active], identity: gone)
        XCTAssertTrue(after.identityChanged)
        XCTAssertTrue(after.watchDegraded)
        XCTAssertEqual(after.changedCredentials.map(\.service), [Keychain.defaultService])
    }

    func testConfigIdentityReadUsesOauthEmailAndMtime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":{"emailAddress":"cal@example.test"}}"#.utf8)
            .write(to: url)
        let identity = ClaudeConfigIdentity.read(at: url)
        XCTAssertTrue(identity.readable)
        XCTAssertEqual(identity.email, "cal@example.test")
        XCTAssertNotNil(identity.modifiedAt)
        let missing = ClaudeConfigIdentity.read(at: dir.appendingPathComponent("absent.json"))
        XCTAssertFalse(missing.readable)
        XCTAssertNil(missing.email)
    }

    func testRefreshMarksEveryUnavailableAccountNeedsLoginEvenWithRecentCapture() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir, now: { self.now })
        try JSONEncoder().encode(["never@example.test"]).write(to: store.declaredFile)
        let recent = AccountSnapshot(
            email: "recent@example.test", nickname: "recent", plan: "max", fiveHourPct: 10,
            fiveHourResetsAt: now.addingTimeInterval(3600), weeklyPct: 20,
            weeklyResetsAt: now.addingTimeInterval(3600), capturedAt: now.addingTimeInterval(-60))
        let old = AccountSnapshot(
            email: "old@example.test", nickname: "old", plan: "max", fiveHourPct: 100,
            fiveHourResetsAt: now.addingTimeInterval(-1), weeklyPct: 83,
            weeklyResetsAt: now.addingTimeInterval(-1), capturedAt: now.addingTimeInterval(-80_000))
        XCTAssertNil(store.save([recent.email: recent, old.email: old]))
        let active = ClaudeCredential(
            service: Keychain.defaultService, accessToken: "fixture-active", subscriptionType: "max",
            rateLimitTier: nil, expiresAt: now.addingTimeInterval(3600), emailHint: "active@example.test")
        var fetched: [String] = []
        let result = await Refresher.refreshClaudeRoster(
            store: store, credentials: { [active] }, fetch: { credential in
                fetched.append(credential.service)
                return self.reading("active", pct: 40)
            }, now: now)
        XCTAssertEqual(fetched, [Keychain.defaultService])
        XCTAssertNil(result.accounts["active@example.test"]?.lastError)
        XCTAssertEqual(result.accounts["never@example.test"]?.lastError, "needs login")
        XCTAssertNil(result.accounts["never@example.test"]?.capturedAt)
        for original in [recent, old] {
            let row = try XCTUnwrap(result.accounts[original.email])
            XCTAssertEqual(row.lastError, "needs login")
            XCTAssertEqual(row.capturedAt, original.capturedAt)
            XCTAssertFalse(row.isRecommendable(now: now))
            XCTAssertNil(row.trustedHeadroomPct(now: now))
            for rule in AccountSnapshot.RestRule.allCases {
                XCTAssertTrue(AccountSnapshot.partition([row], rule: rule, now: now).active.isEmpty)
            }
        }
        XCTAssertEqual(result.accounts[old.email]?.fiveHourPct, 0)
        XCTAssertEqual(result.accounts[old.email]?.weeklyPct, 0)
        XCTAssertEqual(result.accounts[recent.email]?.fiveHourPct, 10)
        XCTAssertEqual(store.load()[recent.email]?.lastError, "needs login")
    }

    func testNeedsLoginExcludesFreshSnapshotsFromRoomAndEveryRestRule() {
        var row = AccountSnapshot(
            email: "unavailable@example.test", nickname: "unavailable", plan: "max", fiveHourPct: 10,
            fiveHourResetsAt: now.addingTimeInterval(3600), weeklyPct: 20,
            weeklyResetsAt: now.addingTimeInterval(3600), capturedAt: now, lastError: "needs login")
        XCTAssertFalse(row.isRecommendable(now: now))
        XCTAssertNil(row.trustedHeadroomPct(now: now))
        for rule in AccountSnapshot.RestRule.allCases {
            XCTAssertTrue(AccountSnapshot.partition([row], rule: rule, now: now).active.isEmpty)
        }
        row.lastError = nil
        XCTAssertTrue(row.isRecommendable(now: now))
        XCTAssertEqual(row.trustedHeadroomPct(now: now), 20)
    }

    func testRefreshFetchesEveryConfiguredAccountAndPersistsTheirOwnReadings() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        let store = Store(dir: dir, mirror: mirror, now: { self.now })
        let credentials = [credential("first"), credential("second"), credential("third")]
        var fetched: [String] = []
        let result = await Refresher.refreshClaudeRoster(
            store: store, credentials: { credentials }, fetch: { credential in
                fetched.append(credential.service)
                let name = String(credential.accessToken.dropFirst("fixture-".count))
                return self.reading(name, pct: Double(fetched.count * 10))
            }, now: now)

        XCTAssertNil(result.saveError)
        XCTAssertEqual(fetched, credentials.map(\.service))
        let bytes = try Data(contentsOf: dir.appendingPathComponent("accounts.json"))
        XCTAssertEqual(bytes, try Data(contentsOf: mirror))
        let written = try JSONDecoder().decode([String: AccountSnapshot].self, from: bytes)
        for (index, credential) in credentials.enumerated() {
            let email = try XCTUnwrap(credential.emailHint)
            for rows in [result.accounts, written] {
                XCTAssertEqual(rows[email]?.fiveHourPct, Double((index + 1) * 10))
                XCTAssertEqual(rows[email]?.weeklyPct, Double((index + 1) * 5))
                XCTAssertEqual(rows[email]?.capturedAt, now)
                XCTAssertNil(rows[email]?.lastError)
            }
        }
    }

    func testFailureDoesNotPreventLaterAccountsFromRefreshing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir, now: { self.now })
        let credentials = [credential("alpha"), credential("failed"), credential("last")]
        let captured = now.addingTimeInterval(-80_000)
        XCTAssertNil(store.save(["failed@example.test": AccountSnapshot(
            email: "failed@example.test", nickname: "failed", plan: "max", fiveHourPct: 61,
            fiveHourResetsAt: now.addingTimeInterval(3600), weeklyPct: 44,
            weeklyResetsAt: now.addingTimeInterval(3600), capturedAt: captured)]))
        var fetched: [String] = []
        let result = await Refresher.refreshClaudeRoster(
            store: store, credentials: { credentials }, fetch: { credential in
                fetched.append(credential.service)
                if credential.emailHint == "failed@example.test" {
                    throw NSError(domain: "test", code: 503,
                                  userInfo: [NSLocalizedDescriptionKey: "fixture unavailable"])
                }
                return self.reading(credential.emailHint == "alpha@example.test" ? "alpha" : "last", pct: 12)
            }, now: now)

        XCTAssertEqual(fetched, credentials.map(\.service))
        XCTAssertEqual(result.accounts["alpha@example.test"]?.fiveHourPct, 12)
        XCTAssertEqual(result.accounts["last@example.test"]?.fiveHourPct, 12)
        XCTAssertEqual(result.accounts["last@example.test"]?.capturedAt, now)
        XCTAssertEqual(result.accounts["failed@example.test"]?.fiveHourPct, 61)
        XCTAssertEqual(result.accounts["failed@example.test"]?.capturedAt, captured)
        XCTAssertTrue(result.accounts["failed@example.test"]?.lastError?.contains("fixture unavailable") == true)
    }

    func testExpiredAccessTokensNeedLoginWithoutFetchingOrRenewingAndKeepCaptureAge() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        let store = Store(dir: dir, mirror: mirror, now: { self.now })
        let credentials = [credential("expired", expiresIn: -1), credential("boundary", expiresIn: 0),
                           credential("unknown-expiry", expiresIn: nil)]
        let captured = now.addingTimeInterval(-80_000)
        var rows: [String: AccountSnapshot] = [:]
        for credential in credentials {
            let email = try XCTUnwrap(credential.emailHint)
            rows[email] = AccountSnapshot(
                email: email, nickname: email, plan: "max", fiveHourPct: 100,
                fiveHourResetsAt: now.addingTimeInterval(-3600), weeklyPct: 83,
                weeklyResetsAt: now.addingTimeInterval(-3600), capturedAt: captured)
        }
        XCTAssertNil(store.save(rows))
        var fetches = 0
        let result = await Refresher.refreshClaudeRoster(
            store: store, credentials: { credentials }, fetch: { _ in
                fetches += 1
                return self.reading("unexpected", pct: 100)
            }, now: now)
        XCTAssertEqual(fetches, 0)
        for credential in credentials {
            let email = try XCTUnwrap(credential.emailHint)
            XCTAssertEqual(result.accounts[email]?.lastError, "needs login")
            XCTAssertEqual(result.accounts[email]?.capturedAt, captured)
            XCTAssertEqual(result.accounts[email]?.fiveHourPct, 0)
            XCTAssertEqual(result.accounts[email]?.weeklyPct, 0)
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("accounts.json")),
                       try Data(contentsOf: mirror))
    }
}
