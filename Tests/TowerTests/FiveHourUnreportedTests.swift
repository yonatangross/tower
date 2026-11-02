import XCTest
@testable import Tower

/// A Claude reply can carry a weekly window and no 5-hour one (observed 2026-11-01 on an active max
/// seat captured seconds earlier). The 2026-08-03 rule stays:
/// a missing 5h reading is genuinely unknown, so the seat does not rank (the API may hide a full 5h
/// window). What changes is what the panel SAYS: the row names the missing
/// window instead of "stale", and the answer stays on the active seat with its weekly room instead of
/// sending the operator to a busier seat.
final class FiveHourUnreportedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func claude(_ nick: String, age: TimeInterval, fiveHour: Double?, weekly: Double?) -> AccountSnapshot {
        var row = AccountSnapshot(email: "\(nick)@example.com", nickname: nick, plan: "max")
        row.capturedAt = now.addingTimeInterval(-age)
        row.fiveHourPct = fiveHour
        row.weeklyPct = weekly
        row.fiveHourResetsAt = fiveHour == nil ? nil : now.addingTimeInterval(3_600)
        row.weeklyResetsAt = weekly == nil ? nil : now.addingTimeInterval(86_400)
        return row
    }

    func testTheRuleIsUnchanged() {
        let eve = claude("eve", age: 30, fiveHour: nil, weekly: 8)
        XCTAssertEqual(eve.worstTrust(now: now), .unknown, "a missing 5h reading stays unknown (08-03 rule)")
        XCTAssertFalse(eve.isRecommendable(now: now))
    }

    func testTheSeatKnowsItsFiveHourWindowIsUnreported() {
        XCTAssertTrue(claude("eve", age: 30, fiveHour: nil, weekly: 8).fiveHourUnreported(now: now))
        XCTAssertFalse(claude("both", age: 30, fiveHour: 0, weekly: 8).fiveHourUnreported(now: now),
                       "a 5h reading is there")
        XCTAssertFalse(claude("old", age: AccountSnapshot.freshnessTTL + 60, fiveHour: nil, weekly: 8)
                           .fiveHourUnreported(now: now), "an old capture is plain stale")
        XCTAssertFalse(claude("empty", age: 30, fiveHour: nil, weekly: nil).fiveHourUnreported(now: now),
                       "no reading at all is not this case")
        var codex = claude("cx", age: 30, fiveHour: nil, weekly: 8)
        codex.provider = .codex
        XCTAssertFalse(codex.fiveHourUnreported(now: now), "Codex has no 5h window to report")
    }

    func testTheRowSaysFiveHourNotReported() {
        let eve = claude("eve", age: 30, fiveHour: nil, weekly: 8)
        let rest = AccountSnapshot.RestReason.stale(30)
        XCTAssertEqual(SeatUsagePresentation.restLabel(rest, account: eve, now: now), "5h not reported")
        XCTAssertEqual(RestingDrawer.state(eve, rest, now: now), "5h not reported")
        let old = claude("old", age: 3 * 3_600, fiveHour: 10, weekly: 8)
        XCTAssertTrue(SeatUsagePresentation.restLabel(.stale(3 * 3_600), account: old, now: now).hasPrefix("stale"),
                      "a real stale row keeps its words")
    }

    func testTheRowIsShownNotFoldedIntoStale() {
        // the branch panelshot 2026-11-01 15:5x: the answer was right but the eve row sat inside
        // "+ 3 stale", so its "5h not reported" label could not be seen
        let eve = claude("eve", age: 30, fiveHour: nil, weekly: 8)
        XCTAssertFalse(SeatBoard.isFolded(.stale(30), account: eve, now: now), "the seat shows its own row")
        let old = claude("old", age: 3 * 86_400, fiveHour: 10, weekly: 8)
        XCTAssertTrue(SeatBoard.isFolded(.stale(3 * 86_400), account: old, now: now), "a real stale seat still folds")
    }

    func testTheAnswerStaysOnTheActiveSeatWithItsWeeklyRoom() {
        let eve = claude("eve", age: 30, fiveHour: nil, weekly: 8)
        var accountB = claude("account-b", age: 30, fiveHour: 0, weekly: 31)
        accountB.plan = "team"
        let advice = AccountSnapshot.advise(activeEmail: eve.email, accounts: [eve, accountB], now: now)
        XCTAssertEqual(advice, .activeFiveHourUnknown(nick: "eve", weekRoomPct: 92, next: "account-b"))
        XCTAssertNil(advice.command, "nothing to run: the operator is already on the seat")
    }

    // HOLD 6560661767 (review-opus-b10): the branch held him on a seat whose week was used up.
    // A missing 5h window may hide a full one, so a capped week must fall through to the switch.
    func testACappedWeekFallsThroughToTheSwitch() {
        let eve = claude("eve", age: 30, fiveHour: nil, weekly: 100)
        var accountB = claude("account-b", age: 30, fiveHour: 0, weekly: 31)
        accountB.plan = "team"
        let advice = AccountSnapshot.advise(activeEmail: eve.email, accounts: [eve, accountB], now: now)
        XCTAssertEqual(advice, .switchTo(nick: "account-b", pct: 31, via: nil), "a used-up week is not a seat to stay on")
        let atCap = claude("eve", age: 30, fiveHour: nil, weekly: AccountSnapshot.cappedPct)
        XCTAssertEqual(AccountSnapshot.advise(activeEmail: atCap.email, accounts: [atCap, accountB], now: now),
                       .switchTo(nick: "account-b", pct: 31, via: nil), "the cap line itself falls through too")
    }

    func testTheGapIsMarkedUnknownNotStay() {
        XCTAssertEqual(RecommendBanner.glyph(for: .activeFiveHourUnknown(nick: "eve", weekRoomPct: 92, next: nil)), "?",
                       "a seat whose 5h is unknown is not drawn with the stay mark")
        XCTAssertEqual(RecommendBanner.glyph(for: .stay(nick: "eve", pct: 1, next: nil)), "✓")
    }

    func testAnActiveSeatWithAFiveHourReadingIsAdvisedAsBefore() {
        let eve = claude("eve", age: 30, fiveHour: 0, weekly: 8)
        var accountB = claude("account-b", age: 30, fiveHour: 0, weekly: 31)
        accountB.plan = "team"
        let advice = AccountSnapshot.advise(activeEmail: eve.email, accounts: [eve, accountB], now: now)
        XCTAssertEqual(advice, .stay(nick: "eve", pct: 8, next: "account-b"))
    }
}
