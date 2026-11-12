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
    // RED STUB
    static func policyURL(home: URL) -> URL { home }

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
            let env = LaneCostRecorder.Environment(
                home: FileManager.default.homeDirectoryForCurrentUser,
                supportDir: Store.defaultSupportDirectory(), now: Date(), privateLanes: nil)
            LaneCostRecorder.recordClosed(previous: before, current: after, env: env)
        }
    }
}
