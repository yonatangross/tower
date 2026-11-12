import Foundation

extension LaneCost.Live {
    /// One `claude agents` row, reduced to what the cost record needs.
    init(_ agent: AgentInfo) {
        self.init(sessionId: agent.sessionId, interactive: agent.isInteractive,
                  lane: agent.displayName ?? agent.repoName, repo: agent.repoName, cwd: agent.cwd,
                  accountSeat: agent.accountEmail.map { Nickname.derive(from: $0) },
                  accountEmail: agent.accountEmail, configDir: agent.configDir)
    }
}

enum LaneCostWiring {
    /// The floor's own copy of the private-lanes list (a copy or link of hq-ext
    /// configs/private-lanes.json). Without it nothing is read or written: fail closed.
    static func policyURL(home: URL) -> URL {
        home.appendingPathComponent(".floor/private-lanes.json")
    }

    /// Called after every refresh with the session list before and after it. Only when both
    /// probes answered: a nil list means `claude agents` could not run, which is not a close.
    /// The transcript reads happen off the main thread. A demo run never reads this Mac's
    /// sessions, so it never writes a ledger either.
    static func observe(previous: AgentSummary?, current: AgentSummary?) {
        guard DemoMode.runsLiveSessionProbe(), let previous, let current else { return }
        let before = previous.interactive.map(LaneCost.Live.init)
        let after = current.interactive.map(LaneCost.Live.init)
        guard !before.isEmpty else { return }
        Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let env = LaneCostRecorder.Environment(
                home: home, supportDir: Store.defaultSupportDirectory(), now: Date(),
                privateLanes: PrivateLanes.load(from: policyURL(home: home), home: home))
            LaneCostRecorder.recordClosed(previous: before, current: after, env: env)
        }
    }
}
