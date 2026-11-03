import Foundation
import XCTest
@testable import Tower

/// Muse, Devin and Antigravity rows in the shared store and its mirror
/// (`quota-cache.json`, the file the dispatcher and quota-guard read).
///
/// The rule these tests pin, from the old `AgentLane` warning: a lane row with no usage
/// evidence must NEVER read as headroom. It is closed by the row's shape. An unreadable
/// lane has no pct key and no capture time, so a mirror reader computing room returns nothing and skips
/// it, and a fleet summary drops it. Everything below reads the real mirror
/// BYTES, not the in-memory rows, because the bytes are what the consumers see.
final class AgentLaneMirrorTests: XCTestCase {
    /// `muse usage --json` as printed on 2026-10-31 (Muse Code 1.4.14). Nothing in it
    /// identifies an account: tier, two windows, an as-of time.
    private static let museWire = """
    {"schemaVersion":1,"allowance":{"tier":"Muse Code Power Usage",\
    "window":{"usedPercent":0,"resetsAtMs":1793452583000},\
    "weekly":{"usedPercent":1,"resetsAtMs":1793577600000},\
    "asOfMs":1793444569598,"source":"mint"},"reason":null,"hint":null}
    """
    private static let asOf = Date(timeIntervalSince1970: 1_793_444_569.598)

    private var dir: URL!
    private var mirror: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        mirror = dir.appendingPathComponent("claude/quota-cache.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(now: Date) -> Store {
        Store(dir: dir, mirror: mirror, now: { now })
    }

    private func mirrorRows() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: mirror)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    }

    private func reading(_ lane: Provider, _ usage: AgentLane.UsageRead) -> AgentLane.Outcome {
        .ok(AgentLane.Reading(provider: lane, configModel: nil, lastDispatch: nil,
                              lastLimitHit: nil, usage: usage))
    }

    private func fold(_ s: Store, _ outcomes: [Provider: AgentLane.Outcome], now: Date) {
        _ = s.mutate { accounts in
            s.seedAgentLaneAccounts(into: &accounts, outcomes: outcomes, now: now)
        }
    }

    // MARK: Muse wire

    func testMuseUsageDecodesTheRecordedWireShape() throws {
        guard case .quota(let q) = AgentLane.museUsage(data: Data(Self.museWire.utf8)) else {
            return XCTFail("recorded muse usage must decode to a quota")
        }
        XCTAssertEqual(q.dailyRemainingPct, 100, "usedPercent 0 is 100 remaining")
        XCTAssertEqual(q.weeklyRemainingPct, 99)
        XCTAssertEqual(q.shortLabel, "Window")
        XCTAssertEqual(q.source, "live")
        XCTAssertEqual(q.plan, "Muse Code Power Usage")
        XCTAssertEqual(q.dailyResetsAt, Date(timeIntervalSince1970: 1_793_452_583))
        XCTAssertEqual(q.fetchedAt, Self.asOf)
    }

    func testMuseNotLoggedInIsNamedNeverZero() {
        let text = "muse usage: not logged in: run 'muse login' first."
        guard case .notReadable(let why) = AgentLane.museUsage(data: Data(text.utf8)) else {
            return XCTFail("a login refusal is not a reading")
        }
        XCTAssertTrue(why.contains("not logged in"), why)
    }

    func testMuseReasonFieldIsCarriedVerbatim() {
        let wire = #"{"schemaVersion":1,"allowance":null,"reason":"rate limited, retry later"}"#
        guard case .notReadable(let why) = AgentLane.museUsage(data: Data(wire.utf8)) else {
            return XCTFail("no allowance is not a reading")
        }
        XCTAssertTrue(why.contains("rate limited, retry later"), why)
    }

    /// A zero tool time is "no time". It must never become a Date that encodes as a
    /// negative capturedAt, which platform's `capturedAt >= 0` rejects for the whole file.
    func testZeroToolTimeIsAbsentNotEpochZero() throws {
        let muse = Self.museWire.replacingOccurrences(of: "\"asOfMs\":1793444569598", with: "\"asOfMs\":0")
        XCTAssertTrue(muse != Self.museWire, "fixture rewrite must have changed the wire")
        guard case .quota(let mq) = AgentLane.museUsage(data: Data(muse.utf8)) else {
            return XCTFail("percentages still decode")
        }
        XCTAssertNil(mq.fetchedAt, "asOfMs 0 is absent, like resetsAtMs 0")

        let devinWire = String(decoding: AgentLaneTests.devinStatusJSON(), as: UTF8.self)
            .replacingOccurrences(of: "\"fetched_at_secs\":\(AgentLaneTests.statusFetched)",
                                  with: "\"fetched_at_secs\":0")
        XCTAssertTrue(devinWire.contains("\"fetched_at_secs\":0"), "fixture rewrite must have changed the wire")
        let dq = try XCTUnwrap(AgentLane.devinUserStatus(data: Data(devinWire.utf8)))
        XCTAssertNil(dq.fetchedAt, "fetched_at_secs 0 is absent")
    }

    func testPublishableQuotaRefusesAToolTimeBeforeTheReferenceDate() {
        func quota(_ at: Date?) -> AgentLane.Outcome {
            reading(.devin, .quota(AgentLane.Quota(
                plan: nil, dailyRemainingPct: 50, weeklyRemainingPct: 50,
                dailyResetsAt: nil, weeklyResetsAt: nil, fetchedAt: at)))
        }
        XCTAssertNil(AgentLane.publishableQuota(quota(Date(timeIntervalSince1970: 0))))
        XCTAssertNil(AgentLane.publishableQuota(quota(Date(timeIntervalSince1970: 978_307_199))),
                     "one second before 2001-01-01 encodes negative")
        XCTAssertNotNil(AgentLane.publishableQuota(quota(Date(timeIntervalSince1970: 978_307_200))),
                        "the reference date itself encodes as 0 and is allowed")
        XCTAssertNil(AgentLane.publishableQuota(quota(Date(timeIntervalSince1970: .infinity))))
    }

    func testMuseOutOfRangePercentIsUnreadableNotClamped() {
        let wire = #"{"allowance":{"window":{"usedPercent":150},"weekly":{"usedPercent":-3},"asOfMs":1}}"#
        guard case .notReadable = AgentLane.museUsage(data: Data(wire.utf8)) else {
            return XCTFail("an impossible percent must not become a number")
        }
    }

    // MARK: Muse spawns only when asked

    func testMuseIsNotSpawnedUnlessARunnerIsInjected() throws {
        let home = dir.appendingPathComponent("home")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let muse = bin.appendingPathComponent("muse")
        try "#!/bin/sh\n".write(to: muse, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: muse.path)

        guard case .ok(let plain) = AgentLane.read(.muse, home: home, env: [:]) else {
            return XCTFail("installed muse reads")
        }
        XCTAssertEqual(plain.usage, .notExposed, "a plain read starts no process")

        var calls = 0
        guard case .ok(let live) = AgentLane.read(.muse, home: home, env: [:], museRunner: { url in
            calls += 1
            XCTAssertEqual(url.lastPathComponent, "muse")
            return Data(Self.museWire.utf8)
        }) else { return XCTFail("installed muse reads") }
        XCTAssertEqual(calls, 1)
        guard case .quota = live.usage else { return XCTFail("runner output must become a quota") }

        guard case .ok(let silent) = AgentLane.read(.muse, home: home, env: [:],
                                                    museRunner: { _ in nil }) else {
            return XCTFail("installed muse reads")
        }
        guard case .notReadable = silent.usage else {
            return XCTFail("a runner with no output is unreadable, never a number")
        }
    }

    // MARK: Mirror bytes

    func testLiveMuseRowPublishesUsedPercentWithToolObservationTime() throws {
        let now = Self.asOf.addingTimeInterval(30)
        let s = store(now: now)
        guard case .quota(let q) = AgentLane.museUsage(data: Data(Self.museWire.utf8)) else {
            return XCTFail("decode")
        }
        fold(s, [.muse: reading(.muse, .quota(q))], now: now)

        let row = try XCTUnwrap(try mirrorRows()["muse:muse@local"])
        XCTAssertEqual(row["provider"] as? String, "muse")
        XCTAssertEqual(row["fiveHourPct"] as? Double, 0, "short window, percent USED")
        XCTAssertEqual(row["weeklyPct"] as? Double, 1)
        XCTAssertEqual(row["source"] as? String, "live")
        XCTAssertNotNil(row["readAt"])
        XCTAssertNotNil(row["capturedAt"])
        XCTAssertNil(row["lastError"])
        let labels = (row["scoped"] as? [[String: Any]])?.compactMap { $0["label"] as? String }
        XCTAssertEqual(labels, ["Window", "Weekly"])
    }

    /// An unreadable lane has NO row. Platform's Tower snapshot requires `capturedAt` on
    /// every row and validates the file at once, so one row without it turns every account
    /// unknown. The reason is not lost: it stays in `tower_lanes` over MCP.
    func testUnreadableLanesPublishNoRowAtAll() throws {
        let now = Self.asOf
        let s = store(now: now)
        _ = s.mutate { accounts in
            var seat = AccountSnapshot(email: "seat@example.test", nickname: "seat", plan: "max")
            seat.fiveHourPct = 10
            seat.capturedAt = now
            accounts[seat.id] = seat
        }
        fold(s, [
            .muse: reading(.muse, .notReadable("Muse is not logged in")),
            .devin: reading(.devin, .notReadable("no user status cache on disk")),
            .agy: reading(.agy, .notExposed),
        ], now: now)

        let keys = Set(try mirrorRows().keys)
        XCTAssertEqual(keys, ["seat@example.test"], "no lane row may appear: \(keys)")
    }

    func testAFailedReadRemovesThePreviousRowInsteadOfKeepingItsNumbers() throws {
        let now = Self.asOf
        let s = store(now: now)
        guard case .quota(let q) = AgentLane.museUsage(data: Data(Self.museWire.utf8)) else {
            return XCTFail("decode")
        }
        fold(s, [.muse: reading(.muse, .quota(q))], now: now)
        XCTAssertNotNil(try mirrorRows()["muse:muse@local"]?["weeklyPct"])

        fold(s, [.muse: reading(.muse, .notReadable("did not answer"))], now: now.addingTimeInterval(300))
        XCTAssertNil(try mirrorRows()["muse:muse@local"],
                     "an old capture must not outlive a failed read")
    }

    /// The invariant platform depends on, over every outcome shape a lane can produce. The
    /// numbers are read from the mirror BYTES, and the scan count is asserted so an empty
    /// scan cannot pass as clean.
    func testNoLaneRowInTheMirrorEverLacksACaptureTime() throws {
        let now = Self.asOf
        let s = store(now: now)
        guard case .quota(let live) = AgentLane.museUsage(data: Data(Self.museWire.utf8)) else {
            return XCTFail("decode")
        }
        let aged = AgentLane.Quota(
            plan: "Devin Pro", dailyRemainingPct: 40, weeklyRemainingPct: 80,
            dailyResetsAt: now.addingTimeInterval(3600), weeklyResetsAt: now.addingTimeInterval(86_400),
            fetchedAt: now.addingTimeInterval(-2 * 3600))
        let noTime = AgentLane.Quota(
            plan: nil, dailyRemainingPct: 10, weeklyRemainingPct: 10,
            dailyResetsAt: nil, weeklyResetsAt: nil, fetchedAt: nil)
        let zeroTime = AgentLane.Quota(
            plan: nil, dailyRemainingPct: 10, weeklyRemainingPct: 10, dailyResetsAt: nil,
            weeklyResetsAt: nil, fetchedAt: Date(timeIntervalSince1970: 0))
        let preReference = AgentLane.Quota(
            plan: nil, dailyRemainingPct: 10, weeklyRemainingPct: 10, dailyResetsAt: nil,
            weeklyResetsAt: nil, fetchedAt: Date(timeIntervalSince1970: 978_307_199))
        let shapes: [[Provider: AgentLane.Outcome]] = [
            [.muse: reading(.muse, .quota(live)), .devin: reading(.devin, .quota(aged)),
             .agy: reading(.agy, .notExposed)],
            [.muse: reading(.muse, .notReadable("x")), .devin: reading(.devin, .quota(noTime)),
             .agy: .unavailable("config unreadable")],
            [.muse: reading(.muse, .quota(zeroTime)), .devin: reading(.devin, .quota(preReference)),
             .agy: reading(.agy, .quota(zeroTime))],
            [.muse: .notConfigured, .devin: reading(.devin, .notReadable("no cache")),
             .agy: reading(.agy, .notExposed)],
        ]
        var scanned = 0
        for shape in shapes {
            fold(s, shape, now: now)
            let rows = try mirrorRows()
            for (key, row) in rows where row["provider"] != nil {
                scanned += 1
                let captured = row["capturedAt"] as? Double
                XCTAssertNotNil(captured, "\(key) lacks a numeric capturedAt")
                XCTAssertTrue((captured ?? -1) >= 0, "\(key) capturedAt \(String(describing: captured)) is negative; platform requires >= 0")
            }
        }
        XCTAssertEqual(scanned, 2,
                       "only the first shape publishes (muse live, devin cache); an empty scan must not pass")
    }

    func testDevinCacheReadTwoHoursLaterIsStaleNotLive() throws {
        let observed = Self.asOf.addingTimeInterval(-2 * 3600)
        let now = Self.asOf
        let quota = AgentLane.Quota(
            plan: "Devin Pro", dailyRemainingPct: 40, weeklyRemainingPct: 80,
            dailyResetsAt: now.addingTimeInterval(3600), weeklyResetsAt: now.addingTimeInterval(86_400),
            fetchedAt: observed)
        let s = store(now: now)
        fold(s, [.devin: reading(.devin, .quota(quota))], now: now)

        let snap = try XCTUnwrap(s.load()["devin:devin@local"])
        XCTAssertEqual(snap.fiveHourPct, 60, "40 remaining is 60 used")
        XCTAssertEqual(snap.weeklyPct, 20)
        XCTAssertEqual(snap.capturedAt, observed, "capturedAt is the cache's own fetch time")
        XCTAssertEqual(snap.source, "cache")
        XCTAssertEqual(snap.readAt, now)
        XCTAssertNotEqual(snap.worstTrust(now: now), .live)
        XCTAssertNil(snap.trustedUsedPct(now: now), "a stale cache is not evidence about now")
        XCTAssertFalse(snap.isRecommendable(now: now))
    }

    func testQuotaWithoutAReadTimeIsNotPublished() throws {
        let now = Self.asOf
        let quota = AgentLane.Quota(
            plan: nil, dailyRemainingPct: 10, weeklyRemainingPct: 10,
            dailyResetsAt: nil, weeklyResetsAt: nil, fetchedAt: nil)
        XCTAssertNil(AgentLane.publishableQuota(reading(.devin, .quota(quota))),
                     "numbers with no age cannot be aged, so they are not published")
        let s = store(now: now)
        fold(s, [.devin: reading(.devin, .quota(quota))], now: now)
        XCTAssertNil(s.load()["devin:devin@local"])
    }

    // MARK: The dispatcher rule

    func testAgentLaneRowsNeverCompeteForRoomAndUnknownIsNeverRoom() throws {
        let now = Self.asOf
        let s = store(now: now)
        guard case .quota(let q) = AgentLane.museUsage(data: Data(Self.museWire.utf8)) else {
            return XCTFail("decode")
        }
        let aged = AgentLane.Quota(
            plan: "Devin Pro", dailyRemainingPct: 90, weeklyRemainingPct: 95,
            dailyResetsAt: now.addingTimeInterval(3600), weeklyResetsAt: now.addingTimeInterval(86_400),
            fetchedAt: now.addingTimeInterval(-2 * 3600))
        fold(s, [
            .muse: reading(.muse, .quota(q)),
            .devin: reading(.devin, .quota(aged)),
            .agy: reading(.agy, .notExposed),
        ], now: now)
        let rows = Array(s.load().values)
        XCTAssertEqual(rows.count, 2, "muse live and devin cache; agy has nothing to publish")

        for lane in AgentLane.mirrorLanes {
            XCTAssertFalse(lane.isRankable, "\(lane) is never ranked for a seat")
        }
        let split = AccountSnapshot.partition(rows, now: now)
        XCTAssertTrue(split.active.filter { $0.kind.isRankable }.isEmpty,
                      "no agent lane may enter the room list")
        for row in rows where row.kind == .devin {
            XCTAssertNil(row.trustedUsedPct(now: now), "a stale cache has no usage figure")
            XCTAssertFalse(row.isRecommendable(now: now), "a stale cache is never room")
        }
    }

    func testLaneNotProbedThisCycleIsLeftAloneAndUninstalledLaneLosesItsRow() throws {
        let now = Self.asOf
        let s = store(now: now)
        guard case .quota(let q) = AgentLane.museUsage(data: Data(Self.museWire.utf8)) else {
            return XCTFail("decode")
        }
        fold(s, [.muse: reading(.muse, .quota(q))], now: now)
        fold(s, [:], now: now.addingTimeInterval(60))
        XCTAssertNotNil(try mirrorRows()["muse:muse@local"], "no outcome means no change")
        fold(s, [.muse: .notConfigured], now: now.addingTimeInterval(120))
        XCTAssertNil(try mirrorRows()["muse:muse@local"], "an uninstalled lane has no row")
    }

    // MARK: tower status

    /// Lane rows no longer reach the store without a capture time, but an older store file
    /// or a hand edit could still hold one. The render must read it as unknown.
    func testLaneRowWithNoCaptureStatusLinePrintsQuestionMarkNotPercent() {
        var snap = AccountSnapshot(email: "muse@local", nickname: "muse", plan: "lane")
        snap.provider = .muse
        snap.lastError = "Muse is not logged in"
        let text = CLI.agentLaneStatusRowLines(snap, now: Self.asOf).joined(separator: "\n")
        XCTAssertTrue(text.contains("? Muse is not logged in"), text)
        XCTAssertFalse(text.contains("%"), "an unreadable lane prints no percentage: \(text)")
    }

    func testLiveLaneStatusLinesNameTheirWindowsNotFiveHourAndSevenDay() throws {
        let now = Self.asOf.addingTimeInterval(30)
        var snap = AccountSnapshot(email: "muse@local", nickname: "muse", plan: "lane")
        snap.provider = .muse
        guard case .quota(let q) = AgentLane.museUsage(data: Data(Self.museWire.utf8)) else {
            return XCTFail("decode")
        }
        AgentLane.apply(q, observedAt: Self.asOf, to: &snap, now: now)
        let text = CLI.agentLaneStatusRowLines(snap, now: now).joined(separator: "\n")
        XCTAssertTrue(text.contains("Window"), text)
        XCTAssertTrue(text.contains("Weekly"), text)
        XCTAssertFalse(text.contains("5h"), text)
        XCTAssertFalse(text.contains("7d"), text)
    }
}
