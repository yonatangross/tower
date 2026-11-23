import XCTest
import AppKit
@testable import Tower

final class SingleInstanceTests: XCTestCase {
    func testBundleIdentifierMatchesApp() {
        // The bundle ID used in enforceSingleInstance must match the app's CFBundleIdentifier
        let bundleID = ProductIdentity.bundleIdentifier
        XCTAssertEqual(bundleID, "ai.yonyon.tower", "Bundle ID must match CFBundleIdentifier")
    }

    func testRunningApplicationsReturnsArray() {
        // Verify NSRunningApplication API is callable with our bundle ID
        let bundleID = ProductIdentity.bundleIdentifier
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        XCTAssertNotNil(apps, "runningApplications should return an array")
    }

    func testProcessIdentifierComparison() {
        // Verify we can filter by process identifier
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundleID = ProductIdentity.bundleIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != pid }
        // In test environment, this should just return an empty or filtered array
        XCTAssertNotNil(others, "Filtering by PID should work")
    }

    func testADifferentBundleIdentifierIsItsOwnInstance() {
        let devID = ProductIdentity.bundleIdentifier + ".dev"
        let dev = SingleInstance.identifier(runningBundleIdentifier: devID)
        XCTAssertEqual(dev, devID)
        XCTAssertNotEqual(dev, ProductIdentity.bundleIdentifier)
    }

    func testTheInstalledIdentifierIsTheOneTheGuardLooksFor() {
        XCTAssertEqual(SingleInstance.identifier(runningBundleIdentifier: ProductIdentity.bundleIdentifier),
                       ProductIdentity.bundleIdentifier)
    }

    /// Only a dev copy is isolated, so no other identifier may run beside the installed Tower.
    func testAnIdentifierThatIsNotIsolatedCollapsesIntoTheInstalledTower() {
        for id in [ProductIdentity.bundleIdentifier + "-dev", ProductIdentity.legacyBundleIdentifier, "com.example.other"] {
            XCTAssertEqual(SingleInstance.identifier(runningBundleIdentifier: id), ProductIdentity.bundleIdentifier, id)
        }
    }

    func testTheGuardLooksUpTheRightPeers() {
        let product = ProductIdentity.bundleIdentifier
        XCTAssertEqual(SingleInstance.lookupIdentifiers(runningBundleIdentifier: product), [product])
        XCTAssertEqual(SingleInstance.lookupIdentifiers(runningBundleIdentifier: nil), [product])
        XCTAssertEqual(SingleInstance.lookupIdentifiers(runningBundleIdentifier: product + ".dev"), [product + ".dev"])
        XCTAssertEqual(SingleInstance.lookupIdentifiers(runningBundleIdentifier: product + "-dev"), [product, product + "-dev"])
    }

    func testADevCopyRefusesToEnableRetention() throws {
        let fixture = try MCPFixture()
        defer { fixture.tearDown() }
        let vault = fixture.keychain.vault(in: fixture.dir, enabled: { false },
                                           setEnabled: { _ in XCTFail("a dev copy must not write the preference") },
                                           refusesSeatChanges: { true })
        XCTAssertEqual(vault.enableRetention(), DevCopyIsolation.refusal)
    }

    func testNoBundleFallsBackToTheConstant() {
        XCTAssertEqual(SingleInstance.identifier(runningBundleIdentifier: nil), ProductIdentity.bundleIdentifier)
        XCTAssertEqual(SingleInstance.identifier(runningBundleIdentifier: ""), ProductIdentity.bundleIdentifier)
    }

    func testADevCopyNeverRetainsSeats() throws {
        let suite = "tower-dev-retention-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dev = ProductIdentity.bundleIdentifier + ".dev"
        XCTAssertFalse(ClaudeSeatRetention.isEnabled(defaults: defaults, domain: dev))
        XCTAssertTrue(ClaudeSeatRetention.isEnabled(defaults: defaults, domain: ProductIdentity.bundleIdentifier))
        ClaudeSeatRetention.setEnabled(true, defaults: defaults)
        XCTAssertFalse(ClaudeSeatRetention.isEnabled(defaults: defaults, domain: dev))
    }

    func testADevCopyGetsItsOwnSupportFolder() {
        let base = URL(fileURLWithPath: "/tmp/support")
        XCTAssertEqual(DevCopyIsolation.supportOverride(isDevCopy: true, env: [:], applicationSupport: base),
                       "/tmp/support/Tower Dev")
        XCTAssertNil(DevCopyIsolation.supportOverride(isDevCopy: false, env: [:], applicationSupport: base))
        XCTAssertNil(DevCopyIsolation.supportOverride(
            isDevCopy: true, env: ["TOWER_SUPPORT_DIR": "/tmp/x"], applicationSupport: base))
    }

    func testADemoRunWithNoStoreStillRefusesOnADevCopy() {
        let base = URL(fileURLWithPath: "/tmp/support")
        let env = ["TOWER_DEMO": "1"]
        XCTAssertNil(DevCopyIsolation.supportOverride(isDevCopy: true, env: env, applicationSupport: base))
        XCTAssertTrue(DemoMode.isMisconfigured(env: env))
    }

    func testADevCopyKeepsItsOwnCursorSignInItem() {
        let installed = KeychainCursorTokenStore.serviceName(domain: ProductIdentity.bundleIdentifier)
        let dev = KeychainCursorTokenStore.serviceName(domain: ProductIdentity.bundleIdentifier + ".dev")
        XCTAssertEqual(installed, "ai.yonyon.tower.cursor-signin")
        XCTAssertNotEqual(dev, installed)
    }

    func testADevCopyDoesNotWriteTheRealMirror() {
        let env = ["TOWER_SUPPORT_DIR": "/tmp/tower-dev", "CLAUDE_CONFIG_DIR": "/tmp/claude"]
        XCTAssertEqual(Store.defaultMirrorPath(env: env, devCopy: true).path, "/tmp/tower-dev/quota-cache.json")
        XCTAssertEqual(Store.defaultMirrorPath(env: env, devCopy: false).path, "/tmp/claude/quota-cache.json")
    }

    func testADevCopyRefusesToChangeStartAtLogin() {
        XCTAssertEqual(LaunchAtLogin.set(false, devCopy: true), DevCopyIsolation.refusal)
        XCTAssertEqual(LaunchAtLogin.set(true, devCopy: true), DevCopyIsolation.refusal)
        XCTAssertEqual(LaunchAtLogin.unregisterService(devCopy: true), DevCopyIsolation.refusal)
    }

    func testADevCopyRefusesToForgetOrRetrustSeats() throws {
        let fixture = try MCPFixture()
        defer { fixture.tearDown() }
        let vault = fixture.keychain.vault(in: fixture.dir, enabled: { true }, setEnabled: { _ in },
                                           refusesSeatChanges: { true })
        XCTAssertEqual(vault.forgetAll(), DevCopyIsolation.refusal)
        XCTAssertEqual(vault.disableAndForget(suppressing: nil), DevCopyIsolation.refusal)
        if case .success = vault.retrust() { XCTFail("a dev copy must not re-trust the installed seats") }
    }

    func testActivateIsCallable() {
        // Verify activate() is callable on NSRunningApplication
        let bundleID = ProductIdentity.bundleIdentifier
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            // activate() without options is the macOS 14+ replacement
            app.activate()
            // No assertion needed: we're just verifying the API exists and is callable
        }
    }
}
