import Foundation
import Security
import XCTest
@testable import Tower

/// An in-memory stand-in for the four Security calls the seat adapter makes, so the real
/// `SystemClaudeSeatKeychain` query construction and parsing run without touching the login
/// keychain. Each item carries the status its ACL answers this build with: 0 for an item this
/// build wrote, errSecAuthFailed or errSecInteractionNotAllowed for one an earlier ad-hoc
/// build wrote.
final class FakeSecItemStore {
    final class ItemReference: NSObject {}

    struct Item {
        let service: String
        let account: String
        let label: String
        var data: Data
        var readStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus = errSecSuccess
    }

    var items: [Item] = []
    private(set) var deletes: [String] = []
    private(set) var adds: [(service: String, account: String, hasExplicitAccess: Bool)] = []
    private(set) var setAccesses: [SecAccess] = []
    var nextSetAccessStatuses: [OSStatus] = []
    /// For each item-data read, the account asked for and whether the query suppressed
    /// user interaction (carried an authentication context). Listing calls are excluded.
    private(set) var itemReads: [(account: String, suppressed: Bool)] = []

    var calls: SecItemCalls {
        SecItemCalls(
            copyMatching: { [unowned self] query, result in copyMatching(query, result) },
            update: { [unowned self] query, attributes in update(query, attributes) },
            add: { [unowned self] query, _ in add(query) },
            delete: { [unowned self] query in delete(query) },
            setAccess: { [unowned self] reference, access in setAccess(reference, access) })
    }

    func keychain(
        counter: KeychainCallCounter,
        accessInspector: @escaping (CFTypeRef) -> Result<SeatKeychainAccessSnapshot, SeatKeychainAccessInspectionError>
            = { _ in .success(SeatKeychainAccessSnapshot(requiresRepair: false)) },
        accessFactory: @escaping (String) -> Result<SecAccess, ClaudeSeatVaultError> = FakeSecItemStore.testAccess
    ) -> SystemClaudeSeatKeychain {
        SystemClaudeSeatKeychain(
            calls: calls, counter: counter,
            accessInspector: accessInspector, accessFactory: accessFactory)
    }

    /// A real SecAccess trusting nothing: the fake store records only that the key
    /// was set. The production factory cannot run here because the xctest bundle
    /// has no usable code signature (errSecCSBadBundleFormat).
    private static func testAccess(descriptor: String) -> Result<SecAccess, ClaudeSeatVaultError> {
        var access: SecAccess?
        let status = SecAccessCreate(descriptor as CFString, [] as CFArray, &access)
        guard status == errSecSuccess, let access else {
            return .failure(ClaudeSeatVaultError("test access creation failed (\(status))"))
        }
        return .success(access)
    }

    func item(_ email: String) -> Item? {
        items.first { $0.account == email }
    }

    private func fields(_ query: CFDictionary) -> [String: Any] {
        (query as NSDictionary) as? [String: Any] ?? [:]
    }

    private func index(of query: [String: Any]) -> Int? {
        items.firstIndex {
            $0.service == query[kSecAttrService as String] as? String
                && $0.account == query[kSecAttrAccount as String] as? String
                && $0.label == query[kSecAttrLabel as String] as? String
        }
    }

    private func copyMatching(_ raw: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let query = fields(raw)
        let matchAll = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
        let returnsData = query[kSecReturnData as String] as? Bool == true
        // The macOS 26 login keychain rejects this combination outright (#45).
        if matchAll && returnsData { return errSecParam }
        if matchAll {
            let label = query[kSecAttrLabel as String] as? String
            let rows = items.filter { $0.label == label }.map { item -> [String: Any] in
                [kSecAttrService as String: item.service, kSecAttrAccount as String: item.account,
                 kSecAttrLabel as String: item.label]
            }
            guard !rows.isEmpty else { return errSecItemNotFound }
            result?.pointee = rows as NSArray
            return errSecSuccess
        }
        itemReads.append((
            account: query[kSecAttrAccount as String] as? String ?? "?",
            suppressed: query[kSecUseAuthenticationContext as String] != nil))
        guard let index = index(of: query) else { return errSecItemNotFound }
        guard items[index].readStatus == errSecSuccess else { return items[index].readStatus }
        if query[kSecReturnRef as String] as? Bool == true {
            result?.pointee = [
                kSecValueData as String: items[index].data,
                kSecValueRef as String: ItemReference(),
            ] as NSDictionary
        } else {
            result?.pointee = items[index].data as NSData
        }
        return errSecSuccess
    }

    private func update(_ raw: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        guard let index = index(of: fields(raw)) else { return errSecItemNotFound }
        guard items[index].readStatus == errSecSuccess else { return items[index].readStatus }
        guard let data = fields(attributes)[kSecValueData as String] as? Data else { return errSecParam }
        items[index].data = data
        return errSecSuccess
    }

    private func add(_ raw: CFDictionary) -> OSStatus {
        let query = fields(raw)
        let service = query[kSecAttrService as String] as? String ?? "?"
        let account = query[kSecAttrAccount as String] as? String ?? "?"
        adds.append((service: service, account: account,
                     hasExplicitAccess: query[kSecAttrAccess as String] != nil))
        guard index(of: query) == nil else { return errSecDuplicateItem }
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String,
              let label = query[kSecAttrLabel as String] as? String,
              let data = query[kSecValueData as String] as? Data
        else { return errSecParam }
        items.append(Item(service: service, account: account, label: label, data: data))
        return errSecSuccess
    }

    private func setAccess(_ reference: CFTypeRef, _ access: SecAccess) -> OSStatus {
        setAccesses.append(access)
        guard reference is ItemReference else { return errSecParam }
        guard !nextSetAccessStatuses.isEmpty else { return errSecSuccess }
        return nextSetAccessStatuses.removeFirst()
    }

    private func delete(_ raw: CFDictionary) -> OSStatus {
        guard let index = index(of: fields(raw)) else { return errSecItemNotFound }
        deletes.append(items[index].service)
        guard items[index].deleteStatus == errSecSuccess else { return items[index].deleteStatus }
        items.remove(at: index)
        return errSecSuccess
    }
}

/// #68: an owned item an earlier ad-hoc build wrote refuses this build. The refresh loop must
/// read the seat items at most once per launch, re-create the active seat's refused item
/// once from the CLI credential, and never retry a refused item within the launch.
final class KeychainReadCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    private func credential(_ token: String, email: String) -> ClaudeCredential {
        ClaudeCredential(service: Keychain.defaultService, accessToken: token,
                         subscriptionType: "max", rateLimitTier: nil,
                         expiresAt: now.addingTimeInterval(3600), emailHint: email)
    }

    private func vault(_ fake: FakeSecItemStore, counter: KeychainCallCounter,
                       log: @escaping (String) -> Void = { _ in },
                       now: (() -> Date)? = nil,
                       mayPrompt: Bool = true) -> ClaudeSeatVault {
        ClaudeSeatVault(keychain: fake.keychain(counter: counter),
                        lockURL: dir.appendingPathComponent("seat.lock"),
                        stateURL: dir.appendingPathComponent("seat-state.plist"),
                        retentionEnabled: { true }, setRetentionEnabled: { _ in }, log: log,
                        now: now ?? { self.now }, mayPrompt: { mayPrompt })
    }

    private func usage() -> UsageResponse {
        UsageResponse(five_hour: UsageWindow(utilization: 10, resets_at: nil),
                      seven_day: UsageWindow(utilization: 20, resets_at: nil),
                      seven_day_opus: nil, seven_day_sonnet: nil, limits: nil)
    }

    /// Three owned seats: `two` written by this build, `one` (the active CLI login) and
    /// `three` written by an earlier signer. Returns the fake after the previous launch.
    private func previousLaunch() -> FakeSecItemStore {
        let fake = FakeSecItemStore()
        let earlier = vault(fake, counter: KeychainCallCounter())
        for (token, email) in [("stale-one", "one@example.test"), ("two", "two@example.test"),
                               ("three", "three@example.test")] {
            XCTAssertNil(earlier.captureVerifiedLogin(
                credential(token, email: email), email: email,
                observation: earlier.beginObservation(), now: now))
        }
        for index in fake.items.indices {
            switch fake.items[index].account {
            case "one@example.test": fake.items[index].readStatus = errSecAuthFailed
            case "three@example.test": fake.items[index].readStatus = errSecInteractionNotAllowed
            default: break
            }
        }
        return fake
    }

    /// Runs the refresh loop's vault sequence (observation, roster read, verified capture of
    /// the CLI credential) `cycles` times and returns SecItemCopyMatching calls per cycle.
    private func refreshCycles(_ cycles: Int, vault: ClaudeSeatVault, counter: KeychainCallCounter,
                               active: ClaudeCredential) async -> [Int] {
        let store = Store(dir: dir, now: { self.now })
        var perCycle: [Int] = []
        for _ in 0..<cycles {
            let start = counter.total
            _ = await Refresher.refreshLoggedInAccount(
                active, store: store, vault: vault,
                profile: { token in token == "fresh-one" ? "one@example.test" : "\(token)@example.test" },
                usage: { _ in self.usage() }, clock: { self.now })
            counter.logCycle("refresh", startTotal: start)
            perCycle.append(counter.total - start)
        }
        return perCycle
    }

    func testRefreshLoopReadsSeatItemsOncePerLaunch() async throws {
        let fake = previousLaunch()
        let counter = KeychainCallCounter()
        var lines: [String] = []
        let launch = vault(fake, counter: counter, log: { lines.append($0) })
        let perCycle = await refreshCycles(3, vault: launch, counter: counter,
                                           active: credential("fresh-one", email: "one@example.test"))
        print("KEYCHAIN MEASURE SecItemCopyMatching per refresh cycle, 3 owned seats: \(perCycle)")
        XCTAssertEqual(perCycle, [4, 0, 0], "one listing plus one read per owned item, once per launch")
    }

    func testRefusedActiveSeatIsRecreatedOnceFromTheCLICredential() async throws {
        let fake = previousLaunch()
        let counter = KeychainCallCounter()
        var lines: [String] = []
        let launch = vault(fake, counter: counter, log: { lines.append($0) })
        _ = await refreshCycles(3, vault: launch, counter: counter,
                                active: credential("fresh-one", email: "one@example.test"))
        XCTAssertEqual(fake.deletes, ["Tower-seat-one@example.test"], "refused active item deleted exactly once")
        XCTAssertEqual(fake.item("one@example.test")?.readStatus, errSecSuccess, "re-created under this build")
        XCTAssertEqual(launch.credentials(active: nil).first { $0.emailHint == "one@example.test" }?.accessToken,
                       "fresh-one", "re-created item holds the CLI credential")
        XCTAssertEqual(lines.filter { $0.contains("re-created") && $0.contains("status=-25293") }.count, 1,
                       "re-create logs one line")
        XCTAssertEqual(fake.item("three@example.test")?.readStatus, errSecInteractionNotAllowed,
                       "an inactive seat has no token to re-create from and is left alone")
        XCTAssertEqual(lines.filter { $0.contains("unreadable") && $0.contains("status=-25308") }.count, 1,
                       "refused inactive seat logs once per launch")
    }

    func testFailedRecreateIsNotRetriedInTheRefreshLoop() async throws {
        let fake = previousLaunch()
        for index in fake.items.indices where fake.items[index].account == "one@example.test" {
            fake.items[index].deleteStatus = errSecAuthFailed
        }
        let counter = KeychainCallCounter()
        var lines: [String] = []
        let launch = vault(fake, counter: counter, log: { lines.append($0) })
        let perCycle = await refreshCycles(3, vault: launch, counter: counter,
                                           active: credential("fresh-one", email: "one@example.test"))
        XCTAssertEqual(fake.deletes, ["Tower-seat-one@example.test"], "failed re-create attempted once per launch")
        XCTAssertEqual(perCycle, [4, 0, 0], "failed re-create does not re-read the keychain")
        XCTAssertEqual(lines.filter { $0.contains("re-create failed") && $0.contains("status=-25293") }.count, 1,
                       "failed re-create logs one line")
    }

    /// A status other than a signer refusal used to make the whole readout uncacheable,
    /// which is what re-asked every item on every refresh. The answer is now kept like any
    /// other and the unreadable item retries only after the backoff, silently.
    func testStatusOtherThanASignerRefusalBacksOffThenRetriesSilently() async throws {
        let fake = previousLaunch()
        for index in fake.items.indices where fake.items[index].account == "three@example.test" {
            fake.items[index].readStatus = errSecDecode
        }
        var current = now
        let counter = KeychainCallCounter()
        let launch = vault(fake, counter: counter, now: { current })
        let active = credential("fresh-one", email: "one@example.test")
        let firstTwo = await refreshCycles(2, vault: launch, counter: counter, active: active)
        XCTAssertEqual(firstTwo, [4, 0], "the decode status is kept; nothing is re-asked inside the backoff")
        XCTAssertEqual(fake.itemReads.map(\.account), ["one@example.test", "two@example.test", "three@example.test"])

        current = now.addingTimeInterval(ClaudeSeatVault.readRetryBackoff + 1)
        let third = await refreshCycles(1, vault: launch, counter: counter, active: active)
        XCTAssertEqual(third, [4], "the unreadable item is asked again once the backoff has passed")
        XCTAssertTrue(fake.itemReads.dropFirst(3).allSatisfy(\.suppressed),
                      "the retry never shows a dialog")
    }

    /// The 2026-11-03 storm: every new process (app launch, `tower status`, a bare build)
    /// used to get one read with the dialog allowed, so an identity change prompted per seat
    /// in every process. A launch and every refresh after it now read suppressed.
    func testRefreshLoopNeverAllowsTheDialog() async throws {
        let fake = previousLaunch()
        var current = now
        let counter = KeychainCallCounter()
        let launch = vault(fake, counter: counter, now: { current })
        _ = await refreshCycles(1, vault: launch, counter: counter,
                                active: credential("fresh-one", email: "one@example.test"))
        XCTAssertEqual(fake.itemReads.map(\.account),
                       ["one@example.test", "two@example.test", "three@example.test"])
        XCTAssertTrue(fake.itemReads.allSatisfy(\.suppressed),
                      "the first read of a launch is suppressed too")

        current = now.addingTimeInterval(ClaudeSeatVault.readRetryBackoff + 1)
        _ = await refreshCycles(1, vault: launch, counter: counter, active: credential("fresh-one", email: "one@example.test"))
        XCTAssertTrue(fake.itemReads.allSatisfy(\.suppressed),
                      "no background attempt may raise the Keychain dialog")
    }

    /// The explicit re-trust is the one read that may prompt, and the first denial inside it
    /// still suppresses the rest. Afterwards the refresh loop is suppressed again.
    func testRetrustAllowsTheDialogOnceThenSuppressesAgain() async throws {
        let fake = previousLaunch()
        var current = now
        let counter = KeychainCallCounter()
        let launch = vault(fake, counter: counter, now: { current })
        let counts = try launch.retrust().get()
        XCTAssertEqual(counts.readable, 1, "only the seat this build wrote is readable")
        XCTAssertEqual(counts.unreadable, 2)
        XCTAssertEqual(fake.itemReads.map(\.suppressed), [false, true, true],
                       "the -25293 denial on the first item suppresses the rest of the re-trust")

        current = now.addingTimeInterval(ClaudeSeatVault.readRetryBackoff + 1)
        _ = await refreshCycles(1, vault: launch, counter: counter,
                                active: credential("fresh-one", email: "one@example.test"))
        XCTAssertTrue(fake.itemReads.dropFirst(3).allSatisfy(\.suppressed),
                      "after a re-trust the refresh loop never prompts")
    }

    /// A bare build matches no item's access list, so a dialog it raised could never be
    /// approved into trust. It is refused before any Keychain call.
    func testRetrustIsRefusedForABareBuild() throws {
        let fake = previousLaunch()
        let readsBefore = fake.itemReads.count
        let launch = vault(fake, counter: KeychainCallCounter(), mayPrompt: false)
        XCTAssertThrowsError(try launch.retrust().get())
        XCTAssertEqual(fake.itemReads.count, readsBefore, "no item read at all")
    }

    /// A read whose items all answered still retries nothing: one real read per launch is
    /// the contract, not one per refresh.
    func testFullyReadableReadoutIsNeverReRead() async throws {
        let fake = FakeSecItemStore()
        let earlier = vault(fake, counter: KeychainCallCounter())
        for (token, email) in [("one", "one@example.test"), ("two", "two@example.test")] {
            XCTAssertNil(earlier.captureVerifiedLogin(
                credential(token, email: email), email: email,
                observation: earlier.beginObservation(), now: now))
        }
        var current = now
        let counter = KeychainCallCounter()
        let launch = vault(fake, counter: counter, now: { current })
        _ = await refreshCycles(1, vault: launch, counter: counter,
                                active: credential("one", email: "one@example.test"))
        current = now.addingTimeInterval(ClaudeSeatVault.readRetryBackoff + 1)
        let later = await refreshCycles(1, vault: launch, counter: counter,
                                        active: credential("one", email: "one@example.test"))
        XCTAssertEqual(later, [0], "a clean readout is served from memory for the whole launch")
    }

    func testActiveSeatWithAnotherStatusIsNeitherDeletedNorOverwritten() async throws {
        let fake = previousLaunch()
        var before = Data()
        for index in fake.items.indices where fake.items[index].account == "one@example.test" {
            fake.items[index].readStatus = errSecDecode
            before = fake.items[index].data
        }
        let counter = KeychainCallCounter()
        var lines: [String] = []
        _ = await refreshCycles(2, vault: vault(fake, counter: counter, log: { lines.append($0) }),
                                counter: counter, active: credential("fresh-one", email: "one@example.test"))
        XCTAssertEqual(fake.deletes, [], "a status other than a signer refusal is never re-created")
        XCTAssertEqual(fake.item("one@example.test")?.readStatus, errSecDecode)
        XCTAssertEqual(fake.item("one@example.test")?.data, before, "and never overwritten in place")
        XCTAssertEqual(lines.filter { $0.contains("re-create") }.count, 0, "no re-create is logged")
    }

    func testNextLaunchReadsAgain() async throws {
        let fake = previousLaunch()
        let counter = KeychainCallCounter()
        let active = credential("fresh-one", email: "one@example.test")
        _ = await refreshCycles(2, vault: vault(fake, counter: counter), counter: counter, active: active)
        let relaunched = await refreshCycles(1, vault: vault(fake, counter: counter), counter: counter,
                                             active: active)
        XCTAssertEqual(relaunched, [4], "a new launch reads the seat items again")
    }
}
