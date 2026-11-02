import XCTest
@testable import Tower

final class ProductIdentityTests: XCTestCase {
    func testDisplayNameIsTowerAndInstallIdentityStaysUnchanged() {
        XCTAssertEqual(ProductIdentity.displayName, "Tower")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "ai.yonatan-hq.claude-limits")
        XCTAssertEqual(ProductIdentity.supportDirectoryName, "HQClaudeLimits")
        XCTAssertEqual(ProductIdentity.processName, "HQClaudeLimits")
    }

    func testStatusHeaderUsesDisplayNameNotLimits() {
        XCTAssertEqual(ProductIdentity.displayName.uppercased(), "TOWER")
        XCTAssertFalse(ProductIdentity.displayName.localizedCaseInsensitiveContains("Limits"))
    }
}
