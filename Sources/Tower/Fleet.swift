import Foundation
import Darwin

// MARK: - Blast radius of the active Claude login

/// Measured sessions on the active Claude seat and the unknown session count.
/// A startup bridge owner does not establish the account after a later login.
/// Background rows have no account evidence and remain unknown.
///
/// The level follows the live usage whenever any session may ride the seat, measured
/// or unknown. Unknown ownership must not silence the warning: on 2026-10-06 every live
/// session had an unknown owner, and all of them stop together when the seat is full.
struct BlastRadius: Equatable {
    /// Warn here, well before the 95 % cap, so a rotation lands while the fleet still runs.
    static let warnMark: Double = 85
    /// A full meter stops every rider.
    static let stopMark: Double = 100

    enum Level: String, Equatable, Comparable {
        /// Nothing rides the login, or room is ample.
        case clear
        /// At or above `warnMark`: rotate before the fleet stops.
        case warn
        /// At or above `stopMark`: every rider is refused.
        case stopped
        /// Sessions may ride the login but it has no live reading to judge. Unknown session
        /// ownership never sets this level; it is the separate `unknown` count.
        case unknown

        private var rank: Int {
            switch self {
            case .clear: return 0
            case .unknown: return 1
            case .warn: return 2
            case .stopped: return 3
            }
        }
        static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    /// A session to restart on another Claude seat before moving a busy one. The stable
    /// id makes duplicate names actionable and keeps the recommendation deterministic.
    struct MoveFirst: Equatable, Identifiable {
        let id: String
        let label: String
        let busy: Bool
        let accountKnown: Bool

        var displayLabel: String {
            let session = label == id ? label : "\(label) [\(id)]"
            return accountKnown ? session : "\(session) (account uncertain)"
        }
    }

    let nickname: String
    /// Interactive sessions with measured ownership on this login.
    let riders: Int
    let unknown: Int
    let interactive: Int
    /// The active login's binding usage from live windows only. nil when unknown.
    let percentUsed: Double?
    let level: Level
    /// Idle interactive sessions come first, then their visible label and stable id.
    /// Unknown interactive sessions remain explicitly uncertain candidates.
    let moveFirst: [MoveFirst]

    /// nil when there is no active Claude login or the session probe did not run: an
    /// unknown rider count must never read as "nothing at risk".
    static func evaluate(active: AccountSnapshot?, sessions: AgentSummary?,
                         now: Date = Date()) -> BlastRadius? {
        guard let active, active.kind == .claude, let sessions else { return nil }
        let activeEmail = active.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func measuredEmail(_ session: AgentInfo) -> String? {
            guard session.accountEvidence != "bridge owner",
                  let email = session.accountEmail?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty else { return nil }
            return email
        }
        let interactive = sessions.interactive.filter { measuredEmail($0) == activeEmail }.count
        let riders = interactive
        let unknown = sessions.interactive.filter { measuredEmail($0) == nil }.count
            + sessions.backgroundCount
        let pct = active.trustedUsedPct(now: now)
        let level: Level
        if riders + unknown == 0 {
            level = .clear
        } else if let pct {
            level = pct >= stopMark ? .stopped : pct >= warnMark ? .warn : .clear
        } else {
            level = .unknown
        }
        let moveFirst = sessions.groups.compactMap { group -> MoveFirst? in
            let sessionEmail = group.accountEvidence == "bridge owner" ? nil
                : group.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // A named different seat is not part of this blast radius. Unknown sessions
            // follow as an explicitly uncertain fallback because current ownership cannot
            // be ruled out without guessing from the active login.
            guard sessionEmail == nil || sessionEmail == activeEmail else { return nil }
            return MoveFirst(id: group.id.key, label: group.label, busy: group.busy,
                             accountKnown: sessionEmail != nil)
        }.sorted {
            if $0.busy != $1.busy { return !$0.busy }
            if $0.accountKnown != $1.accountKnown { return $0.accountKnown }
            let labelOrder = $0.label.localizedCaseInsensitiveCompare($1.label)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
        return BlastRadius(nickname: active.nickname, riders: riders, unknown: unknown, interactive: interactive,
                           percentUsed: pct, level: level, moveFirst: moveFirst)
    }

    private var sessionWord: String { riders == 1 ? "session" : "sessions" }
    private var pctText: String { percentUsed.map { "\(Int($0.rounded())) %" } ?? "?" }

    /// One line, shared by the CLI, the panel and MCP so the wording cannot drift.
    var line: String {
        if riders == 0 && unknown > 0 {
            let sessions = "0 confirmed, \(unknown) unknown \(unknown == 1 ? "session" : "sessions")"
            switch level {
            case .clear:
                return "\(sessions) on \(nickname) at \(pctText)"
            case .warn:
                return "\(sessions) on \(nickname) at \(pctText): rotate before 100 % may stop them all"
            case .stopped:
                return "\(sessions) may be stopped: \(nickname) is at \(pctText)"
            case .unknown:
                return "\(sessions) on \(nickname), usage unknown (no live reading)"
            }
        }
        let suffix = unknown > 0 ? " · \(unknown) unknown" : ""
        let measured: String
        switch level {
        case .clear where riders == 0:
            measured = "no confirmed sessions ride \(nickname)"
        case .clear:
            measured = "\(riders) \(sessionWord) ride \(nickname) at \(pctText), all stop together at 100 %"
        case .warn:
            measured = "\(riders) \(sessionWord) ride \(nickname) at \(pctText): rotate before 100 % stops them all"
        case .stopped:
            measured = "\(riders) \(sessionWord) stopped: \(nickname) is at \(pctText)"
        case .unknown:
            measured = "\(riders) \(sessionWord) ride \(nickname), usage unknown (no live reading)"
        }
        return measured + suffix
    }

    /// The concise follow-up for a warning banner. Keep the full list available to the
    /// panel and MCP, while a one-line surface names the first three candidates.
    var moveFirstLine: String? {
        guard !moveFirst.isEmpty else { return nil }
        let names = moveFirst.prefix(3).map(\.displayLabel).joined(separator: ", ")
        return "move first: \(names)"
    }

    /// Whether this reading should raise a toast, given the level last announced. Only a
    /// rise onto warn or stopped announces; falling back is silent, like the rail.
    func announces(after previous: Level?) -> Bool {
        guard level == .warn || level == .stopped else { return false }
        return level > (previous ?? .clear)
    }
}

// MARK: - Claude model

/// The model Claude Code sessions on this machine run by default: the `model` key of
/// ~/.claude/settings.json. It is one machine setting, not a per-account one, so it is
/// stamped on the active Claude row only and cleared from the others: the active row is
/// the one a newly opened session spends.
enum ClaudeModelSetting {
    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? String, !model.isEmpty
        else { return nil }
        return model
    }

    static func stamp(_ accounts: inout [String: AccountSnapshot], activeEmail: String?,
                      model: String? = read()) {
        for (key, snap) in accounts where snap.kind == .claude {
            accounts[key]?.model = snap.email == activeEmail ? model : nil
        }
    }
}

// MARK: - Machine load

/// Machine room: load1, memory held by the compressor, and swap.
///
/// Measured 2026-09-22: the ceiling all night was the machine, not quota (load1 180 to
/// 320, 14 to 34 GB compressed) while the dispatch gate refused at load1 120. A panel that
/// only says "seat has room" invited a dispatch the gate would then refuse. The marks are
/// the defaults of the dispatch gate Tower was built beside (DISPATCH_MEM_LOAD1 = 120,
/// DISPATCH_MEM_COMPRESSOR_GB = 25), so Tower and the gate agree on what "no room" means.
struct MachineLoad: Equatable {
    static let gateLoad1: Double = 120
    static let gateCompressorGiB: Double = 25
    /// Amber at three quarters of either gate mark: close enough to act, early enough to.
    static let amberFraction: Double = 0.75

    enum Level: String, Equatable { case green, amber, red }

    let load1: Double
    let compressorBytes: UInt64
    /// nil when `vm.swapusage` refuses the read. Measured 2026-09-23: it returns EPERM to
    /// a process spawned from Claude Code, sandboxed or not, while load and the compressor
    /// still answer. Swap does not decide the level, so a refused swap read costs one
    /// field, never the row.
    let swapUsedBytes: UInt64?
    let swapTotalBytes: UInt64?
    let physicalBytes: UInt64
    let sampledAt: Date

    static func gib(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }
    var compressorGiB: Double { Self.gib(compressorBytes) }
    var swapUsedGiB: Double? { swapUsedBytes.map(Self.gib) }
    var swapTotalGiB: Double? { swapTotalBytes.map(Self.gib) }

    /// Red is exactly the gate's refusal (strictly over either mark, as the gate compares).
    var level: Level {
        if load1 > Self.gateLoad1 || compressorGiB > Self.gateCompressorGiB { return .red }
        if load1 > Self.gateLoad1 * Self.amberFraction
            || compressorGiB > Self.gateCompressorGiB * Self.amberFraction { return .amber }
        return .green
    }

    /// Whether a new lane fits on this machine, the machine half of "room".
    var hasRoom: Bool { level != .red }

    /// Why there is no room, in the gate's words, or nil when there is room.
    var refusal: String? {
        if load1 > Self.gateLoad1 {
            return "load1 \(Int(load1.rounded())) over \(Int(Self.gateLoad1))"
        }
        if compressorGiB > Self.gateCompressorGiB {
            return String(format: "compressor %.1f GB over %.0f", compressorGiB, Self.gateCompressorGiB)
        }
        return nil
    }

    var line: String {
        var parts = ["load1 \(Int(load1.rounded()))",
                     String(format: "compressed %.1f GB", compressorGiB)]
        switch (swapUsedGiB, swapTotalGiB) {
        case (_, 0?): parts.append("swap 0")
        case let (used?, total?): parts.append(String(format: "swap %.1f of %.1f GB", used, total))
        default: parts.append("swap ?")
        }
        return parts.joined(separator: " · ")
    }

    /// Live sample from the kernel. nil when load or the compressor cannot be read: those
    /// two decide the level, and a row without them would draw green for a machine we
    /// could not measure. Swap is optional (see `swapUsedBytes`).
    static func sample(now: Date = Date()) -> MachineLoad? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) >= 1 else { return nil }

        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapRead = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        return MachineLoad(
            load1: loads[0],
            compressorBytes: UInt64(stats.compressor_page_count) * UInt64(pageSize),
            swapUsedBytes: swapRead ? swap.xsu_used : nil,
            swapTotalBytes: swapRead ? swap.xsu_total : nil,
            physicalBytes: ProcessInfo.processInfo.physicalMemory, sampledAt: now)
    }
}
