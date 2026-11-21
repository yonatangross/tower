import Foundation
import XCTest
@testable import Tower

/// Betty/User 2026-11-07: "do new Claude accounts show up in Tower by themselves?" A seat Tower has read
/// is real, so it joins known-accounts.json at the next seed. Before, the roster file stayed [] and a store
/// reset (the lineage swap) lost every account that had no other source.
final class RosterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("roster-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func declared(_ store: Store) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: store.declaredFile))) ?? []
    }

    private func snapshot(_ email: String, provider: Provider? = nil, read: Bool) -> AccountSnapshot {
        var snap = AccountSnapshot(email: email, nickname: Nickname.derive(from: email), plan: "max",
                                   tier: nil, capturedAt: read ? Date(timeIntervalSince1970: 1_800_000_000) : nil)
        snap.provider = provider
        return snap
    }

    func testAClaudeAccountTowerHasReadJoinsTheRoster() {
        let store = Store(dir: dir)
        var accounts = ["new@example.test": snapshot("new@example.test", read: true)]
        store.seedDeclaredAccounts(into: &accounts)
        XCTAssertEqual(declared(store), ["new@example.test"], "a read account is declared without a manual step")
        XCTAssertNotNil(accounts["new@example.test"])
    }

    func testRowsNeverReadOrFromOtherProvidersOrRetiredStayOut() {
        let store = Store(dir: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(["gone@example.test"]).write(to: store.retiredFile)
        var accounts = [
            "unread@example.test": snapshot("unread@example.test", read: false),
            "codex": snapshot("codex@example.test", provider: .codex, read: true),
            "gone@example.test": snapshot("gone@example.test", read: true),
        ]
        store.seedDeclaredAccounts(into: &accounts)
        XCTAssertEqual(declared(store), [],
                       "a row that was never read, another provider's row and a retired account are not declared")
    }

    /// b116 nit on #156: the migration treats capturedAt 0 as unread, and so must the roster. A never captured
    /// seat arrives on the wire as epoch zero, which is a date, not a missing value.
    func testASeatCapturedAtEpochZeroIsUnreadAndStaysOutOfTheRoster() {
        let store = Store(dir: dir)
        var epochZero = snapshot("ghost@example.test", read: false)
        epochZero.capturedAt = Date(timeIntervalSince1970: 0)
        var accounts = ["ghost@example.test": epochZero, "real@example.test": snapshot("real@example.test", read: true)]
        store.seedDeclaredAccounts(into: &accounts)
        XCTAssertEqual(declared(store), ["real@example.test"], "only the seat with a real capture joins")
    }

    /// b116 hold on #156 at d90f969: the store decodes dates with the default JSONDecoder, so a wire capturedAt 0
    /// is 2001-01-01 (seconds since the reference date), not 1970. The row must come from real bytes through
    /// the store, or the test never sees what the file holds.
    func testAWireCapturedAtZeroIsUnreadAndStaysOutOfTheRoster() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"ghost@example.test":{"email":"ghost@example.test","nickname":"ghost","plan":"max","scoped":[],"notified":{},"capturedAt":0},"real@example.test":{"email":"real@example.test","nickname":"real","plan":"max","scoped":[],"notified":{},"capturedAt":815745541.5}}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("accounts.json"))
        let store = Store(dir: dir)
        var accounts = store.load()
        XCTAssertNotNil(accounts["ghost@example.test"]?.capturedAt, "the store decodes the wire zero to a real date")
        store.seedDeclaredAccounts(into: &accounts)
        XCTAssertEqual(declared(store), ["real@example.test"], "a wire zero is never captured, even after decoding to 2001")
    }

    func testAnAccountAlreadyDeclaredIsNotDuplicated() {
        let store = Store(dir: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(["a@example.test"]).write(to: store.declaredFile)
        var accounts = ["a@example.test": snapshot("a@example.test", read: true)]
        store.seedDeclaredAccounts(into: &accounts)
        store.seedDeclaredAccounts(into: &accounts)
        XCTAssertEqual(declared(store), ["a@example.test"])
    }
}
