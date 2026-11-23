import Foundation

/// One row per seat of every provider Tower names: can it be read, is it signed in, when
/// was it last read, and if it is not live, why and what fixes it.
///
/// The one rule this type exists for: `live` is earned. A row is live only when its last
/// capture is inside the freshness TTL AND the last read did not fail AND it carries a
/// reading. A failed poll keeps its old numbers on the row, so a young capture alone
/// proves nothing. A hand-entered balance is never live, whatever its age.
enum ProviderCoverage {
    enum State: String, CaseIterable {
        case live, stale, failed, signedOut, neverRead, notConfigured, notExposed, manual, turnedOff
    }

    struct Row: Equatable {
        let provider: Provider
        let seat: String
        let state: State
        /// nil when Tower has no evidence either way.
        let authenticated: Bool?
        /// The last successful capture. nil when nothing was ever observed.
        let lastLiveRead: Date?
        let reason: String?
        let operatorStep: String?

        var isLive: Bool { state == .live }

        var json: JSON {
            [
                "provider": .string(provider.rawValue),
                "seat": .string(seat),
                "supported": .bool(true),
                "state": .string(state.rawValue),
                "live": .bool(isLive),
                "authenticated": .bool(authenticated),
                "lastLiveRead": .date(lastLiveRead),
                "reason": .string(reason),
                "operatorStep": .string(operatorStep),
            ]
        }
    }

    /// One hand-entered credit balance (a TypeSafe decision model). Never live.
    struct ManualBalance: Equatable {
        let seat: String
        let text: String
        let step: String?
        let isOn: Bool
    }

    /// The whole matrix. Every provider appears at least once, so a provider with nothing
    /// to show is a named row and never a silent absence. `accounts` must already be the
    /// rows the operator allows an agent to see; `isOn` says whether a provider's Settings
    /// toggle is on, and an OFF provider is a named row that carries no reading.
    static func matrix(accounts: [AccountSnapshot],
                       lanes: [Provider: AgentLane.Outcome],
                       manualBalances: [ManualBalance],
                       openRouterKeyConfigured: Bool = false,
                       isOn: (Provider) -> Bool = { _ in true },
                       now: Date) -> [Row] {
        var rows: [Row] = []
        for provider in Provider.allCases {
            let seats = accounts.filter { $0.kind == provider }
                .sorted { $0.nickname < $1.nickname }
            if provider == .typesafe {
                rows += manualBalances.map { balance in
                    guard balance.isOn else {
                        return Row(provider: provider, seat: balance.seat, state: .turnedOff,
                                   authenticated: nil, lastLiveRead: nil,
                                   reason: "turned off in Tower Settings", operatorStep: nil)
                    }
                    return Row(provider: provider, seat: balance.seat, state: .manual,
                               authenticated: nil, lastLiveRead: nil,
                               reason: "no billing endpoint; \(balance.text)",
                               operatorStep: balance.step)
                }
            } else if !isOn(provider) {
                rows.append(Row(provider: provider, seat: provider.rawValue, state: .turnedOff,
                                authenticated: nil, lastLiveRead: nil,
                                reason: "turned off in Tower Settings", operatorStep: nil))
            } else if AgentLane.mirrorLanes.contains(provider) {
                rows.append(laneRow(provider, seat: seats.first, outcome: lanes[provider], now: now))
            } else if seats.isEmpty, provider == .openrouter, openRouterKeyConfigured {
                // A rejected or failed first read writes no row, so an empty store does
                // not mean the key is missing.
                rows.append(Row(provider: provider, seat: provider.rawValue, state: .neverRead,
                                authenticated: nil, lastLiveRead: nil,
                                reason: "key configured, no successful balance read yet",
                                operatorStep: nil))
            } else if seats.isEmpty {
                rows.append(Row(provider: provider, seat: provider.rawValue, state: .notConfigured,
                                authenticated: nil, lastLiveRead: nil,
                                reason: "no login or key found", operatorStep: nil))
            } else {
                rows += seats.map { accountRow($0, now: now) }
            }
        }
        return rows
    }

    /// Codex reports a spent plan as a successful read: the cap message lands in
    /// `lastError` beside a measured 100 %.
    private static func isCodexCap(_ a: AccountSnapshot) -> Bool {
        a.kind == .codex && (a.weeklyPct ?? 0) >= 100
    }

    static func accountRow(_ a: AccountSnapshot, now: Date) -> Row {
        func row(_ state: State, authenticated: Bool?, reason: String?, step: String?) -> Row {
            Row(provider: a.kind, seat: a.nickname, state: state, authenticated: authenticated,
                lastLiveRead: a.capturedAt, reason: reason, operatorStep: step)
        }
        if a.needsLogin {
            return row(.signedOut, authenticated: false, reason: a.lastError,
                       step: "/login as \(a.nickname)")
        }
        if let error = a.lastError, !error.isEmpty, !isCodexCap(a) {
            return row(.failed, authenticated: error.contains("refused") ? false : nil,
                       reason: error, step: nil)
        }
        guard let captured = a.capturedAt else {
            return row(.neverRead, authenticated: nil, reason: "no successful read yet", step: nil)
        }
        let age = now.timeIntervalSince(captured)
        guard age >= 0, age <= AccountSnapshot.freshnessTTL else {
            return row(.stale, authenticated: nil,
                       reason: "last capture is outside the \(Int(AccountSnapshot.freshnessTTL / 60)) minute freshness window",
                       step: staleStep(a))
        }
        guard hasCurrentReading(a, now: now) else {
            return row(.stale, authenticated: nil, reason: "the last capture carried no usable window",
                       step: staleStep(a))
        }
        return row(.live, authenticated: true, reason: isCodexCap(a) ? a.lastError : nil, step: nil)
    }

    /// OpenRouter is a balance with no windows, Pi's row is a month of spend, and a lane may
    /// report only its short window, so none of them can use `worstTrust`, which reads the
    /// weekly slot.
    private static func hasCurrentReading(_ a: AccountSnapshot, now: Date) -> Bool {
        if a.kind == .openrouter || a.kind == .pi { return true }
        if a.kind.isAgentLane { return a.fiveHourPct != nil || a.weeklyPct != nil }
        return a.worstTrust(now: now) == .live
    }

    private static func staleStep(_ a: AccountSnapshot) -> String? {
        switch a.kind {
        case .claude: return "switch into \(a.nickname) with /login to read it"
        case .devin: return "run a Devin session; Tower reads the status cache the CLI writes"
        default: return nil
        }
    }

    /// A lane's own latest outcome outranks its stored row: a read that failed just now
    /// must not be answered with the numbers of the read before it.
    static func laneRow(_ lane: Provider, seat: AccountSnapshot?, outcome: AgentLane.Outcome?,
                        now: Date) -> Row {
        func row(_ state: State, authenticated: Bool? = nil, reason: String?, step: String? = nil) -> Row {
            Row(provider: lane, seat: seat?.nickname ?? lane.rawValue, state: state,
                authenticated: authenticated, lastLiveRead: seat?.capturedAt,
                reason: reason, operatorStep: step)
        }
        switch outcome {
        case .none:
            return seat.map { accountRow($0, now: now) }
                ?? row(.notConfigured, reason: "the lane was not read")
        case .notConfigured:
            return row(.notConfigured, reason: "the \(lane.rawValue) CLI is not installed")
        case .unavailable(let why):
            return row(.failed, reason: why)
        case .ok(let reading):
            switch reading.usage {
            case .quota:
                // The probe's own reading, not the stored row: a build that has not
                // written this lane yet leaves no row behind a quota read just now.
                guard let outcome, let quota = AgentLane.publishableQuota(outcome),
                      let observed = quota.fetchedAt else {
                    return row(.failed, reason: "the lane's quota carried no observation time")
                }
                var snap = seat ?? AccountSnapshot(email: AgentLane.mirrorEmail(lane),
                                                   nickname: lane.rawValue, plan: "lane")
                snap.provider = lane
                AgentLane.apply(quota, observedAt: observed, to: &snap, now: now)
                return accountRow(snap, now: now)
            case .notExposed:
                return row(.notExposed, reason: "this read path does not expose \(lane.rawValue) usage")
            case .spend:
                return row(.notExposed, reason: "\(lane.rawValue) records spend, not a quota window")
            case .notReadable(let why):
                if why.contains("not logged in") {
                    return row(.signedOut, authenticated: false, reason: why,
                               step: "run `\(lane.rawValue) login` in a terminal")
                }
                return row(.failed, reason: why)
            }
        }
    }
}
