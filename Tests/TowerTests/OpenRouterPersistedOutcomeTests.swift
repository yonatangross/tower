import Foundation
import XCTest
@testable import Tower

/// The panel starts from the persisted store before its first poll, and a panelshot never
/// polls at all. Both used to start OpenRouter at `.notConfigured`, which hides the MONEY
/// row, so a refused key sitting in the store rendered as no OpenRouter at all. These tests
/// pin that the persisted row comes back as the outcome it records.
final class OpenRouterPersistedOutcomeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A 401 row, written the way a refused poll writes it, reads back as a refusal with
    /// its code, never as absence.
    func testRefusedRowHydratesAsRejectedNotHidden() {
        var accounts = [String: AccountSnapshot]()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir)
        store.seedOpenRouterAccount(
            into: &accounts, outcome: .ok(OpenRouter.Budget(spent: 31.5, limit: 50)),
            now: now.addingTimeInterval(-3600))
        store.seedOpenRouterAccount(
            into: &accounts, outcome: .rejected(401, keyFingerprint: "9f3c", lastSuccessAt: nil),
            now: now)
        let lastSuccess = now.addingTimeInterval(-3600)
        let outcome = OpenRouter.persistedOutcome(
            from: Array(accounts.values), lastSuccessAt: lastSuccess)
        XCTAssertEqual(outcome, .rejected(401, keyFingerprint: nil, lastSuccessAt: lastSuccess))
        XCTAssertNotEqual(outcome, .notConfigured)
    }

    /// The refusal text has one spelling for writer and reader; a 403 keeps its code.
    func testRefusedErrorRoundTrips() {
        XCTAssertEqual(OpenRouter.refusedError(401), "OpenRouter key refused (HTTP 401).")
        XCTAssertEqual(OpenRouter.refusedCode(OpenRouter.refusedError(401)), 401)
        XCTAssertEqual(OpenRouter.refusedCode(OpenRouter.refusedError(403)), 403)
        XCTAssertNil(OpenRouter.refusedCode(OpenRouter.unreadableError))
        XCTAssertNil(OpenRouter.refusedCode("OpenRouter key refused (HTTP x)."))
    }

    /// A network miss stays quietly present, and no row at all is the one case that hides.
    func testUnreadableRowAndMissingRow() {
        var accounts = [String: AccountSnapshot]()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir)
        XCTAssertEqual(OpenRouter.persistedOutcome(from: [], lastSuccessAt: nil), .notConfigured)
        store.seedOpenRouterAccount(
            into: &accounts, outcome: .ok(OpenRouter.Budget(spent: 10, limit: 50)), now: now)
        store.seedOpenRouterAccount(into: &accounts, outcome: .unavailable, now: now)
        XCTAssertEqual(
            OpenRouter.persistedOutcome(from: Array(accounts.values), lastSuccessAt: nil),
            .unavailable)
    }

    /// A healthy row rebuilds the balance the meter draws: what is left and what was added.
    func testHealthyRowRebuildsTheBudget() throws {
        var accounts = [String: AccountSnapshot]()
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir)
        store.seedOpenRouterAccount(
            into: &accounts, outcome: .ok(OpenRouter.Budget(spent: 31.5, limit: 50)), now: now)
        guard case .ok(let budget) = OpenRouter.persistedOutcome(
            from: Array(accounts.values), lastSuccessAt: nil)
        else { return XCTFail("a healthy row must hydrate as ok") }
        XCTAssertEqual(budget.available, 18.5, accuracy: 0.0001)
        XCTAssertEqual(budget.limit, 50, accuracy: 0.0001)

        var drained = [String: AccountSnapshot]()
        store.seedOpenRouterAccount(
            into: &drained, outcome: .ok(OpenRouter.Budget(spent: 50, limit: 50)), now: now)
        guard case .ok(let empty) = OpenRouter.persistedOutcome(
            from: Array(drained.values), lastSuccessAt: nil)
        else { return XCTFail("a drained row is still a reading") }
        XCTAssertEqual(empty.available, 0)
    }

    /// The panelshot boundary carries the outcome, so a shot of a refused key shows the
    /// refusal. The last success comes from the injected read, not the real defaults.
    func testPanelShotHydrationCarriesTheRefusal() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(dir: dir, now: { self.now })
        var accounts = [String: AccountSnapshot]()
        store.seedOpenRouterAccount(
            into: &accounts, outcome: .ok(OpenRouter.Budget(spent: 31.5, limit: 50)), now: now)
        store.seedOpenRouterAccount(
            into: &accounts, outcome: .rejected(401, keyFingerprint: nil, lastSuccessAt: nil), now: now)
        XCTAssertNil(store.save(accounts))

        let state = PanelShotHydration.load(
            store: Store(dir: dir, now: { self.now }),
            switchProfiles: { [:] },
            diskIdentityHint: { nil },
            openRouterLastSuccess: { nil })
        XCTAssertEqual(state.openRouter, .rejected(401, keyFingerprint: nil, lastSuccessAt: nil))
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}
