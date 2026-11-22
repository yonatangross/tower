import Foundation

/// One capture of a seat's two windows, kept beside accounts.json so Tower can tell how fast
/// the floor burns a seat. Written by `Store` on every save that carries a new `capturedAt`.
struct PaceSample: Codable, Equatable {
    let at: Date
    let fiveHour: Double?
    let weekly: Double?
    let fiveHourResetsAt: Date?
    let weeklyResetsAt: Date?
}

/// How long a seat would last at the floor's current pace.
///
/// 2026-11-11: the advice named a 5x seat at 11 % used as next; its 5h window then went
/// from 11 to 95 percent in ten minutes. Percent used says nothing about size: a 20x seat holds
/// four times the work of a 5x one, so the same floor fills the 5x seat four times faster.
/// The burn is measured on the active seat (the only one the floor is drawing on), in that
/// seat's own percent per hour, and scaled to each candidate by the ratio of their sizes.
enum Pace {
    /// The newest capture is compared with the oldest one inside this span.
    static let span: TimeInterval = 90 * 60
    /// Two captures closer than this are noise, not a pace.
    static let minimumGap: TimeInterval = 5 * 60
    /// Samples older than this are dropped from the log.
    static let keep: TimeInterval = 6 * 3600
    static let maxSamples = 48

    /// The floor's burn on the active seat, in that seat's percent per hour.
    struct Burn: Equatable {
        let fiveHourPerHour: Double?
        let weeklyPerHour: Double?
        /// The active seat's size (20 for max 20x, 5 for max 5x), nil when unknown.
        let size: Double?
    }

    /// The seat's size from its rate limit tier: 20 for max 20x, 5 for max 5x, nil unknown.
    static func size(of a: AccountSnapshot) -> Double? {
        guard let tier = a.tier?.lowercased() else { return nil }
        if tier.contains("20x") { return 20 }
        if tier.contains("5x") { return 5 }
        return nil
    }

    /// The burn from one seat's samples: newest against the oldest inside `span`, at least
    /// `minimumGap` apart. A window whose reset moved between the two captures has no burn
    /// (it refilled), and neither does a window that went down. nil when no window has one.
    static func burn(samples: [PaceSample], size: Double?, now: Date) -> Burn? {
        let sorted = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
        guard let newest = sorted.last else { return nil }
        guard let oldest = sorted.first(where: {
            newest.at.timeIntervalSince($0.at) <= span && newest.at.timeIntervalSince($0.at) >= minimumGap
        }) else { return nil }
        let hours = newest.at.timeIntervalSince(oldest.at) / 3600
        func rate(_ a: Double?, _ b: Double?, _ ra: Date?, _ rb: Date?) -> Double? {
            guard let a, let b, b >= a else { return nil }
            if let ra, let rb, abs(ra.timeIntervalSince(rb)) > 60 { return nil }
            return (b - a) / hours
        }
        let five = rate(oldest.fiveHour, newest.fiveHour, oldest.fiveHourResetsAt, newest.fiveHourResetsAt)
        let week = rate(oldest.weekly, newest.weekly, oldest.weeklyResetsAt, newest.weeklyResetsAt)
        guard five != nil || week != nil else { return nil }
        return Burn(fiveHourPerHour: five, weeklyPerHour: week, size: size)
    }

    /// Seconds until the seat runs out at `burn`, scaled to its size. A window that would
    /// refill (reset) before it empties does not bind; `.infinity` when a positive burn empties
    /// after its reset. nil when there is no live reading, zero burn (pace unknown), or no rate.
    static func lastsFor(_ a: AccountSnapshot, burn: Burn, now: Date) -> TimeInterval? {
        // A live weekly read with no 5h window in the reply (every Claude seat since about
        // 2026-11-12) still has a pace: the week binds what Tower can see. Without this the
        // active seat read "pace unknown" while pace.json held its burn (2026-11-17).
        guard a.kind == .claude, a.isRecommendable(now: now) || a.fiveHourUnreported(now: now) else { return nil }
        // Unknown size on either side: assume the same size rather than guess a ratio.
        let ratio: Double
        if let from = burn.size, let to = size(of: a), to > 0 { ratio = from / to } else { ratio = 1 }
        func window(_ used: Double?, _ perHour: Double?, _ resetsAt: Date?) -> TimeInterval?? {
            guard let used, let perHour else { return .some(nil) }
            let scaled = perHour * ratio
            // Zero burn means no work measured in the span, not "lasts forever".
            guard scaled > 0 else { return .some(nil) }
            let empty = max(0, 100 - used) / scaled * 3600
            if let resetsAt, resetsAt.timeIntervalSince(now) <= empty { return .some(.infinity) }
            return .some(empty)
        }
        let five = a.kind.hasFiveHourWindow
            ? window(a.effectiveFiveHour(now: now).pct, burn.fiveHourPerHour, a.fiveHourResetsAt) : .some(nil)
        let week = window(a.effectiveWeekly(now: now).pct, burn.weeklyPerHour, a.weeklyResetsAt)
        let known = [five, week].compactMap { $0 ?? nil }
        return known.min()
    }

    /// The plain words for `lastsFor`.
    static func text(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "pace unknown" }
        if seconds == .infinity { return "lasts past its resets at this pace" }
        let s = max(60, Int(seconds))
        if s < 3600 { return "lasts about \(s / 60)m at this pace" }
        let m = s % 3600 / 60
        return "lasts about \(s / 3600)h\(m >= 5 ? "\(m)m" : "") at this pace"
    }

    /// The floor's burn now: the verified active Claude seat's samples, scaled to its size.
    static func floorBurn(activeEmail: String?, accounts: [String: AccountSnapshot],
                          samples: [String: [PaceSample]], now: Date) -> Burn? {
        guard let activeEmail,
              let active = accounts.values.first(where: { $0.email == activeEmail && $0.kind == .claude }),
              let own = samples[active.id] else { return nil }
        return burn(samples: own, size: size(of: active), now: now)
    }

    /// Re-orders the live Claude rows of an already ranked list by how long each lasts,
    /// longest first, in the slots they already hold. Every other row stays where it is,
    /// so the order stays a valid ranking for the mixed provider list.
    static func reorder(_ ranked: [AccountSnapshot], burn: Burn, now: Date) -> [AccountSnapshot] {
        let slots = ranked.indices.filter { ranked[$0].kind == .claude && ranked[$0].isRecommendable(now: now) }
        guard slots.count > 1 else { return ranked }
        let rows = slots.map { ranked[$0] }
        let keyed = rows.enumerated().map { (i, a) in (i, a, lastsFor(a, burn: burn, now: now) ?? -1) }
        let sorted = keyed.sorted { x, y in x.2 != y.2 ? x.2 > y.2 : x.0 < y.0 }.map(\.1)
        var out = ranked
        for (slot, a) in zip(slots, sorted) { out[slot] = a }
        return out
    }
}
