import XCTest
@testable import Tower

final class ProductIdentityTests: XCTestCase {
    func testDisplayNameAndInstallIdentityAreTower() {
        XCTAssertEqual(ProductIdentity.displayName, "Tower")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "ai.yonyon.tower")
        XCTAssertEqual(ProductIdentity.supportDirectoryName, "Tower")
        XCTAssertEqual(ProductIdentity.processName, "Tower")
    }

    func testStatusHeaderUsesDisplayNameNotLimits() {
        XCTAssertEqual(ProductIdentity.displayName.uppercased(), "TOWER")
        XCTAssertFalse(ProductIdentity.displayName.localizedCaseInsensitiveContains("Limits"))
    }
}
