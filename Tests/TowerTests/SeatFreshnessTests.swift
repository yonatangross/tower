import XCTest
@testable import Tower

final class SeatFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func seat(_ nick: String, age: TimeInterval, used: Double = 20,
                      resetAgo: TimeInterval? = nil) -> AccountSnapshot {
        var row = AccountSnapshot(email: "\(nick)@example.com", nickname: nick, plan: "max")
        row.capturedAt = now.addingTimeInterval(-age)
        row.fiveHourPct = used
        row.weeklyPct = used
        row.fiveHourResetsAt = now.addingTimeInterval(resetAgo.map { -$0 } ?? 3_600)
        row.weeklyResetsAt = now.addingTimeInterval(resetAgo.map { -$0 } ?? 86_400)
        return row
    }

    func testRecentResetCannotReviveCaptureOlderThanShortestWindow() {
        let old = seat("old", age: 5 * 3_600 + 1, resetAgo: 1)
        XCTAssertFalse(old.isRecommendable(now: now), "Old capture must not regain room after reset")
        XCTAssertNil(old.trustedHeadroomPct(now: now))
    }

    func testCaptureTTLBoundaryIsIndependentOfReset() {
        let boundary = seat("boundary", age: AccountSnapshot.freshnessTTL, resetAgo: 1)
        let expired = seat("expired", age: AccountSnapshot.freshnessTTL + 1, resetAgo: 1)
        XCTAssertTrue(boundary.isRecommendable(now: now))
        XCTAssertFalse(expired.isRecommendable(now: now), "Reset must not extend the capture TTL")
    }

    func testStaleRowsNeverSortByCachedRoom() {
        let busy = seat("alpha", age: 3_600, used: 90)
        let roomy = seat("zulu", age: 3_600, used: 1)
        XCTAssertTrue(AccountSnapshot.ranked(busy, roomy, now: now), "Stale rows use stable name order")
        XCTAssertFalse(AccountSnapshot.ranked(roomy, busy, now: now))
    }

    func testEveryRestRuleExcludesStaleAndUnknownRowsFromActiveRanking() {
        let fresh = seat("fresh", age: 60)
        let stale = seat("stale", age: 3_600)
        let unknown = AccountSnapshot(email: "unknown@example.com", nickname: "unknown", plan: "max")
        for rule in AccountSnapshot.RestRule.allCases {
            let split = AccountSnapshot.partition([stale, unknown, fresh], rule: rule, now: now)
            XCTAssertEqual(split.active.map(\.nickname), ["fresh"], "Rule \(rule) must exclude unknown room")
            XCTAssertEqual(Set(split.resting.map { $0.0.nickname }), ["stale", "unknown"])
        }
    }

    func testStaleRestingSeatIsNeverNext() {
        let fresh = seat("fresh", age: 60)
        let old = seat("old", age: 86_401)
        let advice = AccountSnapshot.advise(activeEmail: fresh.email, accounts: [fresh, old], now: now)
        guard case .stay(_, _, let next) = advice else { return XCTFail("Expected to stay on fresh seat") }
        XCTAssertNil(next, "A stale resting seat must not become next")
    }

    func testStaleActiveSeatCannotOverrideFreshRecommendation() {
        let old = seat("old", age: 3_600, used: 1)
        let fresh = seat("fresh", age: 60, used: 50)
        let advice = AccountSnapshot.advise(activeEmail: old.email, accounts: [old, fresh], now: now)
        guard case .switchTo(let nick, _, _) = advice else { return XCTFail("Expected fresh recommendation") }
        XCTAssertEqual(nick, fresh.nickname)
    }

    func testRotateSeparatesUnknownAgeFromUsableRoom() {
        let fresh = seat("fresh", age: 60)
        let old = seat("old", age: 4 * 3_600, used: 2)
        let report = CLI.rotateReport(accounts: [old, fresh], switchProfiles: [
            old.email: ChromeProfileHint(displayName: "Old Profile", chooserEmail: nil),
            fresh.email: ChromeProfileHint(displayName: "Fresh Profile", chooserEmail: nil),
        ], now: now)
        XCTAssertEqual(report.seats.map(\.nickname), ["fresh"])
        XCTAssertTrue(report.lines.contains { $0.contains("unknown since 4h ago") && $0.contains("Old Profile") })
        XCTAssertFalse(report.lines.contains { $0.contains("98%") })
    }

    func testStatusHidesStalePercentagesEvenForActiveSeat() {
        let old = seat("old", age: 3_600, used: 42)
        let lines = CLI.statusRowLines(old, activeEmail: old.email, refreshError: nil, now: now)
        XCTAssertTrue(lines.contains { $0.contains("unknown since 1h ago") })
        XCTAssertFalse(lines.contains { $0.contains("42%") }, "Cached usage is not current room")
    }

    func testStaleBoardUsageLabelsCachedRoomAndItsAgeWithoutMakingItLive() {
        // Both resets still ahead: a passed reset reads as reopened, see SeatReopenedTests.
        var old = seat("dee", age: 4 * 3_600 + 40 * 60, used: 80)
        old.lastError = "needs login"

        let display = SeatUsagePresentation(account: old, now: now)

        XCTAssertEqual(display.roomText, "20%")
        XCTAssertEqual(display.stateText, "read 4h 40m ago")
        XCTAssertFalse(display.isLive)
        XCTAssertFalse(old.isRecommendable(now: now), "Cached room must not rank a stale seat")
    }

    func testLiveBoardUsageKeepsCurrentRoomWithoutCachedState() {
        let fresh = seat("fresh", age: 60, used: 80)
        let display = SeatUsagePresentation(account: fresh, now: now)

        XCTAssertEqual(display.roomText, "20%")
        XCTAssertEqual(display.stateText, "")
        XCTAssertTrue(display.isLive)
        XCTAssertTrue(fresh.isRecommendable(now: now))
    }

    func testNeverCapturedBoardUsageDoesNotInventARoom() {
        let unknown = AccountSnapshot(
            email: "unknown@example.test", nickname: "unknown", plan: "max", fiveHourPct: 80,
            weeklyPct: 80)
        let display = SeatUsagePresentation(account: unknown, now: now)

        XCTAssertEqual(display.roomText, "?")
        XCTAssertEqual(display.stateText, "no data")
        XCTAssertFalse(display.isLive)
    }

    func testCappedAndStaleBoardLabelKeepsTheCacheAge() {
        let oldCap = seat("oldcap", age: 3 * 86_400, used: 100)
        guard let reason = oldCap.restingReason(now: now), case .cappedAndStale = reason else {
            return XCTFail("Expected capped stale reason")
        }

        XCTAssertEqual(
            SeatUsagePresentation.restLabel(reason, account: oldCap, now: now),
            "cap · read 3d 0h ago"
        )
    }

    func testFutureCaptureIsStaleAndNamesClockSkew() {
        let future = seat("future", age: -60, used: 80)
        let display = SeatUsagePresentation(account: future, now: now)

        XCTAssertEqual(display.roomText, "20%")
        XCTAssertEqual(display.stateText, "read time ahead of this clock (clock skew)")
        XCTAssertFalse(display.isLive)
        XCTAssertFalse(future.isRecommendable(now: now))
    }
}
