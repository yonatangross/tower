import XCTest
@testable import Tower

/// The popover layout approved by the operator 2026-11-01 ~16:45 (hqw-build desk,
/// tower-popover/approved-design/mockup.txt): the answer first in room terms, one section per pool
/// with one bar per seat and a state word, warnings one line each, sessions and lanes folded to a
/// count. Type sizes stay HEAD's (22/18/16/15 at M), a deliberate deviation approved by review.
final class PopoverMockupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func claude(_ nick: String, weekly: Double, fiveHour: Double? = 0, age: TimeInterval = 30,
                        plan: String = "max") -> AccountSnapshot {
        var row = AccountSnapshot(email: "\(nick)@example.com", nickname: nick, plan: plan)
        row.capturedAt = now.addingTimeInterval(-age)
        row.weeklyPct = weekly
        row.weeklyResetsAt = now.addingTimeInterval(3 * 86_400)
        row.fiveHourPct = fiveHour
        row.fiveHourResetsAt = fiveHour == nil ? nil : now.addingTimeInterval(3_600)
        return row
    }

    // ANSWER: the pick and its ROOM, in words
    func testTheAnswerSpeaksInRoom() {
        XCTAssertEqual(RecommendBanner.headline(.stay(nick: "eve", pct: 1, next: "ops3")), "Stay on eve · 99% room")
        XCTAssertEqual(RecommendBanner.headline(.switchTo(nick: "ops3", pct: 31, via: nil)), "Switch to ops3 · 69% room")
        XCTAssertEqual(RecommendBanner.headline(.stay(nick: "eve", pct: nil, next: nil)), "Stay on eve")
        XCTAssertEqual(RecommendBanner.headline(.activeUnknown(nick: "ops3", roomPct: 69, via: nil)),
                       "Active seat unknown · most room ops3 69%")
        XCTAssertEqual(RecommendBanner.headline(.allResting(first: nil)), "No ready Claude seat")
        XCTAssertEqual(RecommendBanner.headline(.activeFiveHourUnknown(nick: "eve", weekRoomPct: 92, next: "ops3")),
                       "eve: 5h unknown, week 92% room")
    }



    // TABLE: the state is a word
    func testTheStateIsAWord() {
        let active = claude("eve", weekly: 1)
        XCTAssertEqual(SeatBoardRow.stateWord(account: active, rest: nil, activeEmail: active.email, now: now), "in use")
        XCTAssertEqual(SeatBoardRow.stateWord(account: claude("ops3", weekly: 31), rest: nil, activeEmail: active.email, now: now), "ready")
        XCTAssertEqual(SeatBoardRow.stateWord(account: claude("ops2", weekly: 90), rest: nil, activeEmail: active.email, now: now), "near cap")
        XCTAssertEqual(SeatBoardRow.stateWord(account: claude("alt4", weekly: 66, fiveHour: 96), rest: nil, activeEmail: active.email, now: now), "5h full")
        // the 2026-11-01 render: alt4 at 5h 93% (binding, 7% room) read "ready"
        XCTAssertEqual(SeatBoardRow.stateWord(account: claude("alt4", weekly: 66, fiveHour: 93), rest: nil, activeEmail: active.email, now: now), "near cap")
        XCTAssertEqual(SeatBoardRow.stateWord(account: claude("alt3", weekly: 97), rest: .capped(97), activeEmail: active.email, now: now), "capped")
        XCTAssertEqual(SeatBoardRow.stateWord(account: claude("old", weekly: 10, age: 3 * 86_400), rest: .stale(3 * 86_400), activeEmail: active.email, now: now), "stale")
        XCTAssertEqual(SeatBoardRow.stateWord(account: claude("new", weekly: 10), rest: .neverCaptured, activeEmail: active.email, now: now), "no data")
    }

    // TABLE: one section per pool
    func testEachPoolHasItsOwnHeading() {
        XCTAssertEqual(SeatBoard.poolHeading(.claude, count: 7), "Claude · 7 seats")
        XCTAssertEqual(SeatBoard.poolHeading(.codex, count: 1), "Codex · 1 seat")
        XCTAssertEqual(SeatBoard.poolHeading(.cursor, count: 1), "Cursor · 1 seat")
    }

    // TABLE: the line under the name fits the seat column: plan and state, the product is the
    // pool heading above (the 2026-11-01 render cut "claude code team · ready" to "claude code team...")
    func testThePlanLineCarriesTheStateAndFits() {
        let active = claude("eve", weekly: 1)
        XCTAssertEqual(SeatBoardRow.planLine(account: claude("ops3", weekly: 31, plan: "team"), rest: nil,
                                             activeEmail: active.email, now: now), "team · ready")
        XCTAssertEqual(SeatBoardRow.planLine(account: active, rest: nil, activeEmail: active.email, now: now), "max · in use")
        var cursor = claude("alt4", weekly: 0, plan: "unified_ultra")
        cursor.provider = .cursor
        XCTAssertLessThanOrEqual(SeatBoardRow.planLine(account: cursor, rest: nil, activeEmail: active.email, now: now).count, 16,
                                 "a long plan name is shortened so the state still shows")
    }

    // TABLE: ONE bar per seat, the binding window, else the week
    func testOneBarPerSeat() {
        let week = SeatBoardRow.primaryWindow(claude("ops3", weekly: 31), now: now)
        XCTAssertEqual(week?.label, "7d used")
        XCTAssertEqual(week?.percent, 31)
        let fiveHour = SeatBoardRow.primaryWindow(claude("alt4", weekly: 66, fiveHour: 93), now: now)
        XCTAssertEqual(fiveHour?.label, "5h used", "the binding window is the bar")
        XCTAssertEqual(fiveHour?.percent, 93)
    }

    // WARNINGS: one line, the seats near their cap
    func testNearCapIsOneLine() {
        let rows = [claude("ops1", weekly: 93), claude("ops2", weekly: 90), claude("alt3", weekly: 97), claude("ops3", weekly: 31)]
        XCTAssertEqual(FleetRoom.nearCapLine(rows, now: now), "3 seats near their cap: alt3 97% · ops1 93% · ops2 90%")
        XCTAssertNil(FleetRoom.nearCapLine([claude("ops3", weekly: 31)], now: now))
        XCTAssertNil(FleetRoom.nearCapLine([claude("old", weekly: 99, age: 3 * 86_400)], now: now),
                     "an old reading is not a warning about now")
    }

    // MONEY is one balance line (the operator, 2026-11-01: match the mockup)
    func testMoneyIsOneBalanceLine() {
        XCTAssertEqual(MoneyBoard.balanceLine(available: 12.32, limit: 240), "openrouter  $12.32 left of $240")
        XCTAssertEqual(MoneyBoard.balanceLine(available: 5, limit: 12.5), "openrouter  $5.00 left of $12.50")
    }

    // No SEATS / MONEY heading and no column header row: the pool headings carry the board
    // (the operator, 2026-11-01: match the mockup on both open differences)
    func testNoBoardHeadingsOrColumnHeaderRow() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Tower/DenseOpsUI.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("Text(\"SEATS\")"), "the SEATS heading is gone")
        XCTAssertFalse(text.contains("Text(\"MONEY\")"), "the MONEY heading is gone")
        XCTAssertFalse(text.contains("Text(Self.meterHeading)"), "the column header row is gone")
    }

    // SESSIONS and LANES fold to a count
    func testSessionsAndLanesFoldToACount() {
        XCTAssertEqual(SessionsBoard.foldedLine(nil), "Sessions · ?")
        XCTAssertEqual(LaneBoard.foldedLine(count: 4), "Lanes · 4")
    }
}
