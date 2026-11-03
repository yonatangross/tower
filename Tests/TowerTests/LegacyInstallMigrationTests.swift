import XCTest
@testable import Tower

/// v0.1 renamed the install identity (`ai.yonatan-hq.claude-limits`, `HQClaudeLimits`)
/// to Tower. These pin the first-launch carry-over of a pre-v0.1 install.
final class LegacyInstallMigrationTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        base = fm.temporaryDirectory.appendingPathComponent("tower-legacy-\(UUID().uuidString)")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: base)
        super.tearDown()
    }

    private var legacyDir: URL { base.appendingPathComponent("HQClaudeLimits") }
    private var currentDir: URL { base.appendingPathComponent("Tower") }

    private func write(_ text: String, _ name: String, in dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func read(_ name: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    func testWholeLegacyDirectoryMovesAndTheOldOneIsRemoved() throws {
        try write("store", "accounts.json", in: legacyDir)
        try write("known", "known-accounts.json", in: legacyDir)
        try write("", ".accounts.lock", in: legacyDir)

        let report = LegacyInstallMigration.migrateSupportDirectory(base: base, fileManager: fm)

        XCTAssertEqual(report.movedEntries, ["accounts.json", "known-accounts.json"])
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(read("accounts.json", in: currentDir), "store")
        XCTAssertEqual(read("known-accounts.json", in: currentDir), "known")
        XCTAssertFalse(fm.fileExists(atPath: legacyDir.path), "an emptied legacy directory is removed")
    }

    func testAnEntryTheNewDirectoryHoldsIsNeverOverwritten() throws {
        try write("old store", "accounts.json", in: legacyDir)
        try write("old names", "nicknames.json", in: legacyDir)
        // The store opened once before the migration ran and wrote its own copy.
        try write("new store", "accounts.json", in: currentDir)

        let report = LegacyInstallMigration.migrateSupportDirectory(base: base, fileManager: fm)

        XCTAssertEqual(report.movedEntries, ["nicknames.json"])
        XCTAssertEqual(read("accounts.json", in: currentDir), "new store")
        XCTAssertEqual(read("nicknames.json", in: currentDir), "old names")
        XCTAssertEqual(read("accounts.json", in: legacyDir), "old store",
                       "the entry that was not moved stays where it was, so nothing is lost")
    }

    func testNoLegacyDirectoryIsANoOp() {
        let report = LegacyInstallMigration.migrateSupportDirectory(base: base, fileManager: fm)
        XCTAssertEqual(report, LegacyInstallMigration.Report())
        XCTAssertFalse(fm.fileExists(atPath: currentDir.path), "no directory is created for nothing")
    }

    /// A Re-trust after the rename may import seat items that the pre-v0.1 build wrote,
    /// and nothing that names another product.
    func testKeychainTrustsTheCurrentAndTheLegacyIdOnly() {
        XCTAssertEqual(ProductIdentity.keychainTrustedIdentifiers,
                       ["ai.yonyon.tower", "ai.yonatan-hq.claude-limits"])
    }

    func testLegacyDomainMapping() {
        XCTAssertEqual(LegacyInstallMigration.legacyDomain(for: "ai.yonyon.tower"),
                       "ai.yonatan-hq.claude-limits")
        XCTAssertEqual(LegacyInstallMigration.legacyDomain(for: "ai.yonyon.tower.dev"),
                       "ai.yonatan-hq.claude-limits.dev")
        XCTAssertNil(LegacyInstallMigration.legacyDomain(for: "ai.yonyon.towerx"))
        XCTAssertNil(LegacyInstallMigration.legacyDomain(for: "com.example.other"))
    }

    func testSettingsCopyOnceWithoutOverwriting() throws {
        let suite = "tower-legacy-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("l", forKey: "textSize")
        var asked: [String] = []
        let legacy: (String) -> [String: Any]? = { name in
            asked.append(name)
            return ["textSize": "xl", "retainSeats": false]
        }

        let first = LegacyInstallMigration.migrateSettings(
            domain: "ai.yonyon.tower", into: defaults, legacyValues: legacy)

        XCTAssertEqual(asked, ["ai.yonatan-hq.claude-limits"])
        XCTAssertEqual(first.copiedSettings, ["retainSeats"])
        XCTAssertEqual(defaults.string(forKey: "textSize"), "l", "a key the new domain holds wins")
        XCTAssertEqual(defaults.object(forKey: "retainSeats") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: LegacyInstallMigration.settingsMarkerKey),
                       "ai.yonatan-hq.claude-limits")

        defaults.removeObject(forKey: "retainSeats")
        let second = LegacyInstallMigration.migrateSettings(
            domain: "ai.yonyon.tower", into: defaults, legacyValues: legacy)
        XCTAssertEqual(second.copiedSettings, [], "the copy runs once")
        XCTAssertNil(defaults.object(forKey: "retainSeats"), "a key removed later is not revived")
    }

    func testUnrelatedDomainCopiesNothing() throws {
        let suite = "tower-legacy-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let report = LegacyInstallMigration.migrateSettings(
            domain: "com.example.other", into: defaults, legacyValues: { _ in ["k": "v"] })
        XCTAssertEqual(report.copiedSettings, [])
        XCTAssertNil(defaults.object(forKey: LegacyInstallMigration.settingsMarkerKey))
    }
}
