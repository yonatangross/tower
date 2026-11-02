import Foundation
import XCTest
@testable import Tower

final class SeatCacheHydrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testRestartHydratesLastKnownRowsWithAgeAndMarksActiveHint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let captured = now.addingTimeInterval(-180)
        let active = AccountSnapshot(
            email: "ben@example.test", nickname: "ben", plan: "max", fiveHourPct: 7,
            fiveHourResetsAt: now.addingTimeInterval(3600), weeklyPct: 100,
            weeklyResetsAt: now.addingTimeInterval(3600), capturedAt: captured)
        let prior = AccountSnapshot(
            email: "ana@example.test", nickname: "ana", plan: "max", fiveHourPct: 93,
            fiveHourResetsAt: now.addingTimeInterval(3600), weeklyPct: 40,
            weeklyResetsAt: now.addingTimeInterval(3600), capturedAt: captured)
        let writer = Store(dir: dir, now: { self.now })
        XCTAssertNil(writer.save([active.email: active, prior.email: prior]))

        let reader = Store(dir: dir, now: { self.now })
        let rows = SeatCacheHydration.rows(from: reader)
        XCTAssertEqual(Set(rows.map(\.email)), [active.email, prior.email])
        let hydrated = try XCTUnwrap(rows.first { $0.email == active.email })
        XCTAssertEqual(hydrated.fiveHourPct, 7)
        XCTAssertEqual(hydrated.capturedAt, captured)
        XCTAssertEqual(hydrated.capturedAt.map { self.now.timeIntervalSince($0) }, 180)
        XCTAssertEqual(
            SeatCacheHydration.activeEmail(hint: active.email, accounts: rows),
            active.email)
        XCTAssertNil(SeatCacheHydration.activeEmail(
            hint: "missing@example.test", accounts: rows))
        XCTAssertNil(SeatCacheHydration.activeEmail(hint: nil, accounts: rows))
    }

    func testLoginRefreshPersistsImmediatelyForANewStoreProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir, now: { self.now })
        let vault = MockSeatKeychain().vault(in: dir)
        let login = ClaudeCredential(
            service: Keychain.defaultService, accessToken: "fixture-login",
            subscriptionType: "max", rateLimitTier: nil,
            expiresAt: now.addingTimeInterval(3600), emailHint: "fresh@example.test")
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(7200))
        let result = await Refresher.refreshLoggedInAccount(
            login, store: store, vault: vault,
            fetch: { _ in
                ClaudeFetch(email: "fresh@example.test", usage: UsageResponse(
                    five_hour: UsageWindow(utilization: 11, resets_at: reset),
                    seven_day: UsageWindow(utilization: 22, resets_at: reset),
                    seven_day_opus: nil, seven_day_sonnet: nil, limits: nil))
            }, now: now)
        XCTAssertNil(result.saveError)
        XCTAssertEqual(result.verifiedActiveEmail, "fresh@example.test")

        let otherProcess = Store(dir: dir, now: { self.now })
        let loaded = otherProcess.load()["fresh@example.test"]
        XCTAssertEqual(loaded?.fiveHourPct, 11)
        XCTAssertEqual(loaded?.weeklyPct, 22)
        XCTAssertEqual(loaded?.capturedAt, now)
        XCTAssertEqual(result.verifiedActiveEmail, loaded?.email)
        // The verified identity is persisted too: a new process reads it back with its
        // proof time, which is what lets the panel and MCP report it across restarts.
        XCTAssertEqual(otherProcess.verifiedActiveSeat()?.email, "fresh@example.test")
        XCTAssertEqual(otherProcess.verifiedActiveSeat()?.verifiedAt, now)
    }
}
