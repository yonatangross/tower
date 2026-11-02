import XCTest
@testable import Tower

private final class ResultBox<V>: @unchecked Sendable { var value: V? }

/// Cursor's state.vscdb stopped storing a JWT in `cursorAuth/accessToken` (measured
/// 2026-10-31: 603 chars, no dots, prefix "cur"). `CursorAuth.identity` used to demand a JWT,
/// so it returned nil, the fetch said "not configured", and the row aged for 7.8 days with
/// no `lastError`: a silent stale, which is the false signal this app exists to prevent.
/// These tests pin the replacement behaviour: the seat stays addressable and the failure
/// is named, never silence.
final class CursorOpaqueTokenTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-opaque-\(UUID().uuidString)", isDirectory: true)
        let dir = CursorAuth.stateDB(home: home).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Builds the same ItemTable the real db has, with fake values only.
    private func seed(_ rows: [String: String]) throws {
        let db = CursorAuth.stateDB(home: home)
        var sql = "create table ItemTable (key text unique on conflict replace, value blob);"
        for (k, v) in rows { sql += "insert into ItemTable values ('\(k)','\(v)');" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db.path, sql]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "fixture db built")
    }

    func testOpaqueTokenKeepsTheSeatAddressableUsingTheStoredSubject() throws {
        try seed([
            "cursorAuth/accessToken": "cur_fake_opaque_token_no_dots",
            "cursorAuth/cachedEmail": "cursor@example.test",
            "cursorAuth/stripeMembershipAuthId": "google-oauth2|user_FAKE",
            "cursorAuth/stripeMembershipType": "ultra",
        ])
        let id = try XCTUnwrap(CursorAuth.identity(home: home),
                               "an opaque token must not read as no Cursor lane")
        XCTAssertEqual(id.email, "cursor@example.test")
        XCTAssertEqual(id.subject, "google-oauth2|user_FAKE")
        XCTAssertTrue(id.opaqueToken)
    }

    func testJwtTokenIsNotMarkedOpaque() throws {
        // header.payload.signature, payload {"sub":"google-oauth2|user_FAKE"}
        let payload = Data(#"{"sub":"google-oauth2|user_FAKE"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        try seed([
            "cursorAuth/accessToken": "eyJhbGciOiJub25lIn0.\(payload).sig",
            "cursorAuth/cachedEmail": "cursor@example.test",
        ])
        let id = try XCTUnwrap(CursorAuth.identity(home: home))
        XCTAssertEqual(id.subject, "google-oauth2|user_FAKE")
        XCTAssertFalse(id.opaqueToken)
    }

    func testNoCursorInstallStillMeansNoLane() {
        XCTAssertNil(CursorAuth.identity(home: home), "no db is a normal state, not an error")
    }

    func testOpaqueTokenWithNoSubjectAnywhereIsAnError() throws {
        try seed(["cursorAuth/accessToken": "cur_fake_opaque_token_no_dots"])
        XCTAssertNil(CursorAuth.identity(home: home),
                     "no subject means no honest cookie: not addressable")
    }

    // MARK: End to end, fetch then store

    /// Runs an async call to completion from a synchronous test. The path under test
    /// returns before any network request, so nothing is awaited on a socket.
    private func blocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private func oldCursorRow(email: String, now: Date) -> (key: String, snap: AccountSnapshot) {
        var snap = AccountSnapshot(email: email, nickname: "cursor", plan: "ultra")
        snap.provider = .cursor
        snap.weeklyPct = 30
        snap.weeklyResetsAt = now.addingTimeInterval(86_400)
        snap.capturedAt = now.addingTimeInterval(-8 * 86_400)
        return (AccountSnapshot.storeKey(email: email, provider: .cursor), snap)
    }

    /// The 2026-10-23 failure on the path the first fix missed: an opaque token AND no
    /// stored subject. Identity cannot be built, which used to read as `.notConfigured`,
    /// so the store left the old row alone with no `lastError` and it aged silently.
    func testOpaqueTokenWithNoSubjectNamesTheErrorAndKeepsTheOldNumbersStale() throws {
        try seed([
            "cursorAuth/accessToken": "cur_fake_opaque_token_no_dots",
            "cursorAuth/cachedEmail": "cursor@example.test",
        ])
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (key, old) = oldCursorRow(email: "cursor@example.test", now: now)
        let fakeHome = home!

        let outcome = blocking { await CursorUsage.fetch(home: fakeHome, now: now) }
        XCTAssertEqual(outcome, .identityUnreadable(CursorUsage.identityUnreadableReason),
                       "a login that cannot become an identity is not an absent lane")

        let mirror = home.appendingPathComponent("claude/quota-cache.json")
        let store = Store(dir: home.appendingPathComponent("support"), mirror: mirror, now: { now })
        _ = store.mutate { accounts in
            accounts[key] = old
            _ = store.seedCursorAccount(into: &accounts, outcome: outcome, home: fakeHome, now: now)
        }

        let row = try XCTUnwrap(store.load()[key])
        XCTAssertEqual(row.lastError, CursorUsage.identityUnreadableReason,
                       "the reason must be written onto the existing row")
        XCTAssertEqual(row.weeklyPct, 30, "old numbers are kept, not zeroed")
        XCTAssertEqual(row.capturedAt, old.capturedAt, "capturedAt must never be refreshed")
        XCTAssertNotEqual(row.worstTrust(now: now), .live, "8 day old numbers read stale")
        XCTAssertNil(row.trustedUsedPct(now: now), "stale numbers are not evidence about now")

        // The mirror bytes are what the consumers read.
        let bytes = try Data(contentsOf: mirror)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]])
        XCTAssertEqual(rows[key]?["lastError"] as? String, CursorUsage.identityUnreadableReason)
    }

    func testUnreadableIdentityInventsNoRowWhenNothingWasEverCaptured() throws {
        try seed(["cursorAuth/accessToken": "cur_fake_opaque_token_no_dots"])
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fakeHome = home!
        let outcome = blocking { await CursorUsage.fetch(home: fakeHome, now: now) }
        let store = Store(dir: home.appendingPathComponent("support"), now: { now })
        _ = store.mutate { accounts in
            _ = store.seedCursorAccount(into: &accounts, outcome: outcome, home: fakeHome, now: now)
        }
        XCTAssertTrue(store.load().isEmpty, "nothing to age means no row, and never a number")
    }

    func testNoCursorInstallStillLeavesAnOldRowAloneWithNoError() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let (key, old) = oldCursorRow(email: "cursor@example.test", now: now)
        let fakeHome = home!
        let outcome = blocking { await CursorUsage.fetch(home: fakeHome, now: now) }
        XCTAssertEqual(outcome, .notConfigured, "no db at all is the normal no-Cursor state")
        let store = Store(dir: home.appendingPathComponent("support"), now: { now })
        _ = store.mutate { accounts in
            accounts[key] = old
            _ = store.seedCursorAccount(into: &accounts, outcome: outcome, home: fakeHome, now: now)
        }
        XCTAssertNil(store.load()[key]?.lastError, "absence is not an error")
    }

    func testRefusalForAnOpaqueTokenNamesTheFormatNotJustExpiry() {
        let opaque = CursorUsage.refusedError(code: 401, opaqueToken: true)
        XCTAssertTrue(opaque.contains("HTTP 401"))
        XCTAssertTrue(opaque.contains("not a JWT"),
                      "a format change must not read as a plain expired session: \(opaque)")
        let plain = CursorUsage.refusedError(code: 401, opaqueToken: false)
        XCTAssertTrue(plain.contains("Sign in again"), plain)
    }
}
