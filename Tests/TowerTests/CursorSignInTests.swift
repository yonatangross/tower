import XCTest
@testable import Tower

/// Tower's own Cursor sign-in (replaces CursorOpaqueTokenTests). Since 2026-10-31 the Cursor
/// app stores an opaque value, byte-identical to its refresh token, that the usage route
/// refuses with 401; a re-sign in Cursor writes the same shape again. Tower therefore keeps
/// its own sign-in and never sends anything it reads from the Cursor app. Every token and
/// reply here is invented, and the HTTP layer is scripted: no test reaches Cursor.
final class CursorSignInTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-signin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: CursorAuth.stateDB(home: home).deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// The same ItemTable the Cursor app keeps, with fake values only.
    private func seedCursorApp(_ rows: [String: String]) throws {
        var sql = "create table ItemTable (key text unique on conflict replace, value blob);"
        for (k, v) in rows { sql += "insert into ItemTable values ('\(k)','\(v)');" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [CursorAuth.stateDB(home: home).path, sql]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "fixture db built")
    }

    private func jwt(expiresIn seconds: TimeInterval) -> String {
        FakeJWT.make(["sub": "user_FAKE", "exp": now.timeIntervalSince1970 + seconds])
    }

    private let usageJSON =
        #"{"planUsage":{"autoPercentUsed":12,"apiPercentUsed":100},"billingCycleEnd":"2033-05-25T00:00:00.000Z"}"#

    // MARK: Sign-in

    func testPKCEMatchesRFC7636() {
        XCTAssertEqual(CursorSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pair = CursorSignIn.pkce(random: Array(0..<32))
        XCTAssertEqual(pair.verifier.count, 43)
        XCTAssertEqual(pair.challenge, CursorSignIn.challenge(for: pair.verifier))
    }

    func testAuthorizeURLCarriesChallengeUUIDModeAndTarget() throws {
        let url = CursorSignIn.authorizeURL(challenge: "ch", uuid: "u-1")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "cursor.com")
        XCTAssertEqual(c.path, "/loginDeepControl")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q, ["challenge": "ch", "uuid": "u-1", "mode": "login", "redirectTarget": "cli"])
    }

    func testPollWaitsCompletesAndFails() async {
        XCTAssertEqual(CursorSignIn.pollStep(status: 404, body: Data()), .pending)
        XCTAssertEqual(CursorSignIn.pollStep(status: 202, body: Data()), .pending)
        XCTAssertNotEqual(CursorSignIn.pollStep(status: 500, body: Data()), .pending)
        let http = ScriptedCursorHTTP([(404, ""), (200, #"{"accessToken":"a","refreshToken":"r"}"#)])
        let result = await CursorSignIn.poll(uuid: "u", verifier: "v", http: http, sleep: { _ in })
        XCTAssertEqual(result, .signedIn(.init(accessToken: "a", refreshToken: "r")))
        XCTAssertEqual(http.requests.count, 2)
    }

    func testPollTimesOutAfterFiveMinutes() async {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let http = ScriptedCursorHTTP(Array(repeating: (404, ""), count: 400))
        let result = await CursorSignIn.poll(uuid: "u", verifier: "v", http: http,
                                             now: { clock.t },
                                             sleep: { s in clock.t = clock.t.addingTimeInterval(s) })
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(http.requests.count, 150)
    }

    // MARK: Reader

    func testNoTowerSignInAsksToConnectAndSendsNothing() async throws {
        try seedCursorApp(["cursorAuth/accessToken": "cur_STATE_ONLY_FAKE",
                           "cursorAuth/cachedEmail": "cursor@example.test"])
        let http = ScriptedCursorHTTP([(200, "{}")])
        let outcome = await CursorUsage.fetch(home: home, now: now, store: MemoryCursorTokenStore(), http: http)
        XCTAssertEqual(outcome, .connectNeeded(CursorUsage.connectReason))
        XCTAssertTrue(http.requests.isEmpty, "the Cursor app's value is never sent")
        XCTAssertFalse(CursorUsage.connectReason.contains("Sign in again in Cursor"))
    }

    func testNoCursorAppAndNoSignInIsNoLane() async {
        let outcome = await CursorUsage.fetch(home: home, now: now, store: MemoryCursorTokenStore(),
                                              http: ScriptedCursorHTTP([]))
        XCTAssertEqual(outcome, .notConfigured)
    }

    func testReadsWithTowersOwnTokenOnly() async throws {
        try seedCursorApp(["cursorAuth/accessToken": "cur_STATE_ONLY_FAKE",
                           "cursorAuth/cachedEmail": "cursor@example.test",
                           "cursorAuth/stripeMembershipType": "ultra"])
        let own = jwt(expiresIn: 30 * 86_400)
        let http = ScriptedCursorHTTP([(200, usageJSON)])
        let outcome = await CursorUsage.fetch(home: home, now: now,
                                              store: MemoryCursorTokenStore(.init(accessToken: own, refreshToken: own)),
                                              http: http)
        guard case .ok(let reading) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(reading.email, "cursor@example.test")
        XCTAssertEqual(reading.validOtherModelsPct, 100)
        let auth = http.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(auth, ["Bearer \(own)"])
    }

    func testRenewsBeforeExpiryAndSavesTheNewToken() async {
        let soon = jwt(expiresIn: 3 * 86_400)
        let fresh = jwt(expiresIn: 60 * 86_400)
        let store = MemoryCursorTokenStore(.init(accessToken: soon, refreshToken: soon))
        let http = ScriptedCursorHTTP([(200, #"{"access_token":"\#(fresh)"}"#), (200, usageJSON)])
        let outcome = await CursorUsage.fetch(home: home, now: now, store: store, http: http)
        if case .ok = outcome {} else { XCTFail("\(outcome)") }
        XCTAssertEqual(http.requests.first?.url, CursorSignIn.tokenURL)
        XCTAssertEqual(store.load(), .init(accessToken: fresh, refreshToken: fresh))
    }

    func testShouldLogoutClearsTheSignIn() async {
        let soon = jwt(expiresIn: 3 * 86_400)
        let store = MemoryCursorTokenStore(.init(accessToken: soon, refreshToken: soon))
        let outcome = await CursorUsage.fetch(home: home, now: now, store: store,
                                              http: ScriptedCursorHTTP([(200, #"{"shouldLogout":true}"#)]))
        XCTAssertEqual(outcome, .connectNeeded(CursorUsage.signedOutReason))
        XCTAssertNil(store.load())
    }

    func testRefusalOfTowersTokenAsksToConnectAgain() async {
        let own = jwt(expiresIn: 30 * 86_400)
        let outcome = await CursorUsage.fetch(home: home, now: now,
                                              store: MemoryCursorTokenStore(.init(accessToken: own, refreshToken: own)),
                                              http: ScriptedCursorHTTP([(401, "")]))
        XCTAssertEqual(outcome, .connectNeeded(CursorUsage.refusedOwnReason(code: 401)))
        XCTAssertTrue(CursorUsage.needsConnect(CursorUsage.refusedOwnReason(code: 401)))
    }

    func testCursorAppDatabaseIsOnlyEverReadReadOnly() {
        XCTAssertEqual(CursorAuth.sqliteArguments(db: CursorAuth.stateDB(home: home), key: "k").first, "-readonly")
    }

    // MARK: Store

    func testRowWithoutSignInReadsConnectAndKeepsOldNumbersAging() throws {
        try seedCursorApp(["cursorAuth/cachedEmail": "cursor@example.test",
                           "cursorAuth/stripeMembershipType": "ultra"])
        let key = AccountSnapshot.storeKey(email: "cursor@example.test", provider: .cursor)
        var old = AccountSnapshot(email: "cursor@example.test", nickname: "cursor", plan: "ultra")
        old.provider = .cursor
        old.weeklyPct = 30
        old.capturedAt = now.addingTimeInterval(-8 * 86_400)
        let store = Store(dir: home.appendingPathComponent("support"), now: { [now] in now })
        _ = store.mutate { accounts in
            accounts[key] = old
            _ = store.seedCursorAccount(into: &accounts, outcome: .connectNeeded(CursorUsage.connectReason),
                                        home: home, now: now)
        }
        let row = try XCTUnwrap(store.load()[key])
        XCTAssertEqual(row.lastError, CursorUsage.connectReason)
        XCTAssertEqual(row.weeklyPct, 30, "old numbers are kept, not zeroed")
        XCTAssertEqual(row.capturedAt, old.capturedAt, "capturedAt is never refreshed by a failure")
    }
}
