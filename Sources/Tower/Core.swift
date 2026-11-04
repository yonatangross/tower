import CryptoKit
import Foundation
import os

// MARK: - Wire models (shape verified live against /api/oauth/usage, 2026-07-24)

struct UsageWindow: Codable {
    let utilization: Double?
    let resets_at: String?
}

struct ModelRef: Codable { let display_name: String? }
struct LimitScope: Codable { let model: ModelRef? }

struct LimitEntry: Codable {
    let kind: String?
    let group: String?
    let percent: Double?
    let severity: String?
    let resets_at: String?
    let is_active: Bool?
    let scope: LimitScope?
}

struct UsageResponse: Codable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let limits: [LimitEntry]?
}

struct ProfileResponse: Codable {
    struct Account: Codable {
        let email_address: String?
        let email: String?
    }
    let account: Account?
    let email_address: String?

    var resolvedEmail: String? {
        account?.email_address ?? account?.email ?? email_address
    }
}

// MARK: - Date parsing
// Values look like "2026-07-24T23:10:00.499475+00:00" (6 fractional digits).

enum DateParse {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = iso.date(from: s) { return d }
        if let d = isoNoFrac.date(from: s) { return d }
        // Trim over-long fractional seconds (ISO8601DateFormatter wants <= 3 digits).
        if let dot = s.firstIndex(of: "."),
           let signIdx = s.range(of: "+", range: dot..<s.endIndex)?.lowerBound
                ?? s.range(of: "Z", range: dot..<s.endIndex)?.lowerBound {
            let head = String(s[s.startIndex..<dot])
            let tail = String(s[signIdx...])
            let frac = String(s[s.index(after: dot)..<signIdx]).prefix(3)
            let rebuilt = "\(head).\(frac)\(tail)"
            if let d = iso.date(from: rebuilt) { return d }
        }
        return nil
    }
}

// MARK: - Nicknames
// The short name a seat shows. By default the first six characters of the email's
// local part. A `nicknames.json` object ({"email": "nickname"}) in the support
// directory overrides it per address; it is read once at launch.

enum Nickname {
    static let overridesFileName = "nicknames.json"

    static let overrides: [String: String] = loadOverrides(
        from: Store.defaultSupportDirectory().appendingPathComponent(overridesFileName))

    static func loadOverrides(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        var normalized: [String: String] = [:]
        for (email, nickname) in map {
            let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { normalized[email.lowercased()] = trimmed }
        }
        return normalized
    }

    static func derive(from email: String) -> String {
        derive(from: email, overrides: overrides)
    }

    static func derive(from email: String, overrides: [String: String]) -> String {
        if let chosen = overrides[email.lowercased()] { return chosen }
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return String(local.prefix(6))
    }
}

// MARK: - Keychain access
// We shell out to /usr/bin/security deliberately: the keychain item's ACL is
// evaluated against the *calling process*, and Apple-signed `security` is already
// trusted here. Calling the Security framework from our own ad-hoc-signed bundle
// would re-prompt on every rebuild.

enum Keychain {
    static let defaultService = "Claude Code-credentials"

    private static func security(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// One item of `service`, narrowed to `account` when given. The `-a` is not
    /// decoration: two items share `Claude Code-credentials`, and the query with no
    /// account returns whichever sorts first, which can be the tokenless stub a
    /// session with no $USER wrote under the account name "unknown".
    static func readCredential(service: String = defaultService, account: String? = nil) -> Data? {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        guard let raw = security(args) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    static func profileEmail(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }
        return (oauth["emailAddress"] as? String) ?? (oauth["email"] as? String)
    }

    /// Claude Code reads its identity hint from the current config directory.
    /// The profile endpoint verifies identity before a successful usage capture.
    private static func activeProfileEmail(environment: [String: String]) -> String? {
        profileEmail(at: profileURL(environment: environment))
    }

    static func profileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        guard let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty else {
            return home.appendingPathComponent(".claude.json")
        }
        return URL(fileURLWithPath: configDir).appendingPathComponent(".claude.json")
    }

    /// The macOS account name Claude Code writes its default item under.
    static var loginAccountName: String? {
        let env = ProcessInfo.processInfo.environment["USER"]
        let name = (env?.isEmpty == false ? env : nil) ?? NSUserName()
        return name.isEmpty ? nil : name
    }

    /// One item sharing a service name, described by service, account, and modification time.
    /// Comes from `security dump-keychain` attribute listing, never `-d`: enumerating
    /// candidates must not move secret bytes through this process.
    struct ItemRef: Equatable {
        let service: String
        let account: String
        let modifiedAt: Date?

        init(service: String = Keychain.defaultService, account: String, modifiedAt: Date?) {
            self.service = service
            self.account = account
            self.modifiedAt = modifiedAt
        }
    }

    /// Claude Code 2.1.283 scopes the keychain service by the normalized config directory.
    /// A scoped session must only read its own service, otherwise another seat can become
    /// this process's active login. This mirrors the CLI's `JL` service-name builder.
    static func credentialService(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let secureStorageDir = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            guard !secureStorageDir.isEmpty else { return defaultService }
            return scopedCredentialService(for: secureStorageDir)
        }
        guard let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty else {
            return defaultService
        }
        return scopedCredentialService(for: configDir)
    }

    private static func scopedCredentialService(for configDir: String) -> String {
        let normalized = configDir.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(defaultService)-\(suffix)"
    }

    /// Every item in one Claude Code credential service. `find-generic-password` alone
    /// cannot enumerate: asked for a service it returns one match, so the fallback listing
    /// is a dump of item attributes scoped down to the current credential service.
    static func credentialItems(service: String) -> [ItemRef] {
        let loginKeychain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db")
        guard let dump = security(["dump-keychain", loginKeychain.path]) else { return [] }
        return parseItemRefs(dump, service: service)
    }

    /// One dump block per item, kept to the three attributes the fallback needs:
    /// class, service, account, modified time. A `keychain:` line starts a new item.
    static func parseItemRefs(_ dump: String, service: String) -> [ItemRef] {
        parseItemRefs(dump, matches: { $0 == service })
    }

    private static func parseItemRefs(_ dump: String, matches: (String) -> Bool) -> [ItemRef] {
        var refs: [ItemRef] = []
        var isGeneric = false
        var svce: String?, acct: String?, mdat: Date?
        func flush() {
            if isGeneric, let svce, matches(svce), let acct, !acct.isEmpty {
                refs.append(ItemRef(service: svce, account: acct, modifiedAt: mdat))
            }
            isGeneric = false; svce = nil; acct = nil; mdat = nil
        }
        func blob(_ line: String) -> String? {
            guard let start = line.range(of: "=\"") else { return nil }
            let rest = line[start.upperBound...]
            guard let end = rest.lastIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        /// Timedate lines carry the raw hex and the readable date: take the last quoted
        /// run, which is `2026-09-23 11:51:30 +0000`, not the `=0x...` blob.
        func lastQuoted(_ line: String) -> String? {
            guard let end = line.lastIndex(of: "\""),
                  let start = line[..<end].lastIndex(of: "\"") else { return nil }
            return String(line[line.index(after: start)..<end])
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        for line in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("keychain:") || trimmed.hasPrefix("class:") {
                flush()
                isGeneric = trimmed.hasPrefix("class:") && trimmed.contains("\"genp\"")
            } else if trimmed.hasPrefix("\"svce\"") {
                svce = blob(trimmed)
            } else if trimmed.hasPrefix("\"acct\"") {
                acct = blob(trimmed)
            } else if trimmed.hasPrefix("\"mdat\""), let q = lastQuoted(trimmed) {
                mdat = day.date(from: q)
            }
        }
        flush()
        return refs
    }

    /// Try order for credential service items: the account Claude Code writes under first,
    /// then every other item newest-modified first. Parsing still decides which one is
    /// real; ordering only decides which item is asked first.
    static func orderedItemRefs(_ refs: [ItemRef], preferredAccount: String?) -> [ItemRef] {
        refs.sorted { a, b in
            if (a.account == preferredAccount) != (b.account == preferredAccount) {
                return a.account == preferredAccount
            }
            return (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast)
        }
    }

    /// The testable core of `activeOAuth`: walk the refs in order and return the first
    /// item that parses to a token-bearing credential. An item with no access token,
    /// the "unknown" stub in particular, is skipped by `credential(from:)` and can
    /// never be the answer, however recent its modification date.
    static func firstCredential(
        refs: [ItemRef], preferredAccount: String?,
        read: (String) -> Data?, service: String = defaultService, emailHint: String? = nil
    ) -> ClaudeCredential? {
        for ref in orderedItemRefs(refs, preferredAccount: preferredAccount) {
            if let data = read(ref.account),
               let credential = credential(from: data, service: service, emailHint: emailHint) {
                return credential
            }
        }
        return nil
    }

    /// The item that yielded the last usable credential, so a run that needed the dump
    /// enumerates once and then goes straight at the same scoped keychain service.
    private static var resolvedItem: ItemRef?
    private static let resolvedItemLock = NSLock()
    private static func rememberResolved(_ item: ItemRef) {
        resolvedItemLock.lock()
        resolvedItem = item
        resolvedItemLock.unlock()
    }
    private static func lastResolvedItem() -> ItemRef? {
        resolvedItemLock.lock()
        defer { resolvedItemLock.unlock() }
        return resolvedItem
    }

    /// What one `activeOAuth` walk saw in the current credential service, so a `.noCredential`
    /// outcome can name the items it rejected instead of reporting a bare miss.
    /// Accounts are keychain metadata; the scan never carries item bytes.
    struct ActiveItemScan: Equatable {
        /// Accounts of every item the dump listing returned, in listing order.
        /// Empty when an account-first read answered before the listing ran.
        let itemAccounts: [String]
        /// The account whose item yielded the credential; nil when none did.
        let resolvedAccount: String?
    }

    private static var activeScan = ActiveItemScan(itemAccounts: [], resolvedAccount: nil)
    private static let activeScanLock = NSLock()
    private static func rememberScan(_ scan: ActiveItemScan) {
        activeScanLock.lock()
        activeScan = scan
        activeScanLock.unlock()
    }

    /// The scan left by the most recent `activeOAuth` call this process made.
    static var lastActiveScan: ActiveItemScan {
        activeScanLock.lock()
        defer { activeScanLock.unlock() }
        return activeScan
    }

    /// The `.noCredential` detail a scan earns: nil when the listing found nothing
    /// (the plain text already says unreadable) or when a credential did resolve,
    /// and a named count plus the tried accounts when items existed but none
    /// parsed. Account names are metadata, never secret bytes.
    static func noCredentialDetail(_ scan: ActiveItemScan) -> String? {
        guard scan.resolvedAccount == nil, !scan.itemAccounts.isEmpty else { return nil }
        let accts = scan.itemAccounts.joined(separator: ", ")
        if scan.itemAccounts.count == 1 {
            return "1 item for \(defaultService), acct: \(accts); does not parse to a credential"
        }
        return "\(scan.itemAccounts.count) items for \(defaultService), accts: \(accts); none parses to a credential"
    }

    /// One notice when the listing shows the service is shared: which account the
    /// walk settled on, or that none of the items parsed. Account names only.
    private static func noteSharedService(_ refs: [ItemRef], resolved: String?) {
        guard refs.count > 1 else { return }
        let verdict = resolved.map { "using acct \($0)" } ?? "none yields a credential"
        KeychainCallCounter.logger.notice(
            "\(refs.count, privacy: .public) items for \(defaultService, privacy: .public); \(verdict, privacy: .public)")
    }

    /// The `claudeAiOauth` object Claude Code writes, as one credential. Separate from the
    /// `security` call so the parse is testable on real item bytes without a Keychain.
    static func credential(from data: Data, service: String, emailHint: String?) -> ClaudeCredential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = root["claudeAiOauth"] as? [String: Any],
              let token = o["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let exp = (o["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredential(
            service: service, accessToken: token,
            subscriptionType: (o["subscriptionType"] as? String) ?? "?",
            rateLimitTier: o["rateLimitTier"] as? String,
            // Only the access token is read. The refresh token stays with Claude Code.
            expiresAt: exp, emailHint: emailHint)
    }

    /// Kept for callers that only need the currently signed-in credential.
    ///
    /// Account-first, then enumerate. The unscoped `find-generic-password -s` this
    /// replaced returned whichever `Claude Code-credentials` item sorted first, which
    /// after a session ran with no $USER could be the tokenless "unknown" stub while
    /// the real login sat under the macOS account name. Now the account the CLI writes
    /// under is asked directly, and the dump listing is only a fallback for the case
    /// where no $USER-named item exists at all. Current Claude Code may place that item
    /// under a per-config service suffix, which the fallback reads without persisting it.
    static func activeOAuth(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        read: (String, String?) -> Data? = { readCredential(service: $0, account: $1) },
        list: (String) -> [ItemRef] = { credentialItems(service: $0) }
    ) -> ClaudeCredential? {
        let hint = activeProfileEmail(environment: environment)
        let service = credentialService(environment: environment)
        var tried = Set<String>()
        func itemID(_ ref: ItemRef) -> String { "\(ref.service)\u{0}\(ref.account)" }
        if let account = loginAccountName {
            let ref = ItemRef(service: service, account: account, modifiedAt: nil)
            if let data = read(ref.service, ref.account),
               let credential = credential(from: data, service: defaultService, emailHint: hint) {
                rememberResolved(ref)
                rememberScan(ActiveItemScan(itemAccounts: [], resolvedAccount: ref.account))
                return credential
            }
            tried.insert(itemID(ref))
        }
        if let ref = lastResolvedItem(), ref.service == service, tried.insert(itemID(ref)).inserted,
           let data = read(ref.service, ref.account),
           let credential = credential(from: data, service: defaultService, emailHint: hint) {
            rememberScan(ActiveItemScan(itemAccounts: [], resolvedAccount: ref.account))
            return credential
        }
        let refs = list(service).filter { $0.service == service }
        for ref in orderedItemRefs(refs, preferredAccount: loginAccountName) {
            guard tried.insert(itemID(ref)).inserted else { continue }
            if let data = read(ref.service, ref.account),
               let credential = credential(from: data, service: defaultService, emailHint: hint) {
                rememberResolved(ref)
                rememberScan(ActiveItemScan(itemAccounts: refs.map(\.account), resolvedAccount: ref.account))
                noteSharedService(refs, resolved: ref.account)
                return credential
            }
        }
        rememberScan(ActiveItemScan(itemAccounts: refs.map(\.account), resolvedAccount: nil))
        noteSharedService(refs, resolved: nil)
        return nil
    }
}

// MARK: - API client

enum UsageAPI {
    static let host = "https://api.anthropic.com"
    static let userAgent = "Tower/0.1 (usage monitor)"

    private static func get(_ path: String, token: String) async throws -> Data {
        var req = URLRequest(url: URL(string: host + path)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "UsageAPI", code: code, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(code) for \(path)"
            ])
        }
        return data
    }

    static func usage(token: String) async throws -> UsageResponse {
        let data = try await get("/api/oauth/usage", token: token)
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
        UsageShape.logIfFiveHourMissing(data, usage: usage)
        return usage
    }

    /// Cached per access token. The email bound to a token never changes, and this app polls
    /// on a timer plus every menu open, so re-resolving identity each cycle doubled request
    /// volume against the very token the live Claude Code session depends on. A token
    /// rotation misses the cache and re-resolves, which is exactly when we want to.
    private static var emailCache: (token: String, email: String?)?

    static func email(token: String) async throws -> String? {
        if let cached = emailCache, cached.token == token { return cached.email }
        let data = try await get("/api/oauth/profile", token: token)
        let resolved = (try? JSONDecoder().decode(ProfileResponse.self, from: data))?.resolvedEmail
        emailCache = (token, resolved)
        return resolved
    }
}

/// The SHAPE of a provider reply, for finding where a window lives when a decoder misses
/// it. 2026-11-02: three max seats replied with no `five_hour`, so the 5h window sat
/// somewhere the decoder did not read. The shape names the top-level keys, and for each
/// `limits[]` entry its `kind` and `group` labels and its own keys. It never carries a
/// number, a date, a token or any other value, so it is safe to log in public.
enum UsageShape {
    /// Read with `log show --last 1d --predicate 'subsystem == "ai.yonyon.tower"
    /// AND category == "usage-shape"'`.
    static let logger = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "usage-shape")
    private static let lock = NSLock()
    private static var logged: Set<String> = []
    static let labelLimit = 32

    static func describe(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let top = object as? [String: Any] else { return nil }
        var out = "keys=" + top.keys.sorted().joined(separator: ",")
        guard let limits = top["limits"] else { return out }
        guard let entries = limits as? [Any] else { return out + "; limits=<not a list>" }
        let parts = entries.map { entry -> String in
            guard let fields = entry as? [String: Any] else { return "<not an object>" }
            return label(fields["kind"]) + "/" + label(fields["group"])
                + "{" + fields.keys.sorted().joined(separator: ",") + "}"
        }
        out += "; limits=[" + parts.joined(separator: ", ") + "]"
        return out
    }

    /// A categorical label as text, cut to `labelLimit`; anything that is not a string is named
    /// by its type, so a number can never reach the log through a label slot.
    private static func label(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "<none>"
        case let text as String: return String(text.prefix(labelLimit))
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "<bool>" : "<number>"
        default: return "<object>"
        }
    }

    /// Logs a reply's shape once per distinct shape per process, only when the decoded reply
    /// has no `five_hour` window.
    static func logIfFiveHourMissing(_ data: Data, usage: UsageResponse) {
        guard usage.five_hour == nil, let shape = describe(data) else { return }
        lock.lock()
        let first = logged.insert(shape).inserted
        lock.unlock()
        guard first else { return }
        logger.notice("usage reply without five_hour: \(shape, privacy: .public)")
    }
}

// MARK: - Persisted snapshots

struct ScopedLimit: Codable, Hashable {
    var label: String
    /// Optional so the writer can reject an out-of-range reading to nil; see
    /// `Store.rejectingOutOfRangePercents`. A nil percent is "measured but not
    /// publishable", distinct from a missing entry.
    var percent: Double?
    var resetsAt: Date?
    /// True when `percent` is 0 because `resetsAt` passed, not because a capture said so.
    /// Key omitted otherwise; see `AccountSnapshot.fiveHourReset`.
    var reset: Bool?
}

/// What the operator can select in Chrome, plus the account chooser row when that profile
/// has multiple Google accounts. These are separate facts: joining them into one display
/// string made the CLI quote an impossible Chrome profile name.
struct ChromeProfileHint: Equatable {
    let displayName: String
    let chooserEmail: String?

    var label: String {
        chooserEmail.map { "\(displayName) → \($0)" } ?? displayName
    }
}

struct AccountSnapshot: Codable, Identifiable {
    var email: String
    var nickname: String
    var plan: String
    var tier: String?
    var fiveHourPct: Double?
    var fiveHourResetsAt: Date?
    var weeklyPct: Double?
    var weeklyResetsAt: Date?
    /// The third window state on disk (#103). `effective()` tells a measured 0 from a 0
    /// derived because the window reset; the store writes the derived one as `true` here,
    /// next to the zeroed pct. Absent means the pct is a capture (or there is none), so
    /// consumers that ignore the key read exactly what they read before. Recomputed on
    /// every save from pct, resetsAt and the clock, never carried over from a prior row,
    /// so a fresh capture folded into an existing row clears it.
    var fiveHourReset: Bool?
    var weeklyReset: Bool?
    var scoped: [ScopedLimit] = []
    var capturedAt: Date?
    var lastError: String?
    /// Highest threshold already announced per window, keyed by "<window>@<resetEpoch>".
    /// Keying on the reset time means a new window starts silent automatically.
    var notified: [String: Double] = [:]

    /// OPTIONAL ON PURPOSE, and it must stay that way. Swift's synthesized `init(from:)`
    /// only falls back for Optionals: a non-optional with a default still throws on a
    /// missing key. Every snapshot written before providers existed lacks this key, so a
    /// non-optional here would throw on all of them. nil means `.claude`.
    ///
    /// ⚠️ This rescues a MISSING key ONLY. An unknown VALUE — a provider added by a newer
    /// build than the one reading the file — still throws, Optional or not. That is a
    /// different failure and it is handled where it belongs, in `Store.loadUnlocked`, which
    /// decodes row by row so one such row cannot empty the store. Both behaviours are
    /// pinned by checks; see the comment there for what it cost to find out.
    var provider: Provider?
    /// Codex prepaid credit balance, when the plan has any. nil for everything else.
    var creditBalance: String?
    /// OpenRouter's available cash balance, in USD. It is a point-in-time observation, so
    /// `capturedAt` is set in the same successful fold and never advanced on a failed poll.
    var balanceUSD: Double?
    /// OpenRouter's remaining budget as a percent of its ceiling, 0 to 100: the same
    /// number the BudgetRow shows, percent LEFT rather than percent spent. Statusline
    /// consumers read it directly instead of re-deriving room from the balance.
    var availablePct: Double?
    /// Standing rail crossing for this account, advanced by `Rail.evaluate`: "amber"
    /// while the account stands at or above 80 percent of the 5h meter, "red" at or
    /// above 90 percent of the 5h or 7d meter, key omitted below 80. This is the mirror
    /// field a lane launcher can read to refuse an open above amber. It is machine
    /// state, not a fresh claim: it holds at the last observed band until a capture or a
    /// window reset observes the drop that clears it, which is the safe direction while
    /// nobody is looking.
    var crossing: String?
    /// The model this seat runs, when the provider's own files say. Codex: the newest
    /// session's `turn_context` model, else the config default. Claude: the configured
    /// `model` in ~/.claude/settings.json, on the active login only (it is one machine
    /// setting, and every session rides that login). Optional for the same decode reason
    /// as `provider`.
    var model: String?
    /// How the numbers on a muse, devin or agy row were obtained: "live" (Tower asked the
    /// tool just now) or "cache" (the tool's own cached status, aged by `capturedAt`). A
    /// lane that cannot be read has no row at all. Key omitted on every other row. A
    /// provenance label, not a freshness claim: the age
    /// still comes from `capturedAt` and the window from `resetsAt`. Optional for the
    /// same decode reason as `provider`.
    var source: String?
    /// When Tower last tried to read this lane. `capturedAt` is when the tool observed
    /// its numbers; this is when Tower looked, so a 2 hour old Devin cache read now has
    /// `readAt` fresh and `capturedAt` old. Key omitted on every other row.
    var readAt: Date?

    var kind: Provider { provider ?? .claude }

    static let needsLoginText = "needs login"

    /// A Claude row needs login whenever Tower holds no readable token for it: the bare marker
    /// (no credential, or an expired one) or the marker followed by the reason, such as an
    /// owned Keychain item this build could not read. Either way it must not rank.
    var needsLogin: Bool { kind == .claude && lastError?.hasPrefix(Self.needsLoginText) == true }

    /// Store key. Codex is namespaced because the same person can hold a Claude account and
    /// a ChatGPT account on ONE email (the operator does), and an email-keyed
    /// dictionary would let whichever refreshed last overwrite the other.
    static func storeKey(email: String, provider: Provider) -> String {
        provider == .claude ? email : "\(provider.rawValue):\(email)"
    }

    var id: String { Self.storeKey(email: email, provider: kind) }

    /// The name for a list that mixes providers: the nickname, plus the product when another
    /// row in the same list carries the same nickname (one email holds a Claude and a Codex
    /// seat, both "eve"; observed in the RESTING list 2026-11-01). Unique names stay bare.
    static func listName(_ row: AccountSnapshot, among rows: [AccountSnapshot]) -> String {
        let shared = rows.contains { $0.nickname == row.nickname && $0.id != row.id }
        return shared ? "\(row.nickname) · \(row.kind.rawValue)" : row.nickname
    }

    /// Reset arithmetic for the captured window. This is an estimate after reset;
    /// only a recent capture can establish current room.
    static func effective(pct: Double?, resetsAt: Date?, now: Date = Date())
        -> (pct: Double?, reset: Bool) {
        guard let pct else { return (nil, false) }
        if let r = resetsAt, now >= r { return (0, true) }
        return (pct, false)
    }

    func effectiveFiveHour(now: Date = Date()) -> (pct: Double?, reset: Bool) {
        Self.effective(pct: fiveHourPct, resetsAt: fiveHourResetsAt, now: now)
    }
    func effectiveWeekly(now: Date = Date()) -> (pct: Double?, reset: Bool) {
        Self.effective(pct: weeklyPct, resetsAt: weeklyResetsAt, now: now)
    }

    /// The limit that explains the room shown for a Claude seat. A Fable cap is model
    /// specific, so it leads only at 100%; otherwise the aggregate windows decide room.
    /// This is deliberately presentation state: Fable remains eligible for alternate
    /// models, as `isRecommendable` and `restingReason` continue to use aggregate windows.
    enum BindingLimit: Equatable {
        case fable
        case sevenDay
        case fiveHour

        var label: String {
            switch self {
            case .fable: return "Fable"
            case .sevenDay: return "7d"
            case .fiveHour: return "5h"
            }
        }
    }

    struct BindingQuota: Equatable {
        let limit: BindingLimit
        let percent: Double
        let resetsAt: Date?
        let didReset: Bool

        /// The persisted weekly field represents a Cursor billing month, not a seven-day
        /// quota. Binding text must follow the provider's published clock everywhere.
        func label(for kind: Provider) -> String {
            switch limit {
            case .sevenDay: return kind.primaryWindowLabel
            case .fable, .fiveHour: return limit.label
            }
        }
    }

    func fableScope() -> ScopedLimit? {
        scoped.first { $0.label.caseInsensitiveCompare("Fable") == .orderedSame }
    }

    /// Selects the one quota the seat row must name. At a Fable cap the model-specific
    /// window is the immediate constraint; otherwise an exhausted 7d window wins over 5h.
    /// With no cap, use the more-used aggregate as the useful room estimate.
    func bindingQuota(now: Date = Date()) -> BindingQuota? {
        if let fable = fableScope() {
            let value = Self.effective(pct: fable.percent, resetsAt: fable.resetsAt, now: now)
            if Self.trust(pct: fable.percent, resetsAt: fable.resetsAt,
                          capturedAt: capturedAt, now: now) == .live,
               (value.pct ?? 0) >= 100 {
                return BindingQuota(limit: .fable, percent: value.pct ?? 0,
                                    resetsAt: fable.resetsAt, didReset: value.reset)
            }
        }

        let weekly = effectiveWeekly(now: now)
        if let pct = weekly.pct, pct >= Self.cappedPct {
            return BindingQuota(limit: .sevenDay, percent: pct,
                                resetsAt: weeklyResetsAt, didReset: weekly.reset)
        }
        let fiveHour = effectiveFiveHour(now: now)
        if kind.hasFiveHourWindow, let pct = fiveHour.pct, pct >= Self.cappedPct {
            return BindingQuota(limit: .fiveHour, percent: pct,
                                resetsAt: fiveHourResetsAt, didReset: fiveHour.reset)
        }

        switch (weekly.pct, fiveHour.pct) {
        case let (weeklyPct?, fiveHourPct?) where weeklyPct >= fiveHourPct:
            return BindingQuota(limit: .sevenDay, percent: weeklyPct,
                                resetsAt: weeklyResetsAt, didReset: weekly.reset)
        case let (_, fiveHourPct?) where kind.hasFiveHourWindow:
            return BindingQuota(limit: .fiveHour, percent: fiveHourPct,
                                resetsAt: fiveHourResetsAt, didReset: fiveHour.reset)
        case let (weeklyPct?, _):
            return BindingQuota(limit: .sevenDay, percent: weeklyPct,
                                resetsAt: weeklyResetsAt, didReset: weekly.reset)
        default:
            return nil
        }
    }

    /// A binding marker is a present-tense claim. Keep stale and missing snapshots from
    /// borrowing the raw fallback selected by `bindingQuota` for non-presentation callers.
    func presentableBindingQuota(now: Date = Date()) -> BindingQuota? {
        guard isRecommendable(now: now) else { return nil }
        return bindingQuota(now: now)
    }

    /// A capped Fable bucket does not stop Opus or Sonnet. Aggregate caps do.
    func bindingUsableFor(now: Date = Date()) -> String? {
        guard let binding = bindingQuota(now: now), binding.percent >= Self.cappedPct else {
            return nil
        }
        // A full metered Cursor pool stops Opus; Auto is unmetered and keeps running.
        if kind == .cursor, CursorPool.opusRefused(self, now: now),
           CursorPool.autoOpen(self, now: now) { return "Auto" }
        guard binding.limit == .fable else { return "none" }
        let fiveCapped = kind.hasFiveHourWindow
            && (effectiveFiveHour(now: now).pct ?? 0) >= Self.cappedPct
        let weeklyCapped = (effectiveWeekly(now: now).pct ?? 0) >= Self.cappedPct
        return fiveCapped || weeklyCapped ? "none" : "Opus / Sonnet"
    }

    /// The soonest reset among stored windows that still carry a nonzero percentage: the
    /// instant a number on disk stops describing a current window.
    ///
    /// The store zeroes an expired window only when it saves, and the app saves on a five
    /// minute poll. quota-cache.json is read by tools that do not look at `resetsAt` (the
    /// quota-guard hook blocks a prompt on the raw percentage), so the app rewrites the file
    /// at this instant instead of leaving a reset window at its old number until the next
    /// poll. A passed reset that still carries a percentage is returned as is: it is due now.
    static func nextWindowExpiry<S: Sequence>(_ accounts: S) -> Date?
        where S.Element == AccountSnapshot {
        var soonest: Date?
        func consider(_ pct: Double?, _ reset: Date?) {
            guard let pct, pct > 0, let reset else { return }
            soonest = min(soonest ?? reset, reset)
        }
        for account in accounts {
            consider(account.fiveHourPct, account.fiveHourResetsAt)
            consider(account.weeklyPct, account.weeklyResetsAt)
            for limit in account.scoped { consider(limit.percent, limit.resetsAt) }
        }
        return soonest
    }

    /// Worst binding constraint from the raw numbers, stale ones included.
    /// Callers must check capture trust even for the active account: its poll can fail.
    /// Do not rank or color stale rows using this cached number.
    ///
    /// Percent USED, not headroom: 90 means nearly full. The old `headroomPct` name said
    /// the opposite of what it returned; the alias below exists for one release because
    /// the same word ships as a JSON key on the MCP surface.
    func usedPct(now: Date = Date()) -> Double? {
        let a = effectiveFiveHour(now: now).pct
        let b = effectiveWeekly(now: now).pct
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
            }
    }

    /// One-release alias for `usedPct`, kept while the `headroomPct` JSON key still ships.
    func headroomPct(now: Date = Date()) -> Double? {
        usedPct(now: now)
    }

    /// Displayed room is derived from the binding usage constraint and cannot be negative.
    func roomPct(now: Date = Date()) -> Double? {
        usedPct(now: now).map { max(0, 100 - $0) }
    }

    /// A captured usage reading can exceed its nominal cap; retain that fact for display.
    func isOverCap(now: Date = Date()) -> Bool {
        (usedPct(now: now) ?? 0) > 100
    }

    /// A 5h window can move several points in minutes, so readings age out fast. Past this
    /// we stop claiming to know the number instead of presenting it as current fact.
    static let freshnessTTL: TimeInterval = 15 * 60

    /// Only a successful capture renews trust. A reset describes the captured window,
    /// not usage accumulated since then. The 15-minute capture TTL is stricter than
    /// every provider's shortest quota window, including Claude's five hours.
    static func trust(pct: Double?, resetsAt: Date?, capturedAt: Date?, now: Date = Date())
        -> Trust {
        guard pct != nil, let capturedAt else { return .unknown }
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= freshnessTTL ? .live : .stale
    }

    func trustFiveHour(now: Date = Date()) -> Trust {
        Self.trust(pct: fiveHourPct, resetsAt: fiveHourResetsAt, capturedAt: capturedAt, now: now)
    }
    func trustWeekly(now: Date = Date()) -> Trust {
        Self.trust(pct: weeklyPct, resetsAt: weeklyResetsAt, capturedAt: capturedAt, now: now)
    }

    /// Worst trust across the windows THIS PROVIDER ACTUALLY HAS.
    ///
    /// Filtering by provider is not cosmetic. `trust` returns `.unknown` when there is no
    /// reading, so a Codex account, which has no 5h window at all, scored
    /// `max(.unknown, .live) == .unknown` on every evaluation. Observed live 2026-08-03: a
    /// Codex row captured seconds earlier printed "snapshot just now (stale, not counted)"
    /// and was excluded from ranking forever. A window that cannot exist must not be able
    /// to make the account look untrustworthy.
    func worstTrust(now: Date = Date()) -> Trust {
        if needsLogin { return capturedAt == nil ? .unknown : .stale }
        guard kind.hasFiveHourWindow else { return trustWeekly(now: now) }
        return max(trustFiveHour(now: now), trustWeekly(now: now))
    }

    /// A fresh Claude capture whose reply carried the weekly window and no 5h one (observed live
    /// 2026-11-01 on the active max seat). The seat still does not rank: worstTrust keeps calling
    /// a missing 5h reading unknown, because the API may hide a full 5h window. This only lets
    /// the panel say WHAT is unknown ("5h not reported") instead of calling a seconds-old reading
    /// stale, and lets the answer stay on the active seat with its weekly room.
    func fiveHourUnreported(now: Date = Date()) -> Bool {
        kind == .claude && !needsLogin && fiveHourPct == nil && weeklyPct != nil
            && trustWeekly(now: now) == .live
    }

    /// Weekly-scoped model limits that are live AND exhausted, by label.
    ///
    /// INFORMATIONAL ONLY. It used to gate `isRecommendable`, on the reasoning that a model
    /// capped at 100% is unusable however much aggregate headroom remains. True in general,
    /// wrong in practice: a typical `~/.claude/settings.json` pins `model: opus[1m]`, no agent
    /// selects fable, and Fable is nonetheless the ONLY scoped bucket the API
    /// returns (35-95% across all six accounts, 2026-08-03). Gating on a model you never
    /// choose banishes accounts that are perfectly usable for the model you do.
    ///
    /// So the meters stay, because the numbers are real and worth seeing, and the verdict
    /// goes. If a scoped limit for the model actually in use ever appears, gate on THAT one
    /// rather than on every scoped limit indiscriminately.
    func exhaustedScoped(now: Date = Date()) -> [String] {
        scoped.compactMap { s in
            guard Self.trust(pct: s.percent, resetsAt: s.resetsAt,
                             capturedAt: capturedAt, now: now) == .live,
                  (Self.effective(pct: s.percent, resetsAt: s.resetsAt, now: now).pct ?? 0) >= 100
            else { return nil }
            return s.label
        }
    }

    /// Whether this account may be recommended as having room. Requires EVERY ranked window
    /// to be live: one recently-reset window is not enough, because the window we cannot see
    /// could be the binding constraint.
    ///
    /// Scoped limits deliberately do NOT appear here; see `exhaustedScoped`.
    ///
    /// The `trustedUsedPct` clause is redundant today, since `trust` only returns `.live`
    /// when `pct` is non-nil, so `worstTrust() == .live` already implies a value exists. Kept
    /// explicit so that relaxing one of the rules later cannot silently start recommending an
    /// account with no number attached.
    func isRecommendable(now: Date = Date()) -> Bool {
        worstTrust(now: now) == .live && trustedUsedPct(now: now) != nil
    }

    /// Live accounts first, then by worst binding constraint. A stale reading must never
    /// outrank a live one, and a never-captured account sorts last. Shared by the menubar
    /// and the CLI so the two cannot disagree about who has room.
    static func ranked(_ a: AccountSnapshot, _ b: AccountSnapshot, now: Date = Date()) -> Bool {
        let ta = a.worstTrust(now: now)
        let tb = b.worstTrust(now: now)
        if ta != tb { return ta < tb }
        // Unknown room has no meaningful numeric order. Keep the remembered roster
        // stable by name until another successful capture makes comparison possible.
        guard ta == .live else {
            return a.nickname == b.nickname ? a.id < b.id : a.nickname < b.nickname
        }
        let ha = a.usedPct(now: now) ?? 9_999
        let hb = b.usedPct(now: now) ?? 9_999
        if ha != hb { return ha < hb }
        return a.nickname < b.nickname
    }

    /// Binding constraint counted ONLY from windows we can still vouch for. nil means
    /// "nothing currently known", which must never be rendered as "0% used".
    ///
    /// Percent USED, not headroom: the old `trustedHeadroomPct` name described a value
    /// of `100 - x` that it never computed, and it shipped on the MCP surface where a
    /// consumer comparing "headroom" against a floor would have inverted the check.
    func trustedUsedPct(now: Date = Date()) -> Double? {
        guard !needsLogin else { return nil }
        let a = trustFiveHour(now: now) == .live ? effectiveFiveHour(now: now).pct : nil
        let b = trustWeekly(now: now) == .live ? effectiveWeekly(now: now).pct : nil
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
        }
    }

    /// One-release alias for `trustedUsedPct`, kept while the `trustedHeadroomPct`
    /// JSON key still ships on the MCP surface.
    func trustedHeadroomPct(now: Date = Date()) -> Double? {
        trustedUsedPct(now: now)
    }

    // MARK: Resting

    /// At or above this, the account has no useful room left.
    static let cappedPct: Double = 95

    /// Legacy resting preference threshold. `partition` applies the stricter capture
    /// freshness check first, so no preference can move unknown usage into room ordering.
    static let restingStaleTTL: TimeInterval = 24 * 3600

    /// Why a row is not worth reading right now, or nil when it is.
    ///
    /// Capped and stale are different failures: no room versus no knowledge. Both disqualify
    /// a row from a list whose only job is "which do I use next", and an account can be both
    /// at once, so the reason is reported rather than reduced to a boolean.
    enum RestReason: Equatable {
        case capped(Double)
        /// A Cursor seat whose METERED pool (Opus and other API models) is full while
        /// Auto, which is unmetered, still runs. Its own case so no surface can render it
        /// as a plain "capped", the misreading that marked the seat dead twice
        /// (2026-09-22). See `CursorPool`.
        case meteredCapped(Double)
        case stale(TimeInterval)
        case cappedAndStale(Double, TimeInterval)
        case neverCaptured

        var isCapped: Bool {
            switch self {
            case .capped, .meteredCapped, .cappedAndStale: return true
            default: return false
            }
        }
        var isStale: Bool {
            switch self {
            case .stale, .cappedAndStale, .neverCaptured: return true
            default: return false
            }
        }

        /// Whether a CLOCK decides when this row comes back.
        ///
        /// Capped rows are a passive wait: the window refills on its own and the reset time
        /// is a real promise. A stale row is the opposite, an ACTION: its numbers are merely
        /// unknown, so switching into it and refreshing resolves it immediately. Showing a
        /// reset date beside a stale row implies it is unavailable until then, which is
        /// false, and ben demonstrated it live (7d at 91%, 5h already reset, so usable now,
        /// yet the drawer advertised "opens Aug 5 02:00").
        var isTimeGated: Bool {
            switch self {
            case .capped, .meteredCapped, .cappedAndStale: return true
            case .stale, .neverCaptured: return false
            }
        }

        /// Rendered once here so the menubar drawer and the CLI cannot describe the same
        /// state with different words.
        var text: String {
            /// Compound past a day. `Int(t / 86_400)` truncated, so a 47.5-hour-old reading
            /// printed "stale 1d" and understated its own age by nearly a full day, which is
            /// the wrong direction for a signal whose entire job is to say "trust this less".
            func ageStr(_ t: TimeInterval) -> String {
                if t < 3_600 { return "\(Int(t / 60))m" }
                if t < 86_400 { return "\(Int(t / 3_600))h" }
                let days = Int(t / 86_400)
                let hours = Int((t - Double(days) * 86_400) / 3_600)
                return hours == 0 ? "\(days)d" : "\(days)d\(hours)h"
            }
            switch self {
            case .capped(let p):
                return "capped \(Int(p.rounded()))%"
            case .meteredCapped(let p):
                return "Opus pool capped \(Int(p.rounded()))% · Auto unmetered"
            case .stale(let t):
                return "stale \(ageStr(t))"
            case .cappedAndStale(let p, let t):
                return "capped \(Int(p.rounded()))% · stale \(ageStr(t))"
            case .neverCaptured:
                return "never captured"
            }
        }
    }

    /// Which failures count as resting. Mirrors the three-way control in the design
    /// playground so the rule stays a choice rather than a hardcoded opinion.
    enum RestRule: String, Codable, CaseIterable {
        case capped, stale, either
    }

    func restingReason(rule: RestRule = .either, now: Date = Date()) -> RestReason? {
        if needsLogin {
            return capturedAt.map { .stale(max(0, now.timeIntervalSince($0))) } ?? .neverCaptured
        }
        // Money never rests: an OpenRouter balance is not a quota waiting to reopen.
        guard kind.isRankable else { return nil }

        guard let capturedAt else {
            return rule == .capped ? nil : .neverCaptured
        }
        let age = now.timeIntervalSince(capturedAt)
        let isStale = age > Self.restingStaleTTL

        // Aggregates only. A scoped limit no longer counts as capped; see `exhaustedScoped`
        // for why gating on a model this operator never selects banished usable accounts.
        let worst = usedPct(now: now)
        let isCapped = (worst ?? 0) >= Self.cappedPct

        switch rule {
        case .capped: guard isCapped else { return nil }
        case .stale:  guard isStale  else { return nil }
        case .either: guard isCapped || isStale else { return nil }
        }

        if isCapped && isStale, let w = worst { return .cappedAndStale(w, age) }
        // Cursor: a full metered pool refuses Opus but not Auto, so it gets its own words.
        // Read from the stored pools, not the live-only view: this runs for rows of any
        // age, and a 20 minute old reading must not flip back to a plain "capped". Only
        // while the Auto pool itself is open; with both pools full, "capped" is the truth.
        if isCapped, kind == .cursor, CursorPool.autoOpen(self, now: now),
           let metered = CursorPool.poolPct(self, CursorPool.meteredLabel, now: now),
           metered >= Self.cappedPct {
            return .meteredCapped(metered)
        }
        if isCapped, let w = worst { return .capped(w) }
        return .stale(age)
    }

    /// Split a roster into what you can act on and what you cannot. One function so the
    /// menubar and the CLI cannot disagree about who is resting, the same way `ranked`
    /// keeps them agreeing about who has room.
    static func partition(
        _ accounts: [AccountSnapshot], rule: RestRule = .either, now: Date = Date()
    ) -> (active: [AccountSnapshot], resting: [(AccountSnapshot, RestReason)]) {
        var active: [AccountSnapshot] = []
        var resting: [(AccountSnapshot, RestReason)] = []
        for a in accounts {
            // Display preferences must never promote unknown usage into the room list.
            if a.kind.isRankable && !a.isRecommendable(now: now) {
                let reason: RestReason = a.capturedAt.map {
                    .stale(max(0, now.timeIntervalSince($0)))
                } ?? .neverCaptured
                resting.append((a, reason))
            } else if let why = a.restingReason(rule: rule, now: now) { resting.append((a, why)) }
            else { active.append(a) }
        }
        active.sort { ranked($0, $1, now: now) }
        // Actionable rows first: a stale account can be resolved right now by switching into
        // it, while a capped one can only be waited out. Within the capped group, soonest to
        // reopen leads, so the drawer's one visible line answers "how long until I have an
        // account back".
        resting.sort { a, b in
            if a.1.isTimeGated != b.1.isTimeGated { return !a.1.isTimeGated }
            if !a.1.isTimeGated { return ranked(a.0, b.0, now: now) }
            return reopening(a.0, now: now) ?? .distantFuture
                 < reopening(b.0, now: now) ?? .distantFuture
        }
        return (active, resting)
    }

    // MARK: Advice

    /// What the top line of the panel should say.
    ///
    /// Split out as a pure value because the first version simply printed the best account,
    /// which meant it spent most of its life saying "use eve" while the active marker was
    /// already sitting on eve. A recommendation you are already following is not a
    /// recommendation, so staying and switching are now different answers.
    enum Advice: Equatable {
        /// Already on the best account. `next` names the runner-up so the line still says
        /// something forward-looking rather than merely confirming the status quo.
        case stay(nick: String, pct: Double?, next: String?)
        /// `nick` is the ACCOUNT (ana), `via` the Chrome display profile and, when needed,
        /// the chooser row to select after `/login` opens Google.
        case switchTo(nick: String, pct: Double?, via: ChromeProfileHint?)
        /// Which seat the CLI holds could not be established, so "switch to the best
        /// seat" could name the seat the operator is already on. The roomiest seat is
        /// still reported (`roomPct`, not used) but nothing is claimed about staying.
        case activeUnknown(nick: String, roomPct: Double?, via: ChromeProfileHint?)
        /// The active seat's reply carried no 5h window (`fiveHourUnreported`), so it cannot
        /// rank, yet it is the seat the operator is on with a live weekly reading. Saying
        /// "switch to <busier seat>" was the 2026-11-01 symptom; the answer names the gap and
        /// the weekly room instead, with the best ready seat as `next`. Nothing to run.
        case activeFiveHourUnknown(nick: String, weekRoomPct: Double?, next: String?)
        case allResting(first: Date?)

        /// The command that acts on this advice, or nil when there is nothing to do.
        ///
        /// `/login`, NOT `claude-switch`. The latter is a zsh function over a profile
        /// directory that has not been written to since April and covers 4 of 6 accounts;
        /// printing it gave the operator a command that would fail, or worse, succeed at
        /// rolling `~/.claude.json` back four months (measured: a switch to the ben
        /// snapshot drops ~50 config keys, 2 MCP servers and 5 projects).
        ///
        /// The real switch is `/login` inside Claude Code followed by signing in through
        /// the matching Chrome profile, so the copyable half is `/login` and the profile
        /// to pick is carried alongside in the advice label.
        var command: String? {
            switch self {
            case .switchTo, .activeUnknown: return "/login"
            case .stay, .activeFiveHourUnknown, .allResting: return nil
            }
        }

        /// The Chrome profile hint to sign in through, when one is known.
        var chromeProfile: ChromeProfileHint? {
            switch self {
            case .switchTo(_, _, let via), .activeUnknown(_, _, let via): return via
            case .stay, .activeFiveHourUnknown, .allResting: return nil
            }
        }
    }

    static func advise(
        activeEmail: String?,
        accounts: [AccountSnapshot],
        switchProfiles: [String: ChromeProfileHint] = [:],
        rule: RestRule = .either,
        now: Date = Date()
    ) -> Advice {
        let split = partition(accounts, rule: rule, now: now)
        // The active seat's reply had no 5h window: it cannot rank, but it is where the operator
        // stands with a live weekly reading, so the answer stays there and names the gap. Only
        // while that week has room: a capped week falls through to the switch (HOLD 6560661767),
        // since a missing 5h window may hide a full one too.
        if let activeEmail,
           let active = accounts.first(where: { $0.email == activeEmail && $0.kind == .claude }),
           active.fiveHourUnreported(now: now),
           (active.effectiveWeekly(now: now).pct ?? 100) < cappedPct {
            let next = split.active.first {
                $0.kind == .claude && $0.email != activeEmail && $0.isRecommendable(now: now)
            }
            return .activeFiveHourUnknown(
                nick: active.nickname,
                weekRoomPct: active.effectiveWeekly(now: now).pct.map { max(0, 100 - $0) },
                next: next?.nickname)
        }
        // Claude only: this advises what to pass to `claude-switch`, and a Codex row is not
        // a candidate for that however much headroom it has.
        // An account can be healthy in the usage API yet not be switchable locally.
        // Never emit a command that `claude-switch` cannot execute. An empty mapping
        // preserves the CLI's pure/offline behavior; the app passes its discovered profiles.
        let usable = split.active.filter {
            $0.kind == .claude
                && $0.isRecommendable(now: now)
                && (switchProfiles.isEmpty || switchProfiles[$0.email] != nil)
        }
        guard let best = usable.first else {
            return .allResting(first: split.resting
                .filter { $0.0.kind == .claude && $0.0.isRecommendable(now: now) }
                .compactMap { reopening($0.0, now: now) }.min())
        }
        let pct = best.trustedUsedPct(now: now)
        // With no verified active identity, `best` may BE the seat the CLI holds;
        // naming it as a switch target would be a guess dressed up as advice.
        guard let activeEmail else {
            return .activeUnknown(nick: best.nickname, roomPct: best.roomPct(now: now),
                                  via: switchProfiles[best.email])
        }
        guard best.email == activeEmail else {
            // A switch must be an IMPROVEMENT, not merely a move to the best SWITCHABLE
            // account. `usable` is filtered by `switchProfiles`, which only contains accounts
            // with a `~/.claude/accounts/*.json` carrying an `oauthAccount`. When the account
            // you are already on has no profile file, it cannot appear in `usable` at all, so
            // `usable.first` can easily be worse than where you are standing.
            //
            // Observed 2026-08-16: active dee had 31% room and exactly one account was
            // switchable, ben at 6%. The panel advised "switch to ben · 94% used" — a
            // recommendation to move to the most exhausted account on the fleet.
            //
            // Both sides must have current captures. The active poll can fail, and its
            // older cached room must not veto a fresh recommendation.
            if let active = accounts.first(where: {
                   $0.email == activeEmail && $0.kind == .claude
               }),
               active.isRecommendable(now: now),
               let activeUsed = active.usedPct(now: now),
               let bestUsed = best.usedPct(now: now),
               bestUsed >= activeUsed {
                // Staying is the honest answer; the runner-up line still points forward.
                return .stay(
                    nick: active.nickname,
                    pct: active.trustedUsedPct(now: now),
                    next: usable.first.map { $0.nickname }
                )
            }
            return .switchTo(
                nick: best.nickname, pct: pct, via: switchProfiles[best.email]
            )
        }
        // Runner-up: another usable account if one exists, otherwise the resting account
        // that comes back soonest, which is the real answer to "and after this one?".
        // Account nicknames throughout: Chrome profile hints identify the manual login
        // route, but would read as gibberish in a line whose job is to say which account to
        // use next.
        let next = usable.dropFirst().first.map { $0.nickname }
            ?? split.resting.first(where: {
                $0.0.kind == .claude && $0.0.isRecommendable(now: now)
            }).map { $0.0.nickname }
        return .stay(nick: best.nickname, pct: pct, next: next)
    }

    /// When this account actually becomes usable again. nil when nothing is known.
    ///
    /// The BINDING windows decide this, not the earliest one. Returning the soonest reset of
    /// any window promised relief that does not arrive: observed 2026-08-03, a seat sat near
    /// its weekly cap with its 5h window half used, and the drawer advertised the 5h turnover
    /// as the reopening time. After it the seat was still capped weekly and still unusable.
    ///
    /// When several windows are capped, ALL of them have to clear, so the latest of those
    /// wins. When nothing is capped (a purely stale row) any reset is progress, so the
    /// soonest is the honest answer.
    static func reopening(_ a: AccountSnapshot, now: Date = Date()) -> Date? {
        var binding: [Date] = []
        if a.kind.hasFiveHourWindow,
           (a.effectiveFiveHour(now: now).pct ?? 0) >= cappedPct,
           let r = a.fiveHourResetsAt, r > now { binding.append(r) }
        if (a.effectiveWeekly(now: now).pct ?? 0) >= cappedPct,
           let r = a.weeklyResetsAt, r > now { binding.append(r) }
        if let last = binding.max() { return last }
        return [a.fiveHourResetsAt, a.weeklyResetsAt]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
    }
}

// MARK: - Menubar title

enum MenubarTitle {
    /// Exactly ONE leading glyph: the failure marker when something is wrong, otherwise the
    /// traffic light. Always carrying one is the point. The healthy state used to render as
    /// bare text, which made the item unfindable among a screenful of other status icons
    /// precisely when nothing was wrong, and two glyphs at once just reads as clutter.
    static func glyph(pct: Double?, failing: Bool) -> String {
        if failing { return "⚠️" }
        guard let pct else { return "" }
        if pct >= 90 { return "🔴" }
        if pct >= 70 { return "🟠" }
        return "🟢"
    }
}

// MARK: - Freshness

/// How much we can vouch for a single window's reading right now.
/// Ordered worst-last so `max` picks the least trustworthy of a pair.
enum Trust: Int, Comparable, Codable {
    /// Captured within the TTL, or provably 0 because the window has already reset.
    case live = 0
    /// Older than the TTL and not reset, so the real number may have grown since.
    case stale = 1
    /// Never captured, or no reading for this window.
    case unknown = 2

    static func < (a: Trust, b: Trust) -> Bool { a.rawValue < b.rawValue }
}

/// Last-known seats from disk plus the current login hint. Used so a restart
/// paints aged rows immediately instead of empty placeholders until the first
/// network refresh returns.
enum SeatCacheHydration {
    static func rows(from store: Store) -> [AccountSnapshot] {
        store.load().values.sorted { AccountSnapshot.ranked($0, $1) }
    }

    static func activeEmail(hint: String?, accounts: [AccountSnapshot]) -> String? {
        guard let hint else { return nil }
        guard accounts.contains(where: { $0.email == hint && $0.kind == .claude }) else {
            return nil
        }
        return hint
    }
}

/// The active login's email as last proven by a profile fetch, with when.
///
/// `~/.claude.json`'s `oauthAccount` is only a hint: every Claude Code session
/// rewrites it, so reading it back cannot tell you who is actually logged in.
/// Tower writes this record only from a verified fetch, which is the difference
/// between reporting an identity and repeating a rumour.
struct VerifiedActiveSeat: Codable, Equatable {
    let email: String
    let verifiedAt: Date
    /// SHA-256 of the access token the verification was taken from. The record
    /// speaks only for that token; a login since then reads as unverified.
    var tokenDigest: String = ""

    /// A verification older than one OAuth token lifetime cannot describe the
    /// credential the CLI holds now.
    static let maxAge: TimeInterval = 12 * 3600

    static func digest(of accessToken: String) -> String {
        SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True while this record still describes `credential`: same access token,
    /// fresh verification, and no hint disputing the email. Anything less is an
    /// unknown active seat.
    func binds(to credential: ClaudeCredential, now: Date) -> Bool {
        guard !tokenDigest.isEmpty,
              tokenDigest == Self.digest(of: credential.accessToken),
              now.timeIntervalSince(verifiedAt) <= Self.maxAge else { return false }
        if let hint = credential.emailHint, hint != email { return false }
        return true
    }
}

/// The invented-store demo (scripts/demo-store.py): `TOWER_DEMO=1` together with
/// `TOWER_SUPPORT_DIR`. A demo must never read this Mac's login. Without this mode a
/// demo store could never show a verified seat (its record binds to an invented token,
/// not the real one) and every demo run read the real Claude Code credential to find
/// that out. In demo mode the live credential is `<support>/demo-credential.json` and
/// nothing else: no Keychain read, no network refresh.
enum DemoMode {
    static let credentialFileName = "demo-credential.json"

    /// The demo store, or nil when this is not a demo run. TOWER_DEMO alone does not
    /// count: a demo with no store to point at would read the real one.
    static func supportDirectory(env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard env["TOWER_DEMO"] == "1", let dir = env["TOWER_SUPPORT_DIR"], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The agent lanes a demo panel shows: none of this Mac's CLIs, only an invented Pi
    /// directory the demo names with TOWER_PI_DIR (never the real ~/.pi).
    static func lanes(env: [String: String] = ProcessInfo.processInfo.environment) -> [Provider: AgentLane.Outcome] {
        guard let dir = piDirectory(env: env) else { return [:] }
        return [.pi: PiLane.read(env: [PiLane.rootEnvKey: dir])]
    }

    /// TOWER_PI_DIR, only when it resolves (symlinks followed) to a directory inside the
    /// demo store. Anything else, including a link in the store that points out, is nil.
    static func piDirectory(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let store = supportDirectory(env: env), let dir = env[PiLane.rootEnvKey], !dir.isEmpty,
              let realStore = realPath(store.path),
              let realDir = realPath((dir as NSString).expandingTildeInPath)
        else { return nil }
        return realDir.hasPrefix(realStore.hasSuffix("/") ? realStore : realStore + "/") ? realDir : nil
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `panelshot sessions` runs `claude agents --json`, which lists this Mac's real
    /// sessions; a demo run never does.
    static func runsLiveSessionProbe(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        supportDirectory(env: env) == nil
    }

    /// TOWER_DEMO asked for without a store: the caller refuses to start rather than
    /// quietly running against the real store and Keychain.
    static func isMisconfigured(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["TOWER_DEMO"] == "1" && supportDirectory(env: env) == nil
    }

    /// The one mode main.swift runs for a set of arguments. Both the dispatch and the demo
    /// gate read this, in this order, so the gate always judges the verb that will run:
    /// a gate that only asked "is panelshot present" let `panelshot status` run status live.
    /// Raw values are the CLI words, so tests can walk every verb (MCPSurfaceTests checks
    /// each one dispatches to itself and has an MCP tool). `app` is the no-argument mode.
    enum Verb: String, CaseIterable, Equatable {
        case selftest, mcp, rotate, loginItem = "login-item", status, panelshot, app
    }

    static func dispatched(args: Set<String>) -> Verb {
        if args.contains("selftest") { return .selftest }
        if args.contains("mcp") { return .mcp }
        if args.contains("rotate") { return .rotate }
        if args.contains("login-item") { return .loginItem }
        if args.contains("status") { return .status }
        if args.contains("panelshot") { return .panelshot }
        return .app
    }

    /// Why a demo run must refuse these arguments, or nil when it may proceed. Only the
    /// MCP server and panelshot are wired for demo data (selftest is pure logic and
    /// returns before the gate); every other verb reads the Keychain, the login item or
    /// the network directly.
    static func refusal(args: Set<String>) -> String? {
        switch dispatched(args: args) {
        case .mcp, .panelshot, .selftest: return nil
        case .rotate, .loginItem, .status, .app:
            return "TOWER_DEMO=1 runs only `tower mcp` and `tower panelshot`"
        }
    }

    /// The invented active login. nil when the file is absent or unreadable, which reads
    /// as an unverified seat, exactly like a real Mac with no login.
    static func credential(in dir: URL) -> ClaudeCredential? {
        struct File: Decodable {
            let accessToken: String
            let emailHint: String?
            let subscriptionType: String?
        }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(credentialFileName)),
              let file = try? JSONDecoder().decode(File.self, from: data),
              !file.accessToken.isEmpty else { return nil }
        return ClaudeCredential(
            service: Keychain.defaultService, accessToken: file.accessToken,
            subscriptionType: file.subscriptionType ?? "max", rateLimitTier: nil,
            expiresAt: nil, emailHint: file.emailHint)
    }
}

/// The seat vault's Keychain in demo mode: holds nothing and writes nothing, so the
/// retention tools answer from an empty roster instead of the real login Keychain.
struct DemoSeatKeychain: ClaudeSeatKeychain {
    func readSeats(interaction: ClaudeSeatReadInteraction) -> Result<ClaudeSeatKeychainReadout, ClaudeSeatVaultError> {
        .success(ClaudeSeatKeychainReadout())
    }

    func writeSeat(service: String, account: String, label: String, data: Data) -> String? {
        "demo mode keeps no seats in the Keychain"
    }

    func removeSeat(service: String, account: String, label: String) -> String? {
        nil
    }
}

final class Store {
    static let shared = Store()

    private let dir: URL
    private let file: URL
    private let lock: URL
    private let mirror: URL?
    private let now: () -> Date

    /// Injectable so tests can point at a temp directory instead of the real support dir.
    /// `mirror` defaults to nil so a test Store never writes into the real ~/.claude.
    init(dir: URL, mirror: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.dir = dir
        self.mirror = mirror
        self.now = now
        file = dir.appendingPathComponent("accounts.json")
        lock = dir.appendingPathComponent(".accounts.lock")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private convenience init() {
        self.init(dir: Self.defaultSupportDirectory(), mirror: Self.defaultMirrorPath())
    }

    /// `~/Library/Application Support/Tower`, or `TOWER_SUPPORT_DIR` when set.
    /// The override exists for the MCP integration test, which runs the real binary
    /// against a throwaway store; nothing else sets it.
    static func defaultSupportDirectory(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = env["TOWER_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(ProductIdentity.supportDirectoryName, isDirectory: true)
    }

    /// `$CLAUDE_CONFIG_DIR/quota-cache.json`, defaulting to `~/.claude`. Honoured for the
    /// CLI path; the GUI normally has the variable unset.
    static func defaultMirrorPath(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        // A demo store's rows are invented; mirroring them into ~/.claude would feed
        // them to the real hooks.
        if let demo = DemoMode.supportDirectory(env: env) {
            return demo.appendingPathComponent("quota-cache.json")
        }
        let cfg: URL
        if let value = env["CLAUDE_CONFIG_DIR"], !value.isEmpty {
            cfg = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        } else {
            cfg = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
        }
        return cfg.appendingPathComponent("quota-cache.json")
    }

    /// The GUI app and the `status` CLI are separate PROCESSES, so an in-process actor or
    /// lock cannot serialize them. flock(2) on a sidecar can, and is held only across a
    /// load-modify-save.
    ///
    /// NOT re-entrant: flock ties the lock to the open file description, so a nested call
    /// opens a second fd and deadlocks against itself. Anything invoked from inside `body`
    /// must use the *Unlocked* variants.
    private func withLock<T>(_ body: () -> T) -> T {
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }  // no lock available: proceed, do not drop the write
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return body() }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    func load() -> [String: AccountSnapshot] {
        withLock {
            let clock = now()
            return loadUnlocked(now: clock).accounts
        }
    }

    /// Decodes one row without taking the rest of the file down with it.
    ///
    /// `try?` at the DICTIONARY level is what turned a single bad row into an empty store.
    /// Pushing the `try?` down to the element means a row we cannot read costs exactly that
    /// row.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// Rows that parsed, and the keys of any that did not.
    ///
    /// ROW BY ROW, not whole-file, and this is load-bearing rather than defensive coding.
    ///
    /// Measured 2026-08-18, and it cost the operator every account's history: the build that
    /// added the `cursor` provider wrote `"provider":"cursor"` into the shared store while
    /// the PREVIOUS build was still running its 300s poll. The old binary's `Provider` enum
    /// had no such case, so that ONE row threw; the decode was `try?` over the whole
    /// dictionary, so the whole thing became nil; `mutate` then seeded fresh placeholders
    /// into the resulting empty map and saved them over the file. Six accounts went to
    /// "never captured" with no error shown anywhere, and `writeMirror` copied the same
    /// bytes into ~/.claude.
    ///
    /// `AccountSnapshot.provider` is Optional specifically to survive this shape of change,
    /// and the comment there says so. It does not: Swift's synthesized decoder falls back
    /// for a MISSING key, while an unknown enum VALUE still throws. Verified both ways with
    /// a standalone decode before this was written.
    ///
    /// So a forward-compatibility break can cost the new provider's own row, which is
    /// re-derived on the next refresh anyway, and never the roster.
    private func loadUnlocked(now: Date) -> (accounts: [String: AccountSnapshot], unreadable: [String]) {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return ([:], []) }
        guard let raw = try? JSONDecoder().decode([String: Lenient<AccountSnapshot>].self,
                                                  from: data)
        else {
            // Top-level malformed, so not even the keys are known. Reported as one opaque
            // casualty rather than as an empty store, which stops the caller overwriting a
            // file that may still be salvageable by hand.
            return ([:], ["<whole file>"])
        }
        var accounts: [String: AccountSnapshot] = [:]
        var unreadable: [String] = []
        for (key, row) in raw {
            if let snap = row.value {
                accounts[key] = normalizedForPersistence(snap, now: now)
            } else {
                unreadable.append(key)
            }
        }
        return (accounts, unreadable.sorted())
    }

    /// Returns nil on success, else a reason. A save that silently no-ops means the next
    /// load quietly returns older data, which is the one failure this app must not have.
    @discardableResult
    func save(_ accounts: [String: AccountSnapshot]) -> String? {
        withLock {
            let clock = now()
            return saveUnlocked(accounts, now: clock)
        }
    }

    private func saveUnlocked(_ accounts: [String: AccountSnapshot], now: Date) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        let normalized = normalizedForPersistence(accounts, now: now)
        do { data = try enc.encode(normalized) } catch {
            return "encode failed: \(error.localizedDescription)"
        }
        let tmp = file.appendingPathExtension("tmp")
        do { try data.write(to: tmp, options: .atomic) } catch {
            return "write failed: \(error.localizedDescription)"
        }
        // replaceItemAt needs an existing destination, so the first-ever save has to move.
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: file)
            }
        } catch {
            return "commit failed: \(error.localizedDescription)"
        }
        writeMirror(data)
        return nil
    }

    private var activeSeatFile: URL { dir.appendingPathComponent("active-seat.json") }

    /// The last active login a profile fetch verified, or nil when Tower has never
    /// verified one. This is the only active-seat identity the MCP surface may
    /// report; the config-file hint any session rewrites is not identity.
    func verifiedActiveSeat() -> VerifiedActiveSeat? {
        guard let data = try? Data(contentsOf: activeSeatFile) else { return nil }
        return try? JSONDecoder().decode(VerifiedActiveSeat.self, from: data)
    }

    /// Written inside a locked mutate so the record lands with the roster it was
    /// verified against. No lock of its own: callers hold `withLock`, which is not
    /// re-entrant, and a nil verification must leave the previous record alone.
    /// The token binds the record to the credential it was verified from.
    func recordVerifiedActiveSeatUnlocked(_ email: String, token: String, now: Date) {
        let record = VerifiedActiveSeat(email: email, verifiedAt: now,
                                        tokenDigest: VerifiedActiveSeat.digest(of: token))
        guard let data = try? JSONEncoder().encode(record) else { return }
        let tmp = activeSeatFile.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        if FileManager.default.fileExists(atPath: activeSeatFile.path) {
            _ = try? FileManager.default.replaceItemAt(activeSeatFile, withItemAt: tmp)
        } else {
            try? FileManager.default.moveItem(at: tmp, to: activeSeatFile)
        }
    }

    /// Best-effort copy of the same bytes into ~/.claude, which is NOT TCC-gated.
    ///
    /// Why this exists (2026-08-09): `~/Library/Application Support/<app>` is macOS
    /// "App Data". A Claude Code hook (quota-guard, on UserPromptSubmit) read THIS
    /// store's file, so macOS raised a consent dialog on every prompt the operator
    /// typed - and named the wrong app, because TCC attributes by the responsible
    /// process the terminal multiplexer's SERVER inherited at spawn, not by the
    /// window in front of you. This app writes its own container and prompts nobody,
    /// so mirroring here lets the hook read the same data without ever crossing the
    /// boundary. Consumers read `$CLAUDE_CONFIG_DIR/quota-cache.json`.
    ///
    /// Identical bytes, not a reshaped view: consumers already parse this schema, and
    /// a second shape would be a second thing to keep in sync.
    ///
    /// Silent on failure BY DESIGN. The mirror is a convenience; the save above is
    /// authoritative and must never fail, slow down, or report an error because a
    /// convenience copy could not be written.
    private func writeMirror(_ data: Data) {
        guard let mirror = mirror else { return }
        try? FileManager.default.createDirectory(
            at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = mirror.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        if FileManager.default.fileExists(atPath: mirror.path) {
            _ = try? FileManager.default.replaceItemAt(mirror, withItemAt: tmp)
        } else {
            try? FileManager.default.moveItem(at: tmp, to: mirror)
        }
    }

    /// Locked read-modify-write. Both the GUI timer and the CLI do this, and doing it
    /// unlocked is how one process's capture gets clobbered by the other's stale copy.
    func mutate(_ body: (inout [String: AccountSnapshot]) -> Void)
        -> (accounts: [String: AccountSnapshot], saveError: String?) {
        withLock {
            let clock = now()
            let (loaded, unreadable) = loadUnlocked(now: clock)
            var accounts = loaded
            body(&accounts)
            accounts = normalizedForPersistence(accounts, now: clock)
            // REFUSE TO SAVE over rows we could not read. Writing here would delete data
            // this binary is merely too old to understand, which is precisely how the
            // 2026-08-18 wipe happened. The in-memory result is still returned so the UI
            // renders what we do know; only the destructive half is skipped, and the reason
            // surfaces as a refresh error rather than being swallowed.
            guard unreadable.isEmpty else {
                return (accounts, "not saving: \(unreadable.count) row(s) on disk "
                    + "(\(unreadable.joined(separator: ", "))) were written by a newer "
                    + "version of Tower and could not be read. Update Tower, or move "
                    + "accounts.json aside to start fresh.")
            }
            return (accounts, saveUnlocked(accounts, now: clock))
        }
    }

    /// The one pipeline every snapshot passes through on load, mutate and save,
    /// so the in-memory map, the authoritative file and the mirror can never
    /// disagree about what a row claims.
    private func normalizedForPersistence(
        _ accounts: [String: AccountSnapshot], now: Date
    ) -> [String: AccountSnapshot] {
        accounts.mapValues { normalizedForPersistence($0, now: now) }
    }

    private func normalizedForPersistence(
        _ snapshot: AccountSnapshot, now: Date
    ) -> AccountSnapshot {
        var snapshot = snapshot
        if snapshot.kind == .cursor, snapshot.creditBalance != nil {
            // Older builds divided model-rate dollars by the subscription price. That
            // derived percentage is not a pool reading, even if it falls within 0...100.
            snapshot.creditBalance = nil
            if !snapshot.scoped.contains(where: { $0.label == "Cursor Models" }) {
                snapshot.weeklyPct = nil
                snapshot.weeklyResetsAt = nil
                snapshot.lastError = "Cursor dashboard pool percentages not captured. Refresh Tower."
            }
        }
        return rejectingOutOfRangePercents(normalizingExpiredWindows(snapshot, now: now))
    }

    /// Range validation on write, and on read-back so a row saved before this
    /// rule existed heals on the next load instead of keeping a bogus number.
    /// Any pct field outside 0 to 100 is rejected to nil with the reason
    /// recorded on the row, never written as is: consumers read the raw
    /// percentage and compute room as 100 minus it, so a value like 734.48
    /// published verbatim renders as a false "no room" on every footer that
    /// trusts this file. Never clamp either: 734 is not 100, it is a broken
    /// contract, and the reason is what tells the row apart from "capped".
    private func rejectingOutOfRangePercents(_ snapshot: AccountSnapshot) -> AccountSnapshot {
        var s = snapshot
        var rejected: [String] = []
        func inRange(_ pct: Double) -> Bool { pct >= 0 && pct <= 100 }
        if let pct = s.fiveHourPct, !inRange(pct) {
            s.fiveHourPct = nil
            rejected.append("fiveHourPct \(String(format: "%.2f", pct))")
        }
        if let pct = s.weeklyPct, !inRange(pct) {
            s.weeklyPct = nil
            rejected.append("weeklyPct \(String(format: "%.2f", pct))")
        }
        if let pct = s.availablePct, !inRange(pct) {
            s.availablePct = nil
            rejected.append("availablePct \(String(format: "%.2f", pct))")
        }
        s.scoped = s.scoped.map { limit in
            guard let pct = limit.percent, !inRange(pct) else { return limit }
            rejected.append("scoped \"\(limit.label)\" \(String(format: "%.2f", pct))")
            var l = limit
            l.percent = nil
            return l
        }
        guard !rejected.isEmpty else { return s }
        let note = "withheld pct outside 0 to 100: \(rejected.joined(separator: ", "))"
        s.lastError = s.lastError.map { "\($0) \(note)" } ?? note
        return s
    }

    /// Materialize quota windows that have reset since a snapshot was captured. Capture and
    /// reset timestamps stay intact, so freshness still describes the new window accurately;
    /// only a known percentage from the old window becomes zero, and its reset flag says so.
    /// An unknown percentage stays unknown: a reset does not turn "not measured" into 0.
    private func normalizingExpiredWindows(
        _ accounts: [String: AccountSnapshot], now: Date
    ) -> [String: AccountSnapshot] {
        accounts.mapValues { normalizingExpiredWindows($0, now: now) }
    }

    private func normalizingExpiredWindows(
        _ snapshot: AccountSnapshot, now: Date
    ) -> AccountSnapshot {
        var normalized = snapshot
        let five = AccountSnapshot.effective(
            pct: normalized.fiveHourPct, resetsAt: normalized.fiveHourResetsAt, now: now)
        normalized.fiveHourPct = five.pct
        normalized.fiveHourReset = five.reset ? true : nil
        let weekly = AccountSnapshot.effective(
            pct: normalized.weeklyPct, resetsAt: normalized.weeklyResetsAt, now: now)
        normalized.weeklyPct = weekly.pct
        normalized.weeklyReset = weekly.reset ? true : nil
        normalized.scoped = normalized.scoped.map { limit in
            var normalizedLimit = limit
            let value = AccountSnapshot.effective(
                pct: limit.percent, resetsAt: limit.resetsAt, now: now)
            normalizedLimit.percent = value.pct
            normalizedLimit.reset = value.reset ? true : nil
            return normalizedLimit
        }
        return normalized
    }

    /// EMPTY ON PURPOSE. The roster is DATA, and data about which humans own which
    /// subscriptions does not belong in source control.
    ///
    /// This used to hard-code five real gmail addresses. The repo is private, so nothing
    /// leaked, but "private" is one settings toggle away from "public" and a git history
    /// cannot be un-published. The roster lives in `known-accounts.json` under Application
    /// Support instead: outside the repo, already user-editable, already the file that wins
    /// over this constant anyway.
    ///
    /// Consequence on a FRESH machine: the panel starts empty and fills in as accounts are
    /// discovered — from `~/.claude/accounts/*.json`, from whichever credential is active,
    /// and from the Codex identity. That is slower than a baked-in list and strictly more
    /// honest, because it only ever claims accounts it has actually seen.
    private static let defaultDeclared: [String] = []

    /// Accounts that no longer exist upstream. Never seeded, and actively evicted from a
    /// store or declared-list written before they were retired.
    ///
    /// File-backed for the same reason as the roster: a retirement list is a list of real
    /// addresses. Empty here; the live list is `retired-accounts.json` beside the store.
    ///
    /// Retirement must be EXPLICIT rather than inferred from staleness. An archived account
    /// and an account you simply have not switched into for a week look IDENTICAL from here:
    /// only the active credential is pollable, so both just stop refreshing. Guessing would
    /// silently delete a live account you had not used lately.
    private static let defaultRetired: [String] = []

    var declaredFile: URL { dir.appendingPathComponent("known-accounts.json") }
    var retiredFile: URL { dir.appendingPathComponent("retired-accounts.json") }

    fileprivate enum RetirementRevision: Equatable {
        case missing
        case file(number: UInt64, modifiedAt: Date, size: UInt64)
        case unreadable

        var isReliable: Bool {
            if case .file = self { return true }
            return self == .missing
        }
    }

    struct RetirementSnapshot {
        fileprivate let emails: Set<String>
        fileprivate let revision: RetirementRevision
    }

    /// Addresses to keep out of the roster, read fresh from disk each call so editing the
    /// file takes effect without a rebuild.
    var retiredEmails: Set<String> {
        guard let data = try? Data(contentsOf: retiredFile),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return Set(Self.defaultRetired) }
        return Set(list)
    }

    /// Captures both retirement contents and the file revision before an asynchronous
    /// profile request. The revision prevents an old retirement from authorizing removal
    /// after an operator writes the same address back during that request.
    func retirementSnapshot() -> RetirementSnapshot {
        withLock { retirementSnapshotUnlocked() }
    }

    private func retirementSnapshotUnlocked() -> RetirementSnapshot {
        // A manual atomic rewrite can happen without this process's lock. Read the revision
        // on both sides of the JSON decode, and fail closed if it did not stay stable.
        for _ in 0..<2 {
            let before = retirementRevisionUnlocked()
            let emails = retiredEmails
            let after = retirementRevisionUnlocked()
            if before == after { return RetirementSnapshot(emails: emails, revision: after) }
        }
        return RetirementSnapshot(emails: retiredEmails, revision: .unreadable)
    }

    private func retirementRevisionUnlocked() -> RetirementRevision {
        guard FileManager.default.fileExists(atPath: retiredFile.path) else { return .missing }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: retiredFile.path),
              let number = attributes[.systemFileNumber] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else { return .unreadable }
        return .file(number: number.uint64Value, modifiedAt: modifiedAt, size: size.uint64Value)
    }

    /// A successful profile read for Claude Code's current credential proves that a
    /// previously-retired account is active again. Remove only that explicit retirement;
    /// the subsequent roster fold writes the fresh usage snapshot and its mirror.
    ///
    /// This stays under the store lock because the GUI timer and status CLI can both
    /// observe a completed `/login`. A malformed list fails closed: silently treating it
    /// as empty could revive an account an operator deliberately retired.
    func reactivateVerifiedAccount(_ email: String, from snapshot: RetirementSnapshot) -> String? {
        withLock {
            guard snapshot.revision.isReliable,
                  retirementRevisionUnlocked() == snapshot.revision
            else {
                return "Claude login changed while Tower was verifying it. Run /login in Claude Code, then refresh Tower."
            }
            guard FileManager.default.fileExists(atPath: retiredFile.path) else { return nil }
            let data: Data
            do {
                data = try Data(contentsOf: retiredFile)
            } catch {
                return "could not read retired Claude accounts: \(error.localizedDescription)"
            }
            var retired: [String]
            do {
                retired = try JSONDecoder().decode([String].self, from: data)
            } catch {
                return "could not read retired Claude accounts: \(error.localizedDescription)"
            }
            retired.removeAll { $0 == email }
            let encoded: Data
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                encoded = try encoder.encode(retired)
            } catch {
                return "could not update retired Claude accounts: \(error.localizedDescription)"
            }
            do {
                try encoded.write(to: retiredFile, options: .atomic)
                return nil
            } catch {
                return "could not update retired Claude accounts: \(error.localizedDescription)"
            }
        }
    }

    func seedDeclaredAccounts(into accounts: inout [String: AccountSnapshot]) {
        var declared: [String]
        if let data = try? Data(contentsOf: declaredFile),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            declared = list
        } else {
            declared = Self.defaultDeclared
        }

        // Reconcile the on-disk list rather than merely reading it. The file WINS over
        // `defaultDeclared`, so editing the constant alone changes nothing on a machine that
        // has already run this app: retired accounts would linger and newly-declared ones
        // would never appear.
        //
        // Reconciled = (file ∪ defaults) − retired. Hand-added accounts survive, which is the
        // point of the file being editable; the trade is that removing a DEFAULT by hand does
        // not stick, so retiring one means adding it to `retiredEmails`.
        let retired = retiredEmails            // one disk read per seed, not per element
        var reconciled = declared
        for email in Self.defaultDeclared where !reconciled.contains(email) {
            reconciled.append(email)
        }
        reconciled.removeAll { retired.contains($0) }
        if reconciled != declared || !FileManager.default.fileExists(atPath: declaredFile.path) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            try? enc.encode(reconciled).write(to: declaredFile, options: .atomic)
        }
        declared = reconciled

        // Evict snapshots for retired accounts. Seeding only fills gaps, so without this a
        // row captured while the account still existed would sit in the panel forever.
        for email in retired { accounts.removeValue(forKey: email) }

        for email in declared where accounts[email] == nil {
            accounts[email] = AccountSnapshot(
                email: email,
                nickname: Nickname.derive(from: email),
                plan: "?",
                tier: nil,
                capturedAt: nil
            )
        }
    }

    /// Seed and refresh the Codex row from whatever is already on disk. Cheap enough to run
    /// on every cycle: it is a bounded directory scan and a JSON decode, no network at all.
    ///
    /// `live` is the Codex CLI's own answer (`CodexLive`), fetched by the caller off the
    /// lock. It wins whenever it arrived: the disk reading only advances when a session
    /// writes a rollout, so an idle hour would otherwise read as stale.
    func seedCodexAccount(into accounts: inout [String: AccountSnapshot],
                          live: CodexReader.Reading? = nil,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard let id = CodexAuth.identity(home: home) else { return }
        let key = AccountSnapshot.storeKey(email: id.email, provider: .codex)
        var snap = accounts[key] ?? AccountSnapshot(
            email: id.email,
            nickname: Nickname.derive(from: id.email),
            plan: id.plan
        )
        snap.provider = .codex
        snap.plan = id.plan
        snap.model = CodexReader.currentModel(home: home) ?? snap.model
        if let reading = CodexReader.preferred(live: live, disk: CodexReader.latest(home: home)) {
            // `disk` is an autoclosure: the rollout walk only runs when the CLI did not answer.
            CodexReader.apply(reading, to: &snap)
            // An exhaustion carries no `plan_type`, so fall back to the JWT's plan rather
            // than blanking a field the auth token already answered.
            snap.plan = reading.limits?.plan_type ?? id.plan
        }
        accounts[key] = snap
    }

    /// Seed and refresh the Cursor row.
    ///
    /// Unlike Codex, the numbers need the network, so the caller does the fetch and hands
    /// the outcome in. The IDENTITY is local, which is what makes the failure modes honest:
    /// the row exists as soon as Cursor is signed in on this machine, so a refused session
    /// token shows up as a named error on a visible row that then ages into staleness,
    /// rather than as a section that quietly disappears.
    ///
    /// Returns the store key so the caller can run threshold bookkeeping against it.
    /// nil means there is no Cursor lane here at all, which is a normal state.
    @discardableResult
    func seedCursorAccount(into accounts: inout [String: AccountSnapshot],
                           outcome: CursorUsage.Outcome,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           now: Date = Date()) -> String? {
        guard let id = CursorAuth.identity(home: home) else {
            // A login Tower cannot read is a failure, not an absent lane. Write the reason
            // onto every existing Cursor row and leave its numbers and `capturedAt` exactly
            // as they were, so they keep aging into stale instead of being refreshed or
            // silently kept. Returns nil: no capture happened, so nothing to announce. With
            // no prior row there is nothing to age and nothing is invented.
            if case .identityUnreadable(let why) = outcome {
                for (key, var snap) in accounts where snap.kind == .cursor {
                    snap.lastError = why
                    accounts[key] = snap
                }
            }
            return nil
        }
        let key = AccountSnapshot.storeKey(email: id.email, provider: .cursor)
        var snap = accounts[key] ?? AccountSnapshot(
            email: id.email,
            nickname: Nickname.derive(from: id.email),
            plan: id.plan)
        snap.provider = .cursor
        snap.plan = id.plan

        switch outcome {
        case .ok(let reading):
            CursorUsage.apply(reading, to: &snap, now: now)
        case .rejected(let code):
            // `capturedAt` is deliberately NOT advanced. The old numbers stay on screen and
            // start aging, which is the visible stale state a refused cookie has to produce.
            snap.lastError = CursorUsage.refusedError(code: code, opaqueToken: id.opaqueToken)
        case .unavailable:
            snap.lastError = "could not read Cursor usage (network, or the response "
                + "did not parse)"
        case .identityUnreadable(let why):
            snap.lastError = why
        case .notConfigured:
            // Identity resolved but the fetch declined to run. Leave the row as it stands.
            break
        }
        accounts[key] = snap
        return key
    }

    /// Fold the agent lanes (Muse, Devin, Antigravity) into the shared store so the mirror
    /// carries them. A lane gets a row ONLY when it has a real observation: a tool read
    /// time (`capturedAt`) and a valid percent (`AgentLane.publishableQuota`). A row with
    /// no usage evidence would read as headroom to the dispatcher, and a row with no
    /// `capturedAt` makes platform's whole-file Tower snapshot validation fail for every
    /// account, so an unreadable lane has NO row at all and keeps its reason in
    /// `tower_lanes`. A lane not probed this cycle (`outcomes` has no entry) is left
    /// exactly as it was. Any other outcome removes the row, so an older capture cannot
    /// outlive a failed read.
    func seedAgentLaneAccounts(into accounts: inout [String: AccountSnapshot],
                               outcomes: [Provider: AgentLane.Outcome],
                               now: Date = Date()) {
        for lane in AgentLane.mirrorLanes {
            guard let outcome = outcomes[lane] else { continue }
            let email = AgentLane.mirrorEmail(lane)
            let key = AccountSnapshot.storeKey(email: email, provider: lane)
            // Only a real observation is published. Everything else (not installed, config
            // unreadable, not logged in, no cache, no read time, nothing exposed) removes
            // the row; the reason lives in `tower_lanes`, not in the mirror.
            guard let quota = AgentLane.publishableQuota(outcome),
                  let observed = quota.fetchedAt else {
                accounts.removeValue(forKey: key)
                continue
            }
            var snap = accounts[key] ?? AccountSnapshot(
                email: email, nickname: lane.rawValue, plan: "lane")
            snap.provider = lane
            AgentLane.apply(quota, observedAt: observed, to: &snap, now: now)
            accounts[key] = snap
        }
    }

    /// Fold the OpenRouter balance into the same persisted store as quota providers. The
    /// dispatcher consumes this file (and its byte-identical mirror), so keeping the balance
    /// only in the menubar's transient state leaves overflow routing with no evidence.
    ///
    /// A failed probe deliberately preserves an older capture rather than asserting that the
    /// old balance is new. With no prior successful reading, there is no row to write.
    func seedOpenRouterAccount(into accounts: inout [String: AccountSnapshot],
                               outcome: OpenRouter.Outcome,
                               now: Date = Date()) {
        let email = OpenRouter.storeEmail
        let key = AccountSnapshot.storeKey(email: email, provider: .openrouter)

        switch outcome {
        case .notConfigured:
            // Absence is deliberate, not a failed refresh. Remove a prior balance from the
            // authoritative map so its persisted mirror cannot keep routing on a key that
            // is no longer configured.
            accounts.removeValue(forKey: key)
            return
        case .ok(let budget):
            var snap = accounts[key] ?? AccountSnapshot(
                email: email, nickname: "openrouter", plan: "balance")
            OpenRouter.apply(budget, to: &snap, now: now)
            accounts[key] = snap
        case .rejected(let code, _, _):
            guard var snap = accounts[key] else { return }
            snap.lastError = OpenRouter.refusedError(code)
            accounts[key] = snap
        case .unavailable:
            guard var snap = accounts[key] else { return }
            snap.lastError = OpenRouter.unreadableError
            accounts[key] = snap
        }
    }

    /// Seed accounts we know exist from the legacy ~/.claude/accounts snapshots,
    /// so they appear as "never captured" instead of being invisible.
    ///
    /// Mostly vestigial as of 2026-07-26: those files are settings blobs last written in
    /// April, and only one of the four still carries an `oauthAccount` with an email. Kept
    /// because it is free and still finds that one; `defaultDeclared` is the real source.
    func seedKnownAccounts(into accounts: inout [String: AccountSnapshot]) {
        let retired = retiredEmails
        let home = FileManager.default.homeDirectoryForCurrentUser
        let accountsDir = home.appendingPathComponent(".claude/accounts")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: accountsDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = root["oauthAccount"] as? [String: Any],
                  let email = oauth["emailAddress"] as? String, !email.isEmpty,
                  // Never resurrect a retired account from a legacy settings blob.
                  !retired.contains(email)
            else { continue }
            if accounts[email] == nil {
                accounts[email] = AccountSnapshot(
                    email: email,
                    nickname: Nickname.derive(from: email),
                    plan: "?",
                    tier: nil,
                    capturedAt: nil
                )
            }
        }
    }

    /// Map an account email to the Chrome profile you sign in through.
    ///
    /// THIS IS THE REAL PRECONDITION FOR A SWITCH, and it replaces a check against
    /// `~/.claude/accounts/*.json`. That directory backs `claude-switch`, a zsh function
    /// that swaps the whole `~/.claude.json`. Measured 2026-08-16: every file in it is
    /// dated 2026-04-07, it covers only 4 of the 6 Claude accounts, 3 of those 4 have lost
    /// their `oauthAccount` key, and its `.active` pointer named a different account than
    /// the live config. Nobody has switched that way in four months.
    ///
    /// The operator switches with `/login` inside Claude Code and then signs in through the
    /// matching Chrome profile. So gating candidates on the old directory was gating on a
    /// dead mechanism — and because the ACTIVE account had no file there, it could not even
    /// be a candidate, which is how the panel came to advise a move from 31% room to 6%.
    ///
    /// Chrome's `Local State` carries the authoritative profile-directory → account-email
    /// mapping, which is exactly the thing the operator needs told to them ("which profile
    /// do I pick"). An account with no Chrome profile is genuinely harder to switch into,
    /// so the gate still means something; it just now means the true thing.
    func switchProfilesByEmail() -> [String: ChromeProfileHint] {
        // Chrome's profile list holds this Mac's real Google accounts; a demo shows none.
        guard DemoMode.supportDirectory() == nil else { return [:] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localState = home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: localState),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [:] }

        var byEmail: [String: ChromeProfileHint] = [:]
        var dirForEmail: [String: String] = [:]
        for (dir, raw) in cache {
            guard let info = raw as? [String: Any],
                  let email = info["user_name"] as? String,
                  !email.isEmpty
            else { continue }
            // Two profiles can hold the SAME account (Default and Profile 6 both carry
            // user-e here). Prefer "Default" when it is one of them, otherwise keep
            // the lowest-numbered directory, so the hint is stable across refreshes rather
            // than flipping with dictionary order.
            if let existing = dirForEmail[email] {
                if existing == "Default" { continue }
                if dir != "Default" && existing < dir { continue }
            }
            dirForEmail[email] = dir
            // The DISPLAY NAME, not the directory. "Profile 10" is Chrome's on-disk folder
            // and appears nowhere in its UI; the profile switcher shows the name the
            // operator gave it, which here is already the account nickname ("DEE"). A
            // hint the operator cannot see on screen is not a hint. Falls back to the
            // directory only when a profile has no name at all.
            let shown = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let displayName = shown ?? dir
            // Naming the profile is not always enough. `Local State` records the profile's
            // PRIMARY account, but a profile can have several Google accounts signed into
            // its browser session, and then `/login` raises Google's account chooser.
            // Measured 2026-08-16: 4 of 7 profiles are in that state, and every entry in
            // the chooser shows the same person's name, so the profile name alone cannot tell the
            // operator which row to click — picking wrong signs Claude Code into the wrong
            // account, which is the failure this whole advice line exists to prevent.
            // The email is appended ONLY when a chooser will actually appear, so the
            // single-account profiles stay uncluttered.
            let chooserEmail = signedInCount(profileDir: dir, under: home) > 1 ? email : nil
            byEmail[email] = ChromeProfileHint(
                displayName: displayName, chooserEmail: chooserEmail)
        }
        return byEmail
    }

    /// How many Google accounts are signed into one Chrome profile's browser session.
    ///
    /// Read from that profile's own `Preferences`, because `Local State` only carries the
    /// primary. Returns 1 on any read failure: the fallback must be the QUIET answer, since
    /// guessing "several" would append an email to every row on a transient read error.
    private func signedInCount(profileDir: String, under home: URL) -> Int {
        let prefs = home
            .appendingPathComponent("Library/Application Support/Google/Chrome")
            .appendingPathComponent(profileDir)
            .appendingPathComponent("Preferences")
        guard let data = try? Data(contentsOf: prefs),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["account_info"] as? [[String: Any]]
        else { return 1 }
        return max(accounts.compactMap { $0["email"] as? String }.count, 1)
    }
}

// MARK: - Refresh engine

/// What a refresh attempt actually achieved. Modelled explicitly because the old code
/// could fail completely and be indistinguishable from success.
enum RefreshOutcome {
    case ok(email: String)
    case failed(String)
    /// The keychain yielded no usable credential. `detail` names what the
    /// default-service listing found (for example two items, none parsing) so
    /// the error can say more than a bare miss (#108).
    case noCredential(detail: String?)

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    /// Text worth putting in front of the user, or nil when there is nothing wrong.
    var errorText: String? {
        switch self {
        case .ok: return nil
        case .failed(let reason): return reason
        case .noCredential(let detail):
            guard let detail, !detail.isEmpty else {
                return "active login unreadable in the keychain; seat numbers are live"
            }
            return "active login unreadable in the keychain (\(detail)); seat numbers are live"
        }
    }
}

struct RefreshResult {
    let accounts: [String: AccountSnapshot]
    /// The active login as VERIFIED by a profile fetch this cycle; nil when
    /// unverified, never the credential or config-file hint.
    let activeEmail: String?
    let outcome: RefreshOutcome
    /// The same OpenRouter observation folded into `accounts`, carried back so the GUI can
    /// render and record history without issuing a second request that could disagree.
    let openRouterOutcome: OpenRouter.Outcome
    /// A successful OpenRouter fold is usable only after this specific `mutate` call saved
    /// it. `mutate` returns its in-memory map on a write error, so the row alone is not
    /// evidence that the authoritative store and mirror contain the observation.
    let openRouterFoldCommitted: Bool
    /// Store key of the Cursor row, when this machine has one. Carried so the caller can
    /// run threshold bookkeeping against a row it did not have to go looking for.
    var cursorKey: String?
    /// The agent lanes as read this cycle, carried back so the panel renders the same
    /// answer that was folded into `accounts` instead of reading them a second time (a
    /// second read would spawn `muse usage` twice per cycle).
    var lanes: [Provider: AgentLane.Outcome] = [:]
}

enum Refresher {
    /// Folds local identities and completed provider probes into one persisted account snapshot.
    @discardableResult
    private static func seed(into accounts: inout [String: AccountSnapshot],
                             store: Store,
                             cursor: CursorUsage.Outcome,
                             openRouter: OpenRouter.Outcome,
                             codex: CodexReader.Reading? = nil,
                             lanes: [Provider: AgentLane.Outcome] = [:],
                             now: Date = Date()) -> String? {
        store.seedDeclaredAccounts(into: &accounts)
        store.seedKnownAccounts(into: &accounts)
        // Codex: the CLI's live answer when it came back, else the rollouts on disk, so it
        // refreshes on every seed rather than only when a credential is pollable.
        store.seedCodexAccount(into: &accounts, live: codex)
        // Cursor is the opposite: local identity, remote numbers. The fetch already ran
        // concurrently with the Claude poll, so only the fold happens under the lock.
        let cursorKey = store.seedCursorAccount(into: &accounts, outcome: cursor, now: now)
        store.seedOpenRouterAccount(into: &accounts, outcome: openRouter, now: now)
        store.seedAgentLaneAccounts(into: &accounts, outcomes: lanes, now: now)
        return cursorKey
    }

    /// Injectable Claude-only lane for focused roster tests.  Production combines the
    /// returned observation with the other provider folds below, so all providers still use
    /// one Store mutation per refresh.
    static func refreshClaudeRoster(
        store: Store,
        credentials: @escaping () async -> [ClaudeCredential],
        fetch: @escaping (ClaudeCredential) async throws -> ClaudeFetch,
        now: Date = Date(),
        unreadableSeats: [ClaudeSeatUnreadableItem] = []
    ) async -> ClaudeRosterResult {
        let observation = await ClaudeRoster.collect(
            credentials: await credentials(), fetch: fetch, now: now,
            unreadableSeats: unreadableSeats)
        let filtered = observation.excluding(retiredEmails: store.retiredEmails)
        let (accounts, saveError) = store.mutate { accounts in
            store.seedDeclaredAccounts(into: &accounts)
            store.seedKnownAccounts(into: &accounts)
            ClaudeRoster.apply(
                filtered,
                to: &accounts,
                now: now)
            if let verified = filtered.verifiedActiveEmail,
               let live = filtered.successes.first(where: {
                   $0.credential.service == Keychain.defaultService
               }) {
                store.recordVerifiedActiveSeatUnlocked(verified, token: live.credential.accessToken, now: now)
            }
        }
        return ClaudeRosterResult(
            accounts: accounts, verifiedActiveEmail: filtered.verifiedActiveEmail,
            attemptedServices: observation.attemptedServices,
            failedEmails: observation.failures.compactMap { $0.email ?? $0.credential.emailHint },
            failureText: observation.failures.first?.message ?? (observation.expired.isEmpty ? nil : "needs login"),
            saveError: saveError)
    }

    /// A `/login` changes the default Keychain item.  Refresh just that newly signed-in
    /// account immediately, rather than repeating Cursor/OpenRouter probes or re-polling
    /// every already-captured Claude profile.
    static func refreshLoggedInAccount(
        _ credential: ClaudeCredential? = Keychain.activeOAuth(),
        observation: Result<ClaudeSeatObservation, ClaudeSeatVaultError>? = nil
    ) async -> ClaudeRosterResult {
        await refreshLoggedInAccount(
            credential,
            store: Store.shared,
            vault: .shared,
            profile: UsageAPI.email,
            usage: UsageAPI.usage,
            clock: { Date() },
            observation: observation)
    }

    /// Injectable login capture path. `fetch` verifies the profile identity before this
    /// method passes the observed credential to the retained-seat vault.
    static func refreshLoggedInAccount(
        _ credential: ClaudeCredential?,
        store: Store,
        vault: ClaudeSeatVault,
        fetch: @escaping (ClaudeCredential) async throws -> ClaudeFetch,
        now: Date,
        observation: Result<ClaudeSeatObservation, ClaudeSeatVaultError>? = nil
    ) async -> ClaudeRosterResult {
        let observation = observation ?? vault.beginObservationResult()
        let retirementAtProfileStart = store.retirementSnapshot()
        return await refreshClaudeRoster(
            store: store,
            credentials: { credential.map { [$0] } ?? [] },
            fetch: { observed in
                let verified = try await fetch(observed)
                try verifiedLoginCapture(
                    activeCredential: credential,
                    store: store,
                    vault: vault,
                    observation: observation,
                    observed: observed,
                    email: verified.email,
                    retirementAtProfileStart: retirementAtProfileStart,
                    clock: { now })
                return verified
            },
            now: now)
    }

    /// Injectable production-equivalent login path. It verifies the profile, captures that
    /// verified identity, and only then requests usage. Profile and usage remain separate so
    /// tests can prove that a usage failure does not discard the new login.
    static func refreshLoggedInAccount(
        _ credential: ClaudeCredential?,
        store: Store,
        vault: ClaudeSeatVault,
        profile: @escaping (String) async throws -> String?,
        usage: @escaping (String) async throws -> UsageResponse,
        clock: @escaping () -> Date,
        observation: Result<ClaudeSeatObservation, ClaudeSeatVaultError>? = nil
    ) async -> ClaudeRosterResult {
        let observation = observation ?? vault.beginObservationResult()
        let refreshNow = clock()
        let retirementAtProfileStart = store.retirementSnapshot()
        let roster: ClaudeSeatRoster
        switch rosterCredentials(vault: vault, active: credential, store: store) {
        case .success(let value): roster = value
        case .failure(let error): return retentionReadFailure(store: store, error: error)
        }
        return await refreshClaudeRoster(
            store: store,
            credentials: { roster.credentials },
            fetch: { observed in
                try await fetchClaude(
                    observed,
                    profile: profile,
                    usage: usage,
                    onVerified: { verifiedCredential, email in
                        try verifiedLoginCapture(
                            activeCredential: credential,
                            store: store,
                            vault: vault,
                            observation: observation,
                            observed: verifiedCredential,
                            email: email,
                            retirementAtProfileStart: retirementAtProfileStart,
                            clock: clock)
                    },
                    clock: clock)
            },
            now: refreshNow,
            unreadableSeats: roster.unreadable)
    }

    private static func verifiedLoginCapture(
        activeCredential: ClaudeCredential?,
        store: Store,
        vault: ClaudeSeatVault,
        observation: Result<ClaudeSeatObservation, ClaudeSeatVaultError>,
        observed: ClaudeCredential,
        email: String,
        retirementAtProfileStart: Store.RetirementSnapshot,
        clock: () -> Date
    ) throws {
        guard observed.accessToken == activeCredential?.accessToken,
              observed.service == activeCredential?.service
        else { return }
        if retirementAtProfileStart.emails.contains(email) {
            if let error = store.reactivateVerifiedAccount(email, from: retirementAtProfileStart) {
                throw ClaudeFetchFailure(email: email, message: error)
            }
        }
        guard !store.retiredEmails.contains(email) else {
            throw ClaudeFetchFailure(
                email: email,
                message: "Claude login changed while Tower was verifying it. Run /login in Claude Code, then refresh Tower.")
        }
        guard vault.isRetentionEnabled() else { return }
        let ticket = try observation.get()
        if let error = vault.captureVerifiedLogin(
            observed, email: email, observation: ticket, now: clock()) {
            throw ClaudeSeatVaultError(error)
        }
    }

    private static func rosterCredentials(
        vault: ClaudeSeatVault,
        active: ClaudeCredential?,
        store: Store
    ) -> Result<ClaudeSeatRoster, ClaudeSeatVaultError> {
        let retired = store.retiredEmails
        return vault.rosterResult(active: active).map { roster in
            ClaudeSeatRoster(
                credentials: roster.credentials.filter { credential in
                    !credential.service.hasPrefix(ClaudeSeatVault.ownedServicePrefix)
                        || !retired.contains(credential.emailHint ?? "")
                },
                unreadable: roster.unreadable.filter { !retired.contains($0.account) })
        }
    }

    private static func retentionReadFailure(
        store: Store,
        error: ClaudeSeatVaultError
    ) -> ClaudeRosterResult {
        ClaudeRosterResult(
            accounts: store.load(),
            verifiedActiveEmail: nil,
            attemptedServices: [],
            failedEmails: [],
            failureText: error.localizedDescription,
            saveError: nil)
    }

    /// Production entry point. The callback runs after `/api/oauth/profile` succeeds and
    /// before usage is requested, so a verified login survives a later usage failure.
    private static func fetchClaude(
        _ credential: ClaudeCredential,
        onVerified: @escaping (ClaudeCredential, String) throws -> Void = { _, _ in }
    ) async throws -> ClaudeFetch {
        try await fetchClaude(
            credential, profile: UsageAPI.email, usage: UsageAPI.usage,
            onVerified: onVerified, clock: { Date() })
    }

    /// Injectable identity-then-usage sequence. A 401 thrown here as
    /// ClaudeCredentialExpired makes that seat read needs login.
    static func fetchClaude(
        _ credential: ClaudeCredential,
        profile: @escaping (String) async throws -> String?,
        usage: @escaping (String) async throws -> UsageResponse,
        onVerified: @escaping (ClaudeCredential, String) throws -> Void,
        clock: @escaping () -> Date
    ) async throws -> ClaudeFetch {
        // Attribution is verified before usage is folded.  A cached or old local profile is
        // a useful hint for an expired token, never proof that an unexpired token belongs to
        // that account.
        guard !credential.isExpired(now: clock()) else { throw ClaudeCredentialExpired() }
        // Every thrown message names its step: the refresh banner prints the
        // first failure verbatim, and "HTTP 500" alone cannot say whether the
        // profile read or the usage read failed.
        let resolvedEmail: String?
        do {
            resolvedEmail = try await profile(credential.accessToken)
        } catch {
            if isUnauthorized(error) { throw ClaudeCredentialExpired() }
            // No verified identity exists here: the hint is ~/.claude.json reread and
            // must never promote into the roster's verifiedActiveEmail.
            throw ClaudeFetchFailure(email: nil,
                                   message: "profile fetch: \(error.localizedDescription)")
        }
        guard let email = resolvedEmail, !email.isEmpty else {
            throw ClaudeFetchFailure(email: nil,
                                     message: "profile fetch: could not verify Claude account identity")
        }
        guard !credential.isExpired(now: clock()) else { throw ClaudeCredentialExpired() }
        if credential.service.hasPrefix(ClaudeSeatVault.ownedServicePrefix),
           credential.emailHint != email {
            throw NSError(domain: "ClaudeRoster", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "retained Claude seat identity did not match its verified profile"
            ])
        }
        do {
            try onVerified(credential, email)
        } catch {
            throw ClaudeFetchFailure(email: email, message: error.localizedDescription)
        }
        do {
            return ClaudeFetch(email: email, usage: try await usage(credential.accessToken))
        } catch {
            if isUnauthorized(error) { throw ClaudeCredentialExpired() }
            // The profile succeeded, so preserve that attribution if usage itself fails.
            throw ClaudeFetchFailure(email: email,
                                     message: "usage fetch: \(error.localizedDescription)")
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "UsageAPI" && nsError.code == 401
    }

    /// Fetches the active account and reconciles the full roster in one Store mutation.
    /// Inactive account tokens do not survive /login in the CLI's Keychain item, but the
    /// retained copy of its access token does, until that token expires; then the seat
    /// reads needs login until it signs into Claude Code again.
    @discardableResult
    static func refreshActive() async -> RefreshResult {
        // Independent of the Claude credential entirely: Cursor has its own identity and its
        // own endpoint, so it must still be read on a machine with no Claude Code login at
        // all. Started before the guard for exactly that reason.
        async let cursorProbe = CursorUsage.fetch()
        async let openRouterProbe = OpenRouter.fetch()
        // A subprocess round trip of a second or two; blocking, so off the cooperative pool.
        async let codexProbe = Task.detached(priority: .utility) { CodexLive.fetch() }.value
        // File reads plus one bounded `muse usage --json` (8 s cap), off the main actor.
        async let laneProbe = Task.detached(priority: .utility) {
            AgentLane.readAll(museRunner: AgentLane.runMuseUsage)
        }.value
        let cursor = await cursorProbe
        let openRouter = await openRouterProbe
        let codex = await codexProbe
        let lanes = await laneProbe

        let keychainCallsAtStart = KeychainCallCounter.shared.total
        defer { KeychainCallCounter.shared.logCycle("refresh", startTotal: keychainCallsAtStart) }
        let vault = ClaudeSeatVault.shared
        let retired = Store.shared.retiredEmails
        let retirementError = vault.forgetRetired(retired)
        let activeCredential = Keychain.activeOAuth()
        let loginObservation = vault.beginObservationResult()
        let retirementAtProfileStart = Store.shared.retirementSnapshot()
        let credentials: [ClaudeCredential]
        let observation: ClaudeRosterObservation?
        let retentionReadError: String?
        switch rosterCredentials(vault: vault, active: activeCredential, store: Store.shared) {
        case .success(let roster):
            credentials = roster.credentials
            retentionReadError = nil
            observation = await ClaudeRoster.collect(
                credentials: credentials,
                fetch: { credential in
                    try await fetchClaude(credential, onVerified: { observed, email in
                        try verifiedLoginCapture(
                            activeCredential: activeCredential,
                            store: Store.shared,
                            vault: vault,
                            observation: loginObservation,
                            observed: observed,
                            email: email,
                            retirementAtProfileStart: retirementAtProfileStart,
                            clock: { Date() })
                    })
                },
                now: Date(),
                unreadableSeats: roster.unreadable)
        case .failure(let error):
            credentials = []
            observation = nil
            retentionReadError = error.localizedDescription
        }

        var cursorKey: String?
        let (accounts, saveError) = Store.shared.mutate { accounts in
            cursorKey = seed(into: &accounts, store: Store.shared,
                             cursor: cursor, openRouter: openRouter, codex: codex,
                             lanes: lanes)
            if let observation {
                let filtered = observation.excluding(retiredEmails: Store.shared.retiredEmails)
                ClaudeRoster.apply(
                    filtered,
                    to: &accounts,
                    now: Date())
                ClaudeModelSetting.stamp(&accounts, activeEmail: filtered.verifiedActiveEmail)
                if let verified = filtered.verifiedActiveEmail,
                   let live = filtered.successes.first(where: {
                       $0.credential.service == Keychain.defaultService
                   }) {
                    Store.shared.recordVerifiedActiveSeatUnlocked(
                        verified, token: live.credential.accessToken, now: Date())
                }
            }
        }

        let activeRosterCredential = credentials.first { $0.service == Keychain.defaultService }
        let activeSuccess = observation?.successes.first {
            $0.credential.service == Keychain.defaultService
        }
        let activeFailure = observation?.failures.first {
            $0.credential.service == Keychain.defaultService
        }
        let outcome: RefreshOutcome
        if let saveError {
            outcome = .failed(saveError)
        } else if let retirementError {
            outcome = .failed(retirementError)
        } else if let retentionReadError {
            outcome = .failed(retentionReadError)
        } else if let activeSuccess {
            outcome = .ok(email: activeSuccess.fetch.email)
        } else if activeRosterCredential == nil {
            outcome = .noCredential(detail: Keychain.noCredentialDetail(Keychain.lastActiveScan))
        } else if activeRosterCredential!.isExpired(now: Date()) {
            outcome = .failed("needs login")
        } else {
            outcome = .failed(activeFailure?.message ?? "could not resolve the active account")
        }
        return RefreshResult(
            accounts: accounts, activeEmail: observation?.verifiedActiveEmail,
            outcome: outcome,
            openRouterOutcome: openRouter,
            openRouterFoldCommitted: Self.openRouterFoldCommitted(
                outcome: openRouter, saveError: saveError),
            cursorKey: cursorKey,
            lanes: lanes)
    }

    /// This is deliberately independent from the Claude refresh outcome: a Claude API
    /// failure does not invalidate an OpenRouter balance that this store mutation saved.
    static func openRouterFoldCommitted(
        outcome: OpenRouter.Outcome, saveError: String?
    ) -> Bool {
        guard case .ok = outcome else { return false }
        return saveError == nil
    }

    /// The history point must use the timestamp persisted with this exact successful
    /// balance observation, not the later UI time after unrelated probes have completed.
    static func openRouterObservation(
        outcome: OpenRouter.Outcome, accounts: [String: AccountSnapshot], foldCommitted: Bool
    ) -> (budget: OpenRouter.Budget, capturedAt: Date)? {
        guard foldCommitted, case .ok(let budget) = outcome else { return nil }
        let key = AccountSnapshot.storeKey(email: OpenRouter.storeEmail, provider: .openrouter)
        guard let capturedAt = accounts[key]?.capturedAt else { return nil }
        return (budget, capturedAt)
    }

    /// Pure, so the failure paths are testable without a network.
    /// A lost save counts as a failed refresh: the numbers on screen did not persist.
    static func outcome(email: String?, gotUsage: Bool, failure: String?, saveError: String?)
        -> RefreshOutcome {
        if let saveError { return .failed(saveError) }
        if let failure { return .failed(failure) }
        guard let email, gotUsage else {
            return .failed("could not resolve the active account")
        }
        return .ok(email: email)
    }
}

// MARK: - Threshold alerts

struct Alert {
    let nickname: String
    let window: String
    let pct: Double
    let resetsAt: Date?
}

enum Thresholds {
    /// Announce once per window as each level is first crossed.
    static let levels: [Double] = [80, 95, 100]

    /// Bookkeeping keys are quantised to the minute.
    ///
    /// `resets_at` comes back with sub-second jitter, and truncating to a whole second
    /// minted a BRAND NEW key whenever that jitter crossed an integer boundary, which
    /// re-armed every threshold for a window that had already announced. Observed in a real
    /// store, shown here with invented times: `7d@1800000059: 95` and `7d@1800000060: 95`
    /// side by side, one second apart, for a window that resets WEEKLY. The 95% alert fired
    /// twice.
    private static let keyQuantum: TimeInterval = 60

    static func key(_ window: String, _ resetsAt: Date?) -> String {
        let epoch = resetsAt?.timeIntervalSince1970 ?? 0
        return "\(window)@\(Int((epoch / keyQuantum).rounded()))"
    }

    /// Reverses `key`'s quantisation so the pruner can compare real dates. Returns nil for
    /// anything unparseable, and for pre-quantisation keys: those held raw seconds, which
    /// read back as the year 58000 and would otherwise never be pruned.
    static func expiry(ofKey k: String, now: Date = Date()) -> Date? {
        guard let tail = k.split(separator: "@").last, let q = Double(tail) else { return nil }
        let d = Date(timeIntervalSince1970: q * keyQuantum)
        guard d < now.addingTimeInterval(400 * 86_400) else { return nil }
        return d
    }

    /// One-time migration off the raw-seconds key format.
    ///
    /// Without it, the first evaluate after upgrading finds no record for a window that had
    /// already announced, and re-fires every threshold: one duplicate notification per
    /// account. Keys that collide once quantised keep the highest level already announced,
    /// so a migrated window stays silent rather than replaying 80 then 95 then 100.
    static func migrated(_ notified: [String: Double], now: Date = Date()) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, level) in notified {
            guard let at = k.firstIndex(of: "@"),
                  let raw = Double(k[k.index(after: at)...]) else { continue }
            let window = String(k[k.startIndex..<at])
            // A raw-seconds value read as seconds lands near today. A already-quantised one
            // read the same way lands in 1970, which is how the two formats are told apart.
            let asSeconds = Date(timeIntervalSince1970: raw)
            let isLegacy = abs(asSeconds.timeIntervalSince(now)) < 400 * 86_400
            let newKey = isLegacy ? key(window, asSeconds) : k
            out[newKey] = max(out[newKey] ?? 0, level)
        }
        return out
    }

    /// Pure: mutates only the snapshot's bookkeeping and returns what should be announced.
    /// Kept free of UserNotifications so the `status` CLI never touches the GUI stack.
    static func evaluate(_ snap: inout AccountSnapshot, now: Date = Date()) -> [Alert] {
        var out: [Alert] = []
        snap.notified = migrated(snap.notified, now: now)

        func check(_ window: String, _ pct: Double?, _ resetsAt: Date?) {
            guard let pct else { return }
            // No reset time means no window identity to key the bookkeeping on. `key` would
            // map it to "<window>@0" and the pruner below deletes that on the same call that
            // wrote it, so every poll re-announced the same threshold. At a 300s timer plus
            // one per menu open, that is a notification firehose. Staying silent is the only
            // safe answer, and `resets_at` is Optional in the wire model so this is reachable.
            guard let resetsAt else { return }
            // A window whose reset has passed is empty, not full.
            if now >= resetsAt { return }
            let k = key(window, resetsAt)
            let already = snap.notified[k] ?? 0
            guard let hit = levels.last(where: { pct >= $0 }), hit > already else { return }
            snap.notified[k] = hit
            out.append(Alert(nickname: snap.nickname, window: window, pct: pct, resetsAt: resetsAt))
        }

        check("5h", snap.fiveHourPct, snap.fiveHourResetsAt)
        // Named per provider. The reading lives in `weeklyPct` for every provider, but the
        // alert text is read by a human: "Cursor at 95% of 7d" would promise relief in a
        // week when the credits actually refill on the invoice boundary.
        check(snap.kind.primaryWindowLabel, snap.weeklyPct, snap.weeklyResetsAt)

        // Drop bookkeeping for windows that have already reset, so the dict stays small.
        // `expiry` also discards pre-quantisation keys, which is the migration path off the
        // old raw-seconds format.
        snap.notified = snap.notified.filter { k, _ in
            guard let d = expiry(ofKey: k, now: now) else { return false }
            return d > now
        }
        return out
    }
}

// MARK: - Rail crossings

/// One rail crossing worth announcing: an account rose onto a mark. The wording is the
/// shape the issue pins, "account A at 83 %: no new stations on A, rotation brief due at
/// 90 %", split across a title and a body for the two notification lines.
struct RailCrossing: Equatable {
    let nickname: String
    let level: Rail.Level
    let pct: Double

    /// "account A at 83 %"
    var toastTitle: String {
        "account \(nickname) at \(Int(pct.rounded())) %"
    }

    /// "no new stations on A, rotation brief due at 90 %": the amber toast names the red
    /// mark the rotation brief is due by. On red that mark is behind the account, so the
    /// brief is simply due.
    var toastBody: String {
        switch level {
        case .amber:
            return "no new stations on \(nickname), rotation brief due at \(Int(Rail.redMark)) %"
        case .red:
            return "no new stations on \(nickname), rotation brief due"
        case .none:
            return ""
        }
    }
}

/// The quota rail: amber and red marks on the row's two meters (80 and 90 percent of
/// the 5h meter, 90 percent of the 7d meter), one toast when an account crosses up onto
/// a mark, and the standing crossing written to the mirror as the account's `crossing`
/// field so a lane launcher can refuse an open above amber without scraping
/// the UI.
///
/// The machine is per ACCOUNT and its state is that field. A stored percentage only
/// moves when it is captured or its window resets, so a rising transition always means
/// a fresh reading crossed the mark: two accounts crossing produce two toasts, and one
/// account ticking ten times inside one band produces one. Falling is silent and only
/// rewrites the field, because a toast and a flag both mean "standing above the mark",
/// and both end when a capture or a reset observes that it no longer is. Reset
/// awareness comes from `effective`, the same arithmetic every consumer of the mirror
/// applies.
enum Rail {
    static let amberMark: Double = 80
    static let redMark: Double = 90

    /// Ordered low to high so a rising transition reads as `<`. `label` is the exact
    /// string stored in the mirror's `crossing` field; none stores an absent field.
    enum Level: Int, Comparable {
        case none = 0
        case amber = 1
        case red = 2

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String? {
            switch self {
            case .none: return nil
            case .amber: return "amber"
            case .red: return "red"
            }
        }

        /// The field is written only by `evaluate`, so anything unreadable here degrades
        /// to none: the next evaluate rewrites it, and a one-time spurious toast beats a
        /// permanently stuck flag.
        init(field: String?) {
            self = field == Self.amber.label ? .amber
                : field == Self.red.label ? .red : .none
        }
    }

    /// A mark drawn on a meter: the level, and where it sits as a fraction of the rail.
    struct Mark: Equatable, Identifiable {
        let level: Level
        var position: Double { level == .amber ? amberMark / 100 : redMark / 100 }
        var id: Double { position }
    }

    /// Marks for one meter. The 5h rail carries both marks; the 7d rail is red only, so
    /// a week in the amber band alone crosses nothing.
    static func marks(fiveHour: Bool) -> [Mark] {
        fiveHour ? [Mark(level: .amber), Mark(level: .red)] : [Mark(level: .red)]
    }

    /// Worst standing band across the two railed windows, from stored numbers. The 7d
    /// meter carries no amber mark, so only the 5h reading can produce one.
    static func level(fiveHour: Double?, weekly: Double?) -> Level {
        if (fiveHour ?? -1) >= redMark || (weekly ?? -1) >= redMark { return .red }
        if (fiveHour ?? -1) >= amberMark { return .amber }
        return .none
    }

    /// Pure: mutates only the snapshot's crossing field and returns the crossing to
    /// announce, if this call observed the account rise onto a mark. Kept free of
    /// UserNotifications so the `status` CLI never touches the GUI stack.
    ///
    /// A rise is announced only when the reading that justifies it is live: a stale row
    /// advancing its own stored band on the first pass after an update writes the flag
    /// silently rather than presenting an old number as a fresh crossing. The percentage
    /// quoted is the live reading behind the level, so the toast and the mark agree.
    static func evaluate(_ snap: inout AccountSnapshot, now: Date = Date()) -> RailCrossing? {
        let fh = AccountSnapshot.effective(
            pct: snap.fiveHourPct, resetsAt: snap.fiveHourResetsAt, now: now).pct
        let wk = AccountSnapshot.effective(
            pct: snap.weeklyPct, resetsAt: snap.weeklyResetsAt, now: now).pct
        let current = level(fiveHour: fh, weekly: wk)
        let previous = Level(field: snap.crossing)
        snap.crossing = current.label
        guard current > previous else { return nil }
        let pct: Double?
        switch current {
        case .none:
            pct = nil
        case .amber:
            pct = snap.trustFiveHour(now: now) == .live ? fh : nil
        case .red:
            var readings: [Double] = []
            if let v = fh, v >= redMark, snap.trustFiveHour(now: now) == .live {
                readings.append(v)
            }
            if let v = wk, v >= redMark, snap.trustWeekly(now: now) == .live {
                readings.append(v)
            }
            pct = readings.max()
        }
        guard let pct else { return nil }
        return RailCrossing(nickname: snap.nickname, level: current, pct: pct)
    }
}
