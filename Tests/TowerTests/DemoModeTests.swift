import XCTest
@testable import Tower

/// TOWER_DEMO=1 with TOWER_SUPPORT_DIR: a demo store shows a verified active seat from its
/// own invented credential, and never reads the real login Keychain to find one.
final class DemoModeTests: XCTestCase {
    private var dir: URL!
    private let now = Date()

    /// Counts calls to the Keychain seam; a demo run must leave it at zero.
    final class KeychainSpy: @unchecked Sendable { var reads = 0 }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tower-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func seat(_ nick: String, five: Double, week: Double) -> AccountSnapshot {
            var s = AccountSnapshot(email: "\(nick)@example.com", nickname: nick, plan: "max")
            s.fiveHourPct = five
            s.weeklyPct = week
            s.fiveHourResetsAt = now.addingTimeInterval(3 * 3600)
            s.weeklyResetsAt = now.addingTimeInterval(3 * 86_400)
            s.capturedAt = now.addingTimeInterval(-60)
            return s
        }
        let seats = [seat("work", five: 22, week: 41), seat("side", five: 0, week: 12), seat("lab", five: 81, week: 88)]
        XCTAssertNil(Store(dir: dir).save(Dictionary(uniqueKeysWithValues: seats.map { ($0.email, $0) })))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var demoEnv: [String: String] { ["TOWER_DEMO": "1", "TOWER_SUPPORT_DIR": dir.path] }

    private func advice(_ spy: KeychainSpy) -> MCPToolResult {
        TowerMCPService(env: .live(processEnvironment: demoEnv, keychainCredential: {
            spy.reads += 1
            return nil
        })).advice()
    }

    func testDemoCredentialBindsTheActiveSeatWithoutAKeychainRead() throws {
        try Data(#"{"accessToken":"demo-token-work","emailHint":"work@example.com"}"#.utf8)
            .write(to: dir.appendingPathComponent(DemoMode.credentialFileName))
        Store(dir: dir).recordVerifiedActiveSeatUnlocked("work@example.com", token: "demo-token-work", now: now)
        let spy = KeychainSpy()
        let result = advice(spy)
        let kind = result.structuredContent?["kind"].stringValue
        XCTAssertTrue(kind == "stay" || kind == "switch", "kind \(kind ?? "nil")")
        XCTAssertEqual(spy.reads, 0, "a demo run never reads the Keychain")
    }

    func testDemoWithoutCredentialIsUnverifiedAndWordedAsARecommendation() {
        let spy = KeychainSpy()
        let result = advice(spy)
        XCTAssertEqual(result.structuredContent?["kind"], "activeUnknown", "the schema kind is unchanged")
        XCTAssertEqual(result.content, [.text("no verified active seat; most room: side (88%)")])
        XCTAssertEqual(spy.reads, 0)
    }

    func testDemoModeNeedsBothVariables() {
        XCTAssertNil(DemoMode.supportDirectory(env: ["TOWER_DEMO": "1"]))
        XCTAssertNil(DemoMode.supportDirectory(env: ["TOWER_SUPPORT_DIR": dir.path]))
        XCTAssertTrue(DemoMode.isMisconfigured(env: ["TOWER_DEMO": "1"]))
        XCTAssertEqual(DemoMode.supportDirectory(env: demoEnv)?.path, dir.path)
    }

    func testDemoMirrorStaysInsideTheStore() {
        XCTAssertEqual(Store.defaultMirrorPath(env: demoEnv).deletingLastPathComponent().path, dir.path)
    }

    func testUnverifiedLineNamesSeatAndRoom() {
        XCTAssertEqual(RecommendBanner.unverifiedActiveLine(nick: "side", roomPct: 88),
                       "no verified active seat; most room: side (88%)")
        XCTAssertEqual(RecommendBanner.unverifiedActiveLine(nick: "side", roomPct: nil),
                       "no verified active seat; most room: side")
    }
}
