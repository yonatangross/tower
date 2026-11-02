import Foundation
import Security
import XCTest
@testable import Tower

final class KeychainReadableMigrationTests: XCTestCase {
    private let email = "one@example.test"
    private let payload = Data("retained-seat".utf8)

    func testMatchingLabelWithForeignServiceIsNotReadOrChanged() {
        let fake = FakeSecItemStore()
        fake.items = [FakeSecItemStore.Item(
            service: "other-service", account: email, label: ClaudeSeatVault.ownershipMarker, data: payload)]

        let readout = read(fake, requiresRepair: true)

        XCTAssertTrue(readout.records.isEmpty)
        XCTAssertTrue(readout.unreadable.isEmpty)
        XCTAssertTrue(fake.itemReads.isEmpty, "foreign marker item is never read")
        XCTAssertTrue(fake.deletes.isEmpty)
        XCTAssertTrue(fake.adds.isEmpty)
        XCTAssertTrue(fake.setAccesses.isEmpty)
        XCTAssertEqual(fake.items.first?.data, payload)
    }

    func testReadableLegacyItemReplacesAccessInPlace() {
        let fake = ownedStore()

        let readout = read(fake, requiresRepair: true)

        XCTAssertEqual(readout.records.map(\.data), [payload])
        XCTAssertTrue(readout.unreadable.isEmpty)
        XCTAssertTrue(fake.deletes.isEmpty, "owned readable legacy item is retained")
        XCTAssertTrue(fake.adds.isEmpty)
        XCTAssertEqual(fake.setAccesses.count, 1,
                       "owned readable legacy access is replaced in place")
        XCTAssertEqual(fake.item(email)?.data, payload,
                       "legacy payload remains after in place access replacement")
    }

    func testFailedInPlaceMigrationRetainsPayload() {
        let fake = ownedStore()
        fake.nextSetAccessStatuses = [errSecAuthFailed]

        let readout = read(fake, requiresRepair: true)

        XCTAssertTrue(readout.records.isEmpty)
        XCTAssertEqual(readout.unreadable.map(\.status), [errSecAuthFailed],
                       "failed in place migration reports set access status")
        XCTAssertTrue(fake.deletes.isEmpty)
        XCTAssertTrue(fake.adds.isEmpty)
        XCTAssertEqual(fake.setAccesses.count, 1)
        XCTAssertEqual(fake.item(email)?.data, payload,
                       "failed in place access replacement retains payload")
    }

    func testSuppressedReadDefersACLMutation() {
        let fake = ownedStore()

        let readout = read(fake, requiresRepair: true, interaction: .suppressed)

        XCTAssertEqual(readout.records.map(\.data), [payload])
        XCTAssertTrue(fake.setAccesses.isEmpty, "suppressed read never changes ACL")
        XCTAssertEqual(fake.item(email)?.data, payload)
    }

    func testDeniedACLMutationSuppressesRemainingItemReads() {
        let fake = ownedStore()
        fake.items.append(FakeSecItemStore.Item(
            service: ClaudeSeatVault.service(for: "two@example.test"),
            account: "two@example.test", label: ClaudeSeatVault.ownershipMarker, data: payload))
        fake.nextSetAccessStatuses = [errSecAuthFailed]

        let readout = read(fake, requiresRepair: true)

        XCTAssertEqual(fake.itemReads.map(\.suppressed), [false, true],
                       "denied ACL mutation suppresses remaining item reads")
        XCTAssertEqual(fake.setAccesses.count, 1)
        XCTAssertEqual(readout.unreadable.map(\.status), [errSecAuthFailed])
    }

    func testUnrelatedACLsDoNotSatisfyRequiredReadTrust() {
        let tower = Data("tower-requirement".utf8)
        let security = Data("security-requirement".utf8)
        let unrelated = SeatKeychainACLEntry(
            authorizations: [kSecACLAuthorizationEncrypt as String],
            applicationRequirements: [tower, security])
        let unrelatedSecond = SeatKeychainACLEntry(
            authorizations: [kSecACLAuthorizationSign as String],
            applicationRequirements: [tower, security])

        XCTAssertTrue(TowerSeatKeychainAccess.requiresRepair(
            required: [tower, security], aclEntries: [unrelated, unrelatedSecond]),
                      "unrelated ACL applications do not satisfy read trust")
    }

    private func ownedStore() -> FakeSecItemStore {
        let fake = FakeSecItemStore()
        fake.items = [FakeSecItemStore.Item(
            service: ClaudeSeatVault.service(for: email), account: email,
            label: ClaudeSeatVault.ownershipMarker, data: payload)]
        return fake
    }

    private func read(
        _ fake: FakeSecItemStore, requiresRepair: Bool,
        interaction: ClaudeSeatReadInteraction = .allowed
    ) -> ClaudeSeatKeychainReadout {
        let keychain = fake.keychain(counter: KeychainCallCounter(), accessInspector: { _ in
            .success(SeatKeychainAccessSnapshot(requiresRepair: requiresRepair))
        })
        switch keychain.readSeats(interaction: interaction) {
        case .failure(let error):
            XCTFail(error.message)
            return ClaudeSeatKeychainReadout()
        case .success(let readout): return readout
        }
    }

}
