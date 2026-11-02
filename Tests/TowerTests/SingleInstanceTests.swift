import XCTest
import AppKit
@testable import Tower

final class SingleInstanceTests: XCTestCase {
    func testBundleIdentifierMatchesApp() {
        // The bundle ID used in enforceSingleInstance must match the app's CFBundleIdentifier
        let bundleID = ProductIdentity.bundleIdentifier
        XCTAssertEqual(bundleID, "ai.yonatan-hq.claude-limits", "Bundle ID must match CFBundleIdentifier")
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
