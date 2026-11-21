import XCTest
@testable import Tower

/// 2026-10-28: Devin showed 100% left (read 10:27) and Cursor 0% used (read 5 days
/// earlier) while both were exhausted. A reading older than the freshness TTL is
/// unknown, never room, and never recommended, for every lane and not only Claude.
final class LaneStaleRoomTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let fiveDays: TimeInterval = 5 * 86_400

    private func cursorSeat(age: TimeInterval) -> AccountSnapshot {
        var seat = AccountSnapshot(email: "cursor@example.test", nickname: "cursor", plan: "ultra")
        seat.provider = .cursor
        seat.capturedAt = now.addingTimeInterval(-age)
        seat.weeklyPct = 0
        seat.weeklyResetsAt = now.addingTimeInterval(86_400)
        seat.scoped = [
            ScopedLimit(label: CursorPool.autoLabel, percent: 0, resetsAt: now.addingTimeInterval(86_400)),
            ScopedLimit(label: CursorPool.meteredLabel, percent: 0, resetsAt: now.addingTimeInterval(86_400)),
        ]
        return seat
    }

    private func cursorReading() -> AgentLane.Reading {
        AgentLane.Reading(provider: .cursor, configModel: nil, lastDispatch: nil,
                          lastLimitHit: nil, usage: .notReadable("quota lives in-session"))
    }

    private func devinReading(fetchedAgo: TimeInterval?) -> AgentLane.Reading {
        let q = AgentLane.Quota(
            plan: "pro", dailyRemainingPct: 100, weeklyRemainingPct: 100,
            dailyResetsAt: now.addingTimeInterval(3_600), weeklyResetsAt: now.addingTimeInterval(86_400),
            fetchedAt: fetchedAgo.map { now.addingTimeInterval(-$0) })
        return AgentLane.Reading(provider: .devin, configModel: nil, lastDispatch: nil,
                                 lastLimitHit: nil, usage: .quota(q))
    }

    func testFiveDayOldCursorRowHasUnknownRoomAndIsNotRecommended() {
        let seat = cursorSeat(age: fiveDays)
        let r = cursorReading()
        XCTAssertNil(AgentLane.roomPct(r, cursorSeat: seat, now: now), "5-day-old Cursor row must not report room")
        XCTAssertFalse(AgentLane.isRecommendable(r, cursorSeat: seat, now: now))
        let header = AgentLane.headerDetail(r, cursorSeat: seat, now: now)
        XCTAssertTrue(header.contains("?"), "stale header says unknown: \(header)")
        XCTAssertFalse(header.contains("0%"), "stale header must not print the old 0% used: \(header)")
        XCTAssertTrue(AgentLane.meters(r, cursorSeat: seat, now: now).isEmpty, "no meters from a stale seat")
    }

    func testFreshCursorRowStillReportsRoom() {
        let seat = cursorSeat(age: 60)
        let r = cursorReading()
        XCTAssertEqual(AgentLane.roomPct(r, cursorSeat: seat, now: now), 100)
        XCTAssertTrue(AgentLane.isRecommendable(r, cursorSeat: seat, now: now))
    }

    func testHoursOldDevinStatusIsUnknownNotOneHundredPercent() {
        let r = devinReading(fetchedAgo: 4 * 3_600)
        XCTAssertNil(AgentLane.roomPct(r, cursorSeat: nil, now: now))
        XCTAssertFalse(AgentLane.isRecommendable(r, cursorSeat: nil, now: now))
        let header = AgentLane.headerDetail(r, cursorSeat: nil, now: now)
        XCTAssertFalse(header.contains("100%"), "stale Devin header must not claim 100% left: \(header)")
        XCTAssertTrue(header.contains("?"), header)
        XCTAssertNil(AgentLane.usageLine(r, cursorSeat: nil, now: now).flatMap { $0.contains("100%") ? $0 : nil })
        XCTAssertTrue(AgentLane.meters(r, cursorSeat: nil, now: now).isEmpty)
    }

    func testDevinStatusWithNoFetchTimeIsUnknown() {
        let r = devinReading(fetchedAgo: nil)
        XCTAssertNil(AgentLane.roomPct(r, cursorSeat: nil, now: now))
        XCTAssertFalse(AgentLane.isRecommendable(r, cursorSeat: nil, now: now))
    }

    func testFreshDevinStatusReportsRoom() {
        let r = devinReading(fetchedAgo: 60)
        XCTAssertEqual(AgentLane.roomPct(r, cursorSeat: nil, now: now), 100)
        XCTAssertTrue(AgentLane.isRecommendable(r, cursorSeat: nil, now: now))
        XCTAssertTrue(AgentLane.headerDetail(r, cursorSeat: nil, now: now).contains("100% left"))
    }

    func testLanesWithNoUsageReadingAreNeverRecommended() {
        for p in [Provider.muse, .agy] {
            let r = AgentLane.Reading(provider: p, configModel: nil, lastDispatch: nil, lastLimitHit: nil)
            XCTAssertNil(AgentLane.roomPct(r, cursorSeat: nil, now: now))
            XCTAssertFalse(AgentLane.isRecommendable(r, cursorSeat: nil, now: now))
        }
    }
}
