import Foundation
import XCTest
@testable import Tower

/// Codex on #156 (P1): install.sh writes a LaunchAgent that starts Tower at login and after a crash, and
/// switches the SMAppService entry off so login does not start two instances. LaunchAtLogin only knew
/// SMAppService, so after an install the settings toggle read "off" while Tower did start at login, and
/// turning it off could not stop the agent. The agent counts as start at login, and off removes it.
final class LoginItemTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: LaunchAtLogin.agentPlist(home: home).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    private func installAgent() throws {
        try Data("<plist/>".utf8).write(to: LaunchAtLogin.agentPlist(home: home))
    }

    func testAnInstalledAgentCountsAsStartAtLogin() throws {
        XCTAssertFalse(LaunchAtLogin.agentInstalled(home: home))
        try installAgent()
        XCTAssertTrue(LaunchAtLogin.agentInstalled(home: home), "the plist is the agent")
        XCTAssertTrue(LaunchAtLogin.enabled(home: home, serviceEnabled: false),
                      "start at login reads on when only the agent is installed")
    }

    func testTurningItOffRemovesAndUnloadsTheAgent() throws {
        try installAgent()
        var unloaded: [String] = []
        let error = LaunchAtLogin.removeAgent(home: home, unload: { unloaded.append($0) })
        XCTAssertNil(error)
        XCTAssertEqual(unloaded, ["ai.yonatan-hq.claude-limits"], "the loaded agent is booted out")
        XCTAssertFalse(LaunchAtLogin.agentInstalled(home: home), "the plist is gone")
        XCTAssertFalse(LaunchAtLogin.enabled(home: home, serviceEnabled: false), "off is off")
    }

    /// Codex on 08db68a (P1): the app turning start at login off runs under the agent, and `launchctl bootout`
    /// ends it. Everything that must persist (the plist removal, the login item) happens BEFORE the unload,
    /// so the app dying mid-call still leaves login disabled.
    func testTheDisabledStateIsPersistedBeforeTheUnloadCanEndTheApp() throws {
        try installAgent()
        var plistGoneAtUnload: Bool?
        _ = LaunchAtLogin.removeAgent(home: home, unload: { _ in
            plistGoneAtUnload = !LaunchAtLogin.agentInstalled(home: self.home)
        })
        XCTAssertEqual(plistGoneAtUnload, true, "the plist is already gone when the agent is booted out")
    }

    /// Codex on 68db673 (P2): install.sh recreated and loaded the agent on every update, undoing a user's
    /// "off". Turning it off leaves a marker beside the store that the installer reads; turning it on clears it.
    func testTurningItOffLeavesAMarkerTheInstallerReadsAndOnClearsIt() throws {
        let support = home.appendingPathComponent("Library/Application Support/Tower")
        XCTAssertFalse(LaunchAtLogin.markedOff(support: support))
        LaunchAtLogin.markOff(true, support: support)
        XCTAssertTrue(LaunchAtLogin.markedOff(support: support), "off is remembered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(LaunchAtLogin.offMarkerName).path))
        LaunchAtLogin.markOff(false, support: support)
        XCTAssertFalse(LaunchAtLogin.markedOff(support: support), "on forgets it")
    }

    func testRemovingNoAgentIsQuiet() {
        var unloaded: [String] = []
        XCTAssertNil(LaunchAtLogin.removeAgent(home: home, unload: { unloaded.append($0) }))
        XCTAssertEqual(unloaded, [], "nothing to boot out")
    }
}
