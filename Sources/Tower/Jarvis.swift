import Foundation
import Darwin

// MARK: - Running Claude Code sessions

/// Account identity comes from a session's own transcript, never an active-login fallback.
struct AgentInfo: Decodable, Identifiable, Hashable {
    let kind: String?
    let status: String?
    let cwd: String?
    var sessionId: String? = nil
    /// The name the session chose for itself (`/rename`), which is what the operator
    /// sees in the session list. nil for an unnamed session.
    var name: String? = nil
    var pid: Int? = nil
    /// Whatever `claude agents` emits; kept raw because its shape has changed before.
    var startedAt: String? = nil
    var accountEmail: String? = nil
    /// Whether Tower matched the session's current transcript reset or only its older
    /// bridge ownership record. The former is an inference, never a credential read.
    var accountEvidence: String? = nil
    /// Optional process metadata from `claude agents`. When present, it scopes transcript
    /// and saved-identity reads to that session's configuration root.
    var configDir: String? = nil

    private enum CodingKeys: String, CodingKey {
        case kind, status, cwd, sessionId, name, pid, startedAt, configDir
    }

    init(kind: String? = nil, status: String? = nil, cwd: String? = nil,
         sessionId: String? = nil, name: String? = nil, pid: Int? = nil,
         startedAt: String? = nil, accountEmail: String? = nil, accountEvidence: String? = nil,
         configDir: String? = nil) {
        self.kind = kind
        self.status = status
        self.cwd = cwd
        self.sessionId = sessionId
        self.name = name
        self.pid = pid
        self.startedAt = startedAt
        self.accountEmail = accountEmail
        self.accountEvidence = accountEvidence
        self.configDir = configDir
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        accountEmail = nil
        accountEvidence = nil
        configDir = try c.decodeIfPresent(String.self, forKey: .configDir)
        // pid and startedAt have appeared as numbers and as strings; a wrong guess
        // must cost this field, not the row.
        if let i = try? c.decodeIfPresent(Int.self, forKey: .pid) { pid = i }
        else if let d = try? c.decodeIfPresent(Double.self, forKey: .pid) { pid = Int(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: .startedAt) { startedAt = s }
        else if let d = try? c.decodeIfPresent(Double.self, forKey: .startedAt) { startedAt = String(d) }
    }

    /// The name worth grouping on, or nil when the session never chose one.
    var sessionName: String? {
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// The lane the operator knows this session by, derived from the raw name. The raw
    /// name stays in `sessionName` for tooltips and the MCP `name` field.
    var displayName: String? { SessionLabel.derive(name: sessionName, cwd: cwd) }

    var id: String { sessionId ?? "\(kind ?? "?")|\(status ?? "?")|\(cwd ?? "?")" }
    var repoName: String {
        guard let cwd, !cwd.isEmpty else { return "?" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
    var isInteractive: Bool { kind == "interactive" }
    var isBusy: Bool { status == "busy" }
}

/// What the popover shows: interactive sessions ranked busy-first, plus a count
/// of everything else. Backgrounds dominate the raw list (18 rows with 5 real
/// sessions was typical) and would drown the signal if listed individually.
struct AgentSummary: Equatable {
    var interactive: [AgentInfo] = []
    var backgroundCount = 0
    /// Whether the statusline publishes per-session reset anchors
    /// (`<config>/session-anchors`, scripts/install-statusline-anchor.sh). Without them no
    /// session on Claude Code 2.1.283 or later can be attributed. nil when not checked.
    var anchorsPublished: Bool? = nil

    static func == (a: AgentSummary, b: AgentSummary) -> Bool {
        a.interactive == b.interactive && a.backgroundCount == b.backgroundCount
            && a.anchorsPublished == b.anchorsPublished
    }

    /// "dee 9 · ben 4", sessions per resolved account, most first, with any unresolved
    /// ones counted as "? N". nil when nothing resolved: `unattributedReason` speaks then.
    var accountTally: String? {
        var counts: [String: Int] = [:]
        var unknown = 0
        for session in interactive {
            if let email = session.accountEmail { counts[Nickname.derive(from: email), default: 0] += 1 }
            else { unknown += 1 }
        }
        guard !counts.isEmpty else { return nil }
        var parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
        if unknown > 0 { parts.append("? \(unknown)") }
        return parts.joined(separator: " · ")
    }

    static let anchorInstallCommand = "scripts/install-statusline-anchor.sh --apply"

    /// One line for the whole list when no session could be attributed, instead of an
    /// "account unknown" cell on every row (bug a, 2026-09-30: 13 of 13 rows said it while
    /// the floor ran on known seats). It names why, and the fix when there is one.
    var unattributedReason: String? {
        guard !interactive.isEmpty, interactive.allSatisfy({ $0.accountEmail == nil }) else { return nil }
        if anchorsPublished == false {
            return "accounts unknown: the statusline does not publish session anchors · run "
                + Self.anchorInstallCommand
        }
        return "accounts unknown: no session's reset matches a remembered seat"
    }

    /// One display row per session ID and independently resolved account.
    ///
    /// `claude agents` reports a stable `sessionId` per process and the name the
    /// session chose with /rename. Grouping on the name would merge two different
    /// sessions that happen to share it, so the group key is the session id; the
    /// lane derived from the name (`SessionLabel`) is the label, which is what the
    /// operator recognises. A row without a
    /// session id falls back to name, then directory, and same-directory rows
    /// still collapse to a count. Same-named directories in DIFFERENT paths
    /// (worktrees, the normal case here) gain their parent directory.
    var groups: [SessionGroup] {
        var byKey: [SessionGroup.ID: [AgentInfo]] = [:]
        var order: [SessionGroup.ID] = []
        for s in interactive {
            let key = SessionGroup.ID(key: s.sessionId ?? s.sessionName ?? s.cwd ?? "?",
                                      accountEmail: s.accountEmail)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(s)
        }
        // A directory name shared by different paths cannot stand alone as a label;
        // two accounts in the SAME directory stay plain, the account label splits them.
        var baseLabel: [SessionGroup.ID: String] = [:]
        var pathsByLabel: [String: Set<String>] = [:]
        for key in order {
            let first = byKey[key]!.first!
            let label = first.displayName ?? first.repoName
            baseLabel[key] = label
            if first.displayName == nil { pathsByLabel[label, default: []].insert(first.cwd ?? "?") }
        }
        return order.map { key in
            let rows = byKey[key]!
            var label = baseLabel[key]!
            if pathsByLabel[label, default: []].count > 1,
               let cwd = rows.first?.cwd, !cwd.isEmpty {
                let parent = URL(fileURLWithPath: cwd).deletingLastPathComponent()
                    .lastPathComponent
                if !parent.isEmpty, parent != "/" { label = "\(parent)/\(label)" }
            }
            return SessionGroup(id: key, label: label, count: rows.count,
                                busy: rows.contains { $0.isBusy },
                                sessionName: rows.first?.sessionName, cwd: rows.first?.cwd,
                                accountEvidence: rows.first?.accountEvidence)
        }
    }
}

struct SessionGroup: Identifiable, Equatable {
    struct ID: Hashable {
        /// The session id when `claude agents` reports one, else the name, else the directory.
        let key: String
        let accountEmail: String?
    }
    let id: ID
    let label: String
    let count: Int
    let busy: Bool
    /// The name the group is keyed on, nil for a directory group.
    var sessionName: String? = nil
    /// The first member's directory; informational, never the group key for a named session.
    var cwd: String? = nil
    var accountEvidence: String? = nil
    var accountEmail: String? { id.accountEmail }
    /// A session has no independently measured quota. Unknown never carries a number.
    var accountLabel: String { accountEmail.map(Nickname.derive) ?? "account unknown" }
    /// "×2" only when it means something.
    var suffix: String { count > 1 ? " ×\(count)" : "" }
    /// The full raw name behind a cleaned label, for a tooltip.
    var rawName: String { sessionName ?? cwd ?? label }
}

/// House convention (hq-ext floor, session-identity.md section 3): a session is named by
/// its lane slug, with no prefix, no emoji and no branch. Raw names on the floor mix
/// that with two hook titles, `<repo> · <branch>` and `<branch> · wt`, plus summaries
/// that carry a leading emoji and a trailing ` · <branch> ·`. This keeps the head, and
/// when the head is itself a branch it names the lane by the worktree directory instead.
enum SessionLabel {
    static func derive(name: String?, cwd: String?) -> String? {
        guard var text = name?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        while let first = text.first, isEmoji(first) || first.isWhitespace { text.removeFirst() }
        let parts = text.split(separator: "·", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let head = parts.first ?? ""
        let tail = parts.dropFirst().filter { !$0.isEmpty }
        // A lane slug never holds a slash; a branch usually does. `wt` marks the hook's
        // worktree title, whose head is the branch even when it has no slash.
        let isBranch = tail == ["wt"]
            || (head.contains("/") && !head.contains(where: { $0.isWhitespace }))
        if head.isEmpty || isBranch { return lane(fromCwd: cwd) ?? (head.isEmpty ? nil : head) }
        return head
    }

    /// The worktree directory under `.worktrees/`, else the directory itself.
    static func lane(fromCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let components = URL(fileURLWithPath: cwd).pathComponents
        if let marker = components.lastIndex(of: ".worktrees"), marker + 1 < components.count {
            return components[marker + 1]
        }
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }

    /// ASCII digits, `#` and `*` carry the emoji property too, so only non-ASCII counts.
    private static func isEmoji(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation
            || (scalar.properties.isEmoji && scalar.value > 0x7F)
    }
}

/// The global config can change while a session retains its original credential.
/// Join the session's own reset anchor (the statusline's per-session record, else the
/// transcript's latest quota reset) to Tower's retained Claude snapshots. A bridge
/// owner is only a fallback because it records where the session started, not necessarily
/// the account after /login. Neither path borrows Tower's active login.
struct SessionAccountResolver {
    let home: URL

    struct Resolution {
        let email: String
        let evidence: String
    }

    private enum QuotaObservation {
        case absent
        case reset(Int64, sevenDay: Bool)
        case unusable
    }

    func resolve(_ session: AgentInfo) -> Resolution? {
        guard let sessionID = session.sessionId, !sessionID.isEmpty,
              sessionID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else { return nil }
        let root: URL
        let config: URL
        if let directory = session.configDir {
            guard directory.hasPrefix("/") else { return nil }
            root = URL(fileURLWithPath: directory)
            config = root.appendingPathComponent(".claude.json")
        } else {
            root = home.appendingPathComponent(".claude")
            config = home.appendingPathComponent(".claude.json")
        }
        let cache = root.appendingPathComponent("quota-cache.json")
        // The statusline anchor is rewritten from this session's own payload on every
        // render, so it is the current account. Claude Code 2.1.283 transcripts carry no
        // quotaLimits record, which leaves the transcript path below as a fallback only.
        switch Self.anchorObservation(
            root.appendingPathComponent("session-anchors").appendingPathComponent(sessionID)) {
        case .anchor(let fiveHour, let sevenDay):
            guard let email = Self.email(forFiveHourReset: fiveHour, weeklyReset: sevenDay, cache: cache)
            else { return nil }
            return Resolution(email: email, evidence: "inferred from statusline reset")
        case .unusable:
            return nil
        case .absent:
            break
        }
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(
            at: root.appendingPathComponent("projects"), includingPropertiesForKeys: nil)) ?? []
        let transcripts = projects.map { $0.appendingPathComponent("\(sessionID).jsonl") }
            .filter { fm.fileExists(atPath: $0.path) }
        guard transcripts.count == 1 else { return nil }
        let transcript = transcripts[0]

        // Saved configs are identity mappings only, never a source of active-account state.
        let saved = (try? fm.contentsOfDirectory(
            at: root.appendingPathComponent("accounts"), includingPropertiesForKeys: nil)) ?? []
        let identityFiles = [config] + saved.filter({ $0.pathExtension == "json" })
        // A quota reset from the latest transcript record describes the session's
        // current account. A bridge owner instead describes where it started and can
        // be stale after /login, so use it only when the transcript has no reset record.
        switch Self.latestQuotaObservation(in: transcript) {
        case .reset(let reset, let sevenDay):
            let match = sevenDay ? Self.email(forFiveHourReset: nil, weeklyReset: reset, cache: cache)
                : Self.email(forFiveHourReset: reset, cache: cache)
            guard let email = match else { return nil }
            return Resolution(email: email, evidence: "inferred from transcript reset")
        case .unusable:
            return nil
        case .absent:
            break
        }
        if let owner = Self.ownerUUID(in: transcript),
           let email = Self.email(forOwner: owner, in: identityFiles) {
            return Resolution(email: email, evidence: "bridge owner")
        }
        return nil
    }

    private static func email(forOwner owner: String, in files: [URL]) -> String? {
        var emails = Set<String>()
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = object["oauthAccount"] as? [String: Any],
                  let uuid = oauth["accountUuid"] as? String, uuid.lowercased() == owner,
                  let rawEmail = oauth["emailAddress"] as? String,
                  let email = validEmail(rawEmail) else { continue }
            emails.insert(email)
        }
        return emails.count == 1 ? emails.first : nil
    }

    /// A reset anchor belongs to the session that observed it. The cache only supplies
    /// the account name for that anchor. A reset shared by two rows cannot identify
    /// either one, so it remains unknown. The weekly reset, when both sides have one,
    /// is the statusline's second discriminator and narrows the same way here. A
    /// seven_day transcript record has only the weekly reset, which alone must match.
    private static func email(forFiveHourReset reset: Int64?, weeklyReset: Int64? = nil,
                              cache: URL) -> String? {
        guard reset != nil || weeklyReset != nil else { return nil }
        guard let data = try? Data(contentsOf: cache),
              let snapshots = try? JSONDecoder().decode([String: AccountSnapshot].self, from: data)
        else { return nil }
        func near(_ date: Date?, _ anchor: Int64) -> Bool {
            guard let date else { return false }
            return abs(Int64(date.timeIntervalSince1970.rounded()) - anchor) <= 90
        }
        let emails = Set(snapshots.values.compactMap { snapshot -> String? in
            guard snapshot.kind == .claude else { return nil }
            if let reset, !near(snapshot.fiveHourResetsAt, reset) { return nil }
            if let weeklyReset {
                if reset == nil, !near(snapshot.weeklyResetsAt, weeklyReset) { return nil }
                if snapshot.weeklyResetsAt != nil, !near(snapshot.weeklyResetsAt, weeklyReset) { return nil }
            }
            return validEmail(snapshot.email)
        })
        return emails.count == 1 ? emails.first : nil
    }

    private enum AnchorObservation {
        case absent
        case anchor(fiveHour: Int64, sevenDay: Int64?)
        case unusable
    }

    /// `<config>/session-anchors/<session id>` holds `r5|r7|epoch`, epoch seconds from
    /// the statusline payload's `rate_limits` (scripts/statusline-session-anchor.patch).
    /// A present but unreadable record is uncertainty and never falls back to an
    /// older source, the same rule as an unusable transcript quota record.
    private static func anchorObservation(_ url: URL) -> AnchorObservation {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), data.count <= 256,
              let text = String(data: data, encoding: .utf8) else { return .unusable }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, let fiveHour = Int64(fields[0]), fiveHour > 0 else { return .unusable }
        if fields[1].isEmpty { return .anchor(fiveHour: fiveHour, sevenDay: nil) }
        guard let sevenDay = Int64(fields[1]), sevenDay > 0 else { return .unusable }
        return .anchor(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func validEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.split(separator: "@", omittingEmptySubsequences: false).count == 2,
              !email.hasPrefix("@"), !email.hasSuffix("@"),
              !email.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return email
    }

    /// Stream JSONL so ordinary large transcripts do not accumulate in memory.
    /// Conflicting or incomplete ownership records are uncertainty, never a guess.
    private static func ownerUUID(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var pending = Data()
        var owners = Set<String>()
        func consume(_ line: Data) -> Bool {
            guard line.range(of: Data("\"bridge-session\"".utf8)) != nil else { return true }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { return false }
            guard object["type"] as? String == "bridge-session" else { return true }
            guard let owner = object["ownerAccountUuid"] as? String, !owner.isEmpty else { return false }
            owners.insert(owner.lowercased())
            return owners.count == 1
        }
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    guard consume(Data(pending[..<end])) else { return nil }
                    pending.removeSubrange(...end)
                }
                // Treat an oversized single record as unmeasured, keeping memory bounded.
                guard pending.count <= 1024 * 1024 else { return nil }
            }
        } catch { return nil }
        guard consume(pending), owners.count == 1 else { return nil }
        return owners.first
    }

    /// Returns the final quota observation. A newer unusable record must not fall back to
    /// an earlier reset or bridge owner, because it may describe a just-switched login.
    /// Claude Code has emitted seconds and milliseconds across versions, so normalize here.
    /// Records carry `rateLimitType` (measured on 2.1.281: `seven_day` on a rejected
    /// request). A record without one is the older five hour shape; any other type
    /// names a window Tower does not track, so it is unusable rather than guessed.
    private static func latestQuotaObservation(in url: URL) -> QuotaObservation {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .absent }
        defer { try? handle.close() }
        var pending = Data()
        var latest = QuotaObservation.absent
        func consume(_ line: Data) -> Bool {
            guard line.range(of: Data("\"quotaLimits\"".utf8)) != nil else { return true }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let limits = object["quotaLimits"] as? [String: Any],
                  let raw = limits["resetsAt"] as? NSNumber
            else {
                latest = .unusable
                return true
            }
            let value = raw.int64Value
            guard value > 0 else {
                latest = .unusable
                return true
            }
            let sevenDay: Bool
            switch limits["rateLimitType"] {
            case nil: sevenDay = false
            case let type as String where type == "five_hour": sevenDay = false
            case let type as String where type == "seven_day": sevenDay = true
            default:
                latest = .unusable
                return true
            }
            latest = .reset(value > 100_000_000_000 ? value / 1_000 : value, sevenDay: sevenDay)
            return true
        }
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    guard consume(Data(pending[..<end])) else { return .unusable }
                    pending.removeSubrange(...end)
                }
                guard pending.count <= 1024 * 1024 else { return .unusable }
            }
        } catch { return .unusable }
        guard consume(pending) else { return .unusable }
        return latest
    }
}

enum AgentProbe {
    /// Fixture home is injectable; no subprocess, keychain or account API is needed.
    static func summarize(_ data: Data,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentSummary? {
        guard let rows = try? JSONDecoder().decode([AgentInfo].self, from: data) else {
            return nil
        }
        var out = AgentSummary()
        let resolver = SessionAccountResolver(home: home)
        out.interactive = rows.filter { $0.isInteractive }
            .map { row in
            var session = row
                let resolution = resolver.resolve(session)
                session.accountEmail = resolution?.email
                session.accountEvidence = resolution?.evidence
                return session
            }
            .sorted { a, b in
                if a.isBusy != b.isBusy { return a.isBusy }
                return a.repoName.localizedCaseInsensitiveCompare(b.repoName) == .orderedAscending
            }
        out.backgroundCount = rows.count - out.interactive.count
        out.anchorsPublished = anchorsPublished(for: out.interactive, home: home)
        return out
    }

    /// Whether any session's own config root holds `session-anchors`. The root is the one
    /// `SessionAccountResolver` reads: the session's `configDir`, else `~/.claude`. A
    /// session under CLAUDE_CONFIG_DIR has its anchors there, not in the home default
    /// (review of #126).
    static func anchorsPublished(for sessions: [AgentInfo], home: URL) -> Bool {
        var roots = Set(sessions.compactMap { session -> String? in
            guard let dir = session.configDir else { return nil }
            return dir.hasPrefix("/") ? dir : nil
        })
        if roots.isEmpty || sessions.contains(where: { $0.configDir == nil }) {
            roots.insert(home.appendingPathComponent(".claude").path)
        }
        return roots.contains { root in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: root).appendingPathComponent("session-anchors").path,
                isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// The interactive `claude` in a shell is a zsh FUNCTION; a Process must
    /// resolve the real binary itself. Checked locations first, PATH last.
    static func claudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude",
                          "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `claude agents --json` off the main actor. nil means the probe
    /// failed (no binary, timeout, bad JSON): the UI shows "unavailable", never
    /// a confidently empty list.
    static func fetch() async -> AgentSummary? {
        guard let bin = claudeBinary() else { return nil }
        return await Task.detached(priority: .utility) { () -> AgentSummary? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["agents", "--json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            // Bounded wait: a wedged CLI must not wedge the popover forever.
            let deadline = Date().addingTimeInterval(10)
            while p.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if p.isRunning {
                p.terminate()
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return summarize(data)
        }.value
    }
}
