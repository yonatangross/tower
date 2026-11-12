import Foundation

/// Turns "a session left the `claude agents` list" into one ledger line (see LaneCost).
/// It reads only local files: the session's own transcript, Tower's quota samples, and the
/// other transcripts of the same account for the calculated share. Nothing leaves the Mac.
enum LaneCostRecorder {
    struct Environment {
        var home: URL
        /// Tower's own support directory (`~/Library/Application Support/Tower`).
        var supportDir: URL
        var now: Date
        /// nil means the policy could not be read: nothing is read or written (fail closed).
        var privateLanes: PrivateLanes?
        /// Where the policy was looked for, named in the note left when it is missing.
        var policyPath: String = "~/.floor/private-lanes.json"
    }

    /// How Claude Code names a project folder: the cwd with `/` and `.` turned into `-`.
    static func projectFolder(cwd: String) -> String {
        String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    private static func projectsRoot(config: String?, home: URL) -> URL {
        (config.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude", isDirectory: true))
            .appendingPathComponent("projects", isDirectory: true)
    }

    private static func transcripts(home: URL, config: String? = nil, privateLanes: PrivateLanes) -> [URL] {
        let root = projectsRoot(config: config, home: home)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { !privateLanes.isPrivate(projectFolder: $0.lastPathComponent) }.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
    }

    /// The session's transcript: the cwd-derived folder first, then a scan of every project
    /// folder for the session id. nil when neither has it.
    static func transcriptURL(live: LaneCost.Live, home: URL, privateLanes: PrivateLanes) -> URL? {
        guard let id = live.sessionId, !privateLanes.isPrivate(cwd: live.cwd) else { return nil }
        let root = projectsRoot(config: live.configDir, home: home)
        if let cwd = live.cwd {
            let direct = root.appendingPathComponent(projectFolder(cwd: cwd), isDirectory: true)
                .appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        return transcripts(home: home, config: live.configDir, privateLanes: privateLanes).first { $0.lastPathComponent == "\(id).jsonl" }
    }

    /// The meter samples Tower keeps per account (`pace.json`: email to a list of
    /// `{at (epoch seconds), weekly, fiveHour}`). A missing file, a missing account or an
    /// unreadable entry reads as no samples, never as zeros.
    static func paceSamples(supportDir: URL, email: String?) -> [LaneCost.PaceSample] {
        guard let email,
              let data = try? Data(contentsOf: supportDir.appendingPathComponent("pace.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root[email] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let at = (row["at"] as? NSNumber)?.doubleValue else { return nil }
            return LaneCost.PaceSample(at: Date(timeIntervalSince1970: at),
                                       weekly: (row["weekly"] as? NSNumber)?.doubleValue,
                                       fiveHour: (row["fiveHour"] as? NSNumber)?.doubleValue)
        }.sorted { $0.at < $1.at }
    }

    /// The account's output tokens inside a window, from every transcript of that account
    /// that was touched since the window opened. nil without an account id.
    static func accountOutput(uuid: String?, from: Date, to: Date, home: URL, privateLanes: PrivateLanes) -> Int? {
        guard let uuid else { return nil }
        var total = 0
        for url in transcripts(home: home, privateLanes: privateLanes) {
            let touched = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let touched, touched < from { continue }
            let s = LaneCost.summarize(url: url)
            guard s.accountUuid == uuid else { continue }
            total += s.messages.filter { $0.at >= from && $0.at <= to }.reduce(0) { $0 + $1.output }
        }
        return total
    }

    /// Writes one record per interactive session that left the list, except private lanes (see
    /// PrivateLanes); an unreadable policy (nil) writes nothing. When four or more
    /// sessions were listed and over half vanish at once, that is a failed probe (an empty
    /// `claude agents` answer), not that many closes: nothing is written. A session whose
    /// newest transcript stamp is already in the ledger is not written again.
    @discardableResult
    static func recordClosed(previous: [LaneCost.Live], current: [LaneCost.Live], env: Environment) -> [LaneCost.Record] {
        guard let policy = env.privateLanes else { return [] }
        let all = LaneCost.closed(previous: previous, current: current)
        let before = previous.filter(\.interactive).count
        if before >= 4, all.count * 2 > before { return [] }
        // A private lane is never read and never recorded; its transcript is not opened.
        let gone = all.filter { !policy.isPrivate(cwd: $0.cwd) }
        let url = LaneCost.ledgerURL(now: env.now, home: env.home)
        let existing = Dictionary(LaneCost.latest(in: url).map { ($0.session, $0) }, uniquingKeysWith: { _, b in b })
        var written: [LaneCost.Record] = []
        for live in gone {
            guard let id = live.sessionId else { continue }
            let summary = transcriptURL(live: live, home: env.home, privateLanes: policy).map(LaneCost.summarize(url:)) ?? LaneCost.TranscriptSummary()
            if let old = existing[id], old.end == summary.last.map(LaneCost.stampString) { continue }
            let total = summary.first.flatMap { f in summary.last.map { l in (f, l) } }
                .flatMap { accountOutput(uuid: summary.accountUuid, from: $0.0, to: $0.1, home: env.home, privateLanes: policy) }
            let record = LaneCost.makeRecord(
                live: live, summary: summary,
                samples: paceSamples(supportDir: env.supportDir, email: live.accountEmail),
                accountOutputInWindow: total, now: env.now)
            if (try? LaneCost.append(record, to: url)) != nil { written.append(record) }
        }
        return written
    }
}
