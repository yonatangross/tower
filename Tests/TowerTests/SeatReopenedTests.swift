import XCTest
@testable import Tower

/// A window whose reset has passed is known to have reopened, even when the capture
/// that described it is stale. The board says so instead of printing "due" for a
/// reset that is over, or the old window's percentage as if it still applied. It
/// never makes the seat recommendable: that still needs every ranked window live.
final class SeatReopenedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func seat(_ nick: String, age: TimeInterval,
                      five: Double, fiveReset: TimeInterval,
                      weekly: Double, weeklyReset: TimeInterval) -> AccountSnapshot {
        var row = AccountSnapshot(email: "\(nick)@example.com", nickname: nick, plan: "max")
        row.capturedAt = now.addingTimeInterval(-age)
        row.fiveHourPct = five
        row.fiveHourResetsAt = now.addingTimeInterval(fiveReset)
        row.weeklyPct = weekly
        row.weeklyResetsAt = now.addingTimeInterval(weeklyReset)
        return row
    }

    func testCountdownNamesAPassedResetAsReopenedNeverDue() {
        XCTAssertEqual(BoardText.countdown(now.addingTimeInterval(-(16 * 3_600 + 120)), now: now),
                       "reopened 16h 2m ago")
        XCTAssertEqual(BoardText.countdown(now.addingTimeInterval(-3 * 86_400), now: now),
                       "reopened 3d 0h ago")
        XCTAssertEqual(BoardText.countdown(now, now: now), "reopened just now")
        XCTAssertEqual(BoardText.countdown(now.addingTimeInterval(-30), now: now), "reopened just now")
        for ago: TimeInterval in [0, 30, 3_600, 86_400, 2_592_000] {
            XCTAssertFalse(BoardText.countdown(now.addingTimeInterval(-ago), now: now).contains("due"))
        }
        // Future dates are unchanged.
        XCTAssertEqual(BoardText.countdown(now.addingTimeInterval(42 * 60), now: now), "42m")
        XCTAssertEqual(BoardText.countdown(now.addingTimeInterval(20), now: now), "1m")
        XCTAssertEqual(BoardText.countdown(now.addingTimeInterval(2 * 3_600 + 60), now: now), "2h 1m")
        XCTAssertEqual(BoardText.countdown(nil, now: now), "-")
    }

    func testStaleSeatWhoseWindowsAllPassedReadsReopenedAndStaysUnranked() {
        // Captured two days ago at 80 / 90, both windows reset since.
        var gone = seat("fay", age: 2 * 86_400, five: 80, fiveReset: -16 * 3_600,
                        weekly: 90, weeklyReset: -3_600)
        gone.lastError = "needs login"

        let display = SeatUsagePresentation(account: gone, now: now)
        XCTAssertEqual(display.roomText, "100%", "Both windows reopened: the old 80 / 90 no longer apply")
        XCTAssertEqual(display.stateText, "stale cache 2d 0h", "The capture is still old and says so")
        XCTAssertFalse(display.isLive)
        XCTAssertEqual(display.reopened,
                       SeatUsagePresentation.Reopened(windows: "5h+7d", at: now.addingTimeInterval(-3_600)))

        guard let rest = AccountSnapshot.partition([gone], now: now).resting.first?.1 else {
            return XCTFail("A stale seat must rest")
        }
        // A stale row is an action: the reset column asks for the switch, and the passed
        // resets ride under the pill as the reason to make it.
        XCTAssertEqual(SeatUsagePresentation.resetCell(gone, rest: rest, now: now), .switchToCheck)
        XCTAssertEqual(SeatUsagePresentation.reopenedNote(gone, rest: rest, now: now),
                       "5h+7d reopened 1h 0m ago")
        XCTAssertEqual(SeatBoardRow.roomCell(usage: display, rest: rest), "?",
                       "A stale row prints no room it cannot stand behind")

        XCTAssertFalse(gone.isRecommendable(now: now), "Reopened is not live")
        XCTAssertNil(gone.trustedUsedPct(now: now))
        let fresh = seat("fresh", age: 60, five: 50, fiveReset: 3_600, weekly: 50, weeklyReset: 86_400)
        guard case .stay(let nick, _, let next) =
                AccountSnapshot.advise(activeEmail: fresh.email, accounts: [gone, fresh], now: now)
        else { return XCTFail("Expected to stay on the only live seat") }
        XCTAssertEqual(nick, "fresh")
        XCTAssertNil(next, "A reopened but stale seat must not be offered as next")
    }

    func testStaleSeatWithOnePassedAndOneFutureWindowKeepsTheFutureWindowsCachedRoom() {
        let mixed = seat("dee", age: 22 * 3_600, five: 60, fiveReset: -3 * 3_600,
                         weekly: 85, weeklyReset: 2 * 86_400)

        let display = SeatUsagePresentation(account: mixed, now: now)
        XCTAssertEqual(display.roomText, "15%", "The 7d window has not reset, so its cached 85 still binds")
        XCTAssertEqual(display.stateText, "stale cache 22h 0m")
        XCTAssertEqual(display.reopened,
                       SeatUsagePresentation.Reopened(windows: "5h", at: now.addingTimeInterval(-3 * 3_600)))
        XCTAssertEqual(SeatUsagePresentation.resetCell(mixed, rest: .stale(22 * 3_600), now: now),
                       .switchToCheck)
        XCTAssertEqual(SeatUsagePresentation.reopenedNote(mixed, rest: .stale(22 * 3_600), now: now),
                       "5h reopened 3h 0m ago")
        XCTAssertFalse(mixed.isRecommendable(now: now))
    }

    func testStaleSeatWithNothingReopenedStillAsksForASwitch() {
        let old = seat("old", age: 3_600, five: 40, fiveReset: 3_600, weekly: 40, weeklyReset: 86_400)
        XCTAssertNil(SeatUsagePresentation(account: old, now: now).reopened)
        XCTAssertEqual(SeatUsagePresentation.resetCell(old, rest: .stale(3_600), now: now), .switchToCheck)
        XCTAssertNil(SeatUsagePresentation.reopenedNote(old, rest: .stale(3_600), now: now))
    }

    func testLiveSeatWhoseBindingWindowJustResetSaysReopenedNotDue() {
        // Captured 10 minutes ago, both windows reset 2 minutes ago: live, and every
        // reset the row could point at is behind it.
        let live = seat("live", age: 600, five: 70, fiveReset: -120, weekly: 20, weeklyReset: -120)
        XCTAssertTrue(live.isRecommendable(now: now))
        XCTAssertEqual(SeatUsagePresentation.resetCell(live, rest: nil, now: now),
                       .reopened("5h+7d · 2m ago"))
    }

    func testFutureResetsKeepTheirCountdown() {
        let live = seat("live", age: 60, five: 30, fiveReset: 90 * 60, weekly: 20, weeklyReset: 86_400)
        guard case .countdown(let text, _) =
                SeatUsagePresentation.resetCell(live, rest: nil, now: now)
        else { return XCTFail("Expected a countdown") }
        XCTAssertEqual(text, "1h 30m")
    }

    /// The store zeroes a passed window on load and save. The board must read the same
    /// before and after that round trip, so neither path can show the old percentage.
    func testBoardReadsTheSameBeforeAndAfterTheStoreFlattensAPassedWindow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seat-reopened-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir, now: { self.now })
        let raw = seat("fay", age: 17 * 3_600, five: 90, fiveReset: -16 * 3_600,
                       weekly: 24, weeklyReset: 4 * 86_400)

        XCTAssertNil(store.save([raw.email: raw]))
        let stored = try XCTUnwrap(store.load()[raw.email])
        XCTAssertEqual(stored.fiveHourPct, 0, "Precondition: the store flattened the passed window")

        let before = SeatUsagePresentation(account: raw, now: now)
        let after = SeatUsagePresentation(account: stored, now: now)
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.roomText, "76%")
        XCTAssertEqual(before.reopened?.windows, "5h")
    }
}
