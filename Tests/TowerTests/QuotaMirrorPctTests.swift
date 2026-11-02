import Foundation
import XCTest
@testable import Tower

/// The quota mirror (quota-cache.json, byte-identical to accounts.json) must
/// never publish a pct outside 0 to 100: consumers compute room as 100 minus
/// the stored number, so an out-of-range value renders as a false reading on
/// every footer that trusts the file. Cursor's own `usage-summary` gives two
/// real dashboard pools, not a dollar balance calculated from model costs.
final class QuotaMirrorPctTests: XCTestCase {
    private func makeStore(in dir: URL, now: Date) -> (store: Store, mirror: URL) {
        let mirror = dir.appendingPathComponent("claude/quota-cache.json")
        return (Store(dir: dir, mirror: mirror, now: { now }), mirror)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func mirrorRows(_ mirror: URL) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: mirror)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    }

    /// The live dashboard response has two independent percentages. The stored primary is
    /// their conservative maximum for ranking, while both named pool readings remain intact.
    func testCursorUsageSummaryPublishesTwoDashboardPools() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, mirror) = makeStore(in: dir, now: now)

        let wire = "{\"billingCycleEnd\":\"2033-05-23T17:36:41.000Z\","
            + "\"membershipType\":\"ultra\",\"individualUsage\":{\"plan\":{"
            + "\"autoPercentUsed\":73.004,\"apiPercentUsed\":79.992},"
            + "\"onDemand\":{\"enabled\":false}}}"
        let summary = try JSONDecoder().decode(CursorUsage.Summary.self, from: Data(wire.utf8))
        let reading = CursorUsage.Reading(
            email: "a@b", plan: try XCTUnwrap(summary.membershipType),
            cursorModelsPct: summary.individualUsage?.plan?.autoPercentUsed,
            otherModelsPct: summary.individualUsage?.plan?.apiPercentUsed,
            periodResetsAt: try XCTUnwrap(DateParse.parse(summary.billingCycleEnd)))
        var snap = AccountSnapshot(email: "a@b", nickname: "ab", plan: "ultra")
        CursorUsage.apply(reading, to: &snap, now: now)

        let key = AccountSnapshot.storeKey(email: "a@b", provider: .cursor)
        XCTAssertNil(store.save([key: snap]))
        let row = try XCTUnwrap(mirrorRows(mirror)[key])
        XCTAssertEqual(try XCTUnwrap(row["weeklyPct"] as? Double), 79.992, accuracy: 0.001)
        let pools = try XCTUnwrap(row["scoped"] as? [[String: Any]])
        XCTAssertEqual(pools.map { $0["label"] as? String }, ["Cursor Models", "Other Models"])
        XCTAssertEqual(try XCTUnwrap(pools[0]["percent"] as? Double), 73.004, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(pools[1]["percent"] as? Double), 79.992, accuracy: 0.001)
        XCTAssertNil(row["creditBalance"], "model-rate cost must never render as a bill")
        XCTAssertNil(row["lastError"])
    }

    /// A partial dashboard answer cannot safely rank the seat. The known pool stays visible,
    /// while the primary value becomes unknown instead of borrowing an unrelated dollar total.
    func testCursorPartialPoolsPublishUnknownPrimaryWithReason() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, mirror) = makeStore(in: dir, now: now)

        let resetsAt = now.addingTimeInterval(86_400)
        let reading = CursorUsage.Reading(
            email: "a@b", plan: "ultra", cursorModelsPct: 73, otherModelsPct: nil,
            periodResetsAt: resetsAt)
        var snap = AccountSnapshot(email: "a@b", nickname: "ab", plan: "ultra")
        CursorUsage.apply(reading, to: &snap, now: now)
        XCTAssertNil(snap.weeklyPct)

        let key = AccountSnapshot.storeKey(email: "a@b", provider: .cursor)
        XCTAssertNil(store.save([key: snap]))
        let row = try XCTUnwrap(mirrorRows(mirror)[key])
        XCTAssertNil(row["weeklyPct"])
        let err = try XCTUnwrap(row["lastError"] as? String)
        XCTAssertTrue(err.contains("two valid dashboard pool"), "reason names the missing reading")
        XCTAssertNotNil(row["weeklyResetsAt"])
        let pools = try XCTUnwrap(row["scoped"] as? [[String: Any]])
        XCTAssertEqual(pools[0]["percent"] as? Double, 73)
        XCTAssertNil(pools[1]["percent"])
        // Authoritative file and mirror carry the same bytes.
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("accounts.json")),
                       try Data(contentsOf: mirror))
        // A load sees unknown, never a synthetic allowance percentage.
        XCTAssertNil(store.load()[key]?.weeklyPct)
    }

    /// A fresh summary clears old dollar text from the pre-pool implementation.
    func testCursorPoolReadingClearsLegacyDollarText() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, mirror) = makeStore(in: dir, now: now)

        let reading = CursorUsage.Reading(
            email: "a@b", plan: "ultra", cursorModelsPct: 0, otherModelsPct: 80,
            periodResetsAt: now.addingTimeInterval(86_400))
        var snap = AccountSnapshot(email: "a@b", nickname: "ab", plan: "ultra")
        snap.creditBalance = "$2059.10 of $200 used"
        CursorUsage.apply(reading, to: &snap, now: now)

        let key = AccountSnapshot.storeKey(email: "a@b", provider: .cursor)
        XCTAssertNil(store.save([key: snap]))
        let row = try XCTUnwrap(mirrorRows(mirror)[key])
        XCTAssertEqual(row["weeklyPct"] as? Double, 80)
        XCTAssertNil(row["creditBalance"])
    }

    /// The range rule applies to every pct field on the row, not only the
    /// cursor weekly: no producer can publish 150% anywhere in the file.
    func testEveryPctFieldIsRangeCheckedOnWrite() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, mirror) = makeStore(in: dir, now: now)

        var snap = AccountSnapshot(email: "a@b", nickname: "ab", plan: "max")
        snap.fiveHourPct = 150
        snap.weeklyPct = -3
        snap.scoped = [ScopedLimit(label: "Fable", percent: 250, resetsAt: nil)]
        XCTAssertNil(store.save(["a@b": snap]))

        let row = try XCTUnwrap(mirrorRows(mirror)["a@b"])
        XCTAssertNil(row["fiveHourPct"])
        XCTAssertNil(row["weeklyPct"])
        let scoped = try XCTUnwrap(row["scoped"] as? [[String: Any]])
        XCTAssertEqual(scoped.count, 1)
        XCTAssertNil(scoped[0]["percent"])
        XCTAssertEqual(scoped[0]["label"] as? String, "Fable")
        let err = try XCTUnwrap(row["lastError"] as? String)
        XCTAssertTrue(err.contains("fiveHourPct"), "got: \(err)")
        XCTAssertTrue(err.contains("weeklyPct"), "got: \(err)")
        XCTAssertTrue(err.contains("Fable"), "got: \(err)")
    }

    /// Boundary values are real readings, not violations: 0 and 100 pass
    /// through untouched and earn no reason on the row.
    func testBoundaryPctsPassThroughUnchanged() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, mirror) = makeStore(in: dir, now: now)

        var snap = AccountSnapshot(email: "a@b", nickname: "ab", plan: "max")
        snap.fiveHourPct = 0
        snap.weeklyPct = 100
        snap.scoped = [ScopedLimit(label: "Fable", percent: 100, resetsAt: nil)]
        XCTAssertNil(store.save(["a@b": snap]))

        let row = try XCTUnwrap(mirrorRows(mirror)["a@b"])
        XCTAssertEqual(row["fiveHourPct"] as? Double, 0)
        XCTAssertEqual(row["weeklyPct"] as? Double, 100)
        let scoped = try XCTUnwrap(row["scoped"] as? [[String: Any]])
        XCTAssertEqual(scoped[0]["percent"] as? Double, 100)
        XCTAssertNil(row["lastError"])
    }

    /// The statusline producer renders OpenRouter room straight off the mirror
    /// row: it needs `balanceUSD` (hq_tower.py reads that exact name) and
    /// `availablePct`, the same percent-LEFT number the BudgetRow shows.
    func testOpenRouterRowPublishesBalanceAndAvailablePct() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, mirror) = makeStore(in: dir, now: now)

        let budget = OpenRouter.Budget(spent: 46.18, limit: 100)
        var snap = AccountSnapshot(
            email: OpenRouter.storeEmail, nickname: "openrouter", plan: "balance")
        OpenRouter.apply(budget, to: &snap, now: now)

        let key = AccountSnapshot.storeKey(
            email: OpenRouter.storeEmail, provider: .openrouter)
        XCTAssertNil(store.save([key: snap]))
        let row = try XCTUnwrap(mirrorRows(mirror)[key])
        XCTAssertEqual(try XCTUnwrap(row["balanceUSD"] as? Double),
                       budget.available, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row["availablePct"] as? Double),
                       budget.availablePct, accuracy: 0.0001)
        // The two fields agree: 53.82 left of a 100 ceiling is 53.82 percent.
        XCTAssertEqual(budget.availablePct, 53.82, accuracy: 0.001)
        XCTAssertNil(row["weeklyPct"])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("accounts.json")),
                       try Data(contentsOf: mirror))
    }

    /// availablePct goes through the same range rule as every other pct field:
    /// a row that arrives claiming 150% left is withheld, not published.
    func testAvailablePctIsRangeCheckedOnWrite() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, mirror) = makeStore(in: dir, now: now)

        var snap = AccountSnapshot(email: "a@b", nickname: "ab", plan: "balance")
        snap.provider = .openrouter
        snap.balanceUSD = 150
        snap.availablePct = 150
        snap.capturedAt = now
        XCTAssertNil(store.save(["a@b": snap]))

        let row = try XCTUnwrap(mirrorRows(mirror)["a@b"])
        XCTAssertNil(row["availablePct"])
        // balanceUSD is not a pct field: it is money and stays published.
        XCTAssertEqual(row["balanceUSD"] as? Double, 150)
        let err = try XCTUnwrap(row["lastError"] as? String)
        XCTAssertTrue(err.contains("availablePct"), "reason names the field, got: \(err)")
    }

    /// A file written before this rule existed heals on load: the bad number
    /// is rejected on the way in, and the next save persists the clean row.
    func testLegacyOutOfRangeRowHealsOnLoad() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, mirror) = makeStore(in: dir, now: now)

        var legacy = AccountSnapshot(email: "a@b", nickname: "ab", plan: "ultra")
        legacy.provider = .cursor
        legacy.weeklyPct = 734.48
        legacy.capturedAt = now
        let key = AccountSnapshot.storeKey(email: "a@b", provider: .cursor)
        // Write the bad row directly, the way a pre-fix build left it on disk.
        try JSONEncoder().encode([key: legacy])
            .write(to: dir.appendingPathComponent("accounts.json"))

        XCTAssertNil(store.load()[key]?.weeklyPct)
        XCTAssertTrue(store.load()[key]?.lastError?.contains("weeklyPct") == true)
    }
}
