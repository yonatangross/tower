import Foundation
import Security
import XCTest
@testable import Tower

/// `swift test` runs inside an xctest bundle that answers errSecCSBadBundleFormat to
/// SecStaticCodeCreateWithPath, so the running-application path cannot resolve here.
/// A platform-signed binary stands in for it and the ACL assertions compare
/// requirement DATA, which is what the production repair check compares.
final class KeychainAccessTests: XCTestCase {
    private let applicationStandIn = "/bin/ls"

    func testTrustedApplicationsTrustOnlyTheCurrentApplication() throws {
        let applications: [SecTrustedApplication]
        switch TowerSeatKeychainAccess.trustedApplications(currentPath: applicationStandIn) {
        case .failure(let error):
            XCTFail(error.message)
            return
        case .success(let value): applications = value
        }
        XCTAssertEqual(applications.count, 1, "only the current application is trusted")
        var access: SecAccess?
        XCTAssertEqual(
            SecAccessCreate(ClaudeSeatVault.ownershipMarker as CFString,
                            applications as CFArray, &access),
            errSecSuccess)
        let accessObject = try XCTUnwrap(access)
        let trusted = try trustedRequirementData(in: accessObject)
        let application = try requirementData(at: applicationStandIn)
        XCTAssertTrue(trusted.contains(application),
                      "SecAccess trusts the current application requirement")
        // /usr/bin/security must never be trusted on a seat item: any user process
        // could run it and read seat tokens without a prompt.
        let security = try requirementData(at: TowerSeatKeychainAccess.securityToolPath)
        XCTAssertFalse(trusted.contains(security),
                       "SecAccess must not trust /usr/bin/security")
    }

    func testFreshAccessSatisfiesTheRepairCheck() throws {
        let applications: [SecTrustedApplication]
        switch TowerSeatKeychainAccess.trustedApplications(currentPath: applicationStandIn) {
        case .failure(let error):
            XCTFail(error.message)
            return
        case .success(let value): applications = value
        }
        var access: SecAccess?
        XCTAssertEqual(
            SecAccessCreate(ClaudeSeatVault.ownershipMarker as CFString,
                            applications as CFArray, &access),
            errSecSuccess)
        let accessObject = try XCTUnwrap(access)
        let entries = try aclEntries(in: accessObject)
        let required = try [requirementData(at: applicationStandIn)]
        XCTAssertFalse(TowerSeatKeychainAccess.requiresRepair(required: required, aclEntries: entries),
                       "an access written for the current application is never repaired")
    }

    func testAnyApplicationACLEntryNeedsNoRepair() {
        // SecACLCopyContents reports a NULL application list for an entry that
        // trusts every application; that entry must not read as an error.
        let anyApplication = SeatKeychainACLEntry(
            authorizations: [kSecACLAuthorizationDecrypt as String],
            applicationRequirements: nil)
        XCTAssertFalse(TowerSeatKeychainAccess.requiresRepair(
            required: [Data("unrelated".utf8)], aclEntries: [anyApplication]),
            "an any-application ACL is readable by all and needs no repair")
    }

    func testSignedCodeIsTrusted() {
        switch TowerSeatKeychainAccess.validateSignedCode(at: applicationStandIn) {
        case .failure(let error): XCTFail(error.message)
        case .success: break
        }
    }

    func testUnsignedCodeIsNotTrusted() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("# unsigned fixture\n".utf8).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        switch TowerSeatKeychainAccess.validateSignedCode(at: fixture.path) {
        case .success:
            XCTFail("unsigned code must not be trusted")
        case .failure:
            break
        }
    }

    private func aclEntries(in access: SecAccess) throws -> [SeatKeychainACLEntry] {
        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess, let aclList else {
            throw ClaudeSeatVaultError("could not inspect SecAccess ACLs")
        }
        var entries: [SeatKeychainACLEntry] = []
        for case let acl as SecACL in aclList as [AnyObject] {
            let authorizations = Set(
                (SecACLCopyAuthorizations(acl) as [AnyObject]).compactMap { $0 as? String })
            var applications: CFArray?
            var description: CFString?
            var prompt: SecKeychainPromptSelector = []
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess else {
                throw ClaudeSeatVaultError("could not inspect SecAccess applications")
            }
            // Entries like the Encrypt ACL have a NULL application list, which
            // names every application, so requirements stays nil rather than empty.
            var requirements: Set<Data>?
            if let applications {
                var collected = Set<Data>()
                for case let application as SecTrustedApplication in applications as [AnyObject] {
                    collected.insert(try requirementData(of: application))
                }
                requirements = collected
            }
            entries.append(SeatKeychainACLEntry(
                authorizations: authorizations, applicationRequirements: requirements))
        }
        return entries
    }

    private func trustedRequirementData(in access: SecAccess) throws -> Set<Data> {
        Set(try aclEntries(in: access).flatMap { $0.applicationRequirements ?? [] })
    }

    private func requirementData(of application: SecTrustedApplication) throws -> Data {
        var data: CFData?
        guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess, let data else {
            throw ClaudeSeatVaultError("could not read SecAccess application requirement")
        }
        return data as Data
    }

    private func requirementData(at path: String) throws -> Data {
        var application: SecTrustedApplication?
        guard path.withCString({ SecTrustedApplicationCreateFromPath($0, &application) }) == errSecSuccess,
              let application else {
            throw ClaudeSeatVaultError("could not create trusted application for \(path)")
        }
        return try requirementData(of: application)
    }
}
