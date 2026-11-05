import Foundation
import Security
import CryptoKit
import LocalAuthentication

/// Every remembered seat in ONE Keychain item per signing identity.
///
/// Why: a Keychain item's access list names the build that wrote it. With one item per seat,
/// every identity change (a new signer, a new bundle id, every ad hoc update) made each seat
/// item ask again, and repairing the access list asked for the login password per item.
/// One bundle per identity turns that into a single approval:
///
/// - The running build reads and writes only its own bundle, `Tower-seats-v2` with account
///   = a tag of its designated requirement, always with the dialog suppressed. A fresh
///   install writes its own bundle on the first verified login: 0 prompts.
/// - The operator's Re-trust (`readSeats(interaction: .allowed)`) reads the newest bundle
///   another identity wrote (1 prompt), and the first time only the legacy per-seat items
///   (`Tower-owned Claude seat v1`, one prompt per seat, once). It merges what it read into
///   its own bundle (a new item, so no access repair and no password prompt), then deletes
///   the bundle and the legacy items it migrated from, inside that same operator action.
/// - Nothing here calls SecKeychainItemSetAccess.
///
/// The vault above keeps seeing per-seat records (service `Tower-seat-<email>`, label v1):
/// the bundle stores those records verbatim, so ownership checks are unchanged.
extension TowerSeatKeychainAccess {
    /// True when every entry that grants a read names specific applications, and (when
    /// `only` is given) names nothing outside it. An entry with no application list trusts
    /// every process, which is how a planted item would look.
    static func readClosed(_ entries: [SeatKeychainACLEntry], only: Set<Data>? = nil) -> Bool {
        let readAuthorizations: Set<String> = [
            kSecACLAuthorizationAny as String,
            kSecACLAuthorizationDecrypt as String,
        ]
        let readEntries = entries.filter { !$0.authorizations.isDisjoint(with: readAuthorizations) }
        guard !readEntries.isEmpty else { return false }
        for entry in readEntries {
            guard let apps = entry.applicationRequirements, !apps.isEmpty else { return false }
            if let only, !apps.isSubset(of: only) { return false }
        }
        return true
    }

    /// Import rule for an item Re-trust did not write itself: every entry that grants a read
    /// names only the running Tower app.
    ///
    /// A legacy ACL names a trusted application by its PATH (measured 2026-11-03:
    /// `SecTrustedApplicationCopyData` returns the NUL-terminated path, not a code
    /// requirement), so "names Tower" is decided in three steps, all required:
    /// 1. the path is the running Tower bundle's own path (`ownApplication`, the same bytes
    ///    the running build's own items carry). A signing identifier alone is not enough: an
    ///    ad hoc or self-signed identifier is self-declared, so any program could claim it;
    /// 2. the code at that path is validly signed with an identifier in `accepted`
    ///    (ProductIdentity's Tower ids; a rename adds the old one);
    /// 3. the path is never /usr/bin/security, which is what `security add-generic-password`
    ///    trusts when no -T list is given.
    /// Ad hoc builds: their designated requirement is a bare cdhash with no identifier, but
    /// their signing identifier is still the bundle id and an update replaces the app at the
    /// same path, so Re-trust keeps migrating across ad hoc releases. A build at another path
    /// (a moved install, a dev build) is refused; its seats come back at the next sign-in.
    static func readClosedToTower(
        _ entries: [SeatKeychainACLEntry],
        ownApplication: Data,
        accepted: Set<String> = ProductIdentity.keychainTrustedIdentifiers,
        identifierAt: (Data) -> String? = TowerSeatKeychainAccess.signingIdentifier(applicationData:)
    ) -> Bool {
        guard readClosed(entries, only: [ownApplication]) else { return false }
        if applicationPath(ownApplication) == securityToolPath { return false }
        guard let identifier = identifierAt(ownApplication), accepted.contains(identifier) else { return false }
        return true
    }

    static func applicationPath(_ data: Data) -> String {
        String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The signing identifier of the validly signed code at the path an ACL entry names; nil
    /// when the path holds no code or the code fails validation.
    static func signingIdentifier(applicationData data: Data) -> String? {
        let path = applicationPath(data)
        guard !path.isEmpty else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let fields = info as? [String: Any] else { return nil }
        return fields[kSecCodeInfoIdentifier as String] as? String
    }
}

struct BundledClaudeSeatKeychain: ClaudeSeatKeychain {
    /// Seats go into this build's bundle item, never into the per-seat legacy items.
    var writesBesideLegacyItems: Bool { true }
    static let bundleService = "Tower-seats-v2"
    static let bundleLabel = "Tower-owned Claude seat bundle v2"

    struct Entry: Codable, Equatable {
        let service: String
        let account: String
        let label: String
        let data: Data
    }

    var calls = SecItemCalls()
    var counter = KeychainCallCounter.shared
    var accessFactory: (String) -> Result<SecAccess, ClaudeSeatVaultError>
        = TowerSeatKeychainAccess.make(descriptor:)
    /// The running build's identity; nil for a bare build, which then owns no bundle.
    var identityTag: () -> String? = { BundledClaudeSeatKeychain.runningIdentityTag() }
    /// The running build's designated requirement, the only app its own bundle may trust.
    var ownRequirement: () -> Data? = {
        guard case .success(let requirements) = TowerSeatKeychainAccess.requiredApplicationRequirements()
        else { return nil }
        return requirements.first
    }
    /// Reads an item's ACL without a dialog. Injectable for tests.
    var aclEntries: (CFTypeRef) -> Result<[SeatKeychainACLEntry], SeatKeychainAccessInspectionError>
        = SystemClaudeSeatKeychain.aclEntries
    /// The signing identifier of an application an ACL names. Injectable for tests.
    var identifierAt: (Data) -> String? = TowerSeatKeychainAccess.signingIdentifier(applicationData:)

    /// Import rule for anything Re-trust did not write itself.
    private func importable(_ acl: [SeatKeychainACLEntry]) -> Bool {
        guard let own = ownRequirement() else { return false }
        return TowerSeatKeychainAccess.readClosedToTower(acl, ownApplication: own, identifierAt: identifierAt)
    }

    /// First 16 hex chars of SHA-256 over the running app's designated requirement. Changes
    /// exactly when the Keychain would stop trusting the build.
    static func runningIdentityTag() -> String? {
        guard case .success(let requirements) = TowerSeatKeychainAccess.requiredApplicationRequirements(),
              let first = requirements.first else { return nil }
        return SHA256.hash(data: first).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: ClaudeSeatKeychain

    func readSeats(interaction: ClaudeSeatReadInteraction) -> Result<ClaudeSeatKeychainReadout, ClaudeSeatVaultError> {
        let legacyRows: [Row]
        switch list(label: ClaudeSeatVault.ownershipMarker) {
        case .failure(let error): return .failure(error)
        case .success(let rows): legacyRows = rows.filter {
            $0.service == ClaudeSeatVault.service(for: $0.account)
        }
        }
        guard let tag = identityTag() else {
            // A bare build owns no bundle and never reads with the dialog allowed.
            return .success(ClaudeSeatKeychainReadout(records: [], unreadable: legacyRows.map {
                ClaudeSeatUnreadableItem(service: $0.service, account: $0.account, label: $0.label,
                                         status: errSecInteractionNotAllowed)
            }))
        }
        var entries: [Entry]
        var own = readBundle(account: tag, suppressed: true)
        // Re-trust only, and only after a refusal: one more read of this build's own bundle
        // with the dialog allowed (the process gate is open then), so the operator can answer
        // Always Allow. Background reads never get here (Codex review of 1216598).
        if interaction == .allowed, case .failure(let error) = own, error.isSignerRefusal {
            own = readBundle(account: tag, suppressed: false)
        }
        switch own {
        case .failure(let error) where error.isSignerRefusal && interaction == .allowed:
            // Refused even with the dialog: Re-trust did not recover anything. A failure, so
            // Re-trust never reports success while the bundle stays locked (Codex, 1216598).
            return .failure(error)
        case .failure(let error) where error.isSignerRefusal:
            // The bundle at this build's own name answers to another build. A login fact, not
            // a failed refresh: every seat reads as unreadable, the roster falls back to the
            // CLI credential, and the panel points at Re-trust. Nothing here deletes it.
            var readout = ClaudeSeatKeychainReadout(records: [], unreadable: legacyRows.map {
                ClaudeSeatUnreadableItem(service: $0.service, account: $0.account, label: $0.label,
                                         status: error.status ?? errSecAuthFailed)
            })
            readout.bundleRefused = true
            return .success(readout)
        case .failure(let error): return .failure(error)
        case .success(let own): entries = own ?? []
        }
        var refusedLegacy: [String: OSStatus] = [:]
        if interaction == .allowed {
            switch migrate(into: &entries, ownTag: tag, legacyRows: legacyRows) {
            case .failure(let error): return .failure(error)
            case .success(let refused): refusedLegacy = refused
            }
        }
        let held = Set(entries.map(\.account))
        var readout = ClaudeSeatKeychainReadout()
        readout.records = entries.map {
            ClaudeSeatKeychainRecord(service: $0.service, account: $0.account, label: $0.label, data: $0.data)
        }
        readout.unreadable = legacyRows.filter { !held.contains($0.account) }.map {
            ClaudeSeatUnreadableItem(service: $0.service, account: $0.account, label: $0.label,
                                     status: refusedLegacy[$0.account] ?? errSecInteractionNotAllowed)
        }
        return .success(readout)
    }

    func writeSeat(service: String, account: String, label: String, data: Data) -> String? {
        guard let tag = identityTag() else {
            return "Keychain access requires a signed Tower app bundle"
        }
        var entries: [Entry]
        switch readBundle(account: tag, suppressed: true) {
        case .failure(let error): return error.message
        case .success(let own): entries = own ?? []
        }
        entries.removeAll { $0.account == account }
        entries.append(Entry(service: service, account: account, label: label, data: data))
        return writeBundle(entries, tag: tag)
    }

    /// Removes the seat from this build's bundle and deletes its legacy item if one is left.
    func removeSeat(service: String, account: String, label: String) -> String? {
        if let tag = identityTag() {
            switch readBundle(account: tag, suppressed: true) {
            case .failure(let error): return error.message
            case .success(let own):
                if var entries = own, entries.contains(where: { $0.account == account }) {
                    entries.removeAll { $0.account == account }
                    if let error = writeBundle(entries, tag: tag) { return error }
                }
            }
        }
        return delete(service: service, account: account, label: label)
    }

    /// Forget and disable: every bundle (any identity) and every legacy seat item, so a
    /// forgotten seat cannot come back from an older bundle at the next Re-trust.
    func purgeAll() -> String? {
        var firstError: String?
        for (label, _) in [(Self.bundleLabel, 0), (ClaudeSeatVault.ownershipMarker, 1)] {
            switch list(label: label) {
            case .failure(let error): firstError = firstError ?? error.message
            case .success(let rows):
                for row in rows {
                    if let error = delete(service: row.service, account: row.account, label: row.label) {
                        firstError = firstError ?? error
                    }
                }
            }
        }
        return firstError
    }

    // MARK: Re-trust migration

    /// Reads, with the dialog allowed, the newest other-identity bundle and then the legacy
    /// items for seats still missing. The first refusal suppresses every later read. Writes
    /// the merged bundle, then deletes what it migrated from. Returns the legacy refusals.
    private func migrate(into entries: inout [Entry], ownTag: String,
                         legacyRows: [Row]) -> Result<[String: OSStatus], ClaudeSeatVaultError> {
        var suppressed = false
        var changed = false
        var migratedBundles: [String] = []
        var migratedLegacy: [Row] = []
        var refused: [String: OSStatus] = [:]

        let foreign: [Row]
        switch list(label: Self.bundleLabel) {
        case .failure(let error): return .failure(error)
        case .success(let rows):
            foreign = rows.filter { $0.service == Self.bundleService && $0.account != ownTag }
                .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        for row in foreign {
            let (status, data, reference) = readItem(service: row.service, account: row.account,
                                                     label: row.label, suppressed: suppressed)
            // A bundle a real Tower build wrote names that build alone. One whose read entry
            // trusts every process could have been planted by anyone: never import it.
            if status == errSecSuccess, let data, let reference,
               case .success(let acl) = aclEntries(reference),
               importable(acl),
               let other = try? JSONDecoder().decode([Entry].self, from: data) {
                for entry in other where Self.owned(entry)
                    && !entries.contains(where: { $0.account == entry.account }) {
                    entries.append(entry)
                    changed = true
                }
                migratedBundles.append(row.account)
                break
            }
            if Self.isDenial(status) { suppressed = true }
        }
        for row in legacyRows where !entries.contains(where: { $0.account == row.account }) {
            let (status, data, reference) = readItem(service: row.service, account: row.account,
                                                     label: row.label, suppressed: suppressed)
            if status == errSecSuccess, let data, let reference,
               case .success(let acl) = aclEntries(reference),
               importable(acl) {
                entries.append(Entry(service: row.service, account: row.account, label: row.label, data: data))
                migratedLegacy.append(row)
                changed = true
            } else {
                refused[row.account] = status
                if Self.isDenial(status) { suppressed = true }
            }
        }
        guard changed || !migratedBundles.isEmpty else { return .success(refused) }
        if let error = writeBundle(entries, tag: ownTag) {
            return .failure(ClaudeSeatVaultError(error))
        }
        // Only after the new bundle holds every seat: drop what it was copied from.
        for account in migratedBundles {
            _ = delete(service: Self.bundleService, account: account, label: Self.bundleLabel)
        }
        for row in migratedLegacy {
            _ = delete(service: row.service, account: row.account, label: row.label)
        }
        return .success(refused)
    }

    // MARK: Keychain primitives

    struct Row {
        let service: String
        let account: String
        let label: String
        let modified: Date?
    }

    private func list(label: String) -> Result<[Row], ClaudeSeatVaultError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: label,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = calls.copyMatching(query as CFDictionary, &result)
        counter.recordCopyMatching("list", status: status)
        if status == errSecItemNotFound { return .success([]) }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            return .failure(ClaudeSeatVaultError("Keychain read failed (\(status))", status: status))
        }
        return .success(rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String,
                  let account = row[kSecAttrAccount as String] as? String,
                  let rowLabel = row[kSecAttrLabel as String] as? String,
                  rowLabel == label else { return nil }
            return Row(service: service, account: account, label: rowLabel,
                       modified: row[kSecAttrModificationDate as String] as? Date)
        })
    }

    private func readItem(service: String, account: String, label: String,
                          suppressed: Bool) -> (OSStatus, Data?, CFTypeRef?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnRef as String: true,
        ]
        if suppressed {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = calls.copyMatching(query as CFDictionary, &result)
        counter.recordCopyMatching("item", status: status)
        guard let row = result as? [String: Any] else { return (status, result as? Data, nil) }
        return (status, row[kSecValueData as String] as? Data, row[kSecValueRef as String] as CFTypeRef?)
    }

    /// nil = this identity has no bundle it can trust yet. An item at its own name whose ACL
    /// trusts anything beyond the running build was not written by it, so its contents are
    /// ignored; the next write replaces the item.
    private func readBundle(account: String, suppressed: Bool) -> Result<[Entry]?, ClaudeSeatVaultError> {
        let (status, data, reference) = readItem(service: Self.bundleService, account: account,
                                                 label: Self.bundleLabel, suppressed: suppressed)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess, let data else {
            return .failure(ClaudeSeatVaultError("Keychain read failed (\(status))", status: status))
        }
        guard let reference, let own = ownRequirement(),
              case .success(let acl) = aclEntries(reference),
              TowerSeatKeychainAccess.readClosed(acl, only: [own]) else { return .success(nil) }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return .failure(ClaudeSeatVaultError("Keychain seat bundle did not decode"))
        }
        return .success(entries.filter(Self.owned))
    }

    /// Always delete then add with this build's own access, never update in place: an item
    /// someone else created at this name keeps that creator's ACL through an update, and the
    /// tokens would land in an item another process can read.
    private func writeBundle(_ entries: [Entry], tag: String) -> String? {
        if let error = delete(service: Self.bundleService, account: tag, label: Self.bundleLabel) {
            return error
        }
        if entries.isEmpty { return nil }
        guard let data = try? JSONEncoder().encode(entries) else { return "Keychain seat bundle did not encode" }
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.bundleService,
            kSecAttrAccount as String: tag,
            kSecAttrLabel as String: Self.bundleLabel,
            kSecValueData as String: data,
        ]
        switch accessFactory(Self.bundleLabel) {
        case .failure(let error): return error.message
        case .success(let access): add[kSecAttrAccess as String] = access
        }
        let addStatus = calls.add(add as CFDictionary, nil)
        return addStatus == errSecSuccess ? nil : "Keychain write failed (\(addStatus))"
    }

    /// The vault's ownership rule, applied to every entry that comes out of a bundle.
    private static func owned(_ entry: Entry) -> Bool {
        entry.label == ClaudeSeatVault.ownershipMarker
            && entry.service == ClaudeSeatVault.service(for: entry.account)
    }

    private func delete(service: String, account: String, label: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
        ]
        let status = calls.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return "Keychain remove failed (\(status))"
        }
        return nil
    }

    private static func isDenial(_ status: OSStatus) -> Bool {
        status == errSecUserCanceled || status == errSecAuthFailed
            || status == errSecInteractionNotAllowed
            || status == errSecNoSuchKeychain || status == errSecInvalidKeychain
    }
}
