import XCTest
@testable import Tower

final class BindingLimitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func seat(_ nickname: String, five: Double? = 10, weekly: Double? = 10,
                      fable: Double? = nil, capturedAgo: TimeInterval = 60) -> AccountSnapshot {
        var account = AccountSnapshot(
            email: "\(nickname)@example.test", nickname: nickname, plan: "max",
            fiveHourPct: five, fiveHourResetsAt: now.addingTimeInterval(5 * 3_600),
            weeklyPct: weekly, weeklyResetsAt: now.addingTimeInterval(7 * 86_400),
            capturedAt: now.addingTimeInterval(-capturedAgo))
        if let fable {
            account.scoped = [ScopedLimit(label: "Fable", percent: fable,
                                          resetsAt: now.addingTimeInterval(2 * 86_400))]
        }
        return account
    }

    func testNamedCappedSeatsChooseTheirActualBindingAggregate() throws {
        let expected: [(AccountSnapshot, AccountSnapshot.BindingLimit)] = [
            (seat("eve", five: 100, weekly: 40), .fiveHour),
            (seat("ana", five: 95, weekly: 30), .fiveHour),
            (seat("ben", five: 20, weekly: 100), .sevenDay),
            (seat("dee", five: 10, weekly: 95), .sevenDay),
        ]

        for (account, limit) in expected {
            let binding = try XCTUnwrap(account.bindingQuota(now: now))
            XCTAssertEqual(binding.limit, limit, "\(account.nickname) must name the capped window")
            XCTAssertEqual(binding.percent, limit == .fiveHour ? account.fiveHourPct : account.weeklyPct)
            XCTAssertEqual(binding.resetsAt,
                           limit == .fiveHour ? account.fiveHourResetsAt : account.weeklyResetsAt)
        }
    }

    func testFableAtOneHundredWinsAndNamesAlternateModels() throws {
        let account = seat("cal", five: 1, weekly: 100, fable: 100)
        let binding = try XCTUnwrap(account.bindingQuota(now: now))

        XCTAssertEqual(binding.limit, .fable, "Fable cap takes precedence over aggregate caps")
        XCTAssertEqual(binding.resetsAt, account.scoped.first?.resetsAt,
                       "Fable label must keep the Fable reset")
        XCTAssertEqual(account.bindingUsableFor(now: now), "none")

        var fableOnly = account
        fableOnly.weeklyPct = 10
        XCTAssertEqual(fableOnly.bindingQuota(now: now)?.limit, .fable,
                       "Fable-only cap remains the displayed binding")
        XCTAssertEqual(fableOnly.bindingUsableFor(now: now), "Opus / Sonnet",
                       "Fable-only cap leaves alternate models usable")
        XCTAssertTrue(fableOnly.isRecommendable(now: now), "Fable must not gate alternate models")
        XCTAssertNil(fableOnly.restingReason(rule: .capped, now: now))
    }

    func testNonCappedFallbackIgnoresFableAndHandlesMissingAndExpiredWindows() {
        let roomy = seat("roomy", five: 60, weekly: 70, fable: 99)
        XCTAssertEqual(roomy.bindingQuota(now: now)?.limit, .sevenDay,
                       "Non-capped fallback uses the tighter aggregate")
        XCTAssertEqual(roomy.bindingQuota(now: now)?.percent, 70)
        XCTAssertNil(roomy.bindingUsableFor(now: now))

        var codex = seat("codex", five: nil, weekly: 40)
        codex.provider = .codex
        XCTAssertEqual(codex.bindingQuota(now: now)?.limit, .sevenDay)

        var expired = seat("expired", five: 98, weekly: 20, fable: 100)
        expired.scoped[0].resetsAt = now.addingTimeInterval(-1)
        XCTAssertEqual(expired.bindingQuota(now: now)?.limit, .fiveHour)

        let stale = seat("stale", five: 10, weekly: 20, fable: 100,
                         capturedAgo: AccountSnapshot.freshnessTTL + 1)
        XCTAssertEqual(stale.bindingQuota(now: now)?.limit, .sevenDay,
                       "A stale Fable percentage must not claim a current cap")
    }

    @MainActor
    func testCursorBindingUsesBillingMonthInActiveAndDrawerLabels() {
        var cursor = seat("cursor", five: nil, weekly: 100)
        cursor.provider = .cursor
        let row = AccountRow(account: cursor, isActive: false, headerError: nil, now: now)

        XCTAssertEqual(row.availableSummary(), "0% room · month capped",
                       "Cursor binding label uses billing month in active rows")
        XCTAssertEqual(RestingDrawer.state(cursor, .capped(100), now: now),
                       "0% room · month capped",
                       "Cursor binding label uses billing month in the drawer")
    }

    @MainActor
    func testDisclosedSeatRendersAllThreeWindowsWithOnlyFableMarked() {
        let account = seat("fable", five: 1, weekly: 10, fable: 100)
        let windows = RestingDrawer.meterWindows(account, now: now)

        XCTAssertEqual(windows.map(\.label), ["5h used", "7d used", "Fable used"])
        XCTAssertEqual(windows.filter(\.isBinding).map(\.label), ["Fable used"])
        XCTAssertEqual(windows.first { $0.label == "Fable used" }?.percent, 100)

        let missingFable = seat("missing", five: 20, weekly: 30)
        XCTAssertEqual(RestingDrawer.meterWindows(missingFable, now: now).last?.trust, .unknown,
                       "Missing Fable reading stays unknown")

        let stale = seat("stale", five: 20, weekly: 30, fable: 100,
                         capturedAgo: AccountSnapshot.freshnessTTL + 1)
        XCTAssertNil(stale.presentableBindingQuota(now: now),
                     "Stale readings have no current binding quota")
        XCTAssertTrue(RestingDrawer.meterWindows(stale, now: now).allSatisfy { !$0.isBinding },
                      "Stale readings have no current binding marker")
    }

    @MainActor
    func testBindingWithoutResetDoesNotBorrowAggregateReset() {
        var account = seat("no-fable-reset", five: 1, weekly: 100, fable: 100)
        account.scoped[0].resetsAt = nil

        XCTAssertEqual(account.bindingQuota(now: now)?.limit, .fable)
        XCTAssertEqual(RestingDrawer.action(account, .capped(100), now: now), "reset unknown",
                       "Binding without reset must not borrow an aggregate reset")
    }
}
