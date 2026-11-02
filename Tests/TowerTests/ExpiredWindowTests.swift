import Foundation
import XCTest
@testable import Tower

/// Issue #17 ask 2: a window whose reset has passed reads as 0% used until the next capture,
/// in scoring, in rendered detail, and in the bytes other tools read from quota-cache.json.
/// Capture freshness still gates recommendation (#32), so these fixtures are captured inside
/// the TTL and only the window itself has expired.
final class ExpiredWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func row(_ nick: String, five: Double, fiveReset: TimeInterval,
                     weekly: Double, weeklyReset: TimeInterval,
                     capturedAgo: TimeInterval = 600) -> AccountSnapshot {
        AccountSnapshot(
            email: "\(nick)@example.test", nickname: nick, plan: "max",
            fiveHourPct: five, fiveHourResetsAt: now.addingTimeInterval(fiveReset),
            weeklyPct: weekly, weeklyResetsAt: now.addingTimeInterval(weeklyReset),
            capturedAt: now.addingTimeInterval(-capturedAgo))
    }

    func testExpiredFiveHourWindowScoresZeroAndIsRecommendable() {
        let expired = row("expired", five: 90, fiveReset: -60, weekly: 30, weeklyReset: 3 * 86_400)
        let busy = row("busy", five: 50, fiveReset: 3_600, weekly: 50, weeklyReset: 3 * 86_400)

        XCTAssertEqual(expired.effectiveFiveHour(now: now).pct, 0)
        XCTAssertEqual(expired.headroomPct(now: now), 30)
        XCTAssertEqual(expired.trustedHeadroomPct(now: now), 30)
        XCTAssertTrue(expired.isRecommendable(now: now))
        XCTAssertNil(expired.restingReason(now: now))
        XCTAssertTrue(AccountSnapshot.ranked(expired, busy, now: now), "90% from a reset window must not rank")
        XCTAssertEqual(AccountSnapshot.partition([busy, expired], now: now).active.map(\.nickname),
                       ["expired", "busy"])
        guard case .switchTo(let nick, let pct, _) = AccountSnapshot.advise(
            activeEmail: busy.email, accounts: [busy, expired], now: now)
        else { return XCTFail("Expected a switch to the account whose 5h window reset") }
        XCTAssertEqual(nick, "expired")
        XCTAssertEqual(pct, 30)

        let lines = CLI.statusRowLines(expired, activeEmail: nil, refreshError: nil, now: now)
        XCTAssertTrue(lines.contains { $0.contains("5h") && $0.contains("0%") && $0.contains("reset ✓") },
                      "got \(lines)")
        XCTAssertFalse(lines.contains { $0.contains("90%") }, "got \(lines)")
    }

    func testExpiredWeeklyWindowScoresZeroAndIsRecommendable() {
        let expired = row("weekly", five: 20, fiveReset: 3_600, weekly: 90, weeklyReset: -60)
        XCTAssertEqual(expired.effectiveWeekly(now: now).pct, 0)
        XCTAssertEqual(expired.trustedHeadroomPct(now: now), 20)
        XCTAssertTrue(expired.isRecommendable(now: now))
    }

    func testStoreWritesExpiredWindowsAsZeroInBothFilesWithCaptureKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        let store = Store(dir: dir, mirror: mirror, now: { self.now })
        let expired = row("expired", five: 90, fiveReset: -60, weekly: 30, weeklyReset: 3 * 86_400)

        XCTAssertNil(store.save([expired.email: expired]))
        let bytes = try Data(contentsOf: mirror)
        XCTAssertEqual(bytes, try Data(contentsOf: dir.appendingPathComponent("accounts.json")))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]])
        let written = try XCTUnwrap(json[expired.email])
        XCTAssertEqual(written["fiveHourPct"] as? Double, 0)
        XCTAssertEqual(written["weeklyPct"] as? Double, 30)
        XCTAssertEqual(store.load()[expired.email]?.capturedAt, expired.capturedAt)
        XCTAssertEqual(store.load()[expired.email]?.fiveHourResetsAt, expired.fiveHourResetsAt)
    }

    /// The drawer's per-window detail printed the stored percentage. Rows reach the view from
    /// the last save, so a window that resets between polls kept showing its old number.
    @MainActor
    func testDrawerDetailReadsExpiredWindowsAsZero() {
        let fiveExpired = row("capped", five: 90, fiveReset: -60, weekly: 97, weeklyReset: 3 * 86_400)
        let fiveLines = RestingDrawer.limitWindows(fiveExpired, now: now)
        XCTAssertEqual(fiveLines.first, "5h: 0% used · reset ✓", "got \(fiveLines)")
        XCTAssertFalse(fiveLines.contains { $0.contains("90%") }, "got \(fiveLines)")

        let weeklyExpired = row("capped5h", five: 97, fiveReset: 3_600, weekly: 90, weeklyReset: -60)
        let weeklyLines = RestingDrawer.limitWindows(weeklyExpired, now: now)
        XCTAssertEqual(weeklyLines.last, "7d: 0% used · reset ✓", "got \(weeklyLines)")
        XCTAssertFalse(weeklyLines.contains { $0.contains("90%") }, "got \(weeklyLines)")
    }

    /// quota-cache.json is only rewritten on a save, and the app saves every five minutes.
    /// The app needs the instant a stored percentage stops being true so it can rewrite the
    /// mirror then, instead of leaving the old number for the quota-guard hook to read.
    func testNextWindowExpiryNamesTheSoonestStoredPercentToGoStale() throws {
        var a = row("a", five: 90, fiveReset: 60, weekly: 30, weeklyReset: 3 * 86_400)
        a.scoped = [ScopedLimit(label: "Fable", percent: 50, resetsAt: now.addingTimeInterval(30))]
        let b = row("b", five: 40, fiveReset: 20, weekly: 10, weeklyReset: 86_400)
        let emptyWindow = row("c", five: 0, fiveReset: 5, weekly: 0, weeklyReset: 5)
        let unknown = AccountSnapshot(email: "u@example.test", nickname: "u", plan: "?")

        XCTAssertEqual(AccountSnapshot.nextWindowExpiry([a, emptyWindow, unknown]),
                       now.addingTimeInterval(30), "scoped limits count, 0% windows do not")
        XCTAssertEqual(AccountSnapshot.nextWindowExpiry([a, b, unknown]), now.addingTimeInterval(20))
        XCTAssertNil(AccountSnapshot.nextWindowExpiry([emptyWindow, unknown]))

        // A sweep at that instant rewrites the mirror without touching the capture.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        var clock = now
        let store = Store(dir: dir, mirror: mirror, now: { clock })
        XCTAssertNil(store.save([b.email: b]))
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: mirror))
            as? [String: [String: Any]])
        XCTAssertEqual(before[b.email]?["fiveHourPct"] as? Double, 40)

        clock = try XCTUnwrap(AccountSnapshot.nextWindowExpiry([b]))
        let swept = store.mutate { _ in }
        XCTAssertNil(swept.saveError)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: mirror))
            as? [String: [String: Any]])
        XCTAssertEqual(after[b.email]?["fiveHourPct"] as? Double, 0)
        XCTAssertEqual(after[b.email]?["weeklyPct"] as? Double, 10)
        XCTAssertEqual(store.load()[b.email]?.capturedAt, b.capturedAt)
        XCTAssertEqual(AccountSnapshot.nextWindowExpiry(swept.accounts.values),
                       b.weeklyResetsAt, "once swept, the next expiry moves on")
    }
}
