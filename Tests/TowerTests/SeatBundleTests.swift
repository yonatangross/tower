import Foundation
import Security
import XCTest
@testable import Tower

/// One Keychain item per signing identity holds every remembered seat, so an identity change
/// costs one approval instead of one per seat plus a login password per seat. Fake values only.
final class SeatBundleTests: XCTestCase {
    private let payload = Data("token-pair".utf8)

    private let ownRequirement = Data("requirement-new".utf8)

    /// An ACL whose read entry names only `apps`, or trusts every app when `apps` is nil.
    private func acl(_ apps: Set<Data>?) -> [SeatKeychainACLEntry] {
        [SeatKeychainACLEntry(authorizations: [kSecACLAuthorizationDecrypt as String],
                              applicationRequirements: apps)]
    }

    private func adapter(_ fake: FakeSecItemStore, tag: String?,
                         itemACL: [SeatKeychainACLEntry]? = nil,
                         identifier: String? = ProductIdentity.bundleIdentifier) -> BundledClaudeSeatKeychain {
        var keychain = BundledClaudeSeatKeychain()
        let entries = itemACL ?? acl([ownRequirement])
        keychain.aclEntries = { _ in .success(entries) }
        keychain.ownRequirement = { [ownRequirement] in ownRequirement }
        keychain.identifierAt = { _ in identifier }
        keychain.calls = fake.calls
        keychain.counter = KeychainCallCounter()
        keychain.accessFactory = { descriptor in
            var access: SecAccess?
            let status = SecAccessCreate(descriptor as CFString, [] as CFArray, &access)
            guard status == errSecSuccess, let access else {
                return .failure(ClaudeSeatVaultError("test access creation failed (\(status))"))
            }
            return .success(access)
        }
        keychain.identityTag = { tag }
        return keychain
    }

    private func legacyItem(_ email: String) -> FakeSecItemStore.Item {
        FakeSecItemStore.Item(service: ClaudeSeatVault.service(for: email), account: email,
                              label: ClaudeSeatVault.ownershipMarker, data: payload)
    }

    private func bundleItem(tag: String, emails: [String]) throws -> FakeSecItemStore.Item {
        let entries = emails.map {
            BundledClaudeSeatKeychain.Entry(service: ClaudeSeatVault.service(for: $0), account: $0,
                                            label: ClaudeSeatVault.ownershipMarker, data: payload)
        }
        return FakeSecItemStore.Item(service: BundledClaudeSeatKeychain.bundleService, account: tag,
                                     label: BundledClaudeSeatKeychain.bundleLabel,
                                     data: try JSONEncoder().encode(entries))
    }

    func testFreshInstallWritesItsOwnBundleWithoutAPrompt() throws {
        let fake = FakeSecItemStore()
        let keychain = adapter(fake, tag: "new")
        XCTAssertNil(keychain.writeSeat(service: ClaudeSeatVault.service(for: "a@example.test"),
                                        account: "a@example.test", label: ClaudeSeatVault.ownershipMarker,
                                        data: payload))
        XCTAssertNil(keychain.writeSeat(service: ClaudeSeatVault.service(for: "b@example.test"),
                                        account: "b@example.test", label: ClaudeSeatVault.ownershipMarker,
                                        data: payload))
        XCTAssertEqual(fake.items.map(\.service), [BundledClaudeSeatKeychain.bundleService],
                       "two seats, one item")
        let readout = try keychain.readSeats(interaction: .suppressed).get()
        XCTAssertEqual(Set(readout.records.map(\.account)), ["a@example.test", "b@example.test"])
        XCTAssertTrue(fake.itemReads.allSatisfy(\.suppressed), "no read may show the dialog")
        XCTAssertTrue(fake.setAccesses.isEmpty)
    }

    /// 2026-11-05: the bundle at this build's own name answered -25293 and the whole refresh
    /// failed with "Keychain read failed (-25293)". A refusal is a login fact: every seat reads
    /// as unreadable, the readout says the bundle was refused, and nothing is deleted.
    func testRefusedOwnBundleIsUnreadableNotAFailedRefresh() throws {
        let fake = FakeSecItemStore()
        var bundle = try bundleItem(tag: "new", emails: ["a@example.test"])
        bundle.readStatus = errSecAuthFailed
        fake.items = [bundle, legacyItem("a@example.test")]
        let readout = try adapter(fake, tag: "new").readSeats(interaction: .suppressed).get()
        XCTAssertTrue(readout.bundleRefused)
        XCTAssertTrue(readout.records.isEmpty)
        XCTAssertEqual(readout.unreadable.map(\.account), ["a@example.test"])
        XCTAssertEqual(readout.unreadable.map(\.status), [errSecAuthFailed])
        XCTAssertEqual(readout.signerRefusals, 1)
        XCTAssertTrue(fake.deletes.isEmpty, "a refused item is never deleted by a background read")
    }

    func testBackgroundReadNeverTouchesAnotherIdentitysBundle() throws {
        let fake = FakeSecItemStore()
        fake.items = [try bundleItem(tag: "old", emails: ["a@example.test"])]
        let readout = try adapter(fake, tag: "new").readSeats(interaction: .suppressed).get()
        XCTAssertTrue(readout.records.isEmpty)
        XCTAssertEqual(fake.itemReads.map(\.account), ["new"], "only its own bundle is read")
    }

    func testRetrustMigratesTheOtherBundleWithOneAllowedReadThenDeletesIt() throws {
        let fake = FakeSecItemStore()
        fake.items = [try bundleItem(tag: "old", emails: ["a@example.test", "b@example.test", "c@example.test"])]
        let readout = try adapter(fake, tag: "new").readSeats(interaction: .allowed).get()
        XCTAssertEqual(readout.records.count, 3)
        XCTAssertEqual(fake.itemReads.filter { !$0.suppressed }.map(\.account), ["old"],
                       "three seats, one read that may prompt")
        XCTAssertEqual(fake.items.map(\.account), ["new"], "the migrated-from bundle is deleted")
        XCTAssertTrue(fake.setAccesses.isEmpty, "no access repair, so no password prompt")
    }

    func testFirstMigrationReadsLegacySeatsOnceAndDeletesThem() throws {
        let fake = FakeSecItemStore()
        fake.items = ["a@example.test", "b@example.test"].map(legacyItem)
        let keychain = adapter(fake, tag: "new")
        let readout = try keychain.readSeats(interaction: .allowed).get()
        XCTAssertEqual(Set(readout.records.map(\.account)), ["a@example.test", "b@example.test"])
        XCTAssertTrue(readout.unreadable.isEmpty)
        XCTAssertEqual(fake.items.map(\.service), [BundledClaudeSeatKeychain.bundleService])
        XCTAssertTrue(fake.setAccesses.isEmpty)

        let before = fake.itemReads.count
        _ = try keychain.readSeats(interaction: .suppressed).get()
        XCTAssertEqual(fake.itemReads.dropFirst(before).map(\.account), ["new"],
                       "after migration a refresh reads one item")
    }

    func testRefusedLegacySeatStopsFurtherDialogsAndStaysReported() throws {
        let fake = FakeSecItemStore()
        var refused = legacyItem("a@example.test")
        refused.readStatus = errSecUserCanceled
        fake.items = [refused, legacyItem("b@example.test")]
        let readout = try adapter(fake, tag: "new").readSeats(interaction: .allowed).get()
        XCTAssertEqual(readout.unreadable.map(\.account), ["a@example.test"])
        XCTAssertEqual(readout.unreadable.first?.status, errSecUserCanceled)
        XCTAssertEqual(fake.itemReads.filter { $0.account == "b@example.test" }.map(\.suppressed), [true],
                       "after a denied dialog the rest of the re-trust is suppressed")
    }

    func testPurgeAllRemovesEveryBundleAndLegacyItem() throws {
        let fake = FakeSecItemStore()
        fake.items = [try bundleItem(tag: "old", emails: ["a@example.test"]),
                      try bundleItem(tag: "new", emails: ["b@example.test"]),
                      legacyItem("c@example.test")]
        XCTAssertNil(adapter(fake, tag: "new").purgeAll())
        XCTAssertTrue(fake.items.isEmpty, "Forget means gone, whoever wrote it")
    }

    func testBareBuildReadsNoSeatDataAndCannotWrite() {
        let fake = FakeSecItemStore()
        fake.items = [legacyItem("a@example.test")]
        let keychain = adapter(fake, tag: nil)
        let readout = try? keychain.readSeats(interaction: .allowed).get()
        XCTAssertEqual(readout?.records.count, 0)
        XCTAssertTrue(fake.itemReads.isEmpty, "a bare build reads no item data")
        XCTAssertNotNil(keychain.writeSeat(service: "s", account: "a", label: "l", data: payload))
    }

    /// A bundle whose read entry trusts every process could have been planted by anyone; its
    /// "seats" must never reach the roster.
    func testRetrustNeverImportsABundleOpenToEveryApp() throws {
        let fake = FakeSecItemStore()
        fake.items = [try bundleItem(tag: "planted", emails: ["evil@example.test"])]
        let readout = try adapter(fake, tag: "new", itemACL: acl(nil)).readSeats(interaction: .allowed).get()
        XCTAssertTrue(readout.records.isEmpty)
        XCTAssertEqual(fake.items.map(\.account), ["planted"], "nothing written, nothing deleted")
    }

    /// An item at this build's own name that another process created keeps that creator's
    /// ACL through an update. Its contents are ignored and the write replaces the item.
    func testSquattedOwnBundleIsIgnoredAndReplacedOnWrite() throws {
        let fake = FakeSecItemStore()
        fake.items = [try bundleItem(tag: "new", emails: ["evil@example.test"])]
        let foreignApp = Data("someone-else".utf8)
        let keychain = adapter(fake, tag: "new", itemACL: acl([ownRequirement, foreignApp]))
        XCTAssertTrue(try keychain.readSeats(interaction: .suppressed).get().records.isEmpty)

        let service = ClaudeSeatVault.service(for: "a@example.test")
        XCTAssertNil(keychain.writeSeat(service: service, account: "a@example.test",
                                        label: ClaudeSeatVault.ownershipMarker, data: payload))
        XCTAssertEqual(fake.deletes, [BundledClaudeSeatKeychain.bundleService], "the squatted item is deleted")
        XCTAssertEqual(fake.adds.last?.hasExplicitAccess, true, "re-added with this build's own access")
        let stored = try JSONDecoder().decode([BundledClaudeSeatKeychain.Entry].self,
                                              from: try XCTUnwrap(fake.items.first?.data))
        XCTAssertEqual(stored.map(\.account), ["a@example.test"], "the planted seat is not carried over")
    }

    func testEntriesBreakingTheOwnershipRuleAreDropped() throws {
        let fake = FakeSecItemStore()
        let bad = BundledClaudeSeatKeychain.Entry(service: "Tower-seat-other@example.test",
                                                  account: "a@example.test",
                                                  label: ClaudeSeatVault.ownershipMarker, data: payload)
        fake.items = [FakeSecItemStore.Item(service: BundledClaudeSeatKeychain.bundleService, account: "new",
                                            label: BundledClaudeSeatKeychain.bundleLabel,
                                            data: try JSONEncoder().encode([bad]))]
        XCTAssertTrue(try adapter(fake, tag: "new").readSeats(interaction: .suppressed).get().records.isEmpty)
    }

    // MARK: Import rule (merge-loop-16 legs 1 and 2 on ef4c23d)

    private func pathData(_ path: String) -> Data { Data((path + "\0").utf8) }

    private func importable(_ apps: Set<Data>?, identifier: String? = ProductIdentity.bundleIdentifier,
                            own: Data? = nil) -> Bool {
        TowerSeatKeychainAccess.readClosedToTower(
            acl(apps), ownApplication: own ?? ownRequirement, identifierAt: { _ in identifier })
    }

    /// `security add-generic-password` with no -T list trusts /usr/bin/security only. That
    /// ACL is closed to one app, which the old rule accepted.
    func testItemTrustingOnlyTheSecurityToolIsRefused() {
        let security = pathData(TowerSeatKeychainAccess.securityToolPath)
        XCTAssertFalse(importable([security]))
        XCTAssertFalse(importable([security], own: security),
                       "refused even if the running path were the security tool")
    }

    func testItemTrustingTowerAndAnotherProgramIsRefused() {
        XCTAssertFalse(importable([ownRequirement, pathData("/tmp/attacker")]))
    }

    func testItemTrustingOnlyAnotherProgramIsRefused() {
        XCTAssertFalse(importable([pathData("/tmp/attacker")]))
    }

    /// An ad hoc identifier is self-declared: the right id at the wrong path is refused,
    /// and the right path with a foreign id is refused.
    func testSigningIdentifierAloneIsNotEnough() {
        XCTAssertFalse(importable([pathData("/tmp/fake.app")], identifier: ProductIdentity.bundleIdentifier),
                       "a Tower id claimed by code at another path")
        XCTAssertFalse(importable([ownRequirement], identifier: "com.example.other"),
                       "the running path no longer holds Tower code")
        XCTAssertFalse(importable([ownRequirement], identifier: nil), "no valid code at the path")
    }

    /// Public releases are ad hoc: the designated requirement is a bare cdhash, so it names
    /// no identifier, but an update replaces the app at the same path and the code there
    /// still signs with the bundle id. Re-trust keeps migrating across ad hoc releases.
    func testAdHocReleaseAtTheSamePathKeepsMigrating() throws {
        XCTAssertTrue(importable([ownRequirement]))
        let fake = FakeSecItemStore()
        fake.items = [try bundleItem(tag: "adhoc-previous", emails: ["a@example.test"])]
        let readout = try adapter(fake, tag: "adhoc-current").readSeats(interaction: .allowed).get()
        XCTAssertEqual(readout.records.map(\.account), ["a@example.test"])
    }

    func testRetrustRefusesAPlantedSecurityToolItem() throws {
        let fake = FakeSecItemStore()
        fake.items = [try bundleItem(tag: "planted", emails: ["evil@example.test"]), legacyItem("evil2@example.test")]
        let security = pathData(TowerSeatKeychainAccess.securityToolPath)
        let readout = try adapter(fake, tag: "new", itemACL: acl([security])).readSeats(interaction: .allowed).get()
        XCTAssertTrue(readout.records.isEmpty, "neither the planted bundle nor the planted legacy item is imported")
        XCTAssertEqual(Set(fake.items.map(\.account)), ["planted", "evil2@example.test"], "nothing deleted")
    }

    func testRemovingTheLastSeatDeletesTheBundle() {
        let fake = FakeSecItemStore()
        let keychain = adapter(fake, tag: "new")
        let service = ClaudeSeatVault.service(for: "a@example.test")
        XCTAssertNil(keychain.writeSeat(service: service, account: "a@example.test",
                                        label: ClaudeSeatVault.ownershipMarker, data: payload))
        XCTAssertNil(keychain.removeSeat(service: service, account: "a@example.test",
                                         label: ClaudeSeatVault.ownershipMarker))
        XCTAssertTrue(fake.items.isEmpty)
    }
}
