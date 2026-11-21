import XCTest
import SwiftUI
@testable import Tower

/// #121: the panel stored "Remember Claude seats" OFF in its bundle domain while `tower
/// status` and `tower mcp`, started through the `~/.local/bin/tower` symlink, read the
/// domain `tower`, found no key and defaulted to ON. These pin the resolution that puts
/// every Tower process on one domain, and the text size that rides in it.
final class SettingsDomainTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-settings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// A minimal Tower.app with an Info.plist naming `identifier`, returning the executable.
    private func makeApp(identifier: String) throws -> URL {
        let app = scratch.appendingPathComponent("Tower.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Tower",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "abc1234",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Tower")
        try Data("binary".utf8).write(to: executable)
        return executable
    }

    func testSymlinkedExecutableResolvesItsEnclosingApp() throws {
        let executable = try makeApp(identifier: "ai.yonyon.tower.test")
        let bin = scratch.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("tower")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

        let bundle = ProductIdentity.enclosingAppBundle(executablePath: link.path)
        XCTAssertEqual(bundle?.bundleIdentifier, "ai.yonyon.tower.test")
        XCTAssertEqual(bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "abc1234")
    }

    func testBareBinaryHasNoEnclosingApp() throws {
        let build = scratch.appendingPathComponent(".build/release")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let binary = build.appendingPathComponent("Tower")
        try Data("binary".utf8).write(to: binary)
        XCTAssertNil(ProductIdentity.enclosingAppBundle(executablePath: binary.path))
        XCTAssertNil(ProductIdentity.enclosingAppBundle(executablePath: nil))
        XCTAssertNil(ProductIdentity.enclosingAppBundle(executablePath: ""))
    }

    func testDomainIsTheRunningBundleOrTheInstalledId() {
        XCTAssertEqual(TowerPreferences.domain(runningBundleIdentifier: "ai.yonyon.tower"),
                       "ai.yonyon.tower")
        // A dev copy keeps its own domain, so it cannot flip the installed Tower's settings.
        XCTAssertEqual(TowerPreferences.domain(runningBundleIdentifier: "ai.yonyon.tower.dev"),
                       "ai.yonyon.tower.dev")
        // A bare build product has no bundle: it reads the installed Tower's settings,
        // never a domain named after its own executable.
        XCTAssertEqual(TowerPreferences.domain(runningBundleIdentifier: nil), ProductIdentity.bundleIdentifier)
        XCTAssertEqual(TowerPreferences.domain(runningBundleIdentifier: ""), ProductIdentity.bundleIdentifier)
    }

    func testOwnDomainIsStandardDefaults() {
        let own = TowerPreferences.defaults(domain: "x.y.z", mainBundleIdentifier: "x.y.z")
        XCTAssertTrue(own === UserDefaults.standard)
        let other = TowerPreferences.defaults(domain: "tower-settings-\(UUID().uuidString)",
                                              mainBundleIdentifier: nil)
        XCTAssertFalse(other === UserDefaults.standard)
    }

    /// The regression itself: what the panel writes, the CLI reads. Two separate
    /// UserDefaults objects over one domain stand for the two processes.
    func testRetentionWrittenByThePanelIsWhatTheCLIReads() {
        let domain = "tower-settings-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        // In the app the panel side is .standard over its own bundle domain; the test
        // runner's .standard is some other domain, so the panel side is a suite here.
        let panelSide = UserDefaults(suiteName: domain)!
        let cli = TowerPreferences.defaults(domain: domain, mainBundleIdentifier: nil)

        XCTAssertTrue(ClaudeSeatRetention.isEnabled(defaults: cli), "no key means on")
        ClaudeSeatRetention.setEnabled(false, defaults: panelSide)
        XCTAssertFalse(ClaudeSeatRetention.isEnabled(defaults: cli))
        ClaudeSeatRetention.setEnabled(true, defaults: panelSide)
        XCTAssertTrue(ClaudeSeatRetention.isEnabled(defaults: cli))
    }

    func testTextSizeDefaultsToMediumAndRoundTrips() {
        let domain = "tower-settings-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let defaults = UserDefaults(suiteName: domain)!
        XCTAssertEqual(TowerTextSize.stored(defaults: defaults, environment: [:]), .m)
        TowerTextSize.store(.xl, defaults: defaults)
        XCTAssertEqual(TowerTextSize.stored(defaults: defaults, environment: [:]), .xl)
        defaults.set("huge", forKey: TowerTextSize.preferenceKey)
        XCTAssertEqual(TowerTextSize.stored(defaults: defaults, environment: [:]), .m,
                       "an unknown stored value falls back, never crashes the panel")
    }

    func testEnvironmentOverridesTheStoredSize() {
        let domain = "tower-settings-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let defaults = UserDefaults(suiteName: domain)!
        TowerTextSize.store(.s, defaults: defaults)
        XCTAssertEqual(TowerTextSize.stored(defaults: defaults, environment: ["TOWER_TEXT_SIZE": "L"]), .l)
        XCTAssertEqual(TowerTextSize.stored(defaults: defaults, environment: ["TOWER_TEXT_SIZE": "bogus"]), .s)
    }

    func testFactorsGrowAndSmallIsTheOriginalPanel() {
        XCTAssertEqual(TowerTextSize.s.factor, 1.0)
        let factors = TowerTextSize.allCases.map(\.factor)
        XCTAssertEqual(factors, factors.sorted())
        XCTAssertEqual(Set(factors).count, factors.count)
    }

    func testBoardCapLeavesRoomForHeaderAndFooter() {
        XCTAssertEqual(BoardScroll<EmptyView>.cap(visibleHeight: 1000, textFactor: 1.0), 700)
        XCTAssertEqual(BoardScroll<EmptyView>.cap(visibleHeight: 1000, textFactor: 1.5), 550)
        // A short screen still shows a usable slice of the boards.
        XCTAssertEqual(BoardScroll<EmptyView>.cap(visibleHeight: 300, textFactor: 1.5), 240)
    }
}
