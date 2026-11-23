import XCTest
@testable import Tower

/// A stale or failed reader must never read as live, and no provider may vanish.
final class ProviderCoverageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func claude(age: TimeInterval?, error: String? = nil) -> AccountSnapshot {
        var seat = AccountSnapshot(email: "a@example.test", nickname: "seat", plan: "max")
        seat.weeklyPct = 20
        seat.weeklyResetsAt = now.addingTimeInterval(86_400)
        seat.capturedAt = age.map { now.addingTimeInterval(-$0) }
        seat.lastError = error
        return seat
    }

    private func lane(_ provider: Provider, _ usage: AgentLane.UsageRead) -> AgentLane.Outcome {
        .ok(AgentLane.Reading(provider: provider, configModel: nil, lastDispatch: nil,
                              lastLimitHit: nil, usage: usage))
    }

    private let balance = ProviderCoverage.ManualBalance(
        seat: "jev", text: "balance $1, not live", step: "re-enter", isOn: true)

    private func matrix(_ accounts: [AccountSnapshot],
                        lanes: [Provider: AgentLane.Outcome] = [:],
                        isOn: (Provider) -> Bool = { _ in true }) -> [ProviderCoverage.Row] {
        ProviderCoverage.matrix(accounts: accounts, lanes: lanes, manualBalances: [balance],
                                isOn: isOn, now: now)
    }

    func testFreshSuccessfulCaptureIsLive() {
        let row = ProviderCoverage.accountRow(claude(age: 60), now: now)
        XCTAssertEqual(row.state, .live)
        XCTAssertEqual(row.authenticated, true)
    }

    func testCaptureOutsideTheTTLIsNotLive() {
        let age = AccountSnapshot.freshnessTTL + 1
        let row = ProviderCoverage.accountRow(claude(age: age), now: now)
        XCTAssertEqual(row.state, .stale)
        XCTAssertFalse(row.isLive)
    }

    func testFailedReadWithAFreshCaptureIsNotLive() {
        let seat = claude(age: 30, error: "could not read usage")
        let row = ProviderCoverage.accountRow(seat, now: now)
        XCTAssertEqual(row.state, .failed)
        XCTAssertFalse(row.isLive)
        XCTAssertEqual(row.reason, "could not read usage")
    }

    func testCaptureFromTheFutureIsNotLive() {
        XCTAssertFalse(ProviderCoverage.accountRow(claude(age: -120), now: now).isLive)
    }

    func testLaneFailureOutranksAFreshStoredRow() {
        var stored = AccountSnapshot(email: "muse@local", nickname: "muse", plan: "lane")
        stored.provider = .muse
        stored.weeklyPct = 10
        stored.capturedAt = now.addingTimeInterval(-30)
        let row = ProviderCoverage.laneRow(
            .muse, seat: stored, outcome: lane(.muse, .notReadable("server_sent_no_usage")), now: now)
        XCTAssertEqual(row.state, .failed)
        XCTAssertFalse(row.isLive)
    }

    private func quota(fetchedAgo: TimeInterval?) -> AgentLane.UsageRead {
        .quota(AgentLane.Quota(
            plan: nil, dailyRemainingPct: 90, weeklyRemainingPct: 80,
            dailyResetsAt: now.addingTimeInterval(3_600), weeklyResetsAt: now.addingTimeInterval(86_400),
            fetchedAt: fetchedAgo.map { now.addingTimeInterval(-$0) }))
    }

    func testLaneQuotaReadNowIsLiveWithNoStoredRow() {
        let row = ProviderCoverage.laneRow(.agy, seat: nil, outcome: lane(.agy, quota(fetchedAgo: 5)), now: now)
        XCTAssertEqual(row.state, .live)
    }

    func testOldLaneQuotaIsNotLive() {
        let age = AccountSnapshot.freshnessTTL + 60
        let row = ProviderCoverage.laneRow(.devin, seat: nil, outcome: lane(.devin, quota(fetchedAgo: age)), now: now)
        XCTAssertEqual(row.state, .stale)
    }

    func testLaneQuotaWithoutAnObservationTimeIsNotLive() {
        let row = ProviderCoverage.laneRow(.agy, seat: nil, outcome: lane(.agy, quota(fetchedAgo: nil)), now: now)
        XCTAssertEqual(row.state, .failed)
    }

    func testConfiguredOpenRouterKeyWithNoReadIsNotReportedMissing() {
        let rows = ProviderCoverage.matrix(accounts: [], lanes: [:], manualBalances: [],
                                           openRouterKeyConfigured: true, now: now)
        let row = rows.first { $0.provider == .openrouter }
        XCTAssertEqual(row?.state, .neverRead)
        XCTAssertEqual(row?.isLive, false)
    }

    private func codexSeat(pct: Double, age: TimeInterval, error: String?) -> AccountSnapshot {
        var seat = AccountSnapshot(email: "x@example.test", nickname: "codex", plan: "pro")
        seat.provider = .codex
        seat.weeklyPct = pct
        seat.weeklyResetsAt = now.addingTimeInterval(86_400)
        seat.capturedAt = now.addingTimeInterval(-age)
        seat.lastError = error
        return seat
    }

    func testFreshCodexCapIsALiveReadThatKeepsItsMessage() {
        let row = ProviderCoverage.accountRow(codexSeat(pct: 100, age: 30, error: "limit reached"), now: now)
        XCTAssertEqual(row.state, .live)
        XCTAssertEqual(row.reason, "limit reached")
    }

    func testOldCodexCapIsNotLive() {
        let age = AccountSnapshot.freshnessTTL + 60
        let row = ProviderCoverage.accountRow(codexSeat(pct: 100, age: age, error: "limit reached"), now: now)
        XCTAssertEqual(row.state, .stale)
    }

    func testCodexFailureBelowTheCapIsNotLive() {
        let row = ProviderCoverage.accountRow(codexSeat(pct: 40, age: 30, error: "read failed"), now: now)
        XCTAssertEqual(row.state, .failed)
    }

    func testTypeSafeIsNeverLive() {
        let row = matrix([]).first { $0.provider == .typesafe }
        XCTAssertEqual(row?.state, .manual)
        XCTAssertEqual(row?.isLive, false)
        XCTAssertNil(row?.lastLiveRead)
    }

    func testTurnedOffProviderReadsAsTurnedOff() {
        var seat = AccountSnapshot(email: "x@example.test", nickname: "codex", plan: "pro")
        seat.provider = .codex
        seat.weeklyPct = 10
        seat.capturedAt = now.addingTimeInterval(-30)
        let rows = matrix([seat], isOn: { $0 != .codex })
        let row = rows.first { $0.provider == .codex }
        XCTAssertEqual(row?.state, .turnedOff)
        XCTAssertEqual(row?.isLive, false)
        XCTAssertNil(row?.lastLiveRead)
    }

    func testPiSpendRowIsLiveWhenFresh() {
        var seat = AccountSnapshot(email: "pi@local", nickname: "pi", plan: "lane")
        seat.provider = .pi
        seat.capturedAt = now.addingTimeInterval(-30)
        XCTAssertEqual(ProviderCoverage.accountRow(seat, now: now).state, .live)
    }

    func testEveryProviderHasARow() {
        let named = Set(matrix([]).map(\.provider))
        XCTAssertEqual(named, Set(Provider.allCases))
    }
}
