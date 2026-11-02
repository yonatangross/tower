import Foundation

/// The dense board may show a cached room value for an old observation, but
/// only alongside an explicit stale-cache age. It never supplies a value to
/// ranking or switching decisions.
struct SeatUsagePresentation: Equatable {
    let roomText: String
    let stateText: String
    let isLive: Bool
    /// Ranked windows whose reset has passed since the capture, or nil when none has.
    let reopened: Reopened?

    /// A passed reset is a known fact about the window, not a pending event: the
    /// window reopened at `resetsAt` with nothing used, whatever the capture's age.
    /// It is named on the row so a stale seat does not read as if its old
    /// numbers still describe that window. It never makes the seat live.
    struct Reopened: Equatable {
        /// "5h", "7d", or both joined as "5h+7d".
        let windows: String
        /// The most recent of those resets, so "reopened" holds for every named window.
        let at: Date
    }

    init(account: AccountSnapshot, now: Date = Date()) {
        isLive = account.worstTrust(now: now) == .live
        reopened = Self.reopenedWindows(account, now: now)
        if let liveRoom = account.trustedUsedPct(now: now).map({ max(0, 100 - $0) }) {
            roomText = Self.percent(liveRoom)
            stateText = ""
            return
        }

        guard let capturedAt = account.capturedAt,
              let cachedRoom = Self.cachedRoom(account, now: now) else {
            roomText = "?"
            stateText = "no data"
            return
        }

        roomText = Self.percent(cachedRoom)
        stateText = "stale cache \(Self.age(now.timeIntervalSince(capturedAt)))"
    }

    /// The words for `AccountSnapshot.fiveHourUnreported`, one string for every surface.
    static let fiveHourUnreportedText = "5h not reported"

    static func restLabel(_ rest: AccountSnapshot.RestReason,
                          account: AccountSnapshot,
                          now: Date) -> String {
        let usage = Self(account: account, now: now)
        switch rest {
        case .capped:
            return "capped"
        case .meteredCapped:
            return "Auto only"
        case .cappedAndStale:
            return "cap · \(usage.stateText)"
        case .stale:
            // a seconds-old reply that only lacked the 5h window is not stale: say what is missing
            return account.fiveHourUnreported(now: now) ? Self.fiveHourUnreportedText : usage.stateText
        case .neverCaptured:
            return "no data"
        }
    }

    /// What the board's reset column says. A pure value so no surface can print
    /// "due" for a reset that already happened.
    enum ResetCell: Equatable {
        /// A future reset: compact countdown over the wall clock.
        case countdown(String, clock: String)
        /// A passed reset: "reopened" over "5h · 16h 2m ago".
        case reopened(String)
        /// A stale row with nothing reopened: switching into it resolves the unknown.
        case switchToCheck
        case none
    }

    static func resetCell(_ account: AccountSnapshot,
                          rest: AccountSnapshot.RestReason?,
                          now: Date) -> ResetCell {
        let target: Date?
        if let rest {
            target = rest.isTimeGated ? AccountSnapshot.reopening(account, now: now) : nil
        } else {
            target = account.presentableBindingQuota(now: now)?.resetsAt
        }
        if let target, target > now {
            return .countdown(BoardText.countdown(target, now: now), clock: CLI.clock(target))
        }
        // A row that waits on a refresh is an action whatever its windows did since: the
        // reset column says so, and a passed reset rides under the row's stale pill
        // (`reopenedNote`) instead. It used to take this column, which made a stale seat
        // read as a wait (bug b, 2026-09-30).
        if rest?.isTimeGated == false { return .switchToCheck }
        if let reopened = reopenedWindows(account, now: now), target != nil {
            return .reopened("\(reopened.windows) · \(BoardText.ago(reopened.at, now: now))")
        }
        return .none
    }

    /// The line under a stale row's pill when a ranked window reset since the capture,
    /// "5h reopened 3d 8h ago": the reason switching in is worth it.
    static func reopenedNote(_ account: AccountSnapshot, rest: AccountSnapshot.RestReason?,
                             now: Date) -> String? {
        guard rest?.isTimeGated == false, let reopened = reopenedWindows(account, now: now)
        else { return nil }
        return "\(reopened.windows) reopened \(BoardText.ago(reopened.at, now: now))"
    }

    private static func percent(_ room: Double) -> String {
        "\(Int(room.rounded()))%"
    }

    /// Match the persisted mirror's room calculation exactly. The store zeroes a
    /// window whose reset has passed on every load and save, so the same reset
    /// arithmetic is applied here: a row must read the same whether or not it has
    /// been through the store since its window reopened.
    private static func cachedRoom(_ account: AccountSnapshot, now: Date) -> Double? {
        account.usedPct(now: now).map { min(100, max(0, 100 - $0)) }
    }

    /// Only the windows this provider ranks on, matching `worstTrust`.
    static func reopenedWindows(_ account: AccountSnapshot, now: Date) -> Reopened? {
        var labels: [String] = []
        var latest: Date?
        func consider(_ label: String, _ value: (pct: Double?, reset: Bool), _ resetsAt: Date?) {
            guard value.reset, let resetsAt else { return }
            labels.append(label)
            latest = max(latest ?? resetsAt, resetsAt)
        }
        if account.kind.hasFiveHourWindow {
            consider("5h", account.effectiveFiveHour(now: now), account.fiveHourResetsAt)
        }
        consider(account.kind.primaryWindowLabel, account.effectiveWeekly(now: now),
                 account.weeklyResetsAt)
        guard let latest, !labels.isEmpty else { return nil }
        return Reopened(windows: labels.joined(separator: "+"), at: latest)
    }

    private static func age(_ interval: TimeInterval) -> String {
        if interval < 0 { return "clock skew" }
        let minutes = max(0, Int(interval / 60))
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}

// MARK: - Countdown text

enum BoardText {
    /// Compact countdown: "42m", "2h 1m", "12d 7h". A past date is a window that
    /// has already reopened, so it reads "reopened 16h 2m ago". It used to read
    /// "due", which every surface then printed forever for a reset that was over.
    static func countdown(_ date: Date?, now: Date) -> String {
        guard let date else { return "-" }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "reopened \(ago(date, now: now))" }
        return compact(minutes: max(1, Int(s / 60)))
    }

    /// "16h 2m ago", or "just now" inside the first minute.
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        return minutes < 1 ? "just now" : "\(compact(minutes: minutes)) ago"
    }

    private static func compact(minutes m: Int) -> String {
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 48 { return "\(h)h \(m % 60)m" }
        return "\(h / 24)d \(h % 24)h"
    }

    static func span(_ interval: TimeInterval) -> String {
        let h = Int(interval / 3600)
        if h < 48 { return "\(max(1, h))h" }
        return "\(h / 24)d"
    }
}

// MARK: - Braille meter

/// The Claude Code status line's meter (`bar()` in statusline-command.sh), as pure values
/// the panel draws: `cells` braille cells, six steps each, lit from the bottom up through
/// ⣀ ⣄ ⣤ ⣦ ⣶ ⣷ ⣿, each lit cell coloured by its position along a green, amber, red gradient,
/// and the percent beside it in one level colour. Operator word 2026-09-30: meters
/// "styled like that, instead of hard to see".
enum BrailleMeterMath {
    /// Unicode braille dot bits for the seven steps, ⣀ (empty) to ⣿ (full). Bit i is dot
    /// i + 1: dots 1 to 3 run down the left column, 4 to 6 down the right, 7 and 8 are
    /// the bottom row left and right.
    static let masks: [UInt8] = [0xC0, 0xC4, 0xE4, 0xE6, 0xF6, 0xF7, 0xFF]

    /// Column (0 left, 1 right) and row (0 top, 3 bottom) of dot bit i.
    static let dotPositions: [(column: Int, row: Int)] = [
        (0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3),
    ]

    /// The glyph for a step, for text surfaces and for tests that read like the status line.
    static let glyphs: [Character] = ["⣀", "⣄", "⣤", "⣦", "⣶", "⣷", "⣿"]

    /// Step (0 to 6) of every cell for `percent` used, rounded the way the status line
    /// rounds: `(v * cells * 6 + 50) / 100` lit steps, filled left to right.
    static func steps(percent: Double, cells: Int) -> [Int] {
        guard cells > 0 else { return [] }
        let value = Int(min(max(percent, 0), 100).rounded())
        let lit = (value * cells * 6 + 50) / 100
        return (0..<cells).map { min(6, max(0, lit - $0 * 6)) }
    }

    static func text(percent: Double, cells: Int) -> String {
        String(steps(percent: percent, cells: cells).map { glyphs[$0] })
    }

    struct RGB: Equatable {
        let r: Int, g: Int, b: Int
    }

    /// The unlit cell colour, the status line's 74,71,61.
    static let unlit = RGB(r: 74, g: 71, b: 61)

    /// Cell `index` of `cells`, coloured by its midpoint along the quota gradient: green up
    /// to 30 percent, green to amber by 60, amber to red by 85, red past it. Integer
    /// arithmetic identical to the status line, so the two surfaces agree cell for cell.
    static func gradient(cell index: Int, of cells: Int, amberAt a: Int = 60, redAt b: Int = 85) -> RGB {
        let pos = (2 * index + 1) * 100 / (2 * max(cells, 1))
        if pos <= a / 2 { return RGB(r: 74, g: 222, b: 128) }
        if pos <= a {
            let t = (pos - a / 2) * 100 / (a - a / 2)
            return RGB(r: 74 + 176 * t / 100, g: 222 - 18 * t / 100, b: 128 - 107 * t / 100)
        }
        if pos <= b {
            let t = (pos - a) * 100 / (b - a)
            return RGB(r: 250 - 2 * t / 100, g: 204 - 91 * t / 100, b: 21 + 92 * t / 100)
        }
        return RGB(r: 248, g: 113, b: 113)
    }

    enum Level: Equatable { case ok, watch, high }

    /// The percent's colour, the status line's quota rule: 85 and up red, 60 and up amber.
    static func level(usedPercent: Double) -> Level {
        if usedPercent >= 85 { return .high }
        if usedPercent >= 60 { return .watch }
        return .ok
    }
}
