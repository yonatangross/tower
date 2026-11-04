import Foundation

/// Whether the panel's numbers are being kept fresh, in one line the panel shows above the
/// boards. Seen on a real Mac 2026-11-04: the app had stopped, and the panel shown on
/// relaunch read "stale" on every row with no hint that Tower itself was the cause.
enum RefreshHealth {
    /// nil while refreshes are on time. Two missed intervals is the bar: one late refresh
    /// is normal jitter (a sleep, a slow provider), two means nothing is refreshing.
    /// - lastRefresh: the last successful refresh this run, nil before the first one.
    /// - newestReading: the newest capture in the store, so a panel hydrated from disk
    ///   (a relaunch, or panelshot) can still say how old what it shows is.
    static func line(lastRefresh: Date?, newestReading: Date?, now: Date,
                     interval: TimeInterval) -> String? {
        let bar = 2 * interval
        if let lastRefresh {
            guard now.timeIntervalSince(lastRefresh) > bar else { return nil }
            return "Tower is not refreshing: last refresh \(CLI.clock(lastRefresh)), "
                + "\(SeatUsagePresentation.readingAge(now.timeIntervalSince(lastRefresh))) ago"
        }
        guard let newestReading, now.timeIntervalSince(newestReading) > bar else { return nil }
        return "Saved readings only: newest from \(CLI.clock(newestReading)), "
            + "\(SeatUsagePresentation.readingAge(now.timeIntervalSince(newestReading))) ago"
    }

    /// The newest capture across the rows, the panel's best evidence of when anything
    /// was last read.
    static func newestReading(_ accounts: [AccountSnapshot]) -> Date? {
        accounts.compactMap(\.capturedAt).max()
    }
}

extension Provider {
    /// Where a row's numbers come from, named so a stale row tells the user what to check.
    var readingSource: String {
        switch self {
        case .claude: return "Claude usage API"
        case .codex: return "Codex CLI"
        case .cursor: return "Cursor usage API"
        case .openrouter: return "OpenRouter API"
        case .devin: return "Devin CLI cache"
        case .muse: return "muse usage"
        case .agy: return "Antigravity logs"
        case .pi: return "Pi session logs"
        case .typesafe: return "entered by hand"
        }
    }
}
