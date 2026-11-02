import XCTest
@testable import Tower

final class CursorPoolDisplayTests: XCTestCase {
    func testLegacyCursorCostCannotSurviveLoadAndMirrorAsQuota() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        let store = Store(dir: dir, mirror: mirror, now: { now })
        var legacy = AccountSnapshot(email: "cursor@example.test", nickname: "cursor", plan: "ultra",
                                     weeklyPct: 25, weeklyResetsAt: now.addingTimeInterval(3600),
                                     capturedAt: now)
        legacy.provider = .cursor
        legacy.creditBalance = "$50.00 of $200 used"
        try JSONEncoder().encode([legacy.id: legacy]).write(to: dir.appendingPathComponent("accounts.json"))
        let loaded = try XCTUnwrap(store.load()[legacy.id])
        XCTAssertNil(loaded.weeklyPct, "legacy cost ratio is not a dashboard quota")
        XCTAssertNil(loaded.creditBalance, "legacy model-rate cost is not a bill")
        XCTAssertNotNil(loaded.lastError)
        XCTAssertNil(store.save([loaded.id: loaded]))
        let mirroredData = try Data(contentsOf: mirror)
        let mirrored = try JSONDecoder().decode([String: AccountSnapshot].self, from: mirroredData)
        XCTAssertNil(mirrored[legacy.id]?.weeklyPct)
        XCTAssertNil(mirrored[legacy.id]?.creditBalance)
    }

    @MainActor
    func testCursorShowsBothNamedPoolsIncludingZeroAndUnknown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var account = AccountSnapshot(email: "cursor@example.test", nickname: "cursor", plan: "ultra")
        account.provider = .cursor
        account.capturedAt = now
        account.scoped = [ScopedLimit(label: "Cursor Models", percent: 0,
                                     resetsAt: now.addingTimeInterval(3600))]
        let windows = RestingDrawer.meterWindows(account, now: now)
        XCTAssertEqual(windows.map(\.label), ["Cursor Models", "Other Models"],
                       "Cursor displays two named dashboard pools")
        XCTAssertEqual(windows.first?.percent, 0, "zero is measured usage")
        XCTAssertNil(windows.last?.percent, "missing pool stays unknown")
        XCTAssertEqual(windows.last?.trust, .unknown)
    }

    @MainActor
    func testCursorDashboardPercentagesUseTheirOwnMeters() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = now.addingTimeInterval(3600)
        var account = AccountSnapshot(email: "cursor@example.test", nickname: "cursor", plan: "ultra",
                                      weeklyPct: 80, weeklyResetsAt: reset, capturedAt: now)
        account.provider = .cursor
        account.scoped = [ScopedLimit(label: "Cursor Models", percent: 73, resetsAt: reset),
                          ScopedLimit(label: "Other Models", percent: 80, resetsAt: reset)]
        let windows = RestingDrawer.meterWindows(account, now: now)
        XCTAssertEqual(windows.map(\.percent), [73, 80], "dashboard pools keep distinct percentages")
        XCTAssertEqual(windows.map(\.resetsAt), [reset, reset])
        XCTAssertEqual(windows.map(\.isBinding), [false, true])
    }
}
