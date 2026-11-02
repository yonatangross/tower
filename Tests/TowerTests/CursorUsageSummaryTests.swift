import XCTest
@testable import Tower

final class CursorUsageSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testDashboardPoolReadingUsesTighterPoolAndClearsDollarBalance() {
        let reset = now.addingTimeInterval(86_400)
        let reading = CursorUsage.Reading(
            email: "cursor@example.test", plan: "ultra", cursorModelsPct: 73,
            otherModelsPct: 80, periodResetsAt: reset)
        var snapshot = AccountSnapshot(email: reading.email, nickname: "cursor", plan: "ultra")
        snapshot.creditBalance = "$2059.10 of $200 used"

        CursorUsage.apply(reading, to: &snapshot, now: now)

        XCTAssertEqual(snapshot.weeklyPct, 80, "ranker takes the tighter dashboard pool")
        XCTAssertEqual(snapshot.scoped.map(\.label), ["Cursor Models", "Other Models"])
        XCTAssertEqual(snapshot.scoped.map(\.percent), [73, 80])
        XCTAssertEqual(snapshot.scoped.map(\.resetsAt), [reset, reset])
        XCTAssertNil(snapshot.creditBalance, "removes derived dollar balance")
        XCTAssertNil(snapshot.lastError)
    }

    func testMissingOrInvalidDashboardPoolStaysUnknown() {
        let reset = now.addingTimeInterval(86_400)
        for (cursor, other) in [(73.0, Optional<Double>.none), (101.0, 80.0)] {
            let reading = CursorUsage.Reading(
                email: "cursor@example.test", plan: "ultra", cursorModelsPct: cursor,
                otherModelsPct: other, periodResetsAt: reset)
            var snapshot = AccountSnapshot(email: reading.email, nickname: "cursor", plan: "ultra")
            CursorUsage.apply(reading, to: &snapshot, now: now)

            XCTAssertNil(snapshot.weeklyPct, "unreadable pool never becomes a synthetic percentage")
            XCTAssertEqual(snapshot.lastError,
                           "Cursor did not return two valid dashboard pool percentages")
        }
    }
}
