import Foundation
import Security
import CryptoKit
import LocalAuthentication
import os

/// Tower reads the live credential and retains a copy of each verified seat's access token,
/// so it can read that seat's usage until the token expires. It never stores or presents a
/// refresh token and never renews a token: Claude Code alone does that.
struct ClaudeCredential {
    let service: String
    let accessToken: String
    let subscriptionType: String
    let rateLimitTier: String?
    let expiresAt: Date?
    /// The active config's `oauthAccount.emailAddress`; the profile endpoint verifies it.
    let emailHint: String?

    func isExpired(now: Date) -> Bool {
        // An access token with no expiry is not demonstrably safe to use.  Claude Code
        // normally writes this field; treat a malformed/older item as needing login rather
        // than gambling with an undocumented renewal path.
        guard let expiresAt else { return true }
        return expiresAt <= now
    }
}

/// Boundary around Tower-owned Claude seat items. Keeping this injectable makes the login
/// retention path testable without reading or writing the user's Keychain.
struct ClaudeSeatKeychainRecord {
    let service: String
    let account: String
    let label: String
    let data: Data
}

/// A Tower-owned item whose attributes this build can list but whose data it may not read.
/// Ad-hoc signing makes every rebuild a different signer, so an item written by the previous
/// build answers errSecAuthFailed (-25293) or errSecInteractionNotAllowed (-25308) to this
/// one. The status is kept verbatim so the log and the panel can name it.
struct ClaudeSeatUnreadableItem: Equatable {
    let service: String
    let account: String
    let label: String
    let status: OSStatus
    private var identity: String {
        "service=\(service) account=\(account) label=\(label) status=\(status)"
    }

    /// The two answers an item ACL gives a build other than the one that wrote the item. They
    /// cannot change while this process runs, so the launch never asks that item again.
    var isSignerRefusal: Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed
    }

    /// Statuses where the read was refused on the user's behalf or the keychain's: a denied
    /// or dismissed dialog, a keychain that could not show UI right now, or a locked/absent
    /// keychain. The first one in a read ends user-visible reads for the launch; retries
    /// stay silent so one denied dialog is the last the operator sees.
    var isInteractionDenial: Bool {
        status == errSecUserCanceled || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
            || status == errSecNoSuchKeychain || status == errSecInvalidKeychain
    }

    /// Logged once per launch per refused item, so a reviewer can count how often an owned
    /// item refused this build instead of the roster quietly shrinking.
    var fallbackLogLine: String {
        "retained seat unreadable, roster falls back to the CLI credential: \(identity)"
    }

    /// Logged once per re-create, because deleting an owned item must never be silent.
    var recreateLogLine: String {
        "retained seat re-created under the current signer, unreadable item deleted: \(identity)"
    }

    /// Logged when the one re-create this launch allows fails; the item is left alone until
    /// the next launch or a new login rather than retried every refresh.
    func recreateFailedLogLine(_ error: String) -> String {
        "retained seat re-create failed, not retried this launch: \(identity) error=\(error)"
    }

    /// The row keeps the needs-login prefix so it still cannot rank, and then says why.
    var panelMessage: String {
        "\(AccountSnapshot.needsLoginText): Keychain item \(service) unreadable (\(status)); "
            + "sign in to this seat again to re-create it"
    }
}

/// The roster one refresh works from, plus the owned items it had to skip.
struct ClaudeSeatRoster {
    let credentials: [ClaudeCredential]
    let unreadable: [ClaudeSeatUnreadableItem]
}

/// Everything one Keychain listing found: the records this build could decrypt, plus the
/// owned items it could name but not read.
struct ClaudeSeatKeychainReadout {
    var records: [ClaudeSeatKeychainRecord] = []
    var unreadable: [ClaudeSeatUnreadableItem] = []
}

struct ClaudeSeatVaultError: Error, LocalizedError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Whether a seat-item read may raise the Keychain dialog. Only the first real read of a
/// launch runs `allowed`: that is the one chance an Always Allow click has to bless the
/// current signer. Every later read runs `suppressed`, so a denial or a locked keychain
/// can never start a prompt storm.
enum ClaudeSeatReadInteraction {
    case allowed
    case suppressed
}

protocol ClaudeSeatKeychain {
    func readSeats(interaction: ClaudeSeatReadInteraction) -> Result<ClaudeSeatKeychainReadout, ClaudeSeatVaultError>
    func writeSeat(service: String, account: String, label: String, data: Data) -> String?
    func removeSeat(service: String, account: String, label: String) -> String?
}

/// Counts the `SecItemCopyMatching` calls the seat adapter makes (#68), so the Keychain cost
/// of a refresh cycle is measured rather than guessed. Every call logs one debug line and
/// every refresh cycle logs one notice with its own count:
/// `log show --debug --predicate 'subsystem == "ai.yonyon.tower" AND category == "keychain"'`.
/// Memory only; the count restarts with the process.
final class KeychainCallCounter {
    static let shared = KeychainCallCounter()
    static let logger = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "keychain")

    private let lock = NSLock()
    private var copyMatchingCalls = 0

    var total: Int { lock.withLock { copyMatchingCalls } }

    func recordCopyMatching(_ purpose: String, status: OSStatus) {
        let total = lock.withLock { () -> Int in
            copyMatchingCalls += 1
            return copyMatchingCalls
        }
        Self.logger.debug(
            "SecItemCopyMatching \(purpose, privacy: .public) status=\(status, privacy: .public) launch_total=\(total, privacy: .public)")
    }

    /// One notice per refresh cycle: how many calls that cycle made, and the launch total.
    func logCycle(_ cycle: String, startTotal: Int) {
        let total = self.total
        Self.logger.notice(
            "SecItemCopyMatching calls this \(cycle, privacy: .public): \(total - startTotal, privacy: .public) (launch total \(total, privacy: .public))")
    }
}

/// The Security calls the seat adapter makes, injectable so a test can drive the real query
/// construction and parsing against an in-memory keychain instead of the user's login keychain.
struct SecItemCalls {
    var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
    var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    var delete: (CFDictionary) -> OSStatus = SecItemDelete
    var setAccess: (CFTypeRef, SecAccess) -> OSStatus = { reference, access in
        guard CFGetTypeID(reference) == SecKeychainItemGetTypeID() else { return errSecParam }
        return SecKeychainItemSetAccess(
            unsafeBitCast(reference, to: SecKeychainItem.self), access)
    }
}

struct SeatKeychainAccessInspectionError: Error {
    let status: OSStatus
}

struct SeatKeychainAccessSnapshot {
    let requiresRepair: Bool
}

struct SeatKeychainACLEntry {
    let authorizations: Set<String>
    /// nil means the ACL names no applications, which Keychain reads as
    /// readable-by-all for the authorizations the entry carries.
    let applicationRequirements: Set<Data>?
}

/// The legacy Keychain ACL API is the only macOS API that lets a generic password
/// name the signed applications that may read it. A new seat item names only the
/// running build's designated requirement: every seat reader runs in-process, and
/// trusting /usr/bin/security would let any user process read seat tokens without
/// a prompt.
enum TowerSeatKeychainAccess {
    /// Kept for the negative assertion in tests: the CLI must never be trusted.
    static let securityToolPath = "/usr/bin/security"

    /// Creates the access object supplied to `SecItemAdd`. Resolving Tower from its
    /// enclosing bundle makes a PATH symlink and a Finder launch use the same code
    /// requirement. A bare development binary fails closed because the Security API
    /// treats a nil path as anonymous trust.
    static func make(descriptor: String) -> Result<SecAccess, ClaudeSeatVaultError> {
        switch trustedApplications() {
        case .failure(let error): return .failure(error)
        case .success(let applications):
            var access: SecAccess?
            let status = SecAccessCreate(descriptor as CFString, applications as CFArray, &access)
            guard status == errSecSuccess, let access else {
                return .failure(ClaudeSeatVaultError("Keychain access creation failed (\(status))"))
            }
            return .success(access)
        }
    }

    static func requiredApplicationRequirements() -> Result<[Data], ClaudeSeatVaultError> {
        switch trustedApplications() {
        case .failure(let error): return .failure(error)
        case .success(let applications):
            var requirements: [Data] = []
            for application in applications {
                switch requirementData(for: application) {
                case .failure(let error): return .failure(error)
                case .success(let data): requirements.append(data as Data)
                }
            }
            return .success(requirements)
        }
    }

    static func requiresRepair(required: [Data], aclEntries: [SeatKeychainACLEntry]) -> Bool {
        let readAuthorizations: Set<String> = [
            kSecACLAuthorizationAny as String,
            kSecACLAuthorizationDecrypt as String,
        ]
        let readEntries = aclEntries
            .filter { !$0.authorizations.isDisjoint(with: readAuthorizations) }
        if readEntries.contains(where: { $0.applicationRequirements == nil }) { return false }
        let trustedForRead = readEntries
            .reduce(into: Set<Data>()) { $0.formUnion($1.applicationRequirements ?? []) }
        return !Set(required).isSubset(of: trustedForRead)
    }

    private static func trustedApplications() -> Result<[SecTrustedApplication], ClaudeSeatVaultError> {
        switch currentApplicationPath() {
        case .failure(let error): return .failure(error)
        case .success(let path): return trustedApplications(currentPath: path)
        }
    }

    /// `currentPath` is injectable so a test can stand a platform-signed binary in
    /// for the running app: `swift test` runs inside an xctest bundle that fails
    /// `SecStaticCodeCreateWithPath` with errSecCSBadBundleFormat, so the real
    /// application path is unreachable there.
    static func trustedApplications(currentPath path: String) -> Result<[SecTrustedApplication], ClaudeSeatVaultError> {
        switch trustedApplication(path: path) {
        case .failure(let error): return .failure(error)
        // Only the running build may read a seat item; every Tower reader is
        // in-process.
        case .success(let tower): return .success([tower])
        }
    }

    private static func currentApplicationPath() -> Result<String, ClaudeSeatVaultError> {
        guard let path = ProductIdentity.runningBundle()?.bundlePath, !path.isEmpty else {
            return .failure(ClaudeSeatVaultError("Keychain access requires a signed Tower app bundle"))
        }
        switch validateSignedCode(at: path) {
        case .failure(let error): return .failure(error)
        case .success: return .success(path)
        }
    }

    static func validateSignedCode(at path: String) -> Result<Void, ClaudeSeatVaultError> {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard creationStatus == errSecSuccess, let staticCode else {
            return .failure(ClaudeSeatVaultError("Keychain code signature creation failed (\(creationStatus))"))
        }
        let validationStatus = SecStaticCodeCheckValidity(staticCode, [], nil)
        guard validationStatus == errSecSuccess else {
            return .failure(ClaudeSeatVaultError("Keychain code signature validation failed (\(validationStatus))"))
        }
        return .success(())
    }

    private static func trustedApplication(path: String) -> Result<SecTrustedApplication, ClaudeSeatVaultError> {
        var application: SecTrustedApplication?
        let status = path.withCString { SecTrustedApplicationCreateFromPath($0, &application) }
        guard status == errSecSuccess, let application else {
            return .failure(ClaudeSeatVaultError("Keychain trusted application creation failed (\(status))"))
        }
        return .success(application)
    }

    private static func requirementData(for application: SecTrustedApplication) -> Result<CFData, ClaudeSeatVaultError> {
        var data: CFData?
        let status = SecTrustedApplicationCopyData(application, &data)
        guard status == errSecSuccess, let data else {
            return .failure(ClaudeSeatVaultError("Keychain trusted application read failed (\(status))"))
        }
        return .success(data)
    }
}

/// Tower.app is signed with the self-signed "Tower Dev" identity when the build machine has
/// one and ad-hoc otherwise (CI always, see README "Signing"). An ad-hoc rebuild is a new
/// signer and an item's ACL names only the build that wrote it. Two consequences shape this
/// adapter:
///
/// 1. Listing and reading are separate calls. The login keychain on macOS 26 rejects
///    `kSecMatchLimitAll` combined with `kSecReturnData` with errSecParam (-50) even when no
///    item matches (measured 2026-09-13 with a read-only probe; the attributes-only listing
///    and a `kSecMatchLimitOne` data read both behave). That single rejected query is what the
///    panel showed as "Keychain read failed (-50)" for every account.
/// 2. A data read the item ACL refuses is reported per item, never as a failure of the
///    whole read. The vault falls back to the CLI credential for the roster and logs the
///    item and status once per launch. A signer refusal is re-created under the current
///    signer at the next verified login of that seat (the CLI credential) by deleting that
///    exact item and writing a fresh one, once per launch per token; any other status is
///    left untouched.
/// 3. Reads may show the Keychain dialog only on the launch's first attempt: an
///    `interaction` of `allowed` attaches no suppression, `suppressed` attaches an
///    LAContext with interactionNotAllowed (the non-deprecated replacement for
///    kSecUseAuthenticationUIFail, which macOS 11+ ignores and which let a denied read
///    re-prompt every refresh). The first denial-class status inside one read suppresses
///    the rest of it, so prompts continue only while they are being approved. The vault
///    keeps whatever the read answered (ClaudeSeatLaunchCache), retries a denied, locked
///    or failed read no sooner than `readRetryBackoff`, and never again allows UI, so a
///    refused item is never re-asked interactively inside the launch.
struct SystemClaudeSeatKeychain: ClaudeSeatKeychain {
    var calls = SecItemCalls()
    var counter = KeychainCallCounter.shared
    var accessInspector: (CFTypeRef) -> Result<SeatKeychainAccessSnapshot, SeatKeychainAccessInspectionError>
        = Self.inspectAccess
    var accessFactory: (String) -> Result<SecAccess, ClaudeSeatVaultError>
        = TowerSeatKeychainAccess.make(descriptor:)

    func readSeats(interaction: ClaudeSeatReadInteraction) -> Result<ClaudeSeatKeychainReadout, ClaudeSeatVaultError> {
        let listing: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: ClaudeSeatVault.ownershipMarker,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var listed: CFTypeRef?
        let listStatus = calls.copyMatching(listing as CFDictionary, &listed)
        counter.recordCopyMatching("list", status: listStatus)
        if listStatus == errSecItemNotFound { return .success(ClaudeSeatKeychainReadout()) }
        guard listStatus == errSecSuccess, let rows = listed as? [[String: Any]] else {
            return .failure(keychainError("read", listStatus))
        }
        var readout = ClaudeSeatKeychainReadout()
        var itemInteraction = interaction
        for row in rows {
            guard let service = row[kSecAttrService as String] as? String,
                  let account = row[kSecAttrAccount as String] as? String,
                  let label = row[kSecAttrLabel as String] as? String
            else { continue }
            guard label == ClaudeSeatVault.ownershipMarker,
                  service == ClaudeSeatVault.service(for: account) else { continue }
            var query = seatQuery(service: service, account: account, label: label)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecReturnData as String] = true
            query[kSecReturnRef as String] = true
            if itemInteraction == .suppressed {
                // LAContext.interactionNotAllowed is the non-deprecated form of
                // kSecUseAuthenticationUIFail, which macOS 11+ no longer honours: a
                // suppressed read fails with errSecInteractionNotAllowed instead of
                // raising the dialog on every attempt.
                query[kSecUseAuthenticationContext as String] = Self.suppressedContext()
            }
            var item: CFTypeRef?
            let status = calls.copyMatching(query as CFDictionary, &item)
            counter.recordCopyMatching("item", status: status)
            switch status {
            case errSecSuccess:
                guard let data = Self.itemData(item) else { continue }
                if let itemRef = Self.itemReference(item) {
                    switch accessInspector(itemRef) {
                    case .failure(let inspectionError):
                        readout.unreadable.append(ClaudeSeatUnreadableItem(
                            service: service, account: account, label: label, status: inspectionError.status))
                        continue
                    case .success(let snapshot) where !snapshot.requiresRepair: break
                    case .success(let snapshot) where snapshot.requiresRepair:
                        if itemInteraction == .allowed {
                            let repairStatus = replaceReadableSeat(reference: itemRef, label: label)
                            guard repairStatus == errSecSuccess else {
                                let unreadable = ClaudeSeatUnreadableItem(
                                    service: service, account: account, label: label, status: repairStatus)
                                readout.unreadable.append(unreadable)
                                if unreadable.isInteractionDenial { itemInteraction = .suppressed }
                                continue
                            }
                        }
                    case .success: break
                    }
                }
                readout.records.append(ClaudeSeatKeychainRecord(
                    service: service, account: account, label: label, data: data))
            case errSecItemNotFound:
                // Removed between the listing and this read; nothing to report.
                continue
            default:
                let unreadable = ClaudeSeatUnreadableItem(
                    service: service, account: account, label: label, status: status)
                readout.unreadable.append(unreadable)
                // Prompts may continue only while the operator is approving them. The
                // first denial suppresses the rest of this read, so one denied dialog is
                // the last one this launch shows.
                if unreadable.isInteractionDenial { itemInteraction = .suppressed }
            }
        }
        return .success(readout)
    }

    func writeSeat(service: String, account: String, label: String, data: Data) -> String? {
        let query = seatQuery(service: service, account: account, label: label)
        let update = [kSecValueData as String: data]
        let status = calls.update(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return nil }
        guard status == errSecItemNotFound else { return keychainError("write", status).message }

        var add = query
        add[kSecValueData as String] = data
        switch accessFactory(label) {
        case .failure(let error): return error.message
        case .success(let access): add[kSecAttrAccess as String] = access
        }
        let addStatus = calls.add(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return nil }
        if addStatus == errSecDuplicateItem {
            let retry = calls.update(query as CFDictionary, update as CFDictionary)
            return retry == errSecSuccess ? nil : keychainError("write", retry).message
        }
        return keychainError("write", addStatus).message
    }

    func removeSeat(service: String, account: String, label: String) -> String? {
        let status = calls.delete(seatQuery(service: service, account: account, label: label) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return keychainError("remove", status).message
        }
        return nil
    }

    /// The first successful read after an operator has approved a legacy ACL has the
    /// item's data and its ACL. Replace only that ACL in place when it lacks either
    /// required application, retaining the item and payload if the access update fails.
    private func replaceReadableSeat(reference: CFTypeRef, label: String) -> OSStatus {
        switch accessFactory(label) {
        case .failure: return errSecInternalComponent
        case .success(let access): return calls.setAccess(reference, access)
        }
    }

    private static func inspectAccess(
        _ reference: CFTypeRef
    ) -> Result<SeatKeychainAccessSnapshot, SeatKeychainAccessInspectionError> {
        guard CFGetTypeID(reference) == SecKeychainItemGetTypeID() else {
            return .failure(SeatKeychainAccessInspectionError(status: errSecParam))
        }
        let item = unsafeBitCast(reference, to: SecKeychainItem.self)
        guard case .success(let required) = TowerSeatKeychainAccess.requiredApplicationRequirements() else {
            return .failure(SeatKeychainAccessInspectionError(status: errSecInternalComponent))
        }
        var access: SecAccess?
        let accessStatus = SecKeychainItemCopyAccess(item, &access)
        guard accessStatus == errSecSuccess, let access else {
            return .failure(SeatKeychainAccessInspectionError(status: accessStatus))
        }
        var aclList: CFArray?
        let aclStatus = SecAccessCopyACLList(access, &aclList)
        guard aclStatus == errSecSuccess, let aclList else {
            return .failure(SeatKeychainAccessInspectionError(status: aclStatus))
        }
        var entries: [SeatKeychainACLEntry] = []
        for case let acl as SecACL in aclList as [AnyObject] {
            let authorizations = Set((SecACLCopyAuthorizations(acl) as [AnyObject]).compactMap { $0 as? String })
            var applications: CFArray?
            var description: CFString?
            var prompt: SecKeychainPromptSelector = []
            let contentsStatus = SecACLCopyContents(acl, &applications, &description, &prompt)
            guard contentsStatus == errSecSuccess else {
                return .failure(SeatKeychainAccessInspectionError(status: contentsStatus))
            }
            // A NULL application list means the entry trusts every application,
            // which is not an inspection failure.
            var requirements: Set<Data>?
            if let applications {
                var collected = Set<Data>()
                for case let application as SecTrustedApplication in applications as [AnyObject] {
                    var data: CFData?
                    let dataStatus = SecTrustedApplicationCopyData(application, &data)
                    guard dataStatus == errSecSuccess, let data else {
                        return .failure(SeatKeychainAccessInspectionError(status: dataStatus))
                    }
                    collected.insert(data as Data)
                }
                requirements = collected
            }
            entries.append(SeatKeychainACLEntry(
                authorizations: authorizations, applicationRequirements: requirements))
        }
        return .success(SeatKeychainAccessSnapshot(
            requiresRepair: TowerSeatKeychainAccess.requiresRepair(
                required: required, aclEntries: entries)))
    }

    private static func itemData(_ result: CFTypeRef?) -> Data? {
        if let data = result as? Data { return data }
        return (result as? [String: Any])?[kSecValueData as String] as? Data
    }

    private static func itemReference(_ result: CFTypeRef?) -> CFTypeRef? {
        (result as? [String: Any])?[kSecValueRef as String] as CFTypeRef?
    }

    private func seatQuery(service: String, account: String, label: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
        ]
    }

    /// A fresh context per suppressed read: LAContext is stateful and a shared one could
    /// carry an earlier evaluation into a later query.
    private static func suppressedContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func keychainError(_ operation: String, _ status: OSStatus) -> ClaudeSeatVaultError {
        ClaudeSeatVaultError("Keychain \(operation) failed (\(status))")
    }
}

enum ClaudeSeatRetention {
    static let preferenceKey = "retainClaudeSeats"

    static func isEnabled(defaults: UserDefaults = TowerPreferences.shared) -> Bool {
        guard defaults.object(forKey: preferenceKey) != nil else { return true }
        return defaults.bool(forKey: preferenceKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = TowerPreferences.shared) {
        defaults.set(enabled, forKey: preferenceKey)
    }
}

private struct ClaudeSeatPayload: Codable {
    let email: String
    var accessToken: String
    var expiresAt: Date
    let subscriptionType: String
    let rateLimitTier: String?
    let generation: Int
    let observationTicket: Int
}

private struct ClaudeSeatVaultState: Codable {
    var generation: Int = 0
    var nextTicket: Int = 0
    var suppressedTokenDigest: String?
}

struct ClaudeSeatObservation {
    let generation: Int
    let ticket: Int
}

/// What one launch of Tower knows about its seat items (#68). Every data read of an item an
/// earlier build wrote can raise a Keychain prompt, so the first listing is kept in memory
/// for the life of the process and the vault's own writes and deletes are applied to that
/// copy. A readout is kept whatever it contains: refusing to cache an answer only asks the
/// same question again, and on this keychain asking is what prompts. A denied or locked
/// read retries silently, never inside the backoff the vault sets. A reference type, so
/// every copy of the value-typed vault shares one; a new vault is a new launch. Tokens
/// never leave this process.
final class ClaudeSeatLaunchCache {
    private let lock = NSLock()
    private var readout: ClaudeSeatKeychainReadout?
    private var lastFailure: ClaudeSeatVaultError?
    private var lastAttemptAt: Date?
    /// The one read this launch may show a dialog for. Once it has run (however it
    /// answered) every later read is suppressed, so a denied dialog is never re-asked.
    private var allowedAttemptDone = false
    private var reported: Set<String> = []
    private var recreateAttempts: Set<String> = []

    var readoutForLaunch: ClaudeSeatKeychainReadout? { lock.withLock { readout } }
    var failureForLaunch: ClaudeSeatVaultError? { lock.withLock { lastFailure } }

    var interactionForNextAttempt: ClaudeSeatReadInteraction {
        lock.withLock { allowedAttemptDone ? .suppressed : .allowed }
    }

    /// Whether the vault may make another real Keychain read: never inside `backoff` of the
    /// previous attempt, and afterwards only while something is still unanswered, an
    /// unreadable item, or a failed read that left nothing cached at all.
    func readDue(now: Date, backoff: TimeInterval) -> Bool {
        lock.withLock {
            let unanswered = readout == nil || !(readout?.unreadable.isEmpty ?? true)
            guard unanswered else { return false }
            guard let lastAttemptAt else { return true }
            return now.timeIntervalSince(lastAttemptAt) >= backoff
        }
    }

    func keep(_ value: ClaudeSeatKeychainReadout, now: Date, interaction: ClaudeSeatReadInteraction) {
        lock.withLock {
            readout = value
            lastFailure = nil
            lastAttemptAt = now
            if interaction == .allowed { allowedAttemptDone = true }
        }
    }

    /// A failed read still counts as the attempt: the next one waits out the same backoff,
    /// and callers within it get the kept readout or this error, never a new Keychain call.
    func noteFailure(_ error: ClaudeSeatVaultError, now: Date, interaction: ClaudeSeatReadInteraction) {
        lock.withLock {
            lastFailure = error
            lastAttemptAt = now
            if interaction == .allowed { allowedAttemptDone = true }
        }
    }

    func applyWrite(_ record: ClaudeSeatKeychainRecord) {
        lock.withLock {
            guard var value = readout else { return }
            Self.drop(service: record.service, account: record.account, label: record.label, from: &value)
            value.records.append(record)
            readout = value
        }
    }

    func applyRemoval(service: String, account: String, label: String) {
        lock.withLock {
            guard var value = readout else { return }
            Self.drop(service: service, account: account, label: label, from: &value)
            readout = value
        }
    }

    /// True the first time this launch sees this item answer with this status.
    func firstReport(_ item: ClaudeSeatUnreadableItem) -> Bool {
        lock.withLock {
            reported.insert("\(item.service)|\(item.account)|\(item.label)|\(item.status)").inserted
        }
    }

    /// One re-create per seat per login token per launch. A new login is a new token, so it
    /// earns a new attempt; the five-minute loop repeating the same token does not.
    func claimRecreate(service: String, tokenDigest: String) {
        _ = lock.withLock { recreateAttempts.insert("\(service)|\(tokenDigest)") }
    }

    func attemptedRecreate(service: String, tokenDigest: String) -> Bool {
        lock.withLock { recreateAttempts.contains("\(service)|\(tokenDigest)") }
    }

    private static func drop(service: String, account: String, label: String,
                             from value: inout ClaudeSeatKeychainReadout) {
        value.records.removeAll { $0.service == service && $0.account == account && $0.label == label }
        value.unreadable.removeAll { $0.service == service && $0.account == account && $0.label == label }
    }
}

/// Retains verified login observations and reconstructs the later refresh roster.
/// The Keychain payload is a binary property list containing the seat's access token, its
/// refresh token (#58) and nonsecret metadata. The refresh token is presented only for a seat
/// the CLI no longer holds, so Tower can never rotate the pair behind the active login.
struct ClaudeSeatVault {
    static let ownedServicePrefix = "Tower-seat-"
    static let ownershipMarker = "Tower-owned Claude seat v1"
    /// How long a denied, locked or failed seat read must wait before it is asked again.
    /// Retries always run with interaction suppressed, so they can never raise a dialog.
    static let readRetryBackoff: TimeInterval = 60
    static let shared = ClaudeSeatVault()

    private let keychain: any ClaudeSeatKeychain
    private let launch = ClaudeSeatLaunchCache()
    private let lockURL: URL
    private let stateURL: URL
    private let retentionEnabled: () -> Bool
    private let setRetentionEnabled: (Bool) -> Void
    private let log: (String) -> Void
    private let now: () -> Date

    init(
        keychain: any ClaudeSeatKeychain = SystemClaudeSeatKeychain(),
        lockURL: URL? = nil,
        stateURL: URL? = nil,
        retentionEnabled: @escaping () -> Bool = { ClaudeSeatRetention.isEnabled() },
        setRetentionEnabled: @escaping (Bool) -> Void = { ClaudeSeatRetention.setEnabled($0) },
        log: @escaping (String) -> Void = ClaudeSeatVault.defaultLog,
        now: @escaping () -> Date = { Date() }
    ) {
        self.keychain = keychain
        let directory = Self.defaultDirectory()
        self.lockURL = lockURL ?? directory.appendingPathComponent(".seat-keychain.lock")
        self.stateURL = stateURL ?? directory.appendingPathComponent("seat-retention-state.plist")
        self.retentionEnabled = retentionEnabled
        self.setRetentionEnabled = setRetentionEnabled
        self.log = log
        self.now = now
    }

    /// Where the one-line-per-event record goes. The unified log is the countable sink: the
    /// GUI is launched by LaunchServices, so its stderr reaches nobody, while
    /// `log show --predicate 'subsystem == "ai.yonyon.tower" AND category == "retention"'`
    /// answers "how often did this fire" with the system's own retention caps. stderr stays
    /// for the CLI and for a Tower started from a terminal. Never a file Tower grows itself.
    static let logger = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "retention")

    static func defaultLog(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func service(for email: String) -> String {
        ownedServicePrefix + email
    }

    /// Disabling retention is destructive by design: the switch changes only after every
    /// owned copy has been removed under the same advisory lock.
    func disableAndForget(suppressing credential: ClaudeCredential?) -> String? {
        forget(
            where: { _ in true },
            advanceGeneration: true,
            suppressingToken: credential.map { tokenDigest($0.accessToken) },
            setRetentionAfterSuccess: false,
            freshRead: true)
    }

    func enableRetention() {
        setRetentionEnabled(true)
    }

    func isRetentionEnabled() -> Bool {
        retentionEnabled()
    }

    /// Captures the state generation before asynchronous identity and usage requests begin.
    /// A later Forget advances it under the same lock, so an older in-flight login cannot
    /// restore a token the operator explicitly removed.
    func beginObservation() -> ClaudeSeatObservation? {
        try? beginObservationResult().get()
    }

    /// The result form lets production surface a broken state file or lock rather than
    /// treating it as an observation that may safely write later.
    func beginObservationResult() -> Result<ClaudeSeatObservation, ClaudeSeatVaultError> {
        guard retentionEnabled() else {
            return .success(ClaudeSeatObservation(generation: -1, ticket: -1))
        }
        switch withLock({ () -> Result<ClaudeSeatObservation, ClaudeSeatVaultError> in
            switch readState() {
            case .failure(let error): return .failure(error)
            case .success(var state):
                state.nextTicket += 1
                guard let error = writeState(state) else {
                    return .success(ClaudeSeatObservation(generation: state.generation, ticket: state.nextTicket))
                }
                return .failure(ClaudeSeatVaultError(error))
            }
        }) {
        case .success(let result): return result
        case .failure(let error): return .failure(error)
        }
    }

    func captureVerifiedLogin(
        _ credential: ClaudeCredential,
        email: String,
        observation: ClaudeSeatObservation?,
        now: Date = Date()
    ) -> String? {
        guard retentionEnabled(), !credential.isExpired(now: now), let observation else { return nil }
        switch withLock({ () -> String? in
            guard retentionEnabled() else { return nil }
            let state: ClaudeSeatVaultState
            switch readState() {
            case .success(let value): state = value
            case .failure(let error): return error.message
            }
            guard state.generation == observation.generation else { return nil }
            let digest = tokenDigest(credential.accessToken)
            guard state.suppressedTokenDigest != digest else { return nil }
            let service = Self.service(for: email)
            let readout: ClaudeSeatKeychainReadout
            switch launchReadout() {
            case .success(let value): readout = value
            case .failure(let error): return error.message
            }
            let previous = readout.records.first { record in
                record.service == service && record.account == email
                    && record.label == Self.ownershipMarker
            }.flatMap(decode)
            guard (previous?.observationTicket ?? 0) < observation.ticket else { return nil }
            // No readable item for this seat after this launch already tried to re-create it
            // from this token: the attempt failed, so leave it until the next launch or a new
            // login instead of deleting, writing and failing again every refresh.
            guard previous != nil || !launch.attemptedRecreate(service: service, tokenDigest: digest)
            else { return nil }
            let payload = ClaudeSeatPayload(
                email: email, accessToken: credential.accessToken, expiresAt: credential.expiresAt!,
                subscriptionType: credential.subscriptionType, rateLimitTier: credential.rateLimitTier,
                generation: (previous?.generation ?? 0) + 1,
                observationTicket: observation.ticket)
            guard let data = encode(payload) else { return "could not encode retained seat" }
            if state.suppressedTokenDigest != nil {
                var nextState = state
                nextState.suppressedTokenDigest = nil
                if let error = writeState(nextState) { return error }
            }
            // An item the current signer cannot read cannot be updated in place either: its
            // ACL names the build that wrote it. Delete exactly that item, then write a fresh
            // one this build owns from the verified CLI credential. Once per launch per token,
            // and logged either way, because the delete must never be silent. Only a signer
            // refusal proves the item belongs to an older build; any other status may be a
            // good item this read failed on, so it is neither deleted nor overwritten in place
            // (falling through to writeSeat would update that same item).
            if let unreadable = readout.unreadable.first(where: { item in
                item.service == service && item.account == email && item.label == Self.ownershipMarker
            }) {
                guard unreadable.isSignerRefusal else { return nil }
                launch.claimRecreate(service: service, tokenDigest: digest)
                if let error = removeSeat(
                    service: unreadable.service, account: unreadable.account, label: unreadable.label) {
                    log(unreadable.recreateFailedLogLine(error))
                    return error
                }
                if let error = writeSeat(
                    service: service, account: email, label: Self.ownershipMarker, data: data) {
                    log(unreadable.recreateFailedLogLine(error))
                    return error
                }
                log(unreadable.recreateLogLine)
                return nil
            }
            return writeSeat(
                service: service, account: email, label: Self.ownershipMarker, data: data)
        }) {
        case .success(let error): return error
        case .failure(let error): return error.message
        }
    }

    /// Returns the active credential plus every valid Tower-owned seat. Expired tokens stay
    /// in the roster: the collector marks the corresponding account needs login without
    /// calling the usage endpoint.
    func credentials(active: ClaudeCredential?) -> [ClaudeCredential] {
        switch credentialsResult(active: active) {
        case .success(let credentials): return credentials
        case .failure: return active.map { [$0] } ?? []
        }
    }

    /// Production callers use this result to distinguish an empty retained roster from an
    /// inaccessible Keychain. Falling back to the active credential is only for narrow UI
    /// helpers that cannot report an error.
    func credentialsResult(
        active: ClaudeCredential?
    ) -> Result<[ClaudeCredential], ClaudeSeatVaultError> {
        rosterResult(active: active).map(\.credentials)
    }

    /// The refresh roster: the active CLI credential plus every readable owned seat. Owned
    /// items this build cannot read are the fallback case, not a failure: each is logged once
    /// per launch and returned on every refresh so the panel can name it on that seat's row.
    /// Only a failed listing, a broken state file or a lost lock still fails the whole read.
    func rosterResult(active: ClaudeCredential?) -> Result<ClaudeSeatRoster, ClaudeSeatVaultError> {
        let activeCredentials = active.map { [$0] } ?? []
        guard retentionEnabled() else {
            return .success(ClaudeSeatRoster(credentials: activeCredentials, unreadable: []))
        }
        let retained: [ClaudeCredential]
        let unreadable: [ClaudeSeatUnreadableItem]
        switch withLock({ validSeats() }) {
        case .success(.success(let value)): (retained, unreadable) = value
        case .success(.failure(let error)): return .failure(error)
        case .failure(let error): return .failure(error)
        }
        for item in unreadable where launch.firstReport(item) { log(item.fallbackLogLine) }
        var seenTokens = Set<String>()
        return .success(ClaudeSeatRoster(
            credentials: (activeCredentials + retained).filter { seenTokens.insert($0.accessToken).inserted },
            unreadable: unreadable))
    }

    /// Removes all valid Tower-owned seats. It advances the persistent observation fence
    /// before deletion, so a queued login from before Forget cannot recreate an item.
    func forgetAll(suppressing credential: ClaudeCredential? = nil) -> String? {
        forget(
            where: { _ in true },
            advanceGeneration: true,
            suppressingToken: credential.map { tokenDigest($0.accessToken) },
            setRetentionAfterSuccess: nil,
            freshRead: true)
    }

    /// Retirement is driven by the on-disk roster. It removes only matching Tower-owned
    /// records and leaves the global observation fence alone because the caller rechecks
    /// retirement immediately before capture.
    func forgetRetired(_ emails: Set<String>) -> String? {
        guard retentionEnabled(), !emails.isEmpty else { return nil }
        return forget(
            where: { emails.contains($0.emailHint ?? "") },
            advanceGeneration: false,
            suppressingToken: nil,
            setRetentionAfterSuccess: nil,
            freshRead: false)
    }

    private func forget(
        where keep: (ClaudeCredential) -> Bool,
        advanceGeneration: Bool,
        suppressingToken: String?,
        setRetentionAfterSuccess: Bool?,
        freshRead: Bool
    ) -> String? {
        switch withLock({ () -> String? in
            var state: ClaudeSeatVaultState
            switch readState() {
            case .success(let value): state = value
            case .failure(let error): return error.message
            }
            if advanceGeneration {
                state.generation += 1
                state.suppressedTokenDigest = suppressingToken
                if let error = writeState(state) { return error }
            }
            var firstError: String?
            let readout: ClaudeSeatKeychainReadout
            // Forget and disable are the operator's word and read the Keychain as it is now,
            // including items another Tower process wrote; retirement runs inside the refresh
            // loop and reads this launch's copy.
            switch launchReadout(fresh: freshRead) {
            case .success(let value): readout = value
            case .failure(let error): return error.message
            }
            for record in readout.records {
                guard validOwnership(record), keep(ClaudeCredential(
                    service: record.service, accessToken: "", subscriptionType: "?", rateLimitTier: nil,
                    expiresAt: nil, emailHint: record.account)) else { continue }
                if let error = removeSeat(
                    service: record.service, account: record.account, label: record.label), firstError == nil {
                    firstError = error
                }
            }
            // Forget and retirement own the unreadable items as well: ownership is decided
            // by attributes, which list fine, and the operator asked for them to be gone.
            for item in readout.unreadable {
                guard validOwnership(service: item.service, account: item.account, label: item.label),
                      keep(ClaudeCredential(
                          service: item.service, accessToken: "", subscriptionType: "?", rateLimitTier: nil,
                          expiresAt: nil, emailHint: item.account)) else { continue }
                if let error = removeSeat(
                    service: item.service, account: item.account, label: item.label), firstError == nil {
                    firstError = error
                }
            }
            guard firstError == nil else { return firstError }
            if let setRetentionAfterSuccess { setRetentionEnabled(setRetentionAfterSuccess) }
            return firstError
        }) {
        case .success(let error): return error
        case .failure(let error): return error.message
        }
    }

    /// Readable owned seats, plus the owned items this build could list but not read. The
    /// second list is the fallback path: an unreadable item is excluded and reported, it does
    /// not fail the read.
    private func validSeats() -> Result<([ClaudeCredential], [ClaudeSeatUnreadableItem]), ClaudeSeatVaultError> {
        switch launchReadout() {
        case .failure(let error): return .failure(error)
        case .success(let readout):
            let unreadable = readout.unreadable.filter {
                validOwnership(service: $0.service, account: $0.account, label: $0.label)
            }
            return .success((readout.records.compactMap(validCredential), unreadable))
        }
    }

    /// #68: the refresh loop reads each seat item at most once per launch. The first real
    /// read may show the Keychain dialog (the operator's one Always Allow chance to bless
    /// this signer); whatever it answers is kept for the life of the process. A denied,
    /// locked or failed read is asked again only after `readRetryBackoff`, always with
    /// interaction suppressed, so it can never re-prompt. `fresh` is for the operator's
    /// Forget and disable, which must see the Keychain as it is now and also never prompts.
    private func launchReadout(fresh: Bool = false) -> Result<ClaudeSeatKeychainReadout, ClaudeSeatVaultError> {
        if !fresh && !launch.readDue(now: now(), backoff: Self.readRetryBackoff) {
            if let kept = launch.readoutForLaunch { return .success(kept) }
            return .failure(launch.failureForLaunch ?? ClaudeSeatVaultError("Keychain read failed"))
        }
        let interaction = fresh ? .suppressed : launch.interactionForNextAttempt
        switch keychain.readSeats(interaction: interaction) {
        case .failure(let error):
            launch.noteFailure(error, now: now(), interaction: interaction)
            if !fresh, let kept = launch.readoutForLaunch { return .success(kept) }
            return .failure(error)
        case .success(let readout):
            launch.keep(readout, now: now(), interaction: interaction)
            return .success(readout)
        }
    }

    /// Every vault write and delete goes through these two, so the launch copy stays what the
    /// Keychain holds. A failed call changed nothing, so the copy stays as it was.
    private func writeSeat(service: String, account: String, label: String, data: Data) -> String? {
        let error = keychain.writeSeat(service: service, account: account, label: label, data: data)
        if error == nil {
            launch.applyWrite(ClaudeSeatKeychainRecord(service: service, account: account, label: label, data: data))
        }
        return error
    }

    private func removeSeat(service: String, account: String, label: String) -> String? {
        let error = keychain.removeSeat(service: service, account: account, label: label)
        if error == nil { launch.applyRemoval(service: service, account: account, label: label) }
        return error
    }

    private func validCredential(from record: ClaudeSeatKeychainRecord) -> ClaudeCredential? {
        guard validOwnership(record),
              let payload = decode(record),
              record.account == payload.email,
              record.service == Self.service(for: payload.email),
              !payload.accessToken.isEmpty
        else { return nil }
        return ClaudeCredential(
            service: record.service, accessToken: payload.accessToken,
            subscriptionType: payload.subscriptionType, rateLimitTier: payload.rateLimitTier,
            expiresAt: payload.expiresAt, emailHint: payload.email)
    }

    private func validOwnership(_ record: ClaudeSeatKeychainRecord) -> Bool {
        validOwnership(service: record.service, account: record.account, label: record.label)
    }

    private func validOwnership(service: String, account: String, label: String) -> Bool {
        label == Self.ownershipMarker && service == Self.service(for: account)
    }

    private func encode(_ payload: ClaudeSeatPayload) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(payload)
    }

    private func decode(_ record: ClaudeSeatKeychainRecord) -> ClaudeSeatPayload? {
        try? PropertyListDecoder().decode(ClaudeSeatPayload.self, from: record.data)
    }

    private func tokenDigest(_ token: String) -> String {
        VerifiedActiveSeat.digest(of: token)
    }

    private func readState() -> Result<ClaudeSeatVaultState, ClaudeSeatVaultError> {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return .success(ClaudeSeatVaultState())
        }
        do {
            let data = try Data(contentsOf: stateURL)
            return .success(try PropertyListDecoder().decode(ClaudeSeatVaultState.self, from: data))
        } catch {
            return .failure(ClaudeSeatVaultError("could not read retention state: \(error.localizedDescription)"))
        }
    }

    private func writeState(_ state: ClaudeSeatVaultState) -> String? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            return nil
        } catch {
            return "could not save retention state: \(error.localizedDescription)"
        }
    }

    private func withLock<T>(_ body: () -> T) -> Result<T, ClaudeSeatVaultError> {
        let directory = lockURL.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil else {
            return .failure(ClaudeSeatVaultError("could not create seat retention directory"))
        }
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return .failure(ClaudeSeatVaultError("could not open seat retention lock")) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            return .failure(ClaudeSeatVaultError("could not acquire seat retention lock"))
        }
        defer { flock(fd, LOCK_UN) }
        return .success(body())
    }

    private static func defaultDirectory() -> URL {
        Store.defaultSupportDirectory()
    }
}

/// Snapshot of `~/.claude.json` identity. mtime is a dirty bit that forces a
/// re-read; account change is the oauth email (or the file becoming unreadable).
struct ClaudeConfigIdentity: Equatable {
    var email: String?
    var modifiedAt: TimeInterval?
    var readable: Bool

    static func == (lhs: ClaudeConfigIdentity, rhs: ClaudeConfigIdentity) -> Bool {
        lhs.email == rhs.email && lhs.readable == rhs.readable
    }

    static func read(at url: URL, fileManager: FileManager = .default) -> ClaudeConfigIdentity {
        guard fileManager.fileExists(atPath: url.path) else {
            return ClaudeConfigIdentity(email: nil, modifiedAt: nil, readable: false)
        }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
        return ClaudeConfigIdentity(
            email: Keychain.profileEmail(at: url),
            modifiedAt: mtime,
            readable: true)
    }

    static func defaultURL() -> URL {
        Keychain.profileURL()
    }
}

/// Detect token or ~/.claude.json identity changes per profile.
/// Routine config writes that keep the same email and mtime do not fire.
/// Returned credentials retain the exact token observed, even if another login follows.
struct ClaudeLoginTracker {
    private var previous: [String: String]?
    private var previousIdentity: ClaudeConfigIdentity?

    mutating func changes(in credentials: [ClaudeCredential]) -> [ClaudeCredential] {
        observe(credentials: credentials, identity: nil).changedCredentials
    }

    mutating func observe(
        credentials: [ClaudeCredential],
        identity: ClaudeConfigIdentity?
    ) -> ClaudeLoginObservation {
        let current = Dictionary(credentials.map { ($0.service, fingerprint($0)) },
                                 uniquingKeysWith: { _, latest in latest })
        let seeded = previous != nil || previousIdentity != nil
        let identityChanged: Bool
        let watchDegraded: Bool
        if let identity, let previousIdentity {
            identityChanged = identity != previousIdentity
            watchDegraded = previousIdentity.readable && !identity.readable
        } else {
            identityChanged = false
            watchDegraded = false
        }
        defer {
            previous = current
            if let identity { previousIdentity = identity }
        }
        guard seeded else {
            return ClaudeLoginObservation(
                changedCredentials: [], identityChanged: false, watchDegraded: false)
        }
        var changed = credentials.filter { previous?[$0.service] != current[$0.service] }
        if identityChanged,
           let active = credentials.first(where: { $0.service == Keychain.defaultService }),
           !changed.contains(where: { $0.service == active.service }) {
            changed.append(active)
        }
        return ClaudeLoginObservation(
            changedCredentials: changed,
            identityChanged: identityChanged,
            watchDegraded: watchDegraded)
    }

    private func fingerprint(_ credential: ClaudeCredential) -> String {
        "\(credential.accessToken)|\(credential.expiresAt?.timeIntervalSince1970.description ?? "")|\(credential.emailHint ?? "")"
    }
}

struct ClaudeLoginObservation {
    let changedCredentials: [ClaudeCredential]
    let identityChanged: Bool
    let watchDegraded: Bool
}

struct ClaudeFetch {
    let email: String
    let usage: UsageResponse
}

struct ClaudeFetchFailure: LocalizedError {
    /// The VERIFIED email, set only by failures thrown after the profile fetch
    /// proved one (usage fetch, post-verification bookkeeping). A profile-step
    /// failure carries nil: the credential's hint is ~/.claude.json reread and
    /// must never promote into the roster's verifiedActiveEmail.
    let email: String?
    let message: String
    var errorDescription: String? { message }
}

struct ClaudeCredentialExpired: LocalizedError {
    var errorDescription: String? { "needs login" }
}

struct ClaudeRosterResult {
    let accounts: [String: AccountSnapshot]
    /// The active login's email ONLY as verified by a profile fetch this cycle or a
    /// prior one persisted in the store. The unverified credential hint is not here;
    /// a caller that sees nil must treat the active seat as unknown, not absent.
    let verifiedActiveEmail: String?
    let attemptedServices: [String]
    let failedEmails: [String]
    let failureText: String?
    let saveError: String?
}

/// The completed observations are kept separate from persistence so the app can combine
/// Claude, Cursor and OpenRouter into one locked Store mutation.
struct ClaudeRosterObservation {
    struct Success {
        let credential: ClaudeCredential
        let fetch: ClaudeFetch
    }

    struct Failure {
        let credential: ClaudeCredential
        let email: String?
        let message: String
    }

    let successes: [Success]
    let failures: [Failure]
    let expired: [ClaudeCredential]
    let attemptedServices: [String]
    let activeEmail: String?
    /// The part of `activeEmail` that came back from the profile endpoint. The hint
    /// prime (`credential.emailHint`) is ~/.claude.json reread, which any session can
    /// rewrite; only this field may persist.
    var verifiedActiveEmail: String? = nil
    /// Owned Keychain items this build listed but could not read. They carry no token, so
    /// nothing was fetched for them; the row names the item and status instead.
    var unreadableSeats: [ClaudeSeatUnreadableItem] = []

    /// Retirement can change while a profile or usage request is in flight. Filter again
    /// immediately before the Store mutation so a response cannot recreate that identity.
    func excluding(retiredEmails: Set<String>) -> ClaudeRosterObservation {
        guard !retiredEmails.isEmpty else { return self }
        let successes = successes.filter { !retiredEmails.contains($0.fetch.email) }
        let failures = failures.filter {
            guard let email = $0.email ?? $0.credential.emailHint else { return true }
            return !retiredEmails.contains(email)
        }
        let expired = expired.filter {
            guard let email = $0.emailHint else { return true }
            return !retiredEmails.contains(email)
        }
        return ClaudeRosterObservation(
            successes: successes,
            failures: failures,
            expired: expired,
            attemptedServices: attemptedServices,
            activeEmail: activeEmail.flatMap { retiredEmails.contains($0) ? nil : $0 },
            verifiedActiveEmail: verifiedActiveEmail
                .flatMap { retiredEmails.contains($0) ? nil : $0 },
            unreadableSeats: unreadableSeats.filter { !retiredEmails.contains($0.account) })
    }
}

enum ClaudeRoster {
    /// Fetch the supplied live captures in a stable sequence:
    /// it avoids a burst of OAuth requests and, crucially, one rejected seat never stops a
    /// later seat from being captured. Tokens are never renewed: an expired or refused
    /// token reads needs login until that seat signs into Claude Code again.
    static func collect(
        credentials: [ClaudeCredential],
        fetch: (ClaudeCredential) async throws -> ClaudeFetch,
        now: Date,
        unreadableSeats: [ClaudeSeatUnreadableItem] = []
    ) async -> ClaudeRosterObservation {
        var successes: [ClaudeRosterObservation.Success] = []
        var failures: [ClaudeRosterObservation.Failure] = []
        var expired: [ClaudeCredential] = []
        var attemptedServices: [String] = []
        var activeEmail: String?
        var verifiedActiveEmail: String?
        var seenTokens = Set<String>()

        // Prefer the currently active credential when the caller supplies duplicate captures.
        let ordered = credentials.filter { $0.service == Keychain.defaultService }
            + credentials.filter { $0.service != Keychain.defaultService }
        for original in ordered {
            // The same observed login must not issue duplicate requests.
            guard seenTokens.insert(original.accessToken).inserted else { continue }
            let credential = original
            if credential.service == Keychain.defaultService { activeEmail = credential.emailHint }

            if credential.isExpired(now: now) {
                expired.append(credential)
                continue
            }
            attemptedServices.append(credential.service)
            do {
                let result = try await fetch(credential)
                successes.append(.init(credential: credential, fetch: result))
                if credential.service == Keychain.defaultService {
                    activeEmail = result.email
                    verifiedActiveEmail = result.email
                }
            } catch is ClaudeCredentialExpired {
                // The server refused a token Tower thought was valid: needs login.
                expired.append(credential)
            } catch {
                let resolvedEmail = (error as? ClaudeFetchFailure)?.email
                failures.append(.init(credential: credential, email: resolvedEmail,
                                      message: error.localizedDescription))
                if credential.service == Keychain.defaultService {
                    activeEmail = resolvedEmail ?? credential.emailHint
                    if let resolvedEmail { verifiedActiveEmail = resolvedEmail }
                }
            }
        }
        return ClaudeRosterObservation(successes: successes, failures: failures, expired: expired,
                                       attemptedServices: attemptedServices, activeEmail: activeEmail,
                                       verifiedActiveEmail: verifiedActiveEmail,
                                       unreadableSeats: unreadableSeats)
    }

    static func apply(_ observation: ClaudeRosterObservation,
                      to accounts: inout [String: AccountSnapshot], now: Date) {
        // /login overwrites the one default Keychain item. Reconcile EVERY roster row;
        // inactive accounts have no fetchable token, even if their last capture was recent.
        // Successful observations below clear this status only for the account fetched.
        for key in Array(accounts.keys) where accounts[key]?.kind == .claude {
            accounts[key]?.lastError = "needs login"
        }
        // An owned item this build could not read still needs login, but the row says which
        // item and which status rather than hiding behind the bare marker. Anything observed
        // below for the same seat (expired, failed, or fetched) is more current and wins.
        for item in observation.unreadableSeats {
            let email = item.account
            guard !email.isEmpty else { continue }
            var snapshot = accounts[email] ?? AccountSnapshot(
                email: email, nickname: Nickname.derive(from: email), plan: "?")
            snapshot.lastError = item.panelMessage
            accounts[email] = snapshot
        }
        for credential in observation.expired {
            guard let email = credential.emailHint, !email.isEmpty else { continue }
            var snapshot = accounts[email] ?? AccountSnapshot(
                email: email, nickname: Nickname.derive(from: email), plan: credential.subscriptionType)
            // A stale access token is not a reason to discard the last capture.  It is a
            // reason to tell the operator that this seat needs a normal Claude Code login.
            snapshot.lastError = "needs login"
            accounts[email] = snapshot
        }

        for failure in observation.failures {
            guard let email = failure.email ?? failure.credential.emailHint, !email.isEmpty else { continue }
            var snapshot = accounts[email] ?? AccountSnapshot(
                email: email, nickname: Nickname.derive(from: email), plan: failure.credential.subscriptionType)
            snapshot.lastError = failure.message
            accounts[email] = snapshot
        }

        for success in observation.successes {
            let email = success.fetch.email
            var snapshot = accounts[email] ?? AccountSnapshot(
                email: email, nickname: Nickname.derive(from: email), plan: success.credential.subscriptionType)
            snapshot.nickname = accounts[email]?.nickname ?? Nickname.derive(from: email)
            snapshot.plan = success.credential.subscriptionType
            snapshot.tier = success.credential.rateLimitTier
            snapshot.fiveHourPct = success.fetch.usage.five_hour?.utilization
            snapshot.fiveHourResetsAt = DateParse.parse(success.fetch.usage.five_hour?.resets_at)
            snapshot.weeklyPct = success.fetch.usage.seven_day?.utilization
            snapshot.weeklyResetsAt = DateParse.parse(success.fetch.usage.seven_day?.resets_at)
            snapshot.scoped = (success.fetch.usage.limits ?? []).compactMap { limit in
                guard limit.kind == "weekly_scoped", let label = limit.scope?.model?.display_name,
                      let percent = limit.percent else { return nil }
                return ScopedLimit(label: label, percent: percent,
                                   resetsAt: DateParse.parse(limit.resets_at))
            }
            snapshot.capturedAt = now
            snapshot.lastError = nil
            accounts[email] = snapshot
        }
    }
}
