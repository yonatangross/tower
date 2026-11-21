import AppKit
import Foundation
import XCTest
@testable import Tower

/// 2026-09-27 operator report: "lanes cursor/devin truncation/muse 429". Measured at
/// a868c8a with the lanes hydrated into panelshot: Muse showed an orange "rate limited
/// (HTTP 429) 1d ago" for a refusal 30 hours old, the Cursor lane said "not readable"
/// while the Cursor seat row two sections up had both pool numbers, and the usage text
/// shared one row with a 110 pt name column, so long lines were squeezed.
final class LaneRowRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_500_000)

    private func hit(_ ago: TimeInterval, _ summary: String = "rate limited (HTTP 429)") -> AgentLane.LimitHit {
        AgentLane.LimitHit(at: now.addingTimeInterval(-ago), summary: summary, message: summary)
    }

    private func devin(hit: AgentLane.LimitHit?, daily: Double? = 0, resetIn: TimeInterval? = 3600,
                       fetchedAgo: TimeInterval = 7200) -> AgentLane.Reading {
        AgentLane.Reading(
            provider: .devin, configModel: "swe-2-high", lastDispatch: nil, lastLimitHit: hit,
            usage: .quota(.init(plan: "Pro", dailyRemainingPct: daily, weeklyRemainingPct: 100,
                                dailyResetsAt: resetIn.map { now.addingTimeInterval($0) },
                                weeklyResetsAt: nil,
                                fetchedAt: now.addingTimeInterval(-fetchedAgo))))
    }

    // MARK: Rule 2, a refusal past the lane's own horizon is history

    /// The live case: Muse's newest terminal stream was a 429 thirty hours ago and
    /// nothing has streamed since. Muse publishes no reset, so the fixed horizon decides.
    func testAMuseRefusalPastTheThrottleHorizonIsHistoryNotCurrent() {
        let old = AgentLane.Reading(provider: .muse, configModel: nil, lastDispatch: nil,
                                    lastLimitHit: hit(30 * 3600))
        XCTAssertFalse(AgentLane.limitIsCurrent(old, now: now))
        XCTAssertEqual(AgentLane.pastLimitLine(old.lastLimitHit!, now: now),
                       "earlier: rate limited (HTTP 429) 1d ago")
        // Past a day the panel drops the history line; the record stays in the CLI and MCP.
        XCTAssertFalse(AgentLane.showsPastLimit(old.lastLimitHit!, now: now))
        XCTAssertTrue(AgentLane.showsPastLimit(hit(3 * 3600), now: now))
        XCTAssertEqual(AgentLane.historyHorizon, 86_400)

        let fresh = AgentLane.Reading(provider: .muse, configModel: nil, lastDispatch: nil,
                                      lastLimitHit: hit(20 * 60))
        XCTAssertTrue(AgentLane.limitIsCurrent(fresh, now: now))
        XCTAssertEqual(AgentLane.throttleHorizon, 2 * 3600,
                       "the measured longest 429 run was 52 minutes; the horizon covers it")
        XCTAssertFalse(AgentLane.limitIsCurrent(
            AgentLane.Reading(provider: .muse, configModel: nil, lastDispatch: nil,
                              lastLimitHit: hit(AgentLane.throttleHorizon)), now: now))
    }

    func testNoRefusalIsNeverCurrent() {
        let r = AgentLane.Reading(provider: .muse, configModel: nil, lastDispatch: nil, lastLimitHit: nil)
        XCTAssertFalse(AgentLane.limitIsCurrent(r, now: now))
    }

    /// Devin's status names the next daily reset, so its window started a day before it.
    func testADevinRefusalBeforeTheCurrentDailyWindowBelongsToAWindowThatReset() {
        // Reset in 1 h, so the window opened 23 h ago; the refusal is 25 h old.
        XCTAssertFalse(AgentLane.limitIsCurrent(devin(hit: hit(25 * 3600, "daily quota exhausted")), now: now))
    }

    func testADevinRefusalInsideTheWindowIsCurrentUntilTheReset() {
        let r = devin(hit: hit(30 * 60, "daily quota exhausted"), fetchedAgo: 3600)
        XCTAssertTrue(AgentLane.limitIsCurrent(r, now: now))
        XCTAssertFalse(AgentLane.limitIsCurrent(r, now: now.addingTimeInterval(3601)),
                       "once the reset passes, the refusal describes the old window")
    }

    /// A status the CLI fetched after the refusal that still shows room outranks the
    /// refusal: the seat itself says it can run.
    func testAStatusFetchedAfterTheRefusalWithRoomLeftClearsIt() {
        let r = devin(hit: hit(3600, "daily quota exhausted"), daily: 100, fetchedAgo: 60)
        XCTAssertFalse(AgentLane.limitIsCurrent(r, now: now))
        let empty = devin(hit: hit(3600, "daily quota exhausted"), daily: 0, fetchedAgo: 60)
        XCTAssertTrue(AgentLane.limitIsCurrent(empty, now: now), "a status at 0 % confirms the refusal")
    }

    /// Without a status to place it, a daily quota refusal holds for one day.
    func testADevinRefusalWithoutAStatusHoldsForADay() {
        let placeless = { (ago: TimeInterval) in
            AgentLane.Reading(provider: .devin, configModel: nil, lastDispatch: nil,
                              lastLimitHit: self.hit(ago, "daily quota exhausted"),
                              usage: .notReadable("no user status cache on disk"))
        }
        XCTAssertTrue(AgentLane.limitIsCurrent(placeless(5 * 3600), now: now))
        XCTAssertFalse(AgentLane.limitIsCurrent(placeless(25 * 3600), now: now))
    }

    // MARK: Rule 3, the Cursor lane reads its seat

    private func cursorSeat(auto: Double?, metered: Double?, capturedAgo: TimeInterval = 30) -> AccountSnapshot {
        let reading = CursorUsage.Reading(email: "ben@example.com", plan: "ultra",
                                          cursorModelsPct: auto, otherModelsPct: metered,
                                          periodResetsAt: now.addingTimeInterval(26 * 86_400))
        var snap = AccountSnapshot(email: reading.email, nickname: "ben", plan: "ultra")
        CursorUsage.apply(reading, to: &snap, now: now.addingTimeInterval(-capturedAgo))
        return snap
    }

    private let cursorLane = AgentLane.Reading(
        provider: .cursor, configModel: "auto", lastDispatch: nil, lastLimitHit: nil,
        usage: .notReadable("agent quota lives in-session; the Cursor row reports the same seat"))

    func testTheCursorLaneShowsItsSeatsPools() {
        let seat = cursorSeat(auto: 11, metered: 84)
        let line = "seat ben: Auto unmetered 11% · Opus metered 84% used"
        XCTAssertEqual(AgentLane.usageLine(cursorLane, cursorSeat: seat, now: now), line)
        XCTAssertEqual(AgentLane.headerDetail(cursorLane, cursorSeat: seat, now: now), line)
        // The seat row truncates (SegmentedMeter.displayPercent); the lane must match it.
        XCTAssertEqual(AgentLane.usageLine(cursorLane, cursorSeat: cursorSeat(auto: 11.4, metered: 84.6), now: now),
                       "seat ben: Auto unmetered 11% · Opus metered 84% used")
        XCTAssertEqual(SegmentedMeter.displayPercent(84.6), "84%")
    }

    func testAStaleSeatReadSaysHowOldItIs() {
        let seat = cursorSeat(auto: 11, metered: 84, capturedAgo: 3 * 3600)
        XCTAssertEqual(AgentLane.usageLine(cursorLane, cursorSeat: seat, now: now),
                       "seat ben: Auto unmetered 11% · Opus metered 84% used, read 3h ago")
    }

    func testWithoutASeatTheCursorLaneSaysWhyNot() {
        XCTAssertEqual(AgentLane.usageLine(cursorLane, cursorSeat: nil, now: now),
                       "not readable: agent quota lives in-session and no Cursor seat is on file")
        XCTAssertEqual(AgentLane.headerDetail(cursorLane, cursorSeat: nil, now: now), "usage not readable")
    }

    /// Only the Cursor lane borrows a seat; every other lane reads as before.
    func testOtherLanesIgnoreTheCursorSeat() {
        let seat = cursorSeat(auto: 11, metered: 84)
        let muse = AgentLane.Reading(provider: .muse, configModel: nil, lastDispatch: nil, lastLimitHit: nil)
        XCTAssertNil(AgentLane.usageLine(muse, cursorSeat: seat, now: now))
        XCTAssertEqual(AgentLane.headerDetail(muse, cursorSeat: seat, now: now), "usage not exposed")
        let d = devin(hit: nil, daily: 100)
        XCTAssertEqual(AgentLane.usageLine(d, cursorSeat: seat, now: now), AgentLane.usageLine(d))
    }

    // MARK: Rule 1, the row text fits the panel

    private func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    /// The usage line owns the full row width now. The longest real lines (Devin with
    /// both resets on other days, the Cursor seat line read hours ago) fit in it without
    /// truncation, where the old layout left them what a 110 pt column and the trailing
    /// stack did not take.
    func testTheLongestRealUsageLinesFitTheRowBudget() {
        XCTAssertEqual(LaneBoard.usageWidth, TowerType.panelWidth - 2 * 10 - 24 - 6)
        let longest = [
            "daily 100% left, resets Sep 28 11:00 · weekly 100% left, resets Oct 4 11:00",
            "seat ben: Auto unmetered 11% · Opus metered 84% used, read 23h ago",
            "not readable: agent quota lives in-session and no Cursor seat is on file",
        ]
        for line in longest {
            XCTAssertLessThanOrEqual(width(line, size: TowerType.designSize(.small)),
                                     LaneBoard.usageWidth * CGFloat(LaneBoard.usageLines),
                                     "\(line) exceeds \(LaneBoard.usageLines) lines")
        }
    }

    /// Line one carries name, model and dispatch age. The longest real pair
    /// (antigravity on gemini-3.8-flash-medium) fits the row with its spacing.
    func testTheIdentityLineFitsTheRowBudget() {
        let used = width("antigravity", size: TowerType.designSize(.body), weight: .semibold)
            + width("model gemini-3.8-flash-medium", size: TowerType.designSize(.minimum))
            + width("last dispatch 23h ago", size: TowerType.designSize(.minimum)) + 5 + 6
        XCTAssertLessThanOrEqual(used, LaneBoard.usageWidth)
    }
}
