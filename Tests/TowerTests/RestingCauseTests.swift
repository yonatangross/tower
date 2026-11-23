import XCTest
@testable import Tower

/// A resting or failed seat row names its real cause instead of "unknown since", and the
/// fix it names is the right one per provider. Every value here is invented.
final class RestingCauseTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("resting-cause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: CursorAuth.stateDB(home: home).deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// The same ItemTable the Cursor app keeps, with fake values only. It supplies the row's
    /// label (email and plan), never a token Tower would send.
    private func seedCursorApp(email: String) throws {
        // A test may seed more than once, so the table is created only when it is missing.
        let sql = "create table if not exists ItemTable (key text unique on conflict replace, value blob);"
            + "insert into ItemTable values ('cursorAuth/cachedEmail','\(email)');"
            + "insert into ItemTable values ('cursorAuth/stripeMembershipType','ultra');"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [CursorAuth.stateDB(home: home).path, sql]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "fixture db built")
    }

    private func seat(_ nick: String, week: Double?, agoHours: Double,
                      provider: Provider = .claude, error: String? = nil) -> AccountSnapshot {
        var a = AccountSnapshot(email: "\(nick)@example.test", nickname: nick, plan: "max")
        a.provider = provider
        a.weeklyPct = week
        a.weeklyResetsAt = now.addingTimeInterval(86_400)
        a.capturedAt = now.addingTimeInterval(-agoHours * 3_600)
        a.lastError = error
        return a
    }

    // MARK: Cause words

    func testAStoredCauseBeatsUnknownInTheRowWords() {
        let login = seat("lo", week: 90, agoHours: 72, error: AccountSnapshot.needsLoginText)
        XCTAssertEqual(login.restingCause, "needs login")

        let refused = seat("rf", week: 60, agoHours: 72, provider: .cursor,
                           error: CursorUsage.refusedOwnReason(code: 401))
        XCTAssertEqual(refused.restingCause, "session refused")

        let usageRefused = seat("ur", week: 60, agoHours: 72, provider: .cursor,
                                error: "Cursor refused the usage read (HTTP 401).")
        XCTAssertEqual(usageRefused.restingCause, "session refused")

        let notConnected = seat("nc", week: 60, agoHours: 72, provider: .cursor,
                                error: CursorUsage.connectReason)
        XCTAssertEqual(notConnected.restingCause, "not connected")

        let network = seat("nf", week: 30, agoHours: 72, provider: .cursor,
                           error: "could not read Cursor usage (network, or the response "
                               + "did not parse)")
        XCTAssertEqual(network.restingCause, "read failed")

        XCTAssertNil(seat("ok", week: 10, agoHours: 72).restingCause,
                     "no stored reason keeps the honest unknown")
    }

    func testAStaleRowWithNoStoredCauseStillSaysUnknownSince() {
        let stale = seat("old", week: 10, agoHours: 120)
        let reason = stale.restingReason(now: now)!
        XCTAssertEqual(stale.restingStateText(reason, now: now), "unknown since 5d ago")
        XCTAssertEqual(CLI.restingRowState(stale, reason, now: now), "unknown since 5d ago")
    }

    func testTheDrawerAndTheCLIUseTheSameWords() {
        let login = seat("lo", week: 40, agoHours: 72, error: AccountSnapshot.needsLoginText)
        let reason = login.restingReason(now: now)!
        XCTAssertEqual(RestingDrawer.state(login, reason, now: now), "needs login · 3d ago")
        XCTAssertEqual(CLI.restingRowState(login, reason, now: now), "needs login · 3d ago")

        let refused = seat("rf", week: 60, agoHours: 29 * 24, provider: .cursor,
                           error: CursorUsage.refusedOwnReason(code: 401))
        let refusedReason = refused.restingReason(now: now)!
        XCTAssertEqual(RestingDrawer.state(refused, refusedReason, now: now),
                       "session refused · 29d ago")
        XCTAssertEqual(CLI.restingRowState(refused, refusedReason, now: now),
                       "session refused · 29d ago")
    }

    func testAvailableSummaryAndLimitWindowsLeadWithTheCause() {
        let refused = seat("rf", week: 60, agoHours: 72, provider: .cursor,
                           error: CursorUsage.refusedOwnReason(code: 401))
        XCTAssertEqual(RestingDrawer.limitWindows(refused, now: now), ["session refused · 3d ago"])

        var never = AccountSnapshot(email: "nv@example.test", nickname: "nv", plan: "?")
        never.lastError = AccountSnapshot.needsLoginText
        XCTAssertEqual(RestingDrawer.limitWindows(never, now: now), ["needs login"])
    }

    // MARK: Per provider fix

    func testACursorRefusalNamesConnectCursorNeverASignInInTheCursorApp() {
        for error in [CursorUsage.refusedOwnReason(code: 401),
                      CursorUsage.connectReason,
                      CursorUsage.signedOutReason,
                      "Cursor refused the usage read (HTTP 401)."] {
            let row = seat("cu", week: 60, agoHours: 72, provider: .cursor, error: error)
            let reason = row.restingReason(now: now)!
            XCTAssertEqual(RestingDrawer.action(row, reason, now: now), "connect Cursor", error)
        }
    }

    func testANetworkFailureDoesNotPrescribeAConnect() {
        let row = seat("nf", week: 60, agoHours: 120, provider: .cursor,
                       error: "could not read Cursor usage (network, or the response "
                           + "did not parse)")
        let reason = row.restingReason(now: now)!
        XCTAssertEqual(RestingDrawer.state(row, reason, now: now), "read failed · 5d ago")
        XCTAssertEqual(RestingDrawer.action(row, reason, now: now), "retry on refresh")
    }

    func testOnlyAClaudeRowGetsTheSwitchRemedy() {
        let claude = seat("cl", week: 10, agoHours: 120)
        let codex = seat("cx", week: 10, agoHours: 120, provider: .codex)
        XCTAssertEqual(RestingDrawer.action(claude, claude.restingReason(now: now)!, now: now),
                       "switch to check")
        XCTAssertEqual(RestingDrawer.action(codex, codex.restingReason(now: now)!, now: now),
                       "run a session")
    }

    // MARK: Failed poll versus last capture

    func testAFailedPollIsToldApartFromTheLastCapture() {
        var row = seat("ar", week: 60, agoHours: 5 * 24, provider: .cursor,
                       error: CursorUsage.refusedOwnReason(code: 401))
        row.readAt = now.addingTimeInterval(-3_600)
        let reason = row.restingReason(now: now)!
        XCTAssertNotNil(row.failedPollAt)
        XCTAssertEqual(RestingDrawer.state(row, reason, now: now),
                       "session refused · last poll failed 1h ago · captured 5d ago")
    }

    func testAReadOlderThanTheCaptureIsNotAFailedPoll() {
        var row = seat("ol", week: 60, agoHours: 2, provider: .cursor,
                       error: "could not read Cursor usage (network, or the response "
                           + "did not parse)")
        row.readAt = now.addingTimeInterval(-5 * 3_600)
        XCTAssertNil(row.failedPollAt)
    }

    func testABindingCapSurvivesAFailedRefresh() {
        var row = seat("cp", week: 99, agoHours: 2, provider: .cursor,
                       error: CursorUsage.refusedOwnReason(code: 401))
        row.readAt = now.addingTimeInterval(-120)
        let reason = row.restingReason(now: now)!
        let text = RestingDrawer.state(row, reason, now: now)
        XCTAssertTrue(text.contains("session refused"), text)
        XCTAssertTrue(text.contains("last poll failed 2m ago"), text)
        XCTAssertTrue(text.contains("captured 2h ago"), text)
        XCTAssertEqual(CLI.restingRowState(row, reason, now: now), text)
    }

    // MARK: Store stamps the attempt

    private func seedOutcome(_ outcome: CursorUsage.Outcome, existing: AccountSnapshot?) throws
        -> AccountSnapshot {
        try seedCursorApp(email: "cursor@example.test")
        let key = AccountSnapshot.storeKey(email: "cursor@example.test", provider: .cursor)
        let store = Store(dir: home.appendingPathComponent("support"), now: { [now] in now })
        _ = store.mutate { accounts in
            if let existing { accounts[key] = existing }
            _ = store.seedCursorAccount(into: &accounts, outcome: outcome, home: home, now: now)
        }
        return try XCTUnwrap(store.load()[key])
    }

    private func oldCursorRow() -> AccountSnapshot {
        var old = AccountSnapshot(email: "cursor@example.test", nickname: "cursor", plan: "ultra")
        old.provider = .cursor
        old.weeklyPct = 30
        old.capturedAt = now.addingTimeInterval(-8 * 86_400)
        return old
    }

    func testEveryAttemptedFailureStampsReadAtAndLeavesCapturedAtAlone() throws {
        let old = oldCursorRow()
        let outcomes: [CursorUsage.Outcome] = [
            .rejected(401),
            .unavailable,
            .connectNeeded(CursorUsage.connectReason),
        ]
        for outcome in outcomes {
            let row = try seedOutcome(outcome, existing: old)
            XCTAssertEqual(row.readAt, now, "\(outcome): the attempt is stamped")
            XCTAssertEqual(row.capturedAt, old.capturedAt,
                           "\(outcome): a failure never refreshes the numbers' age")
            XCTAssertEqual(row.failedPollAt, now, "\(outcome)")
        }
    }

    func testASuccessfulReadStampsReadAtToo() throws {
        let reading = CursorUsage.Reading(
            email: "cursor@example.test", plan: "ultra", cursorModelsPct: 20,
            otherModelsPct: 30, periodResetsAt: now.addingTimeInterval(86_400))
        let row = try seedOutcome(.ok(reading), existing: oldCursorRow())
        XCTAssertEqual(row.readAt, now)
        XCTAssertEqual(row.capturedAt, now)
        XCTAssertNil(row.failedPollAt, "a good read leaves no failed poll")
    }
}
