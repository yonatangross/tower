import Foundation

enum CLI {
    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }

    /// A stale bar is drawn hollow, so an old reading cannot pass for a current one at a
    /// glance the way a solid bar does.
    static func bar(_ pct: Double?, width: Int = 12, trust: Trust = .live) -> String {
        guard let pct else { return String(repeating: "?", count: width) }
        let filled = Int((min(max(pct, 0), 100) / 100.0 * Double(width)).rounded())
        let fill = trust == .live ? "█" : "▒"
        return String(repeating: fill, count: filled) + String(repeating: "░", count: width - filled)
    }

    static func clock(_ d: Date?) -> String {
        guard let d else { return "-" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MMM d HH:mm"
        return f.string(from: d)
    }

    static func age(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "never" }
        let s = Int(now.timeIntervalSince(d))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    /// A traffic light is a claim about the present, so anything we cannot vouch for is
    /// white rather than reassuringly green.
    static func light(_ pct: Double?, _ trust: Trust = .live) -> String {
        guard let pct, trust == .live else { return "⚪️" }
        if pct >= 90 { return "🔴" }
        if pct >= 70 { return "🟠" }
        return "🟢"
    }

    /// `rotate` is deliberately an advisory command. Claude Code has one machine-global
    /// Keychain credential, so a shell command cannot bind a particular pane to a seat.
    /// The operator must run `/login` in that pane and choose the named Chrome profile.
    struct RotateReport {
        let code: Int32
        let seats: [AccountSnapshot]
        let lines: [String]
    }

    static func loginPlan(for seat: AccountSnapshot, chromeProfile: ChromeProfileHint) -> [String] {
        let second: String
        if let chooserEmail = chromeProfile.chooserEmail {
            second = "  2. Choose Chrome profile \"\(chromeProfile.displayName)\"; "
                + "if Google shows an account chooser, select \(chooserEmail)."
        } else {
            second = "  2. Choose Chrome profile \"\(chromeProfile.displayName)\" "
                + "and sign in as \(seat.email)."
        }
        return ["  1. In the target Claude Code pane, run /login.", second]
    }

    static func rotateSeatLine(
        for seat: AccountSnapshot, chromeProfile: ChromeProfileHint?, now: Date
    ) -> String {
        let room = seat.roomPct(now: now).map { "\(Int($0.rounded()))%" } ?? "0%"
        let suffix: String
        if seat.isOverCap(now: now), let used = seat.usedPct(now: now) {
            suffix = " over cap (\(Int(used.rounded()))% used)"
        } else {
            suffix = ""
        }
        return "  " + pad(seat.nickname, 10) + pad(room, 8)
            + pad(age(seat.capturedAt, now: now), 15)
            + pad(chromeProfile?.displayName ?? "-", 20)
            + (chromeProfile?.chooserEmail ?? "—") + suffix
    }

    /// Pure rendering makes the one clock read in `rotate()` testable and ensures every
    /// freshness decision, displayed age, and ordering decision uses the same instant.
    static func rotateReport(
        accounts: [AccountSnapshot], switchProfiles: [String: ChromeProfileHint], now: Date
    ) -> RotateReport {
        let mapped = accounts.filter {
            $0.kind == .claude && switchProfiles[$0.email] != nil
        }
        guard !mapped.isEmpty else {
            return RotateReport(code: 1, seats: [], lines: [
                "  No Claude seat has a known Chrome profile; no login plan was made.",
            ])
        }

        let split = AccountSnapshot.partition(mapped, rule: .capped, now: now)

        var lines = [
            "",
            "  ↻ TOWER ROTATE — MANUAL LOGIN PLAN",
            "  " + String(repeating: "─", count: 70),
            "  USABLE CLAUDE SEATS (current captures only)",
            "  " + pad("seat", 10) + pad("room", 8) + pad("snapshot age", 15)
                + pad("Chrome profile", 20) + "Google account",
        ]
        for seat in split.active {
            let profile = switchProfiles[seat.email]
            lines.append(rotateSeatLine(for: seat, chromeProfile: profile, now: now))
        }

        let unknown = mapped.filter { !$0.isRecommendable(now: now) }
            .sorted { AccountSnapshot.ranked($0, $1, now: now) }
        if !unknown.isEmpty {
            lines.append("  UNKNOWN USAGE (excluded from room and next)")
            for seat in unknown {
                let state = seat.capturedAt == nil ? "never captured"
                    : "unknown since " + age(seat.capturedAt, now: now)
                lines.append("  \(seat.nickname)  \(state)  \(switchProfiles[seat.email]?.label ?? "-")")
            }
        }
        if split.active.isEmpty {
            lines.append("  Every Claude seat with a known Chrome profile is resting or unknown.")
            lines.append("  No login was attempted.")
            return RotateReport(code: 1, seats: [], lines: lines)
        }

        // `advise` independently limits the manual plan to a fresh, profiled target. The
        // visible stale rows inform the operator, but are never presented as current room.
        // rotate knows no active seat by design, so the answer is always activeUnknown;
        // the roomiest seat it names is still the right manual-login candidate.
        let advice = AccountSnapshot.advise(
            activeEmail: nil, accounts: mapped, switchProfiles: switchProfiles,
            rule: .capped, now: now)
        var candidate: (nick: String, via: ChromeProfileHint?)?
        switch advice {
        case .switchTo(let nick, _, let via), .activeUnknown(let nick, _, let via):
            candidate = (nick, via)
        case .stay, .activeFiveHourUnknown, .allResting:
            break
        }
        if let (nick, profile) = candidate,
           let seat = split.active.first(where: { $0.nickname == nick }), let profile {
            lines.append("")
            lines.append("  Manual login plan — this command did not switch anything:")
            lines.append(contentsOf: loginPlan(for: seat, chromeProfile: profile))
        } else {
            lines.append("")
            lines.append("  No fresh seat can be recommended for manual login; stale rows are cached only.")
        }
        lines.append("")
        return RotateReport(code: 0, seats: split.active, lines: lines)
    }

    /// What `tower retrust` prints and its exit code: the counts on success (exit 0), the
    /// vault's own refusal on failure (exit 1), for example an unsigned build that may
    /// never show the Keychain dialog. The running app picks the seats up by itself: it
    /// re-reads an unreadable seat silently every `ClaudeSeatVault.readRetryBackoff`.
    static func retrustReport(_ result: Result<(readable: Int, unreadable: Int), ClaudeSeatVaultError>)
        -> (code: Int32, lines: [String]) {
        switch result {
        case .success(let counts):
            return (0, ["Re-trust: \(counts.readable) remembered seats readable, \(counts.unreadable) still unreadable. macOS asks Always Allow once per seat."])
        case .failure(let error):
            return (1, ["Re-trust failed: \(error.message)"])
        }
    }

    /// Prints an advisory manual-login plan without changing the active Claude credential.
    static func rotate() -> Int32 {
        let now = Date()
        let report = rotateReport(
            accounts: Array(Store.shared.load().values),
            switchProfiles: Store.shared.switchProfilesByEmail(), now: now)
        report.lines.forEach { print($0) }
        return report.code
    }

    /// The production status assembly groups active rows before the final renderer decides
    /// whether a provider is quota-based or OpenRouter's dedicated balance section.
    private struct StatusSection {
        let provider: Provider
        let rows: [AccountSnapshot]
    }

    private static func statusSections(active: [AccountSnapshot]) -> [StatusSection] {
        Provider.allCases.compactMap { provider in
            let rows = active.filter { $0.kind == provider }
            return rows.isEmpty ? nil : StatusSection(provider: provider, rows: rows)
        }
    }

    /// Exercises the pure logic that has no other coverage: threshold de-duplication,
    /// reset-awareness, nickname derivation, and the 6-fractional-digit date format.
    static func selftest() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  ✅ \(name)" : "  ❌ \(name) \(detail)")
            if !ok { failures += 1 }
        }
        func profile(_ displayName: String, chooserEmail: String? = nil) -> ChromeProfileHint {
            ChromeProfileHint(displayName: displayName, chooserEmail: chooserEmail)
        }

        print("\n  🧪 SELFTEST\n  " + String(repeating: "─", count: 56))

        // Dates as returned live by /api/oauth/usage (6 fractional digits, +00:00).
        let parsed = DateParse.parse("2026-07-24T23:10:00.499475+00:00")
        check("parses 6-digit fractional seconds", parsed != nil)
        check("parses Z form", DateParse.parse("2026-07-24T23:10:00Z") != nil)
        check("nil on garbage", DateParse.parse("not-a-date") == nil)

        // `Nickname.derive` uses the local part only, so example.com addresses exercise
        // the same path as real ones.
        let nicknameOverrides = ["work@example.com": "w1", "OPS@example.com": "ops"]
            .reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        let expected = [
            "alice@example.com": "alice", "bob.smith@example.com": "bob.sm",
            "work@example.com": "w1", "Ops@Example.com": "ops",
        ]
        for (email, want) in expected.sorted(by: { $0.key < $1.key }) {
            let got = Nickname.derive(from: email, overrides: nicknameOverrides)
            check("nickname \(email) -> \(want)", got == want, "got \(got)")
        }
        let nicknameFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-nicknames-\(UUID().uuidString).json")
        try? Data(#"{"Work@Example.com":" w1 ","blank@example.com":"  "}"#.utf8).write(to: nicknameFile)
        let loadedNicknames = Nickname.loadOverrides(from: nicknameFile)
        try? FileManager.default.removeItem(at: nicknameFile)
        check("nicknames.json is read lowercased and trimmed, blanks dropped",
              loadedNicknames == ["work@example.com": "w1"], "got \(loadedNicknames)")
        check("a missing nicknames.json is no overrides",
              Nickname.loadOverrides(from: nicknameFile).isEmpty)

        let future = Date().addingTimeInterval(3600)
        let past = Date().addingTimeInterval(-3600)
        var s = AccountSnapshot(email: "t@t", nickname: "t", plan: "max")
        s.fiveHourResetsAt = future
        s.weeklyResetsAt = future

        s.fiveHourPct = 50
        check("no alert below 80", Thresholds.evaluate(&s).isEmpty)

        s.fiveHourPct = 85
        check("fires once at 80", Thresholds.evaluate(&s).count == 1)

        s.fiveHourPct = 88
        check("does NOT re-fire same level", Thresholds.evaluate(&s).isEmpty)

        s.fiveHourPct = 96
        check("fires again at 95", Thresholds.evaluate(&s).count == 1)

        s.fiveHourPct = 100
        check("fires again at 100", Thresholds.evaluate(&s).count == 1)

        s.fiveHourPct = 100
        check("silent after 100", Thresholds.evaluate(&s).isEmpty)

        var r = AccountSnapshot(email: "r@r", nickname: "r", plan: "max")
        r.weeklyPct = 99
        r.weeklyResetsAt = past
        check("silent when window already reset", Thresholds.evaluate(&r).isEmpty)
        check("prunes stale bookkeeping", r.notified.isEmpty)

        // --- Rail crossings ------------------------------------------------------------
        // Amber and red marks with one toast per account crossing. capturedAt is pinned
        // to the wall clock so the readings are live and allowed to announce.
        var rq = AccountSnapshot(email: "q@q", nickname: "q", plan: "max", capturedAt: Date())
        rq.fiveHourResetsAt = future
        rq.weeklyResetsAt = future

        rq.fiveHourPct = 70
        check("no rail crossing at 70", Rail.evaluate(&rq) == nil && rq.crossing == nil)

        rq.fiveHourPct = 83
        let railAmber = Rail.evaluate(&rq)
        check("rail announces amber at 83",
              railAmber?.level == .amber && rq.crossing == "amber")

        rq.fiveHourPct = 84
        check("rail silent inside the band",
              Rail.evaluate(&rq) == nil && rq.crossing == "amber")

        rq.fiveHourPct = 91
        let railRed = Rail.evaluate(&rq)
        check("rail announces red at 91", railRed?.level == .red && rq.crossing == "red")

        rq.fiveHourPct = 95
        check("rail silent above red", Rail.evaluate(&rq) == nil && rq.crossing == "red")

        rq.fiveHourPct = 70
        check("rail clears below 80", Rail.evaluate(&rq) == nil && rq.crossing == nil)

        rq.fiveHourPct = 83
        check("rail announces again after clear", Rail.evaluate(&rq)?.level == .amber)

        // Boundary values on the 5h meter: marks are inclusive.
        var rb = AccountSnapshot(email: "b@b", nickname: "b", plan: "max", capturedAt: Date())
        rb.fiveHourResetsAt = future
        rb.weeklyResetsAt = future
        rb.fiveHourPct = 79.9
        check("rail none at 79.9", Rail.evaluate(&rb) == nil && rb.crossing == nil)
        rb.fiveHourPct = 80.0
        check("rail amber at 80.0", Rail.evaluate(&rb)?.level == .amber)
        rb.fiveHourPct = 89.9
        _ = Rail.evaluate(&rb)
        check("rail amber at 89.9", rb.crossing == "amber")
        rb.fiveHourPct = 90.0
        check("rail red at 90.0", Rail.evaluate(&rb)?.level == .red)

        // The 7d meter carries only the red mark: the amber band crosses nothing there.
        var rw = AccountSnapshot(email: "w@w", nickname: "w", plan: "max", capturedAt: Date())
        rw.fiveHourResetsAt = future
        rw.weeklyResetsAt = future
        rw.weeklyPct = 89.9
        check("7d rail silent below 90", Rail.evaluate(&rw) == nil && rw.crossing == nil)
        rw.weeklyPct = 90.0
        check("7d rail red at 90.0", Rail.evaluate(&rw)?.level == .red && rw.crossing == "red")

        // A stale row advancing its own band writes the flag but never toasts: an old
        // number must not present itself as a fresh crossing.
        var rs = AccountSnapshot(email: "s@s", nickname: "s", plan: "max")
        rs.fiveHourPct = 91
        rs.fiveHourResetsAt = future
        rs.weeklyResetsAt = future
        rs.capturedAt = Date().addingTimeInterval(-3_600)
        check("stale band writes flag silently",
              Rail.evaluate(&rs) == nil && rs.crossing == "red")

        // The toast wording, exactly the shape the issue pins.
        let railShape = RailCrossing(nickname: "A", level: .amber, pct: 83)
        check("rail toast wording matches the issue shape",
              "\(railShape.toastTitle): \(railShape.toastBody)"
                  == "account A at 83 %: no new stations on A, rotation brief due at 90 %")

        var e = AccountSnapshot(email: "e@e", nickname: "e", plan: "max")
        e.weeklyPct = 99
        e.weeklyResetsAt = past
        check("reset window reads as 0%", e.effectiveWeekly().pct == 0)
        check("reset window flagged", e.effectiveWeekly().reset)

        // --- Freshness ---------------------------------------------------------------
        // Fixed clock: these assertions are about age arithmetic, not about wall time.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-60)
        let ancient = now.addingTimeInterval(-86_400)
        let upcoming = now.addingTimeInterval(3_600)
        let elapsed = now.addingTimeInterval(-1)

        check("trust live inside the TTL",
              AccountSnapshot.trust(pct: 50, resetsAt: upcoming, capturedAt: recent, now: now)
                  == .live)
        check("trust stale past the TTL",
              AccountSnapshot.trust(pct: 50, resetsAt: upcoming, capturedAt: ancient, now: now)
                  == .stale)
        check("trust unknown when never captured",
              AccountSnapshot.trust(pct: 50, resetsAt: upcoming, capturedAt: nil, now: now)
                  == .unknown)
        check("trust unknown when there is no reading",
              AccountSnapshot.trust(pct: nil, resetsAt: upcoming, capturedAt: recent, now: now)
                  == .unknown)
        // Reset arithmetic cannot observe new usage or renew an expired capture.
        check("trust stays stale when an old capture reset moments ago",
              AccountSnapshot.trust(pct: 99, resetsAt: now.addingTimeInterval(-60),
                                    capturedAt: ancient, now: now) == .stale)
        // But a reset is a fact with a shelf life, not a permanent one. This is the blocker:
        // a weekly resetsAt is at most 7 days after its capture, so treating any passed reset
        // as live classified EVERY snapshot older than a week as a live 0% and recommended
        // it first. With six accounts and one pollable credential that is the common case.
        check("trust stale when the reset is itself old",
              AccountSnapshot.trust(pct: 99, resetsAt: now.addingTimeInterval(-86_400),
                                    capturedAt: ancient, now: now) == .stale)

        var weekOld = AccountSnapshot(email: "w@w", nickname: "w", plan: "max")
        weekOld.capturedAt = now.addingTimeInterval(-8 * 86_400)
        weekOld.fiveHourPct = 99
        weekOld.fiveHourResetsAt = now.addingTimeInterval(-8 * 86_400 + 5 * 3_600)
        weekOld.weeklyPct = 97
        weekOld.weeklyResetsAt = now.addingTimeInterval(-86_400)
        check("an 8-day-old snapshot is not live", weekOld.worstTrust(now: now) == .stale)
        check("an 8-day-old snapshot is not recommendable",
              !weekOld.isRecommendable(now: now))
        check("an 8-day-old snapshot has no trusted usage",
              weekOld.trustedUsedPct(now: now) == nil)

        var stale = AccountSnapshot(email: "s@s", nickname: "s", plan: "max")
        stale.capturedAt = ancient
        stale.fiveHourPct = 40
        stale.fiveHourResetsAt = upcoming
        stale.weeklyPct = 35
        stale.weeklyResetsAt = upcoming
        check("stale account has no trusted usage", stale.trustedUsedPct(now: now) == nil)
        check("stale account still exposes the raw number", stale.usedPct(now: now) == 40)
        check("stale account worstTrust is stale", stale.worstTrust(now: now) == .stale)

        // A stale reading says how old it is and where it came from, never a bare
        // "stale": the user needs to know whether to wait, refresh or fix a source.
        var oldRead = AccountSnapshot(email: "r@r", nickname: "r", plan: "max")
        oldRead.capturedAt = now.addingTimeInterval(-(2 * 3600 + 2 * 60))
        oldRead.weeklyPct = 30
        oldRead.weeklyResetsAt = upcoming
        check("a stale row says how long ago it was read",
              SeatUsagePresentation(account: oldRead, now: now).stateText == "read 2h 2m ago",
              SeatUsagePresentation(account: oldRead, now: now).stateText)
        check("every quota provider names where its reading comes from",
              Provider.claude.readingSource == "Claude usage API"
                  && Provider.codex.readingSource == "Codex CLI"
                  && Provider.cursor.readingSource == "Cursor usage API"
                  && Provider.devin.readingSource == "Devin CLI cache"
                  && Provider.muse.readingSource == "muse usage")
        // The panel says so when Tower itself stopped refreshing (or only shows readings
        // saved by an earlier run), instead of leaving every row to read "stale".
        let lastGood = now.addingTimeInterval(-20 * 60)
        check("panel says Tower is not refreshing after two missed intervals",
              RefreshHealth.line(lastRefresh: lastGood, newestReading: lastGood, now: now, interval: 300)
                  == "Tower is not refreshing: last refresh \(CLI.clock(lastGood)), 20m ago",
              RefreshHealth.line(lastRefresh: lastGood, newestReading: lastGood, now: now, interval: 300) ?? "nil")
        let savedOnly = now.addingTimeInterval(-52 * 60)
        check("panel with no refresh yet says it shows saved readings and how old",
              RefreshHealth.line(lastRefresh: nil, newestReading: savedOnly, now: now, interval: 300)
                  == "Saved readings only: newest from \(CLI.clock(savedOnly)), 52m ago",
              RefreshHealth.line(lastRefresh: nil, newestReading: savedOnly, now: now, interval: 300) ?? "nil")
        check("panel says nothing while refreshes are on time",
              RefreshHealth.line(lastRefresh: now.addingTimeInterval(-240), newestReading: now, now: now, interval: 300) == nil
                  && RefreshHealth.line(lastRefresh: nil, newestReading: now.addingTimeInterval(-120), now: now, interval: 300) == nil
                  && RefreshHealth.line(lastRefresh: nil, newestReading: nil, now: now, interval: 300) == nil)

        var mixed = AccountSnapshot(email: "m@m", nickname: "m", plan: "max")
        mixed.capturedAt = ancient
        mixed.fiveHourPct = 90
        mixed.fiveHourResetsAt = elapsed   // old capture remains stale after reset
        mixed.weeklyPct = 35
        mixed.weeklyResetsAt = upcoming    // stale, so not counted
        check("mixed account cannot count a reset as a new capture",
              mixed.trustedUsedPct(now: now) == nil)
        // Reset arithmetic cannot make the old capture safe to recommend.
        check("partially stale account is not recommendable", !mixed.isRecommendable(now: now))
        check("fully stale account is not recommendable", !stale.isRecommendable(now: now))

        var live = AccountSnapshot(email: "l@l", nickname: "l", plan: "max")
        live.capturedAt = recent
        live.fiveHourPct = 80
        live.fiveHourResetsAt = upcoming
        live.weeklyPct = 80
        live.weeklyResetsAt = upcoming
        let never = AccountSnapshot(email: "n@n", nickname: "n", plan: "?")
        // The bug this encodes: a live 80% must still outrank a stale 35%, because the
        // stale number is not a fact about now.
        check("live outranks stale even at higher usage",
              AccountSnapshot.ranked(live, stale, now: now))
        check("stale outranks never-captured", AccountSnapshot.ranked(stale, never, now: now))
        check("never-captured does not outrank stale",
              !AccountSnapshot.ranked(never, stale, now: now))
        check("a fully live account is recommendable", live.isRecommendable(now: now))
        check("never-captured account is not recommendable", !never.isRecommendable(now: now))

        // --- Refresh outcomes --------------------------------------------------------
        check("outcome ok when identity and usage both arrived",
              Refresher.outcome(email: "a@a", gotUsage: true, failure: nil, saveError: nil).isOK)
        // The dropped case: identity resolution threw, so there was no account to attach
        // the error to and the old code discarded it entirely.
        check("outcome carries the failure when identity threw",
              Refresher.outcome(email: nil, gotUsage: false, failure: "boom", saveError: nil)
                  .errorText == "boom")
        check("outcome not ok when the account never resolved",
              !Refresher.outcome(email: nil, gotUsage: false, failure: nil, saveError: nil).isOK)
        check("outcome not ok when usage threw",
              !Refresher.outcome(email: "a@a", gotUsage: false, failure: "usage boom",
                                 saveError: nil).isOK)
        // A save that did not land is a failed refresh: the screen would show numbers that
        // were never persisted.
        check("a lost save is reported as a failure",
              Refresher.outcome(email: "a@a", gotUsage: true, failure: nil,
                                saveError: "disk full").errorText == "disk full")
        check("noCredential is not ok", !RefreshOutcome.noCredential(detail: nil).isOK)
        check("noCredential explains itself",
              RefreshOutcome.noCredential(detail: nil).errorText != nil)
        check("noCredential detail reaches the error text",
              RefreshOutcome.noCredential(detail: "2 items").errorText?.contains("2 items") == true)
        check("ok has no error text", RefreshOutcome.ok(email: "a@a").errorText == nil)

        // #108: a session started without $USER once left a tokenless "unknown"
        // stub beside the real login item. Selection goes by the bound account,
        // never by whichever of the two `security` happens to return first.
        let dump108 = """
        keychain: "/Users/selftest/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "svce"<blob>="Claude Code-credentials"
            "acct"<blob>="unknown"
            "mdat"<timedate>=0x0000  "2026-09-21 22:03:54 +0000"
        class: "genp"
        attributes:
            "svce"<blob>="Claude Code-credentials"
            "acct"<blob>="selftest-user"
            "mdat"<timedate>=0x0000  "2026-09-23 08:59:03 +0000"
        """
        let refs108 = Keychain.parseItemRefs(dump108, service: Keychain.defaultService)
        check("the shared service enumerates both items",
              refs108.map(\.account) == ["unknown", "selftest-user"])
        let reads108: [String: Data] = [
            "unknown": Data("{}".utf8),
            "selftest-user": Data(
                #"{"claudeAiOauth":{"accessToken":"selftest-live","expiresAt":1999999999000}}"#.utf8),
        ]
        let picked108 = Keychain.firstCredential(
            refs: refs108, preferredAccount: "selftest-user",
            read: { reads108[$0] }, service: Keychain.defaultService, emailHint: nil)
        check("the bound account wins over the newer stub",
              picked108?.accessToken == "selftest-live")
        let detail108 = Keychain.noCredentialDetail(
            Keychain.ActiveItemScan(itemAccounts: refs108.map(\.account), resolvedAccount: nil))
        check("a shared service names both accounts in the error",
              detail108?.contains("2 items") == true
                  && detail108?.contains("selftest-user") == true)
        check("a resolved scan earns no error detail",
              Keychain.noCredentialDetail(
                  Keychain.ActiveItemScan(itemAccounts: [], resolvedAccount: "selftest-user")) == nil)

        // --- Store ------------------------------------------------------------------
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-\(UUID().uuidString)")
        let store = Store(dir: tmp)
        var one = AccountSnapshot(email: "a@a", nickname: "a", plan: "max")
        one.weeklyPct = 42
        check("first save succeeds (create path)", store.save(["a@a": one]) == nil)
        check("load round-trips", store.load()["a@a"]?.weeklyPct == 42)
        check("second save succeeds (replace path)", store.save(["a@a": one]) == nil)
        let (merged, mutateErr) = store.mutate {
            $0["b@b"] = AccountSnapshot(email: "b@b", nickname: "b", plan: "max")
        }
        check("mutate reports no error", mutateErr == nil)
        check("mutate returns the merged map", merged.count == 2)
        check("mutate is visible to a fresh load", store.load().count == 2)
        // The hotkey's registration result is logged in words, because a failed
        // RegisterEventHotKey used to be discarded and cmd+. then did nothing, silently.
        check("a registered hotkey reads as registered",
              PanelHotkey.describe(status: 0).contains("registered"))
        check("-9878 says this process already registered the hotkey, not that another app holds it",
              PanelHotkey.describe(status: -9878).contains("this process already registered")
                  && !PanelHotkey.describe(status: -9878).contains("another app"))
        check("an unknown hotkey status carries its number",
              PanelHotkey.describe(status: -1234).contains("-1234"))
        check("only status 0 counts as registered",
              PanelHotkey.isRegistered(status: 0) && !PanelHotkey.isRegistered(status: -9878))
        check("display name is Tower", ProductIdentity.displayName == "Tower")
        check("bundle id is ai.yonyon.tower",
              ProductIdentity.bundleIdentifier == "ai.yonyon.tower")
        check("support dir is Tower",
              ProductIdentity.supportDirectoryName == "Tower")
        do {
            // A pre-v0.1 support directory moves under the new name, keeping what the
            // new directory already holds.
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("tower-selftest-legacy-\(UUID().uuidString)")
            let legacy = base.appendingPathComponent(ProductIdentity.legacySupportDirectoryName)
            let current = base.appendingPathComponent(ProductIdentity.supportDirectoryName)
            try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            try? Data("old".utf8).write(to: legacy.appendingPathComponent("accounts.json"))
            try? Data("old".utf8).write(to: legacy.appendingPathComponent("nicknames.json"))
            try? Data("new".utf8).write(to: current.appendingPathComponent("nicknames.json"))
            let report = LegacyInstallMigration.migrateSupportDirectory(base: base)
            check("legacy support dir: store moved",
                  (try? String(contentsOf: current.appendingPathComponent("accounts.json"), encoding: .utf8)) == "old")
            check("legacy support dir: newer entry kept",
                  (try? String(contentsOf: current.appendingPathComponent("nicknames.json"), encoding: .utf8)) == "new")
            check("legacy support dir: report names only the moved entry",
                  report.movedEntries == ["accounts.json"] && report.problems.isEmpty)
            try? FileManager.default.removeItem(at: base)
        }
        let hydratedRows = SeatCacheHydration.rows(from: store)
        check("hydration reads last known seats from disk",
              hydratedRows.contains(where: { $0.email == "a@a" && $0.weeklyPct == 42 }))
        check("hydration marks the login hint ACTIVE",
              SeatCacheHydration.activeEmail(hint: "a@a", accounts: hydratedRows) == "a@a")
        check("a hint with no Claude seat is not ACTIVE",
              SeatCacheHydration.activeEmail(hint: "ghost@x", accounts: hydratedRows) == nil)
        let panelshotIdentity = tmp.appendingPathComponent("panelshot-identity.json")
        let panelshotFixture = """
        {"oauthAccount":{"emailAddress":"a@a"}}
        """
        try? panelshotFixture.data(using: .utf8)?.write(to: panelshotIdentity)
        var panelshotProfileReads = 0
        let panelshotState = PanelShotHydration.load(
            store: store,
            switchProfiles: { panelshotProfileReads += 1; return [:] },
            diskIdentityHint: { Keychain.profileEmail(at: panelshotIdentity) },
            lanes: { [.devin: .notConfigured] })
        check("panelshot resolves ACTIVE from its disk identity fixture",
              panelshotState.activeEmail == "a@a")
        check("panelshot hydrates the lanes it is handed",
              panelshotState.laneOutcomes[.devin] == .notConfigured)
        check("panelshot hydration reads cached rows and local profiles once",
              panelshotState.accounts.count == 2 && panelshotProfileReads == 1)
        let panelshotPreparation = MainActor.assumeIsolated { () -> (Int, PanelRefreshMode, Int, Int) in
            var hydrations = 0
            var panelshotWrites = 0
            let content = PanelShot.makeContent(
                model: PanelShot.makeModel(expandedWriter: { _ in panelshotWrites += 1 }),
                cachedHydration: { hydrations += 1 })
            content.model.expanded.insert("seat.fixture")

            var liveWrites = 0
            let liveModel = LimitsModel(
                expanded: [], expandedWriter: { _ in liveWrites += 1 })
            liveModel.expanded.insert("seat.fixture")
            return (hydrations, content.refreshMode, panelshotWrites, liveWrites)
        }
        check("panelshot preparation invokes only cached hydration",
              panelshotPreparation.0 == 1)
        check("panelshot passes cached mode to MenuContent's on-appear refresh",
              panelshotPreparation.1 == .cached
              && !panelshotPreparation.1.refreshesOnAppear)
        check("panelshot expansion never writes preferences while live expansion does",
              panelshotPreparation.2 == 0 && panelshotPreparation.3 == 1)
        try? FileManager.default.removeItem(at: panelshotIdentity)
        let shotBounds = NSRect(x: 0, y: 0, width: 400, height: 120)
        let shot3x = PanelShot.bitmap(for: shotBounds, scale: 3)
        check("panelshot scale 3 makes the pixel width 3x the point width",
              shot3x?.pixelsWide == 1200 && shot3x?.pixelsHigh == 360
              && shot3x?.size == shotBounds.size)
        check("panelshot with no scale keeps the screen's own backing scale",
              PanelShot.requestedScale(env: [:]) == .success(nil))
        check("panelshot reads TOWER_PANELSHOT_SCALE=3 as 3",
              PanelShot.requestedScale(env: [PanelShot.scaleEnvKey: "3"]) == .success(3))
        check("panelshot refuses a scale that is not a whole number from 1 to 4",
              ["0", "5", "2.5", "x", "-3"].allSatisfy {
                  if case .failure = PanelShot.requestedScale(env: [PanelShot.scaleEnvKey: $0]) { return true }
                  return false
              } && PanelShot.bitmap(for: shotBounds, scale: 9) == nil)
        var loginWatch = ClaudeLoginTracker()
        let sameToken = ClaudeCredential(
            service: Keychain.defaultService, accessToken: "same-token",
            subscriptionType: "max", rateLimitTier: nil,
            expiresAt: now.addingTimeInterval(3600), emailHint: "ana@example.test")
        let identA = ClaudeConfigIdentity(email: "ana@example.test", modifiedAt: 100, readable: true)
        let identB = ClaudeConfigIdentity(email: "ben@example.test", modifiedAt: 200, readable: true)
        check("login watch seeds without firing",
              loginWatch.observe(credentials: [sameToken], identity: identA)
                  .changedCredentials.isEmpty)
        let switched = loginWatch.observe(credentials: [sameToken], identity: identB)
        check("oauth email change retriggers the default seat",
              switched.identityChanged && switched.changedCredentials.count == 1)
        let gone = loginWatch.observe(
            credentials: [sameToken],
            identity: ClaudeConfigIdentity(email: nil, modifiedAt: nil, readable: false))
        check("unreadable config after a known identity is degraded",
              gone.watchDegraded && gone.identityChanged)
        var mtimeWatch = ClaudeLoginTracker()
        let identSame = ClaudeConfigIdentity(email: "ana@example.test", modifiedAt: 1, readable: true)
        let identTouched = ClaudeConfigIdentity(email: "ana@example.test", modifiedAt: 9, readable: true)
        _ = mtimeWatch.observe(credentials: [sameToken], identity: identSame)
        check("same oauth email with a newer mtime is not a login",
              mtimeWatch.observe(credentials: [sameToken], identity: identTouched)
                  .changedCredentials.isEmpty)

        // Diagnostic for the status-line anchor mismatch: a successful usage response
        // must replace the weekly anchor even when the five-hour anchor has not changed.
        do {
            let clock = Date(timeIntervalSince1970: 1_789_828_254)
            let fiveHour = Date(timeIntervalSince1970: 1_789_828_800)
            let oldWeekly = Date(timeIntervalSince1970: 1_790_060_400)
            let newWeekly = Date(timeIntervalSince1970: 1_790_222_400)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("tower-weekly-anchor-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let mirror = tmp.appendingPathComponent("claude/quota-cache.json")
            let store = Store(dir: tmp, mirror: mirror, now: { clock })
            let email = "anchor@example.test"
            let credential = ClaudeCredential(
                service: "fixture", accessToken: "fixture", subscriptionType: "max",
                rateLimitTier: nil, expiresAt: clock.addingTimeInterval(3600), emailHint: email)
            check("weekly anchor fixture saves", store.save([email: AccountSnapshot(
                email: email, nickname: "anchor", plan: "max", fiveHourPct: 10,
                fiveHourResetsAt: fiveHour, weeklyPct: 97, weeklyResetsAt: oldWeekly,
                capturedAt: clock.addingTimeInterval(-300))]) == nil)
            let wire = Data(#"{"five_hour":{"utilization":10,"resets_at":"2026-09-19T14:40:00Z"},"seven_day":{"utilization":12,"resets_at":"2026-09-24T04:00:00Z"}}"#.utf8)
            let usage = try JSONDecoder().decode(UsageResponse.self, from: wire)
            let observation = ClaudeRosterObservation(
                successes: [.init(credential: credential, fetch: ClaudeFetch(email: email, usage: usage))],
                failures: [], expired: [], attemptedServices: [credential.service], activeEmail: email)
            let result = store.mutate { ClaudeRoster.apply(observation, to: &$0, now: clock) }
            let bytes = try Data(contentsOf: mirror)
            let mirrored = try JSONDecoder().decode([String: AccountSnapshot].self, from: bytes)
            let saved = try Data(contentsOf: tmp.appendingPathComponent("accounts.json"))
            check("weekly anchor refresh saves identical store and mirror bytes",
                  result.saveError == nil && bytes == saved)
            check("weekly anchor refresh replaces old reset with unchanged five-hour reset",
                  [result.accounts, store.load(), mirrored].allSatisfy { rows in
                      rows[email]?.fiveHourResetsAt == fiveHour
                          && rows[email]?.weeklyResetsAt == newWeekly
                          && rows[email]?.weeklyPct == 12
                          && rows[email]?.capturedAt == clock
                          && rows[email]?.lastError == nil
                  })
        } catch {
            check("weekly anchor fixture executes", false, error.localizedDescription)
        }

        // The dispatcher reads the mirror, not the UI's in-memory OpenRouter state. Exercise
        // the normal successful fold through a temp Store and prove the authoritative file
        // and mirror carry the same bytes and all three required facts.
        let openRouterTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-openrouter-selftest-\(UUID().uuidString)")
        let openRouterMirror = openRouterTmp
            .appendingPathComponent("claude/quota-cache.json")
        let openRouterStore = Store(
            dir: openRouterTmp.appendingPathComponent("authoritative"), mirror: openRouterMirror)
        let openRouterCapturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var openRouterAccounts: [String: AccountSnapshot] = [:]
        openRouterStore.seedOpenRouterAccount(
            into: &openRouterAccounts,
            outcome: .ok(OpenRouter.Budget(spent: 46.18, limit: 100)),
            now: openRouterCapturedAt)
        check("openrouter row saves through the normal store path",
              openRouterStore.save(openRouterAccounts) == nil)
        let openRouterKey = AccountSnapshot.storeKey(
            email: OpenRouter.storeEmail, provider: .openrouter)
        let openRouterRow = openRouterStore.load()[openRouterKey]
        check("openrouter row: provider=openrouter balanceUSD=53.82 capturedAt=true",
              openRouterRow?.provider == .openrouter
              && openRouterRow?.balanceUSD == 53.82
              && openRouterRow?.capturedAt == openRouterCapturedAt)
        // The statusline producer reads availablePct straight off the mirror row; it is the
        // same percent-LEFT number the BudgetRow shows, not a re-derived one.
        let orBudget = OpenRouter.Budget(spent: 46.18, limit: 100)
        check("openrouter row publishes availablePct matching Budget.availablePct",
              openRouterRow?.availablePct == orBudget.availablePct
              && openRouterRow?.balanceUSD == orBudget.available)
        let orMirrorJSON = (try? Data(contentsOf: openRouterMirror))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            as? [String: [String: Any]]
        check("openrouter mirror row carries balanceUSD and availablePct",
              orMirrorJSON?[openRouterKey]?["balanceUSD"] as? Double == 53.82
              && orMirrorJSON?[openRouterKey]?["availablePct"] as? Double == 53.82)
        var statusOpenRouter = openRouterRow
        statusOpenRouter?.lastError = "scripted OpenRouter probe failure"
        let openRouterStatus = statusOpenRouter.map {
            statusSectionLines(
                provider: .openrouter, rows: [$0], activeEmail: nil, refreshError: nil,
                now: openRouterCapturedAt.addingTimeInterval(300))
        } ?? []
        check("reachability: status renders OpenRouter balance, age, and error — not quota windows",
              openRouterStatus == [
                  "  OPENROUTER  (1 balance)",
                  "  openrouter  BALANCE",
                  "      balance $53.82 · captured 5m ago · ⚠️ scripted OpenRouter probe failure",
              ] && !openRouterStatus.joined(separator: "\n").contains("7d"))
        let boundaryNow = Date(timeIntervalSince1970: 1_800_200_000)
        var boundaryRow = AccountSnapshot(email: "boundary@example.com", nickname: "boundary", plan: "max")
        boundaryRow.fiveHourPct = 40
        boundaryRow.fiveHourResetsAt = boundaryNow.addingTimeInterval(3_600)
        boundaryRow.weeklyPct = 30
        boundaryRow.weeklyResetsAt = boundaryNow.addingTimeInterval(7 * 86_400)
        boundaryRow.capturedAt = boundaryNow.addingTimeInterval(-AccountSnapshot.freshnessTTL - 60)
        let boundaryStatus = statusSectionLines(
            provider: .claude, rows: [boundaryRow], activeEmail: nil, refreshError: nil,
            now: boundaryNow)
        check("reachability: final status uses one pinned clock across trust and snapshot age",
              boundaryStatus.contains { $0.hasSuffix("⚪️") }
              && boundaryStatus.contains { $0.contains("unknown since 16m ago") })
        openRouterStore.seedOpenRouterAccount(
            into: &openRouterAccounts, outcome: .unavailable,
            now: openRouterCapturedAt.addingTimeInterval(300))
        check("openrouter failed refresh preserves balance and capturedAt",
              openRouterAccounts[openRouterKey]?.balanceUSD == 53.82
              && openRouterAccounts[openRouterKey]?.availablePct == orBudget.availablePct
              && openRouterAccounts[openRouterKey]?.capturedAt == openRouterCapturedAt)
        // the key command runs on every refresh; one that never finishes (a
        // dialog, a fingerprint wait) must not hold the refresh.
        let keyStart = Date()
        let slowKey = OpenRouter.runKeyCommand(["/bin/sleep", "5"], timeout: 0.5)
        let keyElapsed = Date().timeIntervalSince(keyStart)
        check("an OpenRouter key command that does not finish is stopped at its timeout",
              slowKey == nil && keyElapsed < 2, "result \(String(describing: slowKey)), \(keyElapsed) s")
        // the timeout stops the whole process tree, not only the direct child.
        let grandchildPidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-grandchild-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: grandchildPidFile) }
        let wrapperResult = OpenRouter.runKeyCommand(
            ["/bin/sh", "-c", "sleep 60 & echo $! > '\(grandchildPidFile)'; wait"], timeout: 0.7)
        let grandchildPid = (try? String(contentsOfFile: grandchildPidFile, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var grandchildGone = false
        if let grandchildPid {
            for _ in 0..<60 where kill(grandchildPid, 0) == 0 { usleep(50_000) }
            grandchildGone = kill(grandchildPid, 0) != 0
        }
        check("a key command's grandchild is killed with its group on timeout",
              wrapperResult == nil && grandchildPid != nil && grandchildGone,
              "result \(String(describing: wrapperResult)), grandchild \(String(describing: grandchildPid)), gone \(grandchildGone)")
        // A descendant in a NEW session escapes the group kill and keeps stdout open. The
        // drain then times out, and the read end of the pipe must still be closed.
        func openDescriptors() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        let descriptorsBefore = openDescriptors()
        // The child must have left the group BEFORE the command ends, or the final group
        // kill reaches it first, the pipe closes and the command succeeds. So the child
        // touches a marker after setsid, and the wrapper waits for it before it prints.
        // The delay before setsid keeps the proof deterministic: without the wait it fails.
        let escapedMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-escaped-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: escapedMarker) }
        let escapeScript = "/usr/bin/perl -MPOSIX -e 'if (!fork) { select(undef,undef,undef,0.3); POSIX::setsid(); "
            + "open(F, \">\", $ARGV[0]); close(F); exec \"sleep\", \"5\" }' '\(escapedMarker)'; "
            + "for n in $(seq 1 100); do [ -e '\(escapedMarker)' ] && break; sleep 0.05; done; echo key"
        let escaped = OpenRouter.runKeyCommand(["/bin/sh", "-c", escapeScript], timeout: 5)
        var descriptorsAfter = openDescriptors()
        for _ in 0..<40 where descriptorsAfter > descriptorsBefore {
            usleep(50_000)
            descriptorsAfter = openDescriptors()
        }
        check("a key command whose descendant escaped the group does not leak the pipe",
              escaped == nil && FileManager.default.fileExists(atPath: escapedMarker) && descriptorsBefore >= 0 && descriptorsAfter <= descriptorsBefore,
              "result \(String(describing: escaped)), descriptors \(descriptorsBefore) to \(descriptorsAfter)")
        // The key command is a user's own program: it inherits nothing of Tower's but the
        // three standard streams. A descriptor opened without close-on-exec proves it.
        let inheritable = open("/dev/null", O_RDONLY)
        let countAboveStderr = OpenRouter.runKeyCommand(
            ["/usr/bin/perl", "-MPOSIX", "-e",
             "print scalar(grep { my @s = POSIX::fstat($_); @s } 3..255)"], timeout: 5)
        if inheritable >= 0 { close(inheritable) }
        check("a key command inherits no descriptor beyond stdin, stdout and stderr",
              inheritable >= 0 && countAboveStderr == "0",
              "descriptor \(inheritable), the command saw \(String(describing: countAboveStderr)) above stderr")
        check("a key command that finishes in time still returns its output",
              OpenRouter.runKeyCommand(["/bin/echo", "sk-test"], timeout: 5)?
                  .trimmingCharacters(in: .whitespacesAndNewlines) == "sk-test")
        openRouterStore.seedOpenRouterAccount(
            into: &openRouterAccounts, outcome: .rejected(401, keyFingerprint: "9f3c", lastSuccessAt: nil),
            now: openRouterCapturedAt.addingTimeInterval(600))
        check("openrouter rejected refresh preserves balance and capturedAt",
              openRouterAccounts[openRouterKey]?.balanceUSD == 53.82
              && openRouterAccounts[openRouterKey]?.availablePct == orBudget.availablePct
              && openRouterAccounts[openRouterKey]?.capturedAt == openRouterCapturedAt
              && openRouterAccounts[openRouterKey]?.lastError?.contains("HTTP 401") == true)
        // The panel starts from the store, so the persisted 401 row must come back as a
        // refusal (a red MONEY row), never `.notConfigured` (no row at all).
        check("openrouter persisted 401 row hydrates the panel as rejected, not hidden",
              OpenRouter.persistedOutcome(
                  from: Array(openRouterAccounts.values), lastSuccessAt: nil)
              == .rejected(401, keyFingerprint: nil, lastSuccessAt: nil))

        // The TypeSafe lane (issue #91) shows a balance the user entered: TypeSafe publishes
        // no billing or usage endpoint, so there is nothing to fetch. Nothing ships by
        // default; with no entry there is no row.
        check("typesafe balance level: 4.99 red, 5.00 amber, 9.99 amber, 10.00 green",
              TypeSafe.balanceLevel(4.99) == .red
              && TypeSafe.balanceLevel(5.00) == .amber
              && TypeSafe.balanceLevel(9.99) == .amber
              && TypeSafe.balanceLevel(10.00) == .green)
        let typeSafeDay = DateFormatter()
        typeSafeDay.locale = Locale(identifier: "en_US_POSIX")
        typeSafeDay.dateFormat = "yyyy-MM-dd HH:mm"
        let typeSafeSuite = "tower-typesafe-selftest-\(UUID().uuidString)"
        let typeSafeDefaults = UserDefaults(suiteName: typeSafeSuite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: typeSafeSuite) }
        check("typesafe ships no balance: no entry, no row",
              TypeSafe.entry(defaults: typeSafeDefaults) == nil
              && typeSafeStatusRowLines(defaults: typeSafeDefaults).isEmpty
              && TypeSafe.reenterHint(defaults: typeSafeDefaults) == nil)
        TypeSafe.enter(12.00, now: typeSafeDay.date(from: "2026-09-18 12:00")!, defaults: typeSafeDefaults)
        // Two local days after the 2026-09-18 entry.
        let typeSafeNow = typeSafeDay.date(from: "2026-09-20 12:00")!
        let typeSafeStatus = typeSafeStatusRowLines(now: typeSafeNow, defaults: typeSafeDefaults)
        check("reachability: status renders the entered typesafe balance, not quota windows",
              typeSafeStatus == [
                  "  credits     BALANCE",
                  "      jev   TypeSafe   balance $12.00 (entered 09-18 · 2d ago), not live",
              ] && !typeSafeStatus.joined(separator: "\n").contains("7d"))
        let typeSafeLate = typeSafeDay.date(from: "2026-09-27 12:00")!
        let staleLines = typeSafeStatusRowLines(now: typeSafeLate, defaults: typeSafeDefaults)
        check("typesafe stale row says how to re-enter",
              staleLines.count == 3 && staleLines[2].contains("tower_config_set typesafe.balanceUSD "))
        TypeSafe.enter(18.40, now: typeSafeLate, defaults: typeSafeDefaults)
        check("typesafe re-entry is dated today and clears the stale hint",
              TypeSafe.entry(defaults: typeSafeDefaults) == TypeSafe.Entry(usd: 18.40, asOf: "2026-09-27")
              && typeSafeStatusRowLines(now: typeSafeLate, defaults: typeSafeDefaults) == [
                  "  credits     BALANCE",
                  "      jev   TypeSafe   balance $18.40 (entered 09-27 · 0d ago), not live",
              ])
        // TypeSafe ships two decision models. Clef has its own key pair and its own day,
        // so entering it leaves the Jev figure alone and adds a second line under the same
        // heading; a stale Clef names its own key, never Jev's.
        check("typesafe clef is absent until entered and leaves jev alone",
              TypeSafe.entry(model: .clef, defaults: typeSafeDefaults) == nil
              && TypeSafe.enteredModels(defaults: typeSafeDefaults) == [.jev])
        TypeSafe.enter(4.20, model: .clef, now: typeSafeDay.date(from: "2026-09-20 09:00")!,
                       defaults: typeSafeDefaults)
        check("typesafe status groups jev and clef under one heading",
              typeSafeStatusRowLines(now: typeSafeLate, defaults: typeSafeDefaults) == [
                  "  credits     BALANCE",
                  "      jev   TypeSafe   balance $18.40 (entered 09-27 · 0d ago), not live",
                  "      clef  Cloudflare balance $4.20 (entered 09-20 · 7d ago), stale, not live",
                  "            read the Cloudflare dashboard (Workers AI), then tower_config_set cloudflare.clef.balanceUSD <usd>",
              ]
              && TypeSafe.entry(defaults: typeSafeDefaults) == TypeSafe.Entry(usd: 18.40, asOf: "2026-09-27"))
        // The MCP payload carries both models; it must still validate against the schema
        // `tower_status` and `tower_config_get` declare, or a strict client drops the call.
        let typeSafeGroup = TowerMCPService.typesafeJSON(now: typeSafeLate, defaults: typeSafeDefaults)
        check("typesafe MCP group validates and reports clef beside jev",
              JSONSchemaCheck.validate(typeSafeGroup, against: TowerMCPService.typesafeGroupSchema).isEmpty
              && typeSafeGroup["balanceUSD"] == .number(18.40)
              && typeSafeGroup["models"]["clef"]["balanceUSD"] == .number(4.20)
              && typeSafeGroup["models"]["clef"]["stale"] == .bool(true)
              && typeSafeGroup["models"]["clef"]["live"] == .bool(false))
        TypeSafe.clearEntry(model: .jev, defaults: typeSafeDefaults)
        check("typesafe group stays while clef alone is entered",
              TypeSafe.enteredModels(defaults: typeSafeDefaults) == [.clef]
              && typeSafeStatusRowLines(now: typeSafeLate, defaults: typeSafeDefaults).count == 3)
        // Clef is Cloudflare's decision model (Workers AI, Jev-API compatible), not a
        // TypeSafe product: every label names its own vendor, a stale Clef points at the
        // Cloudflare dashboard, and the new key is cloudflare.clef.balanceUSD while the old
        // typesafe.clef.balanceUSD still writes the same entry.
        check("clef is Cloudflare's model and jev is TypeSafe's",
              TypeSafe.Model.clef.vendor == "Cloudflare" && TypeSafe.Model.jev.vendor == "TypeSafe")
        check("a stale clef names the Cloudflare dashboard and the cloudflare key",
              TypeSafe.reenterHint(model: .clef, now: typeSafeLate, defaults: typeSafeDefaults)
                  == "read the Cloudflare dashboard (Workers AI), then tower_config_set cloudflare.clef.balanceUSD <usd>")
        check("the folded clef line names Cloudflare, the jev line names TypeSafe",
              TypeSafeCreditRow.foldedLine(model: .clef, now: typeSafeLate, open: false, defaults: typeSafeDefaults)
                  .contains("clef · Cloudflare")
                  && !TypeSafeCreditRow.groupDetail.lowercased().contains("typesafe"))
        let clefEnvDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-clef-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: clefEnvDir) }
        var clefEnv = TowerMCPService.Environment.demo(supportDirectory: clefEnvDir)
        clefEnv.defaults = typeSafeDefaults
        let clefService = TowerMCPService(env: clefEnv)
        let viaNewKey = clefService.configSet(key: "cloudflare.clef.balanceUSD", value: .number(6.50))
        let newKeyEntry = TypeSafe.entry(model: .clef, defaults: typeSafeDefaults)
        let viaOldKey = clefService.configSet(key: "typesafe.clef.balanceUSD", value: .number(7.25))
        check("cloudflare.clef.balanceUSD sets clef, and the old typesafe.clef key still does",
              viaNewKey.isError != true && newKeyEntry?.usd == 6.50
                  && viaOldKey.isError != true && TypeSafe.entry(model: .clef, defaults: typeSafeDefaults)?.usd == 7.25,
              "\(viaNewKey.content) \(viaOldKey.content)")
        let emptyClefSuite = "tower-selftest-clef-empty-\(UUID().uuidString)"
        let emptyClefDefaults = UserDefaults(suiteName: emptyClefSuite)!
        defer { emptyClefDefaults.removePersistentDomain(forName: emptyClefSuite) }
        check("an unentered clef names the cloudflare key, not the old typesafe one",
              TypeSafe.statusRowText(model: .clef, now: typeSafeLate, defaults: emptyClefDefaults)
                  == "no balance entered (tower_config_set cloudflare.clef.balanceUSD <usd>)",
              TypeSafe.statusRowText(model: .clef, now: typeSafeLate, defaults: emptyClefDefaults))
        check("the MCP group names each model's vendor",
              TowerMCPService.typesafeJSON(now: typeSafeLate, defaults: typeSafeDefaults)["models"]["clef"]["vendor"]
                  == .string("Cloudflare"))

        let historyDefaultsName = "tower-openrouter-history-\(UUID().uuidString)"
        let historyDefaults = UserDefaults(suiteName: historyDefaultsName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: historyDefaultsName) }
        let committedFold = Refresher.openRouterFoldCommitted(
            outcome: .ok(OpenRouter.Budget(spent: 46.18, limit: 100)), saveError: nil)
        let observation = Refresher.openRouterObservation(
            outcome: .ok(OpenRouter.Budget(spent: 46.18, limit: 100)),
            accounts: openRouterStore.load(), foldCommitted: committedFold)
        let history = observation.map {
            OpenRouter.History.record($0.budget, now: $0.capturedAt, defaults: historyDefaults)
        }
        check("openrouter history uses the persisted observation timestamp",
              observation?.capturedAt == openRouterCapturedAt
              && history?.last?.capturedAt == openRouterCapturedAt)
        check("openrouter observation rejects an uncommitted fold",
              Refresher.openRouterObservation(
                  outcome: .ok(OpenRouter.Budget(spent: 46.18, limit: 100)),
                  accounts: openRouterStore.load(),
                  foldCommitted: Refresher.openRouterFoldCommitted(
                      outcome: .ok(OpenRouter.Budget(spent: 46.18, limit: 100)),
                      saveError: "disk full")
              ) == nil)
        let failedClaude = Refresher.outcome(
            email: "claude@example.com", gotUsage: false, failure: "Claude API failed", saveError: nil)
        check("openrouter committed fold remains observable after Claude refresh failure",
              !failedClaude.isOK && observation != nil)

        // Named openRouterSnapshot, not openRouterStatus: that name is already the
        // [String] status-line capture declared earlier in this same self-test
        // scope, and Swift rejects the redeclaration (#27).
        var openRouterSnapshot = openRouterRow!
        openRouterSnapshot.lastError = "OpenRouter key refused (HTTP 401)."
        var claudeStatus = AccountSnapshot(email: "c@example.com", nickname: "c", plan: "max")
        claudeStatus.fiveHourPct = 20
        claudeStatus.weeklyPct = 20
        let statusSections = statusSections(active: [claudeStatus, openRouterSnapshot])
        let openRouterSections = statusSections.filter { $0.provider == .openrouter }
        let statusLines = openRouterSections.flatMap {
            statusSectionLines(
                provider: $0.provider, rows: $0.rows, activeEmail: nil, refreshError: nil,
                now: openRouterCapturedAt.addingTimeInterval(300))
        }
        check("openrouter status assembly renders one balance section, not a quota section",
              openRouterSections.count == 1 && statusLines == [
                  "  OPENROUTER  (1 balance)",
                  "  openrouter  BALANCE",
                  "      balance $53.82 · captured 5m ago · ⚠️ OpenRouter key refused (HTTP 401).",
              ], "got \(statusLines)")

        openRouterStore.seedOpenRouterAccount(
            into: &openRouterAccounts, outcome: .notConfigured,
            now: openRouterCapturedAt.addingTimeInterval(900))
        let removed = openRouterStore.save(openRouterAccounts) == nil
            && openRouterStore.load()[openRouterKey] == nil
        let authoritativeBytes = try? Data(contentsOf: openRouterTmp
            .appendingPathComponent("authoritative/accounts.json"))
        let mirrorBytes = try? Data(contentsOf: openRouterMirror)
        check("openrouter notConfigured removes the authoritative row and byte-identical mirror",
              removed && authoritativeBytes == mirrorBytes)
        try? FileManager.default.removeItem(at: openRouterTmp)

        // --- A row from a NEWER build must not cost the roster ------------------------
        //
        // Regression test for the 2026-08-18 wipe. The build that added `cursor` wrote
        // "provider":"cursor" while the previous build was still polling; that one unknown
        // enum value threw, the whole-dictionary `try?` turned it into an empty store, and
        // the next save wrote placeholders over six accounts' history.
        //
        // "provider":"quantum-abacus" stands in for any provider a future build adds. The
        // point is not that string, it is that ONE unreadable row must cost exactly itself.
        let fwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-fwd-\(UUID().uuidString)")
        let fwdStore = Store(dir: fwd)
        let fwdJSON = """
        {"keep@a": {"email":"keep@a","nickname":"keep","plan":"max","scoped":[],\
        "notified":{},"weeklyPct":42},\
        "future@b": {"email":"future@b","nickname":"fut","plan":"pro","scoped":[],\
        "notified":{},"provider":"quantum-abacus"}}
        """
        try? FileManager.default.createDirectory(at: fwd, withIntermediateDirectories: true)
        try? Data(fwdJSON.utf8).write(to: fwd.appendingPathComponent("accounts.json"))

        let survivors = fwdStore.load()
        check("an unknown provider costs only its own row",
              survivors.count == 1 && survivors["keep@a"]?.weeklyPct == 42,
              "got \(survivors.count) rows")

        // And the destructive half must not run: saving here would delete a row this build
        // is merely too old to understand.
        let (fwdAfter, fwdErr) = fwdStore.mutate {
            $0["added@c"] = AccountSnapshot(email: "added@c", nickname: "add", plan: "max")
        }
        check("a mutate over an unreadable row refuses to save", fwdErr != nil)
        check("and says which row it could not read",
              fwdErr?.contains("future@b") == true, "got \(fwdErr ?? "nil")")
        check("while still returning what we do know", fwdAfter.count == 2)

        let onDisk = (try? Data(contentsOf: fwd.appendingPathComponent("accounts.json")))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("the newer build's row is still on disk, untouched",
              onDisk.contains("quantum-abacus"))
        check("and the refused save wrote nothing", !onDisk.contains("added@c"))

        // Total corruption is reported as a casualty too, so a salvageable file is not
        // silently replaced with placeholders.
        try? Data("{not json".utf8).write(to: fwd.appendingPathComponent("accounts.json"))
        check("an unparseable file refuses to save rather than overwriting",
              fwdStore.mutate { _ in }.saveError != nil)

        // An EMPTY store is the genuine first-run case and must still save normally,
        // otherwise a fresh machine could never write its first snapshot.
        try? FileManager.default.removeItem(at: fwd.appendingPathComponent("accounts.json"))
        check("a first run on an empty store still saves",
              fwdStore.mutate { $0["new@d"] = one }.saveError == nil)
        try? FileManager.default.removeItem(at: fwd)

        // root ignores the permission bits, which would invert this assertion under sudo or
        // in a root container, so skip rather than report a phantom failure.
        if getuid() == 0 {
            print("  ⏭  unwritable-store check skipped (running as root)")
        } else {
            let readOnly = FileManager.default.temporaryDirectory
                .appendingPathComponent("tower-selftest-ro-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(
                at: readOnly, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
            check("an unwritable store reports the failure instead of dropping it",
                  Store(dir: readOnly).save(["a@a": one]) != nil)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
            try? FileManager.default.removeItem(at: readOnly)
        }
        try? FileManager.default.removeItem(at: tmp)

        // Mirror pct range validation (#86). Consumers read the stored pct and
        // compute room as 100 minus it, so a value like 734.48 published
        // verbatim renders as a false "no room" on every footer that trusts
        // the file. The writer rejects any pct outside 0 to 100 to nil and
        // records the reason on the row.
        let pctTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-pct-selftest-\(UUID().uuidString)")
        let pctMirror = pctTmp.appendingPathComponent("claude/quota-cache.json")
        let pctStore = Store(dir: pctTmp, mirror: pctMirror, now: { now })

        // The dashboard's two real usage pools rank by their tighter reading. Model-rate
        // costs are deliberately absent: they describe a request price, not either pool.
        let wireSummary = try? JSONDecoder().decode(
            CursorUsage.Summary.self,
            from: ("{\"billingCycleEnd\":\"2033-05-17T12:34:56.000Z\","
                + "\"membershipType\":\"ultra\",\"individualUsage\":{\"plan\":{"
                + "\"autoPercentUsed\":73.004,\"apiPercentUsed\":79.992}}}")
                .data(using: .utf8)!)
        var cursorRow = AccountSnapshot(email: "a@b", nickname: "ab", plan: "ultra")
        if let summary = wireSummary {
            CursorUsage.apply(CursorUsage.Reading(
                email: "a@b", plan: summary.membershipType ?? "?",
                cursorModelsPct: summary.individualUsage?.plan?.autoPercentUsed,
                otherModelsPct: summary.individualUsage?.plan?.apiPercentUsed,
                periodResetsAt: DateParse.parse(summary.billingCycleEnd)), to: &cursorRow, now: now)
        }
        let cursorKey = AccountSnapshot.storeKey(email: "a@b", provider: .cursor)
        let cursorPct = { () -> Double? in
            _ = pctStore.save([cursorKey: cursorRow])
            return pctStore.load()[cursorKey]?.weeklyPct
        }()
        check("cursor row ranks by the tighter real dashboard pool",
              cursorPct.map { abs($0 - 79.992) < 0.001 } == true,
              "got \(cursorPct.map(String.init(describing:)) ?? "nil")")
        check("cursor row carries no error for a clean reading",
              pctStore.load()[cursorKey]?.lastError == nil)
        check("cursor row retains both named dashboard pools",
              pctStore.load()[cursorKey]?.scoped.map(\.label) == ["Cursor Models", "Other Models"]
              && pctStore.load()[cursorKey]?.scoped.map(\.percent) == [73.004, 79.992])
        check("cursor row never renders model-rate cost as a balance",
              pctStore.load()[cursorKey]?.creditBalance == nil)
        check("authoritative and mirror stay byte identical",
              (try? Data(contentsOf: pctTmp.appendingPathComponent("accounts.json")))
                  == (try? Data(contentsOf: pctMirror)))

        // A missing pool is unknown, never replaced with a plan-price calculation.
        var noWindow = AccountSnapshot(email: "a@b", nickname: "ab", plan: "ultra")
        CursorUsage.apply(CursorUsage.Reading(
            email: "a@b", plan: "ultra", cursorModelsPct: 73,
            otherModelsPct: nil, periodResetsAt: upcoming), to: &noWindow, now: now)
        check("a missing dashboard pool publishes unknown with a reason",
              pctStore.save([cursorKey: noWindow]) == nil
              && pctStore.load()[cursorKey]?.weeklyPct == nil
              && pctStore.load()[cursorKey]?.lastError?.contains("dashboard pool") == true,
              "got \(pctStore.load()[cursorKey]?.lastError ?? "nil")")

        // The rule covers every pct field on the row, not only weekly.
        var bad = AccountSnapshot(email: "a@b", nickname: "ab", plan: "max")
        bad.fiveHourPct = 150
        bad.weeklyPct = -3
        bad.scoped = [ScopedLimit(label: "Fable", percent: 250, resetsAt: nil)]
        _ = pctStore.save(["a@b": bad])
        let badRow = pctStore.load()["a@b"]
        check("every pct field is range checked on write",
              badRow?.fiveHourPct == nil && badRow?.weeklyPct == nil
              && badRow?.scoped.first?.percent == nil,
              "got \(badRow?.lastError ?? "nil")")
        var bounds = AccountSnapshot(email: "a@b", nickname: "ab", plan: "max")
        bounds.fiveHourPct = 0
        bounds.weeklyPct = 100
        bounds.scoped = [ScopedLimit(label: "Fable", percent: 100, resetsAt: nil)]
        _ = pctStore.save(["a@b": bounds])
        let boundsRow = pctStore.load()["a@b"]
        check("boundary values 0 and 100 pass through with no reason",
              boundsRow?.fiveHourPct == 0 && boundsRow?.weeklyPct == 100
              && boundsRow?.scoped.first?.percent == 100 && boundsRow?.lastError == nil)
        try? FileManager.default.removeItem(at: pctTmp)

        // --- Threshold bookkeeping without a reset time -------------------------------
        // "<window>@0" is written and then immediately dropped by the pruner, so this used
        // to re-announce on every single poll.
        var noReset = AccountSnapshot(email: "nr@nr", nickname: "nr", plan: "max")
        noReset.fiveHourPct = 85
        noReset.fiveHourResetsAt = nil
        let first = Thresholds.evaluate(&noReset)
        let second = Thresholds.evaluate(&noReset)
        check("no alert without a reset time to key on", first.isEmpty && second.isEmpty)

        // --- Threshold key quantisation ----------------------------------------------
        // The live bug: the operator's real store held BOTH "7d@1785383999" and
        // "7d@1785384000" at level 95, one second apart, for a WEEKLY window. Sub-second
        // jitter in resets_at crossed an integer boundary and re-armed the threshold.
        let jitterA = Date(timeIntervalSince1970: 1_785_383_999.9)
        let jitterB = Date(timeIntervalSince1970: 1_785_384_000.1)
        check("jitter across a second boundary keeps ONE key",
              Thresholds.key("7d", jitterA) == Thresholds.key("7d", jitterB))
        check("genuinely different windows still get different keys",
              Thresholds.key("7d", jitterA)
                  != Thresholds.key("7d", jitterA.addingTimeInterval(3_600)))

        // Pinned clock, NOT Date(): jitterA is a fixed epoch (2026-07-30), and evaluating
        // against the wall clock turned this into a time bomb. The day reality passed the
        // hardcoded reset, `evaluate` correctly saw an already-reset (empty) window and
        // fired nothing, failing the test with the production code blameless.
        let beforeReset = Date(timeIntervalSince1970: 1_785_300_000)
        var wobble = AccountSnapshot(email: "w2@w", nickname: "w2", plan: "max")
        wobble.weeklyPct = 96
        wobble.weeklyResetsAt = jitterA
        let fire1 = Thresholds.evaluate(&wobble, now: beforeReset)
        wobble.weeklyResetsAt = jitterB          // same window, jittered timestamp
        let fire2 = Thresholds.evaluate(&wobble, now: beforeReset)
        check("threshold announces once across the jitter",
              fire1.count == 1 && fire2.isEmpty)

        // Pre-quantisation keys held raw seconds; read back naively they land in year 58000
        // and would never prune. They must be discarded instead.
        check("legacy raw-seconds key is dropped, not kept forever",
              Thresholds.expiry(ofKey: "7d@1785383999") == nil)

        // Card tower-menu-bugs-2026-10-06: count measured seats and disclose uncertainty.
        let menuNow = Date(timeIntervalSince1970: 2_000_000_000)
        var menuSeat = AccountSnapshot(email: "active@example.com", nickname: "ana", plan: "max")
        menuSeat.fiveHourPct = 90
        menuSeat.fiveHourResetsAt = menuNow.addingTimeInterval(3600)
        menuSeat.weeklyPct = 10
        menuSeat.weeklyResetsAt = menuNow.addingTimeInterval(86400)
        menuSeat.capturedAt = menuNow
        var menuSessions = AgentSummary()
        menuSessions.interactive = [
            AgentInfo(kind: "interactive", sessionId: "known", accountEmail: menuSeat.email,
                      accountEvidence: "inferred from statusline reset"),
            AgentInfo(kind: "interactive", sessionId: "other", accountEmail: "other@example.com",
                      accountEvidence: "inferred from statusline reset"),
            AgentInfo(kind: "interactive", sessionId: "unknown"),
            AgentInfo(kind: "interactive", sessionId: "bridge", accountEmail: menuSeat.email,
                      accountEvidence: "bridge owner"),
        ]
        menuSessions.backgroundCount = 2
        let menuBlast = BlastRadius.evaluate(active: menuSeat, sessions: menuSessions, now: menuNow)
        check("menu F2 counts only measured active-seat sessions",
              menuBlast?.riders == 1 && menuBlast?.interactive == 1)
        check("menu F2 shows the unknown count",
              menuBlast?.line == "1 session ride ana at 90 %: rotate before 100 % stops them all · 4 unknown")
        check("menu F2 publishes the unknown count over MCP",
              TowerMCPService.blastRadiusJSON(menuBlast)["unknown"].intValue == 4)
        var unknownSessions = AgentSummary()
        unknownSessions.interactive = (0..<20).map {
            AgentInfo(kind: "interactive", sessionId: "unknown-\($0)")
        }
        let unknownBlast = BlastRadius.evaluate(active: menuSeat, sessions: unknownSessions, now: menuNow)
        check("menu F2 all unknown sessions have no measured riders",
              unknownBlast?.riders == 0 && unknownBlast?.unknown == 20)
        // Review HOLD at e9fc976f: every live session has an unknown owner today, so the
        // level must still follow the live usage or the rotate warning goes silent.
        check("menu F2 all unknown sessions on a hot seat warn and announce",
              unknownBlast?.level == .warn
                && unknownBlast?.line == "0 confirmed, 20 unknown sessions on ana at 90 %: rotate before 100 % may stop them all"
                && unknownBlast?.announces(after: nil) == true)
        var fullSeat = menuSeat
        fullSeat.fiveHourPct = 100
        let fullUnknown = BlastRadius.evaluate(active: fullSeat, sessions: unknownSessions, now: menuNow)
        check("menu F2 all unknown sessions on a full seat read stopped",
              fullUnknown?.level == .stopped
                && fullUnknown?.line == "0 confirmed, 20 unknown sessions may be stopped: ana is at 100 %"
                && fullUnknown?.announces(after: .warn) == true)
        var coolSeat = menuSeat
        coolSeat.fiveHourPct = 71
        let coolUnknown = BlastRadius.evaluate(active: coolSeat, sessions: unknownSessions, now: menuNow)
        check("menu F2 all unknown sessions below the warn mark stay clear and silent",
              coolUnknown?.level == .clear
                && coolUnknown?.line == "0 confirmed, 20 unknown sessions on ana at 71 %"
                && coolUnknown?.announces(after: nil) == false)
        var blankSessions = AgentSummary()
        blankSessions.interactive = [AgentInfo(kind: "interactive", sessionId: "blank", accountEmail: " ")]
        let blankBlast = BlastRadius.evaluate(active: menuSeat, sessions: blankSessions, now: menuNow)
        check("menu F2 empty account is unknown",
              blankBlast?.riders == 0 && blankBlast?.line.contains("1 unknown") == true)
        var switchSeat = menuSeat
        switchSeat.email = "next@example.com"
        switchSeat.nickname = "dee"
        for weekly in [90.0, 91.0, 100.0] {
            switchSeat.weeklyPct = weekly
            check("menu F3 greys switch at 7d \(Int(weekly)) with a reason",
                  SeatBoardRow.switchAction(account: switchSeat,
                                            rest: switchSeat.restingReason(rule: .capped, now: menuNow),
                                            activeEmail: menuSeat.email, now: menuNow)
                    == .disabled("7d at or above 90 %: wait for reset"))
        }
        switchSeat.weeklyPct = 89.9
        check("menu F3 permits switching below 7d 90",
              SeatBoardRow.switchAction(account: switchSeat, rest: nil,
                                        activeEmail: menuSeat.email, now: menuNow) == .enabled)
        check("menu F3 hides switch for the active or unverified seat",
              SeatBoardRow.switchAction(account: switchSeat, rest: nil,
                                        activeEmail: nil, now: menuNow) == .hidden
                && SeatBoardRow.switchAction(account: switchSeat, rest: nil,
                                            activeEmail: switchSeat.email, now: menuNow) == .hidden)
        switchSeat.weeklyPct = 91
        switchSeat.weeklyResetsAt = menuNow.addingTimeInterval(-1)
        check("menu F3 an elapsed 7d window does not block a refresh",
              SeatBoardRow.switchAction(account: switchSeat, rest: nil,
                                        activeEmail: menuSeat.email, now: menuNow) == .enabled)

        // Migration, using the operator's ACTUAL polluted bookkeeping. Both legacy keys
        // describe one window, so they must collapse to a single quantised key at the
        // highest level already announced, and that window must then stay silent.
        let realWorld = ["7d@1785383999": 95.0, "7d@1785384000": 95.0]
        let now2 = Date(timeIntervalSince1970: 1_785_300_000)
        let mig = Thresholds.migrated(realWorld, now: now2)
        check("two jittered legacy keys collapse to one", mig.count == 1)
        check("and keep the level already announced", mig.values.first == 95.0)
        check("migration is idempotent",
              Thresholds.migrated(mig, now: now2) == mig)

        var migrated = AccountSnapshot(email: "mg@mg", nickname: "mg", plan: "max")
        migrated.weeklyPct = 96
        migrated.weeklyResetsAt = Date(timeIntervalSince1970: 1_785_383_999.9)
        migrated.notified = realWorld
        check("a migrated window does NOT re-announce on upgrade",
              Thresholds.evaluate(&migrated, now: now2).isEmpty)
        check("quantised key round-trips to a real date",
              Thresholds.expiry(ofKey: Thresholds.key("7d", jitterA))
                  .map { abs($0.timeIntervalSince(jitterA)) < 60 } == true)

        // --- Scoped limits REPORT, they do not bind ----------------------------------
        // Reversed 2026-08-03. Gating here was principled in the abstract and wrong in
        // fact: settings.json pins `model: opus[1m]`, no configured agent selects fable,
        // and Fable is the only scoped bucket this API returns. Blocking on a model the
        // operator never picks banished accounts that were fine for the model they do pick.
        var capped = AccountSnapshot(email: "c@c", nickname: "c", plan: "max")
        capped.capturedAt = recent
        capped.fiveHourPct = 12
        capped.fiveHourResetsAt = upcoming
        capped.weeklyPct = 12
        capped.weeklyResetsAt = upcoming
        capped.scoped = [ScopedLimit(label: "Fable", percent: 100, resetsAt: upcoming)]
        check("aggregate usage still reads low", capped.trustedUsedPct(now: now) == 12)
        check("an exhausted scoped model NO LONGER blocks the recommendation",
              capped.isRecommendable(now: now))
        check("but it is still reported, so the meter stays truthful",
              capped.exhaustedScoped(now: now) == ["Fable"])
        check("and it does not push the account into the resting drawer",
              capped.restingReason(rule: AccountSnapshot.RestRule.capped, now: now) == nil)

        var partial = AccountSnapshot(email: "p@p", nickname: "p", plan: "max")
        partial.capturedAt = recent
        partial.fiveHourPct = 12
        partial.fiveHourResetsAt = upcoming
        partial.weeklyPct = 12
        partial.weeklyResetsAt = upcoming
        partial.scoped = [ScopedLimit(label: "Fable", percent: 64, resetsAt: upcoming)]
        check("a scoped limit below 100 does not block", partial.isRecommendable(now: now))
        check("and reports nothing exhausted", partial.exhaustedScoped(now: now).isEmpty)

        var staleCap = AccountSnapshot(email: "sc@sc", nickname: "sc", plan: "max")
        staleCap.capturedAt = ancient
        staleCap.scoped = [ScopedLimit(label: "Fable", percent: 100, resetsAt: upcoming)]
        check("a STALE exhausted scoped limit is not asserted as fact",
              staleCap.exhaustedScoped(now: now).isEmpty)

        // --- Menubar glyph -----------------------------------------------------------
        // The healthy state must still carry a glyph. Rendering bare text under 70% made
        // the item unfindable among a screenful of status icons exactly when nothing was
        // wrong, which is how a working app reads as "did you even start it".
        check("healthy shows green", MenubarTitle.glyph(pct: 56, failing: false) == "🟢")
        check("70 and over shows orange", MenubarTitle.glyph(pct: 76, failing: false) == "🟠")
        check("90 and over shows red", MenubarTitle.glyph(pct: 99, failing: false) == "🔴")
        check("boundary 70 is orange", MenubarTitle.glyph(pct: 70, failing: false) == "🟠")
        check("boundary 90 is red", MenubarTitle.glyph(pct: 90, failing: false) == "🔴")
        // Exactly one glyph: the failure marker replaces the light rather than stacking.
        check("failure overrides the light",
              MenubarTitle.glyph(pct: 56, failing: true) == "⚠️")
        check("failure with no number still warns",
              MenubarTitle.glyph(pct: nil, failing: true) == "⚠️")
        check("no number and no failure shows nothing",
              MenubarTitle.glyph(pct: nil, failing: false) == "")

        // ── ranked() ordering ────────────────────────────────────────────────
        // The invariant was documented on `ranked` and pinned by NOTHING, and it
        // broke in the panel on 2026-07-29: a 2-day-stale account outranked two
        // live ones because the popover sorted once at refresh while the rows
        // recomputed against `now` on every render. 47 checks passed throughout.
        func snap(_ nick: String, five: Double?, week: Double?, captured: Date?) -> AccountSnapshot {
            var s = AccountSnapshot(email: "\(nick)@x", nickname: nick, plan: "max")
            s.capturedAt = captured
            s.fiveHourPct = five
            s.fiveHourResetsAt = five == nil ? nil : upcoming
            s.weeklyPct = week
            s.weeklyResetsAt = week == nil ? nil : upcoming
            return s
        }
        let liveBusy = snap("live-busy", five: 100, week: 79, captured: recent)
        let liveFree = snap("live-free", five: 14, week: 24, captured: recent)
        let staleFree = snap("stale-free", five: 0, week: 5, captured: ancient)
        let uncaptured = snap("uncaptured", five: nil, week: nil, captured: nil)

        // The exact shape of the observed bug: a stale account with BETTER numbers
        // must still lose to a live one with worse numbers. Ranking on the figure
        // alone puts the unverifiable reading on top.
        check("a stale account never outranks a live one, even with better numbers",
              AccountSnapshot.ranked(liveBusy, staleFree, now: now)
                  && !AccountSnapshot.ranked(staleFree, liveBusy, now: now))
        check("within the live tier, more headroom sorts first",
              AccountSnapshot.ranked(liveFree, liveBusy, now: now)
                  && !AccountSnapshot.ranked(liveBusy, liveFree, now: now))
        check("a never-captured account sorts last",
              AccountSnapshot.ranked(staleFree, uncaptured, now: now)
                  && !AccountSnapshot.ranked(uncaptured, staleFree, now: now))
        // "cal" vs "eve" differ at char 4 ('1' 0x31 < 'g' 0x67). Equal usage was
        // the real tie in the panel, so the fallback has to be deterministic.
        let tieA = snap("cal", five: 100, week: 21, captured: recent)
        let tieB = snap("eve", five: 100, week: 21, captured: recent)
        check("equal usage falls back to nickname order",
              AccountSnapshot.ranked(tieA, tieB, now: now)
                  && !AccountSnapshot.ranked(tieB, tieA, now: now))
        // The regression itself: order is a function of `now`, so a correct order
        // rots by the clock alone with no new data. This is what the panel cached.
        //
        // These future resets keep the raw readings constant while capture trust expires.
        let farOff = now.addingTimeInterval(30 * 86_400)
        func aging(_ nick: String, pct: Double, capturedAgo: TimeInterval) -> AccountSnapshot {
            var s = AccountSnapshot(email: "\(nick)@x", nickname: nick, plan: "max")
            s.capturedAt = now.addingTimeInterval(-capturedAgo)
            s.fiveHourPct = pct
            s.fiveHourResetsAt = farOff
            s.weeklyPct = pct
            s.weeklyResetsAt = farOff
            return s
        }
        // Fresh but nearly exhausted, versus older but nearly empty.
        let freshBusy = aging("fresh-busy", pct: 100, capturedAgo: 60)
        let agingFree = aging("aging-free", pct: 5, capturedAgo: 20 * 60)
        check("a fresh reading beats a better stale one WHILE it is fresh",
              AccountSnapshot.ranked(freshBusy, agingFree, now: now))
        // 16 minutes on, nothing about the data changed. The fresh one crossed the
        // 15-minute TTL, both are stale, and stable nickname ordering takes over.
        let later = now.addingTimeInterval(16 * 60)
        check("and loses once it ages past the TTL, on the clock alone",
              !AccountSnapshot.ranked(freshBusy, agingFree, now: later))
        check("so a cached sort is wrong by construction, not by bad luck",
              AccountSnapshot.ranked(freshBusy, agingFree, now: now)
                  != AccountSnapshot.ranked(freshBusy, agingFree, now: later))
        check("a full sort puts live-free, live-busy, stale, uncaptured in that order",
              [uncaptured, staleFree, liveBusy, liveFree]
                  .sorted { AccountSnapshot.ranked($0, $1, now: now) }
                  .map(\.nickname) == ["live-free", "live-busy", "stale-free", "uncaptured"])

        // --- Agent probe parsing -----------------------------------------------------
        // Real `claude agents --json` output mixes background rows (status null) with
        // interactive ones, and carries fields this app does not model. The parse must
        // survive both, list interactive busy-first, and count the rest.
        let agentsJSON = Data("""
        [{"kind":"background","status":null,"cwd":"/tmp/x","extra":42},
         {"kind":"interactive","status":"idle","cwd":"/Users/u/coding/beta"},
         {"kind":"interactive","status":"busy","cwd":"/Users/u/coding/alpha"},
         {"kind":"background","status":null,"cwd":"/tmp/y"}]
        """.utf8)
        let summary = AgentProbe.summarize(agentsJSON)
        check("agent probe decodes real-shaped JSON with unknown fields",
              summary != nil)
        check("interactive sessions listed busy-first",
              summary?.interactive.map(\.repoName) == ["alpha", "beta"])
        check("background rows are counted, not listed",
              summary?.backgroundCount == 2)
        check("garbage JSON yields nil, never an empty confident list",
              AgentProbe.summarize(Data("not json".utf8)) == nil)
        // The age clock is pinned against a fixture pair exactly two hours
        // apart, so this cannot rot into a failure when reality passes a
        // hardcoded date.
        let entryDate = ISO8601DateFormatter().date(from: "2026-08-02T03:34:51Z")
        let pinnedNow = ISO8601DateFormatter().date(from: "2026-08-02T05:34:51Z")
        check("row age renders against a pinned clock",
              CLI.age(entryDate, now: pinnedNow ?? Date()) == "2h ago")

        // ── Providers and resting ────────────────────────────────────────────
        let t0 = Date()
        func acct(_ nick: String, five: Double?, week: Double?, agoHours: Double,
                  provider: Provider = .claude) -> AccountSnapshot {
            var a = AccountSnapshot(email: "\(nick)@x", nickname: nick, plan: "max")
            a.provider = provider
            a.fiveHourPct = five
            a.weeklyPct = week
            // Windows still open, so `effective` does not zero them out from under the test.
            a.fiveHourResetsAt = t0.addingTimeInterval(3600)
            a.weeklyResetsAt = t0.addingTimeInterval(86_400)
            a.capturedAt = t0.addingTimeInterval(-agoHours * 3600)
            return a
        }

        check("provider defaults to claude when the key is absent",
              AccountSnapshot(email: "a@b", nickname: "a", plan: "max").kind == .claude)
        check("codex has no 5h window", !Provider.codex.hasFiveHourWindow)
        check("claude has a 5h window", Provider.claude.hasFiveHourWindow)
        check("openrouter is not rankable", !Provider.openrouter.isRankable)
        check("codex store key is namespaced",
              AccountSnapshot.storeKey(email: "a@b", provider: .codex) == "codex:a@b")
        check("claude store key stays the bare email",
              AccountSnapshot.storeKey(email: "a@b", provider: .claude) == "a@b")

        // Rows carry the product mark; the vendor mark is account chrome only.
        // BrandMarkTests owns the source-asset inventory under XCTest; this
        // selftest pins the runtime mapping and bundle render policy.
        check("claude row mark is the real Claude app icon",
              Provider.claude.brandIconName == "claude")
        check("anthropic mark is vendor chrome, never a row mark",
              Provider.claude.vendorIconName == "icon-anthropic"
              && Provider.allCases.allSatisfy { $0.brandIconName != "icon-anthropic" })
        check("codex seats show the ChatGPT app icon",
              Provider.codex.brandIconName == "chatgpt")
        check("agy lane shows the antigravity product mark",
              Provider.agy.brandIconName == "antigravity")
        check("devin lane shows the Devin app icon",
              Provider.devin.brandIconName == "devin")
        // Brand-mark ship mode, both halves of the local|off contract.
        // build-app.sh stamps TowerBrandMarks into Info.plist; a bare
        // `swift build` binary carries no stamp and no bundle. This check only
        // observes Bundle.main, so an installed app and a copied standalone
        // executable never need a source checkout beside them. BrandMarkTests
        // owns the source-asset inventory under XCTest.
        let markMode = Bundle.main.object(forInfoDictionaryKey: "TowerBrandMarks") as? String
        let marksBundled = Bundle.main.path(
            forResource: "claude", ofType: "png", inDirectory: "BrandMarks") != nil
        check("brand-mark stamp matches the bundle contents",
              markMode == nil || (markMode == "local") == marksBundled,
              "stamped \(markMode ?? "none"), BrandMarks dir "
                  + (marksBundled ? "present" : "absent"))
        switch markMode {
        case "local":
            check("local build resolves every real app icon",
                  Provider.allCases.allSatisfy {
                      guard let name = $0.brandIconName, !name.hasPrefix("icon-")
                      else { return true }
                      return $0.bundledAppIcon != nil
                  })
        case "off":
            check("marks-off build bundles no real app icon",
                  Provider.allCases.allSatisfy { $0.bundledAppIcon == nil })
        default:
            break
        }
        // Vendor logos are trademarks and never ship; those rows draw a monogram.
        check("no vendor template logo ships in the bundle",
              [Provider.claude.vendorIconName, Provider.openrouter.brandIconName]
                .compactMap { $0 }
                .allSatisfy {
                    Bundle.main.path(forResource: $0, ofType: "png", inDirectory: "icons") == nil
                })
        // Template marks paint every pixel that is not transparent, so an opaque
        // asset renders as a solid square (the blank OpenRouter tile, 2026-09-27).
        // Checked on the bundled files, so an installed app proves its own assets.
        check("bundled template marks carry transparency",
              [Provider.claude.vendorIconName, Provider.openrouter.brandIconName]
                .compactMap { $0 }
                .compactMap { Bundle.main.path(forResource: $0, ofType: "png", inDirectory: "icons") }
                .allSatisfy { BrandMark.templateMarkHasTransparency(atPath: $0) })
        // The fallback contract both modes rely on: a provider whose real icon
        // is absent still renders a mark, never a blank square. BrandMark's
        // chain ends in the boardMark monogram, so a non-empty monogram is the
        // "never blank" guarantee.
        check("every row falls back to a non-empty mark",
              Provider.allCases.allSatisfy {
                  $0.bundledAppIcon != nil || !$0.boardMark.isEmpty
              })
        check("dense meter names what each Cursor pool means to a lane",
              SegmentedMeter.displayLabel("Cursor Models") == "Auto"
              && SegmentedMeter.displayLabel("Other Models") == "Opus"
              && CursorPool.displayLabel("Cursor Models") == "Auto unmetered"
              && CursorPool.displayLabel("Other Models") == "Opus metered")
        check("stacked pool labels and percentages fit the meter column",
              SegmentedMeter.labelsFit()
              && SegmentedMeter.displayPercent(73) == "73%"
              && SegmentedMeter.displayPercent(nil) == "?")
        check("braille meter steps match the status line",
              BrailleMeterMath.text(percent: 54, cells: 5) == "⣿⣿⣶⣀⣀"
              && BrailleMeterMath.text(percent: 0, cells: 3) == "⣀⣀⣀"
              && BrailleMeterMath.text(percent: 100, cells: 3) == "⣿⣿⣿")
        // Every quota number says which it is (seen 2026-11-04: a bare Codex "0%" was read
        // as "0 % room" by another tool). The panel's pool column is USED, the room column
        // is ROOM, and both headings say so; `tower status` puts the word on every number.
        check("seat board headings name used and room",
              SeatBoard.meterHeading == "used" && SeatBoard.roomHeading == "room")
        var codexZero = AccountSnapshot(email: "c@x", nickname: "cx", plan: "pro")
        codexZero.provider = .codex
        codexZero.capturedAt = Date().addingTimeInterval(-60)
        codexZero.weeklyPct = 0
        codexZero.weeklyResetsAt = Date().addingTimeInterval(3 * 86_400)
        let codexLines = statusRowLines(codexZero, activeEmail: nil, refreshError: nil, now: Date())
        check("tower status says a Codex 0 is used, not room",
              codexLines.contains { $0.contains("7d") && $0.contains("0% used") }, codexLines.joined(separator: " | "))
        var laneRow = AccountSnapshot(email: AgentLane.mirrorEmail(.devin), nickname: "devin", plan: "Pro")
        laneRow.provider = .devin
        laneRow.capturedAt = Date().addingTimeInterval(-60)
        laneRow.scoped = [ScopedLimit(label: "Daily", percent: 35, resetsAt: Date().addingTimeInterval(3600))]
        let laneLines = agentLaneStatusRowLines(laneRow, now: Date())
        check("tower status says a lane window is used",
              laneLines.contains { $0.contains("Daily") && $0.contains("35% used") }, laneLines.joined(separator: " | "))
        // Before the first refresh nothing was attempted, so nothing may read as failed.
        check("fleet lines before the first refresh say not read yet",
              fleetLines(blast: nil, machine: nil, read: .notYet)
                == ["  ❔ Blast radius: not read yet", "  ❔ Machine: load not read yet"])
        check("no active login is not blamed on the session probe",
              fleetLines(blast: nil, machine: nil, read: .done(sessions: true)).first
                == "  ❔ Blast radius: no active Claude login to measure")
        check("an unknown session count is ?, never 0",
              SessionsBoard.heading(nil) == "SESSIONS · ?"
              && SessionsBoard.missingLine(probed: false) == "not read yet")

        // Opening Tower.app is a request to see it: a menu-bar-only app that answers a click
        // with nothing reads as broken, and the menu-bar item can sit behind the notch.
        check("opening Tower.app by hand shows the panel",
              PanelOpenPolicy.showOnLaunch(asLoginItem: false))
        check("a start-at-login launch stays in the menu bar",
              !PanelOpenPolicy.showOnLaunch(asLoginItem: true))
        check("opening Tower.app while it runs shows the panel",
              PanelOpenPolicy.showOnReopen(panelVisible: false))
        check("opening Tower.app while the panel is up keeps it up",
              PanelOpenPolicy.showOnReopen(panelVisible: true))

        // One Tower per login session. A dead pid that Launch Services still lists (a temp
        // build that exited with children alive) is not an instance to hand off to.
        check("a second launch finds the live instance",
              SingleInstance.liveOther(pids: [111, 222], selfPid: 222, alive: { $0 == 111 }) == 111)
        check("a dead Launch Services record is not an instance",
              SingleInstance.liveOther(pids: [16867, 222], selfPid: 222, alive: { _ in false }) == nil)
        check("the only instance is itself",
              SingleInstance.liveOther(pids: [222], selfPid: 222, alive: { _ in true }) == nil)

        // A Keychain refusal is a login fact with a button, never a bare status in red.
        check("a refused seat read names the Re-trust button",
              KeychainRefusal.headerLine(refusedSeats: 3)
                == "🔑 3 remembered seats are locked to an older Tower build: press Re-trust, then Always Allow")
        check("no refused seat, no Keychain line", KeychainRefusal.headerLine(refusedSeats: 0) == nil)
        check("errSecAuthFailed is a signer refusal",
              ClaudeSeatVaultError("x", status: errSecAuthFailed).isSignerRefusal)
        check("errSecInvalidOwnerEdit is a signer refusal",
              ClaudeSeatVaultError("x", status: errSecInvalidOwnerEdit).isSignerRefusal)
        check("a decode failure is not a signer refusal",
              !ClaudeSeatVaultError("x", status: errSecDecode).isSignerRefusal
              && !ClaudeSeatVaultError("x").isSignerRefusal)
        check("a vault that writes beside legacy items never deletes them",
              ClaudeSeatVault.recreateSteps(writesBesideLegacyItems: true) == [.write])
        check("a per-item vault still replaces the refused item",
              ClaudeSeatVault.recreateSteps(writesBesideLegacyItems: false) == [.delete, .write])
        // Codex review of 1216598: a refused bundle with no legacy items left an empty
        // unreadable list, so the launch cache never asked again.
        var refusedOnly = ClaudeSeatKeychainReadout()
        refusedOnly.bundleRefused = true
        check("a refused bundle stays unanswered, so the launch cache retries it",
              refusedOnly.isUnanswered)
        check("a clean readout is answered", !ClaudeSeatKeychainReadout().isUnanswered)
        check("a Re-trust that is refused again names the dialog answer",
              ClaudeSeatVault.retrustRefusalMessage
                == "The Keychain still refuses this Tower build: press Re-trust and choose Always Allow")

        // The header age never says "never" over rows that carry readings.
        check("failed first refresh over cached rows reads cached",
              PanelHeaderAge.text(lastRefresh: nil, probed: true, failed: true, hasRows: true, now: t0) == "cached")
        check("failed first refresh with no rows reads never",
              PanelHeaderAge.text(lastRefresh: nil, probed: true, failed: true, hasRows: false, now: t0) == "never")

        // The blast dot follows the meter colours: 73 % is amber on the meter, so not green.
        check("blast radius at 73 % is amber", CLI.blastIcon(level: .clear, percent: 73) == "🟠")
        check("blast radius at 30 % is green", CLI.blastIcon(level: .clear, percent: 30) == "🟢")
        check("blast radius warn keeps its warning", CLI.blastIcon(level: .warn, percent: 88) == "⚠️")
        check("blast radius with no reading is unknown", CLI.blastIcon(level: .unknown, percent: nil) == "❔")

        // The stale fold is a control with words, not a "- 7" that reads as a stray row.
        check("folded stale seats read as a control",
              SeatBoard.staleLine(count: 7, open: false) == "▸ Show 7 stale seats")
        check("open stale seats read as a control",
              SeatBoard.staleLine(count: 7, open: true) == "▾ Hide 7 stale seats")

        // One unknown state: every seat Tower cannot judge now says "unknown" and why.
        check("one unknown wording", SeatUsagePresentation.unknownText("5h not reported") == "unknown · 5h not reported")

        let rHealthy = acct("ok", five: 32, week: 91, agoHours: 0)
        let rCapped  = acct("cap", five: 99, week: 40, agoHours: 0)
        let rStale   = acct("old", five: 10, week: 10, agoHours: 120)
        let rBoth    = acct("bad", five: 98, week: 93, agoHours: 120)

        check("healthy account does not rest", rHealthy.restingReason(now: t0) == nil)
        check("capped rests under .either", rCapped.restingReason(rule: AccountSnapshot.RestRule.either, now: t0)?.isCapped == true)
        check("capped does NOT rest under .stale", rCapped.restingReason(rule: AccountSnapshot.RestRule.stale, now: t0) == nil)
        check("stale rests under .either", rStale.restingReason(rule: AccountSnapshot.RestRule.either, now: t0)?.isStale == true)
        check("stale does NOT rest under .capped", rStale.restingReason(rule: AccountSnapshot.RestRule.capped, now: t0) == nil)
        check("both failures are reported together",
              rBoth.restingReason(now: t0) == .cappedAndStale(98, 120 * 3600))
        check("94% is not capped, 95% is",
              acct("a", five: 94, week: 0, agoHours: 0).restingReason(rule: AccountSnapshot.RestRule.capped, now: t0) == nil
              && acct("b", five: 95, week: 0, agoHours: 0).restingReason(rule: AccountSnapshot.RestRule.capped, now: t0) != nil)

        // Keep the saved resting preference compatible. Partition applies capture trust
        // first, so this legacy threshold never admits unknown room into its active list.
        check("legacy resting preference alone allows an hour-old capture",
              acct("h", five: 10, week: 10, agoHours: 1).restingReason(rule: AccountSnapshot.RestRule.stale, now: t0) == nil)
        check("resting TTL is a day, not the 15-minute freshness TTL",
              AccountSnapshot.restingStaleTTL == 24 * 3600
              && AccountSnapshot.freshnessTTL == 15 * 60)

        var codexSnap = acct("cx", five: nil, week: 6, agoHours: 0, provider: .codex)
        codexSnap.fiveHourResetsAt = nil
        let part = AccountSnapshot.partition([rHealthy, rCapped, rStale, rBoth, codexSnap], now: t0)
        check("partition keeps only actionable rows",
              part.active.map { $0.nickname }.sorted() == ["cx", "ok"],
              "got \(part.active.map { $0.nickname }.sorted())")
        check("partition collects the rest with reasons",
              part.resting.count == 3, "got \(part.resting.count)")
        check("never-captured rests rather than reading as 0%",
              AccountSnapshot(email: "n@n", nickname: "n", plan: "?")
                  .restingReason(now: t0) == .neverCaptured)

        // Codex wire shape, copied verbatim from a real payload (2026-08-03). Written to a
        // temp file so the REAL reader path runs, not merely the Decodable conformance.
        let codexLine = "{\"payload\":{\"rate_limits\":{\"limit_id\":\"codex\","
            + "\"primary\":{\"used_percent\":6.0,\"window_minutes\":10080,"
            + "\"resets_at\":1786164329},\"secondary\":null,"
            + "\"credits\":{\"has_credits\":false,\"unlimited\":false,\"balance\":\"0\"},"
            + "\"plan_type\":\"prolite\"}}}"
        let cxTmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rollout-selftest.jsonl")
        // A leading line with no rate_limits, and a trailing one with them: the reader must
        // scan from the end and pick the LAST payload, which is the current one.
        try? ("{\"payload\":{}}\n" + codexLine + "\n")
            .write(to: cxTmp, atomically: true, encoding: .utf8)
        let decoded = CodexReader.lastRateLimits(in: cxTmp)
        try? FileManager.default.removeItem(at: cxTmp)
        check("codex payload decodes from a real rollout line", decoded != nil)
        check("codex primary is a 7d window", decoded?.primary?.window_minutes == 10080)
        check("codex used_percent survives", decoded?.primary?.used_percent == 6.0)
        check("codex secondary is absent, so no 5h meter", decoded?.secondary == nil)
        check("codex resets_at is epoch seconds, not ISO",
              decoded?.primary?.resetDate == Date(timeIntervalSince1970: 1786164329))
        check("codex plan_type read", decoded?.plan_type == "prolite")

        var applied = AccountSnapshot(email: "c@c", nickname: "c", plan: "?")
        if let d = decoded {
            CodexReader.apply(CodexReader.Reading(limits: d, capturedAt: t0), to: &applied)
        }
        check("codex maps onto the weekly window", applied.weeklyPct == 6.0)
        check("codex leaves the 5h window empty", applied.fiveHourPct == nil)
        check("codex with no credits reports no balance", applied.creditBalance == nil)

        // ── Resting drawer: age precision and time-gating ────────────────────
        // Live 2026-08-03: ben was 47.5h stale and rendered "stale 1d", understating its own
        // age by nearly a day, in the one signal whose job is to say "trust this less".
        check("47h does not truncate to 1d",
              AccountSnapshot.RestReason.stale(47.5 * 3600).text == "stale 1d23h",
              "got \(AccountSnapshot.RestReason.stale(47.5 * 3600).text)")
        check("an exact day has no dangling hours",
              AccountSnapshot.RestReason.stale(48 * 3600).text == "stale 2d")
        check("under a day still reads in hours",
              AccountSnapshot.RestReason.stale(5 * 3600).text == "stale 5h")
        check("under an hour reads in minutes",
              AccountSnapshot.RestReason.stale(300).text == "stale 5m")
        check("a combined reason carries the precise age too",
              AccountSnapshot.RestReason.cappedAndStale(99, 41.8 * 3600).text
                  == "capped 99% · stale 1d17h",
              "got \(AccountSnapshot.RestReason.cappedAndStale(99, 41.8 * 3600).text)")

        // Only a capped row is waiting on a clock. ben sat at 91% weekly with its 5h already
        // reset, so it was usable immediately, yet the drawer advertised "opens Aug 5 02:00".
        check("a capped row is time-gated", AccountSnapshot.RestReason.capped(96).isTimeGated)
        check("a stale row is NOT time-gated",
              !AccountSnapshot.RestReason.stale(48 * 3600).isTimeGated)
        check("a never-captured row is NOT time-gated",
              !AccountSnapshot.RestReason.neverCaptured.isTimeGated)
        check("capped-and-stale is still time-gated",
              AccountSnapshot.RestReason.cappedAndStale(99, 48 * 3600).isTimeGated)

        // Actionable rows lead the drawer.
        let gatedRow = acct("gated", five: 10, week: 99, agoHours: 0)
        let refreshRow = acct("refresh", five: 10, week: 10, agoHours: 48)
        let order = AccountSnapshot.partition([gatedRow, refreshRow], now: t0).resting
        check("both rows rest", order.count == 2)
        check("the refreshable row sorts above the one you can only wait out",
              order.first?.0.nickname == "refresh", "got \(order.map { $0.0.nickname })")

        // ── Declared-roster reconciliation ───────────────────────────────────
        // The on-disk list WINS over the constant, so editing the constant alone changes
        // nothing on a machine that has already run the app. ana lingered for exactly this
        // reason until the reconcile step was added.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hqlimits-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpStore = Store(dir: tmpDir)
        // Roster + retirement are both DATA on disk now, not constants in source.
        // A pre-flip file: carries an account that has since been retired, plus one
        // the operator added by hand.
        let oldList = ["a-gross@example.com", "retired-gross@example.com",
                       "b-gross@example.com", "someone-i-added@example.com"]
        try? JSONEncoder().encode(oldList)
            .write(to: tmpStore.declaredFile, options: .atomic)
        try? JSONEncoder().encode(["retired-gross@example.com"])
            .write(to: tmpStore.retiredFile, options: .atomic)
        var seeded: [String: AccountSnapshot] = [
            "retired-gross@example.com": AccountSnapshot(
                email: "retired-gross@example.com", nickname: "ret", plan: "max"),
        ]
        tmpStore.seedDeclaredAccounts(into: &seeded)
        let after = (try? JSONDecoder().decode(
            [String].self, from: Data(contentsOf: tmpStore.declaredFile))) ?? []
        check("retirement is read from disk, not compiled in",
              tmpStore.retiredEmails == ["retired-gross@example.com"])
        check("a retired account is dropped from the declared file",
              !after.contains("retired-gross@example.com"), "got \(after)")
        check("and its existing snapshot is evicted, not left to linger",
              seeded["retired-gross@example.com"] == nil)
        check("a hand-added account survives reconciliation",
              after.contains("someone-i-added@example.com"))
        check("the surviving roster is exactly the non-retired entries",
              after.count == 3, "got \(after.count): \(after)")
        // The invariant this whole change exists to protect: no real address may be
        // reintroduced as a compiled-in default.
        check("no roster is hardcoded in source",
              tmpStore.retiredEmails.isEmpty == false && after.allSatisfy { $0.hasSuffix("@example.com") })
        try? FileManager.default.removeItem(at: tmpDir)

        // ── Advice: staying is not the same answer as switching ──────────────
        // The first version printed the best account unconditionally, so it spent most of
        // its life saying "use eve" while the active marker already sat on eve.
        let advHealthy = acct("ok", five: 32, week: 40, agoHours: 0)
        let advSecond  = acct("two", five: 50, week: 50, agoHours: 0)
        let advCapped  = acct("full", five: 99, week: 99, agoHours: 0)

        let onBest = AccountSnapshot.advise(
            activeEmail: advHealthy.email, accounts: [advHealthy, advSecond], now: t0)
        check("already on the best account advises STAY",
              onBest == .stay(nick: "ok", pct: 40, next: "two"), "got \(onBest)")
        check("stay is not actionable, so there is no command", onBest.command == nil)

        let onWorse = AccountSnapshot.advise(
            activeEmail: advSecond.email, accounts: [advHealthy, advSecond], now: t0)
        check("on a worse account advises SWITCH",
              onWorse == .switchTo(nick: "ok", pct: 40, via: nil), "got \(onWorse)")
        check("switch carries the exact command to run",
              onWorse.command == "/login", "got \(onWorse.command ?? "nil")")

        let mappedProfiles = [advHealthy.email: profile("eve"), advSecond.email: profile("fay")]
        let mappedSwitch = AccountSnapshot.advise(
            activeEmail: advSecond.email,
            accounts: [advHealthy, advSecond],
            switchProfiles: mappedProfiles,
            now: t0)
        check("switch advice carries the Chrome profile to sign in through",
              mappedSwitch.chromeProfile == profile("eve"),
              "got \(mappedSwitch.chromeProfile?.label ?? "nil")")

        // The account WITHOUT a profile (advHealthy, the roomiest) must never be named, and
        // the switchable one must still be offered when it is a genuine improvement.
        //
        // This case used to sit on advHealthy and expect "switch to fay" — i.e. it asserted a
        // move from 40% used to 50% used. That expectation was the 2026-08-16 bug written
        // down as a test: the only switchable account is not automatically a better one. The
        // active account is now the worst of the three, so a switch is real progress and the
        // original intent (never name an unswitchable account) is still what is measured.
        let advWorst = acct("worst", five: 70, week: 70, agoHours: 0)
        let onlySecondSwitchable = AccountSnapshot.advise(
            activeEmail: advWorst.email,
            accounts: [advHealthy, advSecond, advWorst],
            switchProfiles: [advSecond.email: profile("fay")],
            now: t0)
        check("an account without a local switch profile is never recommended",
              onlySecondSwitchable.chromeProfile == profile("fay"),
              "got \(onlySecondSwitchable.chromeProfile?.label ?? "nil")")

        let noneLeft = AccountSnapshot.advise(
            activeEmail: advCapped.email, accounts: [advCapped], now: t0)
        check("everything capped advises ALL RESTING",
              noneLeft == .allResting(first: advCapped.weeklyResetsAt), "got \(noneLeft)")
        let soloBest = AccountSnapshot.advise(
            activeEmail: advHealthy.email, accounts: [advHealthy], now: t0)
        check("a lone healthy account still stays, with no runner-up",
              soloBest == .stay(nick: "ok", pct: 40, next: nil), "got \(soloBest)")

        var advCodex = acct("cxx", five: nil, week: 1, agoHours: 0, provider: .codex)
        advCodex.fiveHourResetsAt = nil
        let codexIgnored = AccountSnapshot.advise(
            activeEmail: advCapped.email, accounts: [advCapped, advCodex], now: t0)
        check("codex is never advised, however roomy",
              codexIgnored == .allResting(first: advCapped.weeklyResetsAt), "got \(codexIgnored)")

        // ── Session grouping ─────────────────────────────────────────────────
        func agent(_ cwd: String, busy: Bool = false) -> AgentInfo {
            AgentInfo(kind: "interactive", status: busy ? "busy" : "idle", cwd: cwd)
        }
        var sum = AgentSummary()
        sum.interactive = [
            agent("/a/platform", busy: true), agent("/a/platform"),
            agent("/w1/shaked-client-artifacts"), agent("/w2/shaked-client-artifacts"),
            agent("/a/core"),
        ]
        let gs = sum.groups
        check("sessions in ONE directory collapse to a single row",
              gs.filter { $0.label.hasSuffix("platform") }.count == 1,
              "got \(gs.map(\.label))")
        check("the collapsed row carries a count", gs.first { $0.label == "platform" }?.count == 2)
        check("a group is busy when ANY of its sessions is",
              gs.first { $0.label == "platform" }?.busy == true)
        check("same name in DIFFERENT paths stays two rows",
              gs.filter { $0.label.hasSuffix("shaked-client-artifacts") }.count == 2)
        check("and gains its parent directory to disambiguate",
              gs.contains { $0.label == "w1/shaked-client-artifacts" }
              && gs.contains { $0.label == "w2/shaked-client-artifacts" },
              "got \(gs.map(\.label))")
        check("a unique name is left alone", gs.contains { $0.label == "core" })
        check("×N suffix only when it means something",
              gs.first { $0.label == "platform" }?.suffix == " ×2"
              && gs.first { $0.label == "core" }?.suffix == "")
        check("five raw sessions render as four rows", gs.count == 4, "got \(gs.count)")

        // A window the provider does not have must not drag trust down. Live 2026-08-03 a
        // Codex row captured seconds earlier read "just now (stale, not counted)".
        var cxTrust = AccountSnapshot(email: "x@x", nickname: "x", plan: "prolite")
        cxTrust.provider = .codex
        cxTrust.weeklyPct = 8
        cxTrust.weeklyResetsAt = t0.addingTimeInterval(5 * 86_400)
        cxTrust.capturedAt = t0.addingTimeInterval(-30)
        check("a codex row with no 5h window is still live",
              cxTrust.worstTrust(now: t0) == .live)
        check("a fresh codex row is recommendable", cxTrust.isRecommendable(now: t0))
        var cxAsClaude = cxTrust
        cxAsClaude.provider = .claude
        check("the same row as claude is NOT live, because its 5h is genuinely unknown",
              cxAsClaude.worstTrust(now: t0) == .unknown)

        // `reopening` must name when the account is USABLE, not when any window turns over.
        var bind = AccountSnapshot(email: "b@b", nickname: "b", plan: "max")
        bind.capturedAt = t0
        bind.fiveHourPct = 55
        bind.fiveHourResetsAt = t0.addingTimeInterval(600)          // soon, but not binding
        bind.weeklyPct = 96
        bind.weeklyResetsAt = t0.addingTimeInterval(3 * 86_400)     // the real constraint
        check("reopening skips a non-binding window",
              AccountSnapshot.reopening(bind, now: t0) == bind.weeklyResetsAt)
        var bothCapped = bind
        bothCapped.fiveHourPct = 99
        check("when both windows are capped, the LATER one governs",
              AccountSnapshot.reopening(bothCapped, now: t0) == bothCapped.weeklyResetsAt)
        var noneCapped = bind
        noneCapped.weeklyPct = 10
        check("with nothing capped the soonest reset is the honest answer",
              AccountSnapshot.reopening(noneCapped, now: t0) == noneCapped.fiveHourResetsAt)

        // Round-trip guards for the backward-compatibility claim on `provider`. A snapshot
        // that loses its provider on save reads back as Claude and resurrects the phantom
        // 5h meter, so this is load-bearing rather than pedantic.
        var pv = AccountSnapshot(email: "p@p", nickname: "p", plan: "x")
        pv.provider = .codex
        let pvData = (try? JSONEncoder().encode(pv)) ?? Data()
        let pvJSON = String(data: pvData, encoding: .utf8) ?? ""
        check("provider is written to disk", pvJSON.contains("\"provider\":\"codex\""),
              "got \(pvJSON)")
        check("provider survives a round trip",
              (try? JSONDecoder().decode(AccountSnapshot.self, from: pvData))?.kind == .codex)
        let legacyJSON = "{\"email\":\"l@l\",\"nickname\":\"l\",\"plan\":\"max\","
            + "\"scoped\":[],\"notified\":{}}"
        let legacy = try? JSONDecoder().decode(
            AccountSnapshot.self, from: legacyJSON.data(using: .utf8)!)
        check("a pre-provider snapshot still decodes", legacy != nil)
        check("a pre-provider snapshot reads as claude", legacy?.kind == .claude)

        check("JWT payload decodes base64url without padding",
              (CodexAuth.decodeJWTPayload("x.eyJlbWFpbCI6ImFAYiJ9.y")?["email"] as? String) == "a@b")

        // MARK: Cursor

        // The whole point of the row is that a monthly allowance is not a week.
        check("cursor's primary window is a month, not 7d",
              Provider.cursor.primaryWindowLabel == "month")
        check("claude and codex still say 7d",
              Provider.claude.primaryWindowLabel == "7d"
              && Provider.codex.primaryWindowLabel == "7d")
        check("cursor has no 5h window", !Provider.cursor.hasFiveHourWindow)
        check("cursor is rankable, because credits do refill", Provider.cursor.isRankable)
        check("cursor store key is namespaced",
              AccountSnapshot.storeKey(email: "a@b", provider: .cursor) == "cursor:a@b")

        // Cursor's dashboard owns the two readings and the reset, so neither needs a
        // plan-price denominator inferred by Tower.
        let cursorReading = CursorUsage.Reading(
            email: "a@b", plan: "ultra", cursorModelsPct: 73, otherModelsPct: 80,
            periodResetsAt: t0.addingTimeInterval(86_400))
        check("cursor ranks by the tighter dashboard pool", cursorReading.bindingPct == 80)
        check("one absent pool makes cursor rank unknown",
              CursorUsage.Reading(email: "a@b", plan: "ultra", cursorModelsPct: 73,
                                  otherModelsPct: nil, periodResetsAt: nil).bindingPct == nil)
        check("out-of-range dashboard data is unknown, not clamped",
              CursorUsage.Reading(email: "a@b", plan: "ultra", cursorModelsPct: 101,
                                  otherModelsPct: 80, periodResetsAt: nil).bindingPct == nil)

        var cursorSnap = acct("cur", five: nil, week: nil, agoHours: 0)
        CursorUsage.apply(cursorReading, to: &cursorSnap, now: t0)
        check("cursor maps the tighter pool onto the primary window", cursorSnap.weeklyPct == 80)
        check("cursor leaves the 5h window empty", cursorSnap.fiveHourPct == nil)
        check("cursor keeps its two dashboard pools distinct",
              cursorSnap.scoped.map(\.label) == ["Cursor Models", "Other Models"]
              && cursorSnap.scoped.map(\.percent) == [73, 80])
        check("cursor does not show model-rate cost as a balance", cursorSnap.creditBalance == nil)
        check("cursor carries the period reset",
              cursorSnap.weeklyResetsAt == t0.addingTimeInterval(86_400))

        // A single measured pool stays visible, while the ranker correctly refuses to guess.
        var noCeiling = acct("cur2", five: nil, week: nil, agoHours: 0)
        CursorUsage.apply(
            CursorUsage.Reading(email: "a@b", plan: "ultra", cursorModelsPct: 73,
                                otherModelsPct: nil, periodResetsAt: nil),
            to: &noCeiling, now: t0)
        check("a partial dashboard reading keeps the known pool",
              noCeiling.scoped.map(\.percent) == [73, nil])
        check("a partial dashboard reading does not rank", noCeiling.weeklyPct == nil)

        let summaryWire = "{\"billingCycleEnd\":\"2033-05-17T12:34:56.000Z\","
            + "\"membershipType\":\"ultra\",\"individualUsage\":{\"plan\":{"
            + "\"autoPercentUsed\":73.004,\"apiPercentUsed\":79.992},"
            + "\"onDemand\":{\"enabled\":false}}}"
        let cursorSummary = try? JSONDecoder().decode(
            CursorUsage.Summary.self, from: summaryWire.data(using: .utf8)!)
        check("usage-summary decodes both dashboard pools",
              cursorSummary?.individualUsage?.plan?.autoPercentUsed == 73.004
              && cursorSummary?.individualUsage?.plan?.apiPercentUsed == 79.992)
        check("usage-summary retains the dashboard reset", cursorSummary?.billingCycleEnd != nil)

        check("cursor outcomes tell refusal from absence",
              CursorUsage.Outcome.rejected(401) != CursorUsage.Outcome.notConfigured
              && CursorUsage.Outcome.unavailable != CursorUsage.Outcome.notConfigured)

        // No Cursor install must be silence, not a broken row.
        check("no cursor install yields no label",
              CursorAuth.label(home: URL(fileURLWithPath: "/nonexistent")) == nil)
        check("a missing state db reads as nil, not as an empty string",
              CursorAuth.read("cursorAuth/accessToken",
                              db: URL(fileURLWithPath: "/nonexistent/state.vscdb")) == nil)

        // --- Tower's own Cursor sign-in ---------------------------------------------------
        // The token item is never written into an existing item (another app could have
        // created it first with an access list it controls): delete, then add a fresh one
        // whose access list trusts Tower only; no access list means nothing is written.
        do {
            final class KeychainLog: @unchecked Sendable { var calls: [String] = []; var added: [String: Any] = [:] }
            let log = KeychainLog()
            var store = KeychainCursorTokenStore()
            var dummyAccess: SecAccess?
            _ = SecAccessCreate("tower-selftest" as CFString, nil, &dummyAccess)
            store.ops = .init(delete: { _ in log.calls.append("delete"); return errSecItemNotFound },
                              add: { q in log.calls.append("add"); log.added = q; return errSecSuccess },
                              makeAccess: { dummyAccess })
            let saved = store.save(CursorSignIn.Tokens(accessToken: "cur_FAKE", refreshToken: "cur_FAKE"))
            check("cursor token save deletes any existing item, then adds a fresh one",
                  saved && log.calls == ["delete", "add"], "\(log.calls)")
            check("cursor token item is added with Tower's own access list",
                  log.added[kSecAttrAccess as String] != nil)
            let blocked = KeychainLog()
            var noAccess = KeychainCursorTokenStore()
            noAccess.ops = .init(delete: { _ in blocked.calls.append("delete"); return errSecSuccess },
                                 add: { _ in blocked.calls.append("add"); return errSecSuccess },
                                 makeAccess: { nil })
            check("a failed random draw makes no PKCE pair (never a zero-byte verifier)",
                  CursorSignIn.newPKCE(fill: { _ in errSecAllocate }) == nil
                      && CursorSignIn.newPKCE(fill: { bytes in
                          for i in bytes.indices { bytes[i] = UInt8(i) }; return errSecSuccess }) != nil)
            check("cursor token save writes nothing without a Tower access list (fails closed)",
                  !noAccess.save(CursorSignIn.Tokens(accessToken: "cur_FAKE", refreshToken: "cur_FAKE"))
                      && blocked.calls.isEmpty, "\(blocked.calls)")
        }
        // Cursor's app now stores an opaque value that the usage route refuses, so Tower keeps
        // its own sign-in (PKCE browser login, a JWT in a Tower-owned Keychain item) and never
        // sends anything it reads from the Cursor app. Every reply below is invented.
        do {
            // RFC 7636 appendix B vector.
            check("cursor sign-in PKCE challenge is S256 of the verifier",
                  CursorSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                      == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
            let pair = CursorSignIn.pkce(random: Array(0..<32))
            check("cursor sign-in PKCE pair is base64url and its challenge matches",
                  pair.verifier.count == 43 && !pair.verifier.contains("=") && !pair.verifier.contains("+")
                      && pair.challenge == CursorSignIn.challenge(for: pair.verifier))
            let authorize = URLComponents(url: CursorSignIn.authorizeURL(challenge: pair.challenge, uuid: "u-1"),
                                          resolvingAgainstBaseURL: false)
            let q = Dictionary(uniqueKeysWithValues: (authorize?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            check("cursor sign-in opens loginDeepControl with challenge, uuid, mode and target",
                  authorize?.host == "cursor.com" && authorize?.path == "/loginDeepControl"
                      && q == ["challenge": pair.challenge, "uuid": "u-1", "mode": "login", "redirectTarget": "cli"])
            let pollURL = URLComponents(url: CursorSignIn.pollRequest(uuid: "u-1", verifier: pair.verifier).url!,
                                        resolvingAgainstBaseURL: false)
            check("cursor sign-in polls auth/poll with uuid and verifier",
                  pollURL?.host == "api2.cursor.sh" && pollURL?.path == "/auth/poll"
                      && Set((pollURL?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" })
                          == ["uuid=u-1", "verifier=\(pair.verifier)"])
            let pairJSON = #"{"accessToken":"acc-FAKE","refreshToken":"ref-FAKE"}"#
            check("cursor sign-in poll: 404 and 202 wait, 200 with both tokens completes, others fail",
                  CursorSignIn.pollStep(status: 404, body: Data()) == .pending
                      && CursorSignIn.pollStep(status: 202, body: Data()) == .pending
                      && CursorSignIn.pollStep(status: 200, body: Data(pairJSON.utf8))
                          == .complete(.init(accessToken: "acc-FAKE", refreshToken: "ref-FAKE"))
                      && CursorSignIn.pollStep(status: 200, body: Data(#"{"accessToken":"acc-FAKE"}"#.utf8)) != .pending
                      && CursorSignIn.pollStep(status: 500, body: Data()) != .pending)
            let pollHTTP = ScriptedCursorHTTP([(404, ""), (202, ""), (200, pairJSON)])
            let signed = AsyncBlock.run {
                await CursorSignIn.poll(uuid: "u-1", verifier: pair.verifier, http: pollHTTP, sleep: { _ in })
            }
            check("cursor sign-in poll completes after pending answers",
                  signed == .signedIn(.init(accessToken: "acc-FAKE", refreshToken: "ref-FAKE"))
                      && pollHTTP.requests.count == 3)
            final class FakeClock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000_000) }
            let clock = FakeClock()
            let foreverPending = ScriptedCursorHTTP(Array(repeating: (404, ""), count: 400))
            let timedOut = AsyncBlock.run {
                await CursorSignIn.poll(uuid: "u-1", verifier: pair.verifier, http: foreverPending,
                                        now: { clock.t }, sleep: { s in clock.t = clock.t.addingTimeInterval(s) })
            }
            check("cursor sign-in poll gives up after 300 s", timedOut == .timedOut
                  && foreverPending.requests.count >= 150 && foreverPending.requests.count <= 151,
                  "\(timedOut) after \(foreverPending.requests.count) polls")

            // Renewal a week before the 60 day JWT expires; shouldLogout ends the sign-in.
            let renewNow = Date(timeIntervalSince1970: 2_000_000_000)
            let soon = FakeJWT.make(["sub": "user_FAKE", "exp": renewNow.timeIntervalSince1970 + 3 * 86_400])
            let later = FakeJWT.make(["sub": "user_FAKE", "exp": renewNow.timeIntervalSince1970 + 30 * 86_400])
            check("cursor sign-in renews a JWT that expires within 7 days, not one with 30 left",
                  CursorSignIn.needsRenewal(.init(accessToken: soon, refreshToken: soon), now: renewNow)
                      && !CursorSignIn.needsRenewal(.init(accessToken: later, refreshToken: later), now: renewNow)
                      && !CursorSignIn.needsRenewal(.init(accessToken: "opaque", refreshToken: "opaque"), now: renewNow))
            let renew = CursorSignIn.renewRequest(refreshToken: "ref-FAKE")
            let renewBody = (try? JSONSerialization.jsonObject(with: renew.httpBody ?? Data())) as? [String: String]
            check("cursor sign-in renewal posts the refresh token to oauth/token",
                  renew.url == CursorSignIn.tokenURL && renew.httpMethod == "POST"
                      && renewBody?["grant_type"] == "refresh_token" && renewBody?["refresh_token"] == "ref-FAKE"
                      && renewBody?["client_id"] == CursorSignIn.clientID && !CursorSignIn.clientID.contains("__"))
            check("cursor sign-in renewal: a new access token also becomes the refresh token; shouldLogout ends it",
                  CursorSignIn.renewResult(status: 200, body: Data(#"{"access_token":"acc-NEW"}"#.utf8))
                      == .renewed(.init(accessToken: "acc-NEW", refreshToken: "acc-NEW"))
                      && CursorSignIn.renewResult(status: 200, body: Data(#"{"shouldLogout":true}"#.utf8)) == .loggedOut
                      && CursorSignIn.renewResult(status: 500, body: Data()) == .failed)

            // The reader: Tower's own token, never the Cursor app's.
            let cursorHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("tower-selftest-cursor-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: cursorHome) }
            let stateDB = CursorAuth.stateDB(home: cursorHome)
            try? FileManager.default.createDirectory(at: stateDB.deletingLastPathComponent(), withIntermediateDirectories: true)
            let seedDB = Process()
            seedDB.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            seedDB.arguments = [stateDB.path,
                "create table ItemTable (key text unique on conflict replace, value blob);"
                + "insert into ItemTable values ('cursorAuth/accessToken','cur_STATE_ONLY_FAKE');"
                + "insert into ItemTable values ('cursorAuth/refreshToken','cur_STATE_ONLY_FAKE');"
                + "insert into ItemTable values ('cursorAuth/cachedEmail','cursor@example.test');"
                + "insert into ItemTable values ('cursorAuth/stripeMembershipType','ultra');"]
            try? seedDB.run()
            seedDB.waitUntilExit()
            let noOwnHTTP = ScriptedCursorHTTP([(200, "{}")])
            let noOwn = AsyncBlock.run {
                await CursorUsage.fetch(home: cursorHome, now: renewNow, store: MemoryCursorTokenStore(), http: noOwnHTTP)
            }
            check("cursor with no Tower sign-in asks to connect and sends nothing",
                  noOwn == .connectNeeded(CursorUsage.connectReason) && noOwnHTTP.requests.isEmpty,
                  "\(noOwn), \(noOwnHTTP.requests.count) requests")
            check("cursor connect text names Tower, never the Cursor app's sign-in",
                  CursorUsage.connectReason.contains("Connect Cursor in Tower")
                      && !CursorUsage.connectReason.lowercased().contains("sign in again in cursor"))
            let usageJSON = #"{"planUsage":{"autoPercentUsed":12,"apiPercentUsed":100},"billingCycleEnd":"2033-05-25T00:00:00.000Z"}"#
            let ownStore = MemoryCursorTokenStore(.init(accessToken: later, refreshToken: later))
            let ownHTTP = ScriptedCursorHTTP([(200, usageJSON)])
            let own = AsyncBlock.run {
                await CursorUsage.fetch(home: cursorHome, now: renewNow, store: ownStore, http: ownHTTP)
            }
            let sent = ownHTTP.requests.map { $0.value(forHTTPHeaderField: "Authorization") ?? "" }
            if case .ok(let r) = own {
                check("cursor reads with Tower's own token, never the Cursor app's",
                      sent == ["Bearer \(later)"] && !sent.joined().contains("cur_STATE_ONLY_FAKE")
                          && r.validOtherModelsPct == 100 && r.validCursorModelsPct == 12 && r.email == "cursor@example.test",
                      "\(sent.count) requests")
            } else {
                check("cursor reads with Tower's own token, never the Cursor app's", false, "\(own)")
            }
            let renewStore = MemoryCursorTokenStore(.init(accessToken: soon, refreshToken: soon))
            let renewHTTP = ScriptedCursorHTTP([(200, #"{"access_token":"\#(later)"}"#), (200, usageJSON)])
            let renewed = AsyncBlock.run {
                await CursorUsage.fetch(home: cursorHome, now: renewNow, store: renewStore, http: renewHTTP)
            }
            check("cursor renews a near-expiry own token first, saves it, then reads with it",
                  { if case .ok = renewed { return true }; return false }()
                      && renewHTTP.requests.first?.url == CursorSignIn.tokenURL
                      && renewHTTP.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(later)"
                      && renewStore.load()?.accessToken == later, "\(renewed)")
            let logoutStore = MemoryCursorTokenStore(.init(accessToken: soon, refreshToken: soon))
            let logout = AsyncBlock.run {
                await CursorUsage.fetch(home: cursorHome, now: renewNow, store: logoutStore,
                                        http: ScriptedCursorHTTP([(200, #"{"shouldLogout":true}"#)]))
            }
            check("cursor shouldLogout clears Tower's sign-in and asks to connect again",
                  logout == .connectNeeded(CursorUsage.signedOutReason) && logoutStore.load() == nil, "\(logout)")
            let refusedStore = MemoryCursorTokenStore(.init(accessToken: later, refreshToken: later))
            let refused = AsyncBlock.run {
                await CursorUsage.fetch(home: cursorHome, now: renewNow, store: refusedStore,
                                        http: ScriptedCursorHTTP([(401, "")]))
            }
            check("cursor 401 with Tower's own token asks to connect again",
                  refused == .connectNeeded(CursorUsage.refusedOwnReason(code: 401))
                      && CursorUsage.refusedOwnReason(code: 401).contains("Connect Cursor in Tower"), "\(refused)")
            check("cursor app label is email and plan only",
                  CursorAuth.label(home: cursorHome) == CursorAuth.Label(email: "cursor@example.test", plan: "ultra"))
            check("every read of the Cursor app's database is -readonly",
                  CursorAuth.sqliteArguments(db: stateDB, key: "cursorAuth/cachedEmail").first == "-readonly")
            let seedStore = Store(dir: cursorHome.appendingPathComponent("support"), now: { renewNow })
            _ = seedStore.mutate { accounts in
                _ = seedStore.seedCursorAccount(into: &accounts, outcome: noOwn, home: cursorHome, now: renewNow)
            }
            let cursorRow = seedStore.load()[AccountSnapshot.storeKey(email: "cursor@example.test", provider: .cursor)]
            check("the Connect Cursor action shows for every reason a sign-in fixes, and only those",
                  CursorUsage.needsConnect(CursorUsage.connectReason)
                      && CursorUsage.needsConnect(CursorUsage.signedOutReason)
                      && CursorUsage.needsConnect(CursorUsage.refusedOwnReason(code: 401))
                      && !CursorUsage.needsConnect(nil)
                      && !CursorUsage.needsConnect("could not read Cursor usage (network, or the response did not parse)"))
            check("cursor row without a Tower sign-in reads Connect Cursor in Tower",
                  cursorRow?.lastError?.contains("Connect Cursor in Tower") == true
                      && cursorRow?.lastError?.contains("Sign in again in Cursor") == false,
                  cursorRow?.lastError ?? "no row")
        }

        // A threshold alert names the window a human will read. "Cursor at 95% of 7d"
        // promises relief in a week for credits that refill on the invoice boundary.
        var cursorAlert = acct("cura", five: nil, week: 96, agoHours: 0)
        cursorAlert.provider = .cursor
        cursorAlert.fiveHourResetsAt = nil
        let cursorAlerts = Thresholds.evaluate(&cursorAlert, now: t0)
        check("a cursor threshold fires", cursorAlerts.count == 1)
        check("and names the month, not 7d", cursorAlerts.first?.window == "month",
              "got \(cursorAlerts.first?.window ?? "none")")

        // OpenRouter must never invent a number it could not fetch.
        // Inject a reader so the suite never prompts for a real secret.
        let orCommand = OpenRouter.KeySource(command: ["/fixture/key-reader", "item"],
                                             environmentKey: "fixture-env-key")
        check("openrouter key absent yields nil, not an empty string",
              OpenRouter.apiKey(source: orCommand, run: { _ in nil }) == nil)
        check("openrouter reads the configured command, and the env copy never overrides it",
              OpenRouter.apiKey(source: orCommand, run: { argv in
                  argv == ["/fixture/key-reader", "item"] ? "fixture-key" : nil
              }) == "fixture-key")
        check("openrouter falls back to the environment key when no command is set",
              OpenRouter.apiKey(source: OpenRouter.KeySource(environmentKey: "fixture-env-key"),
                                run: { _ in nil }) == "fixture-env-key")
        check("openrouter with no source is not configured",
              !OpenRouter.KeySource().isConfigured)
        // Invented figures in the shape the live API returns.
        let orLive = OpenRouter.Budget(spent: 17.5, limit: 50)
        check("the headline is what is AVAILABLE, matching the dashboard",
              String(format: "%.2f", orLive.available) == "32.50"
              && Int(orLive.availablePct.rounded()) == 65,
              "pct=\(Int(orLive.pct.rounded())) remaining=\(orLive.remaining)")
        // A refused key must never render as absence. This is the exact failure the
        // operator hit: rotated in 1Password 4h after being copied to the Keychain, and
        // the section silently vanished.
        check("401 is REJECTED, not notConfigured",
              OpenRouter.Outcome.rejected(401, keyFingerprint: nil, lastSuccessAt: nil) != OpenRouter.Outcome.notConfigured)
        check("403 is also a refusal", OpenRouter.Outcome.rejected(403, keyFingerprint: nil, lastSuccessAt: nil) == .rejected(403, keyFingerprint: nil, lastSuccessAt: nil))
        check("rejected carries the status code so the row can name it",
              { if case .rejected(let c, _, _) = OpenRouter.Outcome.rejected(401, keyFingerprint: nil, lastSuccessAt: nil) { return c == 401 }
                return false }())
        check("unavailable is distinct from both",
              OpenRouter.Outcome.unavailable != .notConfigured
              && OpenRouter.Outcome.unavailable != .rejected(401, keyFingerprint: nil, lastSuccessAt: nil))
        check("ok carries the budget",
              OpenRouter.Outcome.ok(OpenRouter.Budget(spent: 31.5, limit: 50))
              == .ok(OpenRouter.Budget(spent: 31.5, limit: 50)))

        let b = OpenRouter.Budget(spent: 12.5, limit: 25)
        check("budget percentage", b.pct == 50)
        check("budget remaining", b.remaining == 12.5)
        check("budget cannot exceed 100%", OpenRouter.Budget(spent: 99, limit: 25).pct == 100)

        // Balance history is a record of observed points, never a made-up OHLC candle. The
        // delta must be against the immediately previous observation, not a bucket boundary.
        let chartStart = Date(timeIntervalSince1970: 1_700_000_000)
        let chartSamples = [
            OpenRouter.History.Sample(capturedAt: chartStart, available: 20, spent: 20, totalCredits: 40),
            OpenRouter.History.Sample(capturedAt: chartStart.addingTimeInterval(60), available: 15, spent: 25, totalCredits: 40),
            OpenRouter.History.Sample(capturedAt: chartStart.addingTimeInterval(120), available: 30, spent: 30, totalCredits: 60),
        ]
        let trend = OpenRouter.History.trend(chartSamples)
        check("one balance reading stays in collecting state",
              OpenRouter.History.trend([chartSamples[0]]) == nil)
        check("trend uses the previous observed balance for the delta",
              trend?.changeSincePrevious == 15 && trend?.changeSpan == 60)
        check("trend keeps the observed endpoints and timeframe",
              trend?.first.available == 20 && trend?.latest.available == 30
              && trend?.observedSpan == 120)
        check("a real balance change permits a labelled trend",
              trend?.hasMeaningfulChange == true)
        let flatSamples = [
            OpenRouter.History.Sample(capturedAt: chartStart, available: 20, spent: 20, totalCredits: 40),
            OpenRouter.History.Sample(capturedAt: chartStart.addingTimeInterval(60), available: 20, spent: 20, totalCredits: 40),
        ]
        check("flat observations do not pretend there is a balance trend",
              OpenRouter.History.trend(flatSamples)?.hasMeaningfulChange == false)

        // --- Codex exhaustion --------------------------------------------------------
        // 2026-08-16: Codex was hard-limited until Aug 20 while the panel read
        // "1 available · 7d ?" and the mirrored cache carried NO usage fields at all.
        // An exhausted turn fails before any usage payload exists, so it writes an error
        // event instead of `rate_limits`; a reader that knew only `rate_limits` saw nothing,
        // and "nothing" renders identically to "healthy, not polled yet".
        let limitMsg = "You've hit your usage limit. Visit "
            + "https://chatgpt.com/codex/settings/usage to purchase more credits or "
            + "try again at Aug 20th, 2026 8:12 AM."
        let reopen = CodexReader.reopening(in: limitMsg)
        check("parses the reopening date out of the limit message", reopen != nil)
        if let reopen {
            let c = Calendar(identifier: .gregorian)
                .dateComponents([.year, .month, .day, .hour, .minute], from: reopen)
            check("reopening parsed as Aug 20 2026 08:12",
                  c.year == 2026 && c.month == 8 && c.day == 20 && c.hour == 8 && c.minute == 12,
                  "got \(c)")
        }
        check("parses a message with no ordinal suffix",
              CodexReader.reopening(in: "try again at Sep 3, 2026 11:05 PM") != nil)
        check("parses a date-only message",
              CodexReader.reopening(in: "try again at Dec 1st, 2026") != nil)
        // nil means "exhausted, reopening unknown" — never "not exhausted".
        check("no readable date yields nil rather than a bogus one",
              CodexReader.reopening(in: "You've hit your usage limit.") == nil)

        // Byte-shape copied from a real rollout file.
        let exhaustLine = """
        {"timestamp":"2026-08-16T11:03:26.079Z","type":"event_msg","payload":\
        {"type":"task_complete","turn_id":"t1","error":{"message":"\(limitMsg)",\
        "codex_error_info":"usage_limit_exceeded"},"duration_ms":4546}}
        """
        let rateLine = """
        {"timestamp":"2026-08-16T10:00:00.000Z","type":"event_msg","payload":{"rate_limits":\
        {"primary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1786878201},\
        "secondary":null,"plan_type":"prolite"}}}
        """
        let codexTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: codexTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexTmp) }

        let bothURL = codexTmp.appendingPathComponent("rollout-both.jsonl")
        let healthyURL = codexTmp.appendingPathComponent("rollout-healthy.jsonl")
        try? [rateLine, exhaustLine].joined(separator: "\n")
            .write(to: bothURL, atomically: true, encoding: .utf8)
        try? rateLine.write(to: healthyURL, atomically: true, encoding: .utf8)

        // A session that ran normally and THEN hit the wall carries both signals; the wall is
        // the later, current one.
        let found = CodexReader.lastUsageLimit(in: bothURL)
        check("finds the exhaustion even when rate_limits precedes it", found != nil)
        check("a healthy session reports no exhaustion",
              CodexReader.lastUsageLimit(in: healthyURL) == nil)

        if let found {
            var cx = AccountSnapshot(email: "c@example.com", nickname: "cx", plan: "prolite")
            // The fixture's reopening date is historical. Keep this selftest pinned just
            // before it, rather than letting wall time turn an exhausted fixture into a
            // reset window and falsely fail the resting assertions.
            let at = found.resetsAt?.addingTimeInterval(-60)
                ?? Date(timeIntervalSince1970: 1_787_000_000)
            CodexReader.apply(CodexReader.Reading(exhaustion: found, capturedAt: at), to: &cx)
            check("an exhausted plan reads as 100% spent", cx.weeklyPct == 100)
            check("the reopening time is carried onto the snapshot", cx.weeklyResetsAt != nil)
            check("no 5h window is invented for codex", cx.fiveHourPct == nil)
            check("stale credit is dropped beside an exhausted window", cx.creditBalance == nil)
            // The bug, stated as an assertion. Note the boundary that matters is RESTING,
            // not `isRecommendable`: the latter answers "can we vouch for this number", and
            // a confidently-known 100% is still a number we can vouch for. What must not
            // happen is the row surviving `partition` into the active list, because that is
            // the list the panel counts as "available" and `advise` draws candidates from.
            check("an exhausted account rests", cx.restingReason(now: at) != nil)
            let (activeRows, restingRows) = AccountSnapshot.partition([cx], now: at)
            check("an exhausted account is NOT in the active list", activeRows.isEmpty)
            check("and it appears in the resting list with a reason", restingRows.count == 1)
            // Routing the date through weeklyResetsAt is what makes this self-clearing.
            if let reset = cx.weeklyResetsAt {
                let after = reset.addingTimeInterval(60)
                check("the exhaustion clears itself once the reset passes",
                      cx.effectiveWeekly(now: after).pct == 0)
            }
        }

        // A healthy reading must fold exactly as it did before this change.
        if let healthy = CodexReader.lastRateLimits(in: healthyURL) {
            var cx = AccountSnapshot(email: "c@example.com", nickname: "cx", plan: "?")
            CodexReader.apply(CodexReader.Reading(limits: healthy, capturedAt: Date()), to: &cx)
            check("a healthy codex reading still folds its usage", cx.weeklyPct == 42.0)
            check("a healthy codex reading still folds its plan", cx.plan == "prolite")
        }

        // --- Switch advice -----------------------------------------------------------
        // 2026-08-16: active dee had 31% room and the panel advised "switch to ben ·
        // 94% used". `usable` is filtered by switchProfiles, built from the
        // ~/.claude/accounts/*.json files that still carry an oauthAccount — only ONE of
        // four did, and the ACTIVE account had no file at all, so it could not appear among
        // the candidates and `usable.first` was free to be worse than where you stood.
        func acct(_ nick: String, _ email: String, five: Double?, weekly: Double,
                  at: Date, provider: Provider = .claude) -> AccountSnapshot {
            var a = AccountSnapshot(email: email, nickname: nick, plan: "max")
            a.provider = provider
            a.fiveHourPct = five
            a.weeklyPct = weekly
            a.fiveHourResetsAt = at.addingTimeInterval(3_600)
            a.weeklyResetsAt = at.addingTimeInterval(7 * 24 * 3_600)
            a.capturedAt = at
            return a
        }
        let adviceNow = Date()
        let onGood = acct("dee", "dee@example.com", five: 4, weekly: 69, at: adviceNow)
        let onBad = acct("ben", "ben@example.com", five: 94, weekly: 67, at: adviceNow)
        let worseAdvice = AccountSnapshot.advise(
            activeEmail: onGood.email, accounts: [onGood, onBad],
            switchProfiles: ["ben@example.com": profile("ben")], now: adviceNow)
        check("never advises a switch that lowers headroom", worseAdvice.command == nil,
              "got \(worseAdvice)")

        let better = acct("dee", "dee@example.com", five: 4, weekly: 20, at: adviceNow)
        let betterAdvice = AccountSnapshot.advise(
            activeEmail: onBad.email, accounts: [onBad, better],
            switchProfiles: ["dee@example.com": profile("dee"),
                             "ben@example.com": profile("ben")],
            now: adviceNow)
        check("still advises a switch that raises headroom",
              betterAdvice.command == "/login" && betterAdvice.chromeProfile == profile("dee"),
              "got \(betterAdvice)")

        let tie = acct("b", "b@example.com", five: 50, weekly: 50, at: adviceNow)
        let tieActive = acct("a", "a@example.com", five: 50, weekly: 50, at: adviceNow)
        check("equal headroom is not an improvement",
              AccountSnapshot.advise(activeEmail: tieActive.email, accounts: [tieActive, tie],
                           switchProfiles: ["b@example.com": profile("b")], now: adviceNow).command == nil)

        // Nothing to compare against means the prior behaviour stands.
        let lone = acct("a", "a@example.com", five: 10, weekly: 10, at: adviceNow)
        check("an unknown active account still gets a recommendation",
              AccountSnapshot.advise(activeEmail: String?.none, accounts: [lone],
                           switchProfiles: ["a@example.com": profile("a")],
                           now: adviceNow).command == "/login")

        // ── tower rotate: advisory only ---------------------------------------------
        // Freshness is primary: cached room must not displace a smaller, current room.
        // The four-hour cached row stays visible as unknown, outside the usable list.
        let rotateNow = Date(timeIntervalSince1970: 1_800_100_000)
        func rotateSeat(_ nick: String, used: Double, age: TimeInterval) -> AccountSnapshot {
            var seat = AccountSnapshot(email: "\(nick)@example.com", nickname: nick, plan: "max")
            seat.fiveHourPct = used
            seat.weeklyPct = used
            seat.fiveHourResetsAt = rotateNow.addingTimeInterval(3_600)
            seat.weeklyResetsAt = rotateNow.addingTimeInterval(7 * 86_400)
            seat.capturedAt = rotateNow.addingTimeInterval(-age)
            return seat
        }
        let freshRoomy = rotateSeat("fresh-roomy", used: 20, age: 60)
        let freshTight = rotateSeat("fresh-tight", used: 55, age: 60)
        let staleRoomy = rotateSeat("stale-roomy", used: 2, age: 4 * 3_600)
        let cappedSeat = rotateSeat("capped", used: 99, age: 60)
        let profiles = [
            freshRoomy.email: profile("Fresh Roomy"), freshTight.email: profile("Fresh Tight"),
            staleRoomy.email: profile("Stale Roomy"), cappedSeat.email: profile("Capped"),
        ]
        let rotation = rotateReport(
            accounts: [staleRoomy, cappedSeat, freshTight, freshRoomy],
            switchProfiles: profiles, now: rotateNow)
        check("rotate ranks fresh seats ahead of a roomier stale gauge",
              rotation.seats.map(\.nickname) == ["fresh-roomy", "fresh-tight"],
              "got \(rotation.seats.map(\.nickname))")
        check("rotate shows snapshot age and Chrome profile",
              rotation.lines.contains { $0.contains("4h ago") && $0.contains("Stale Roomy") })
        check("rotate prints the exact two-line manual login plan",
              loginPlan(for: freshRoomy, chromeProfile: profile("Fresh Roomy")) == [
                  "  1. In the target Claude Code pane, run /login.",
                  "  2. Choose Chrome profile \"Fresh Roomy\" and sign in as fresh-roomy@example.com.",
              ])
        check("rotate multi-account profile hint keeps chooser email out of the profile name",
              loginPlan(
                  for: freshRoomy,
                  chromeProfile: profile("Profile Name", chooserEmail: "chooser@example.com")
              ) == [
                  "  1. In the target Claude Code pane, run /login.",
                  "  2. Choose Chrome profile \"Profile Name\"; if Google shows an account chooser, select chooser@example.com.",
              ])
        let multiProfileRotation = rotateReport(
            accounts: [freshRoomy],
            switchProfiles: [freshRoomy.email:
                profile("Profile Name", chooserEmail: "chooser@example.com")],
            now: rotateNow)
        check("rotate roster separates Chrome profile from Google account",
              multiProfileRotation.lines.contains(
                  "  seat      room    snapshot age   Chrome profile      Google account")
              && multiProfileRotation.lines.contains { line in
                  line.contains("Profile Name") && line.contains("chooser@example.com")
                      && !line.contains("Profile Name → chooser@example.com")
              })
        let allResting = rotateReport(
            accounts: [cappedSeat], switchProfiles: [cappedSeat.email: profile("Capped")], now: rotateNow)
        check("rotate exits 1 and says every seat is resting",
              allResting.code == 1
                  && allResting.lines.contains { $0.contains("Every Claude seat") && $0.contains("resting") })

        // Pi: an invented session log in a temp root (never the real ~/.pi), summed for a
        // fixed "now" in UTC so the month and day edges do not depend on this machine.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let piNow = DateParse.parse("2026-11-04T12:00:00Z")!
        func piTurn(_ id: String, _ at: String, _ usd: Double) -> String {
            #"{"type":"message","id":"\#(id)","timestamp":"\#(at)","message":{"role":"assistant","provider":"openrouter","model":"m","usage":{"cost":{"total":\#(usd)}}}}"#
        }
        var piTally = PiLane.Tally(now: piNow, calendar: utc)
        piTally.add(text: [
            piTurn("a", "2026-11-04T09:00:00Z", 1.25),
            piTurn("b", "2026-11-02T09:00:00Z", 2.00),
            piTurn("c", "2026-10-31T23:00:00Z", 9.00),
            piTurn("a", "2026-11-04T09:00:00Z", 1.25),
            "{not json \"assistant\" \"cost\"",
        ].joined(separator: "\n"))
        check("pi sums this month and today, once per entry",
              abs(piTally.spend.monthUSD - 3.25) < 1e-9 && abs(piTally.spend.todayUSD - 1.25) < 1e-9
                  && piTally.spend.messages == 2,
              "month \(piTally.spend.monthUSD) today \(piTally.spend.todayUSD)")
        check("pi skips a malformed line instead of failing", piTally.spend.skippedLines == 1)
        var piSpend = piTally.spend
        piSpend.provider = "openrouter"
        let piShare = PiLane.share(piSpend, openRouter: .ok(OpenRouter.Budget(spent: 40, limit: 50)))
        check("pi share is month spend over the OpenRouter limit, left is limit minus spent",
              piShare == .openRouter(pct: 6.5, leftUSD: 10, limitUSD: 50), "\(piShare)")
        check("pi without an OpenRouter balance shows spend only and says why",
              PiLane.share(piSpend, openRouter: .notConfigured) == .spendOnly("no OpenRouter key in Tower"))
        let piHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-pi-\(UUID().uuidString)")
        // Muse is spawned only on a refresh (its runner); hydration and panelshot read it
        // with no runner. They show the last reading the store kept, or "not read yet",
        // never "usage not exposed": Muse does expose usage (seen 2026-11-04, Muse 1.4.14).
        let museSeen = Date().addingTimeInterval(-40 * 60)
        let museQuota = AgentLane.Quota(plan: "Muse Pro", dailyRemainingPct: 99, weeklyRemainingPct: 98,
                                        dailyResetsAt: museSeen.addingTimeInterval(3600),
                                        weeklyResetsAt: museSeen.addingTimeInterval(5 * 86_400),
                                        fetchedAt: museSeen, shortLabel: "Window", source: "live")
        var museMirror = AccountSnapshot(email: AgentLane.mirrorEmail(.muse), nickname: "muse", plan: "lane")
        museMirror.provider = .muse
        AgentLane.apply(museQuota, observedAt: museSeen, to: &museMirror, now: museSeen)
        let noRunner: [Provider: AgentLane.Outcome] = [
            .muse: .ok(AgentLane.Reading(provider: .muse, configModel: "m", lastDispatch: nil, lastLimitHit: nil)),
        ]
        let hydratedMuse = AgentLane.withSavedReadings(noRunner, accounts: [museMirror])
        if case .ok(let r)? = hydratedMuse[.muse], case .quota(let q) = r.usage {
            check("hydration shows Muse's saved reading, not 'not exposed'",
                  q.dailyRemainingPct == 99 && q.weeklyRemainingPct == 98 && q.fetchedAt == museSeen
                      && q.source == "saved" && q.shortLabel == "Window", "\(q)")
        } else {
            check("hydration shows Muse's saved reading, not 'not exposed'", false, "\(String(describing: hydratedMuse[.muse]))")
        }
        let hydratedEmpty = AgentLane.withSavedReadings(noRunner, accounts: [])
        if case .ok(let r)? = hydratedEmpty[.muse] {
            check("hydration with no saved Muse reading says not read yet",
                  r.usage == .notReadable("not read yet, refreshing"), "\(r.usage)")
        } else {
            check("hydration with no saved Muse reading says not read yet", false)
        }
        if case .ok(let r)? = hydratedMuse[.muse] {
            check("a saved Muse reading always says it is saved, even when recent",
                  AgentLane.usageAgeLine(r, now: museSeen.addingTimeInterval(60))?.hasPrefix("saved reading, read ") == true,
                  AgentLane.usageAgeLine(r, now: museSeen.addingTimeInterval(60)) ?? "nil")
        }
        check("panelshot hydration fills Muse from the store",
              PanelShotHydration.lanesFromStore(noRunner, accounts: [museMirror])[.muse]
                  == hydratedMuse[.muse])

        check("pi row is hidden when the Pi directory does not exist",
              PiLane.read(home: piHome, env: [PiLane.rootEnvKey: piHome.appendingPathComponent("absent").path])
                  == .notConfigured)
        // The disk path end to end: settings, one session this month, auth.json beside them.
        let piRoot = piHome.appendingPathComponent("agent")
        let piSession = piRoot.appendingPathComponent("sessions/--demo--/s.jsonl")
        try? FileManager.default.createDirectory(at: piSession.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(#"{"defaultProvider":"openrouter","defaultModel":"demo/model"}"#.utf8)
            .write(to: piRoot.appendingPathComponent("settings.json"))
        try? Data((piTurn("d1", "2026-11-03T10:00:00.000Z", 0.75) + "\n").utf8).write(to: piSession)
        try? FileManager.default.setAttributes([.modificationDate: piNow], ofItemAtPath: piSession.path)
        let piRead = PiLane.read(home: piHome, env: [PiLane.rootEnvKey: piRoot.path],
                                 now: piNow, calendar: utc)
        if case .ok(let r) = piRead, case .spend(let s) = r.usage {
            check("pi reads settings and a session file from its root",
                  s.provider == "openrouter" && s.model == "demo/model"
                      && abs(s.monthUSD - 0.75) < 1e-9 && s.files == 1, "\(s)")
        } else {
            check("pi reads settings and a session file from its root", false, "\(piRead)")
        }
        try? FileManager.default.removeItem(at: piHome)

        // --- Demo mode (TOWER_DEMO=1) -----------------------------------------------
        // A demo store must show a verified active seat from its own invented credential,
        // and must never fall through to the real login Keychain to get one.
        do {
            let demoDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tower-selftest-demo-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: demoDir) }
            let demoNow = Date()
            func demoSeat(_ nick: String, five: Double, week: Double) -> AccountSnapshot {
                var seat = AccountSnapshot(email: "\(nick)@example.com", nickname: nick, plan: "max")
                seat.fiveHourPct = five
                seat.weeklyPct = week
                seat.fiveHourResetsAt = demoNow.addingTimeInterval(3 * 3600)
                seat.weeklyResetsAt = demoNow.addingTimeInterval(3 * 86_400)
                seat.capturedAt = demoNow.addingTimeInterval(-60)
                return seat
            }
            let demoSeats = [demoSeat("work", five: 22, week: 41), demoSeat("side", five: 0, week: 12),
                             demoSeat("lab", five: 81, week: 88)]
            let demoStore = Store(dir: demoDir)
            _ = demoStore.save(Dictionary(uniqueKeysWithValues: demoSeats.map { ($0.email, $0) }))
            let demoEnv = ["TOWER_DEMO": "1", "TOWER_SUPPORT_DIR": demoDir.path]
            final class KeychainSpy: @unchecked Sendable { var reads = 0 }

            // No demo-credential.json: honestly unverified, worded as a recommendation.
            let blindSpy = KeychainSpy()
            let blind = TowerMCPService(env: .live(processEnvironment: demoEnv, keychainCredential: {
                blindSpy.reads += 1
                return nil
            })).advice()
            check("demo without a credential file reads no Keychain", blindSpy.reads == 0,
                  "Keychain reads: \(blindSpy.reads)")
            check("unverified active seat names the roomiest seat and its room",
                  blind.structuredContent?["kind"] == "activeUnknown"
                      && blind.content == [.text("no verified active seat; most room: side (88%)")],
                  "got \(blind.content)")

            // The invented credential whose digest active-seat.json carries binds the seat.
            try? Data(#"{"accessToken":"demo-token-work","emailHint":"work@example.com"}"#.utf8)
                .write(to: demoDir.appendingPathComponent("demo-credential.json"))
            demoStore.recordVerifiedActiveSeatUnlocked("work@example.com", token: "demo-token-work", now: demoNow)
            let boundSpy = KeychainSpy()
            let bound = TowerMCPService(env: .live(processEnvironment: demoEnv, keychainCredential: {
                boundSpy.reads += 1
                return nil
            })).advice()
            let boundKind = bound.structuredContent?["kind"].stringValue
            check("demo credential binds the demo active seat (stay or switch)",
                  boundKind == "stay" || boundKind == "switch", "kind \(boundKind ?? "nil")")
            check("demo with a credential file reads no Keychain", boundSpy.reads == 0,
                  "Keychain reads: \(boundSpy.reads)")
            check("TOWER_DEMO alone is not demo mode",
                  DemoMode.supportDirectory(env: ["TOWER_DEMO": "1"]) == nil
                      && DemoMode.supportDirectory(env: ["TOWER_SUPPORT_DIR": demoDir.path]) == nil)
            // The gate must judge the verb that will run, not any verb present: main.swift
            // dispatches rotate, login-item and status before panelshot, so these three
            // would run live against the real Keychain, login and login item.
            check("demo refuses `panelshot status` (status runs first, live)",
                  DemoMode.refusal(args: ["panelshot", "status"]) != nil)
            check("demo refuses `panelshot rotate` (rotate runs first, live)",
                  DemoMode.refusal(args: ["panelshot", "rotate"]) != nil)
            check("demo refuses `panelshot login-item on` (login-item runs first, live)",
                  DemoMode.refusal(args: ["panelshot", "login-item", "on"]) != nil)
            check("demo still runs `mcp`, `mcp --self-test` and `panelshot out.png`",
                  DemoMode.refusal(args: ["mcp"]) == nil && DemoMode.refusal(args: ["mcp", "--self-test"]) == nil
                      && DemoMode.refusal(args: ["panelshot", "out.png"]) == nil)
            check("demo refuses the app and plain status", DemoMode.refusal(args: []) != nil
                      && DemoMode.refusal(args: ["status"]) != nil)
            // `tower retrust`: an agent can start Re-trust; the user still approves each
            // Keychain dialog. A demo has no real Keychain, so it refuses.
            check("retrust dispatches to its own verb and a demo refuses it",
                  DemoMode.dispatched(args: ["retrust"]) == .retrust
                      && DemoMode.refusal(args: ["retrust"]) != nil)
            let retrustOK = CLI.retrustReport(.success((readable: 6, unreadable: 1)))
            check("tower retrust reports readable and unreadable seats and exits 0",
                  retrustOK.code == 0
                      && retrustOK.lines == ["Re-trust: 6 remembered seats readable, 1 still unreadable. macOS asks Always Allow once per seat."],
                  "\(retrustOK)")
            let retrustNo = CLI.retrustReport(.failure(ClaudeSeatVaultError("Re-trust needs the signed Tower app")))
            check("tower retrust prints the refusal and exits 1",
                  retrustNo.code == 1 && retrustNo.lines == ["Re-trust failed: Re-trust needs the signed Tower app"],
                  "\(retrustNo)")
            let demoRetrust = TowerMCPService(env: .demo(supportDirectory: demoDir)).retrust()
            check("tower_retrust in a demo is refused, with no Keychain dialog",
                  demoRetrust.isError && demoRetrust.structuredContent?["error"]["code"] == "RetrustRefused",
                  "\(demoRetrust.content)")
            // b87 on #22: an agent may raise the Re-trust dialog at most once a minute.
            var coolEnv = TowerMCPService.Environment.demo(supportDirectory: demoDir)
            var coolNow = Date(timeIntervalSince1970: 1_800_000_000)
            coolEnv.now = { coolNow }
            let cooled = TowerMCPService(env: coolEnv, retrustCooldown: RetrustCooldown())
            _ = cooled.retrust()
            coolNow = coolNow.addingTimeInterval(10)
            let second = cooled.retrust()
            coolNow = coolNow.addingTimeInterval(RetrustCooldown.window)
            let later = cooled.retrust()
            check("tower_retrust refuses a second call within a minute, then allows one",
                  second.structuredContent?["error"]["code"] == "RetrustCooldown"
                      && later.structuredContent?["error"]["code"] != "RetrustCooldown",
                  "\(second.content) / \(later.content)")
            // b87 on #23: the MCP render's size comes from the PNG, so the new `wrote` line
            // (points and pixels) cannot zero it, and the server's scale does not leak in.
            let tinyRep = PanelShot.bitmap(for: NSRect(x: 0, y: 0, width: 3, height: 2), scale: 2)
            let tinyPNG = tinyRep?.representation(using: .png, properties: [:]) ?? Data()
            let shotSize = TowerMCPService.panelshotSize(
                stdout: "wrote /tmp/x.png (2x2 pt, 6x4 px)\n", png: tinyPNG)
            check("tower_panelshot reads its size from the PNG, not the wrote line",
                  shotSize == (6, 4), "\(shotSize)")
            let childEnv = TowerMCPService.panelshotChildEnvironment(
                [PanelShot.scaleEnvKey: "3", "HOME": "/Users/x"])
            check("tower_panelshot never passes the server's TOWER_PANELSHOT_SCALE to its render",
                  childEnv[PanelShot.scaleEnvKey] == nil && childEnv["HOME"] == "/Users/x", "\(childEnv)")
            // 2026-11-04: LAContext.interactionNotAllowed did not stop a legacy keychain
            // dialog (measured); the process switch did. Background reads run with it off,
            // Re-trust alone turns it on and off again.
            final class GateSpy: ClaudeSeatKeychain {
                let gate: KeychainDialogGate
                var allowedAtRead: [Bool] = []
                init(gate: KeychainDialogGate) { self.gate = gate }
                func readSeats(interaction: ClaudeSeatReadInteraction) -> Result<ClaudeSeatKeychainReadout, ClaudeSeatVaultError> {
                    allowedAtRead.append(gate.dialogsAllowed)
                    return .success(ClaudeSeatKeychainReadout())
                }
                func writeSeat(service: String, account: String, label: String, data: Data) -> String? { nil }
                func removeSeat(service: String, account: String, label: String) -> String? { nil }
                func purgeAll() -> String? { nil }
            }
            func gateVault(_ spy: GateSpy) -> ClaudeSeatVault {
                ClaudeSeatVault(keychain: spy,
                                lockURL: demoDir.appendingPathComponent("gate.lock"),
                                stateURL: demoDir.appendingPathComponent("gate-state.plist"),
                                retentionEnabled: { true }, setRetentionEnabled: { _ in },
                                log: { _ in }, mayPrompt: { true }, dialogGate: spy.gate)
            }
            let backgroundSpy = GateSpy(gate: KeychainDialogGate(set: { _ in errSecSuccess }))
            _ = gateVault(backgroundSpy).credentials(active: nil)
            check("a background seat read runs with Keychain dialogs switched off",
                  backgroundSpy.allowedAtRead == [false], "\(backgroundSpy.allowedAtRead)")
            var switches: [Bool] = []
            let retrustSpy = GateSpy(gate: KeychainDialogGate(set: { switches.append($0); return errSecSuccess }))
            _ = gateVault(retrustSpy).retrust()
            check("Re-trust reads with dialogs on, then switches them off again",
                  retrustSpy.allowedAtRead == [true] && switches.last == false
                      && !retrustSpy.gate.dialogsAllowed, "\(retrustSpy.allowedAtRead) \(switches)")
            let failingGate = KeychainDialogGate(set: { _ in errSecParam })
            failingGate.closeForProcess()
            check("a failed switch is never reported as dialogs off", failingGate.dialogsAllowed)
            // b87 should-fix on #24: a background read on another thread during Re-trust must
            // neither switch dialogs off under the operator's read nor run while they are on.
            let overlapGate = KeychainDialogGate(set: { _ in errSecSuccess })
            let retrustStarted = DispatchSemaphore(value: 0)
            let releaseRetrust = DispatchSemaphore(value: 0)
            let backgroundDone = DispatchSemaphore(value: 0)
            let overlapBox = NSLock()
            var allowedAtRetrustEnd = false
            var backgroundSawDialogs = true
            DispatchQueue.global().async {
                overlapGate.withDialogAllowed {
                    retrustStarted.signal()
                    _ = releaseRetrust.wait(timeout: .now() + 2)
                    overlapBox.withLock { allowedAtRetrustEnd = overlapGate.dialogsAllowed }
                }
            }
            retrustStarted.wait()
            DispatchQueue.global().async {
                overlapGate.withDialogsOff {
                    overlapBox.withLock { backgroundSawDialogs = overlapGate.dialogsAllowed }
                }
                backgroundDone.signal()
            }
            Thread.sleep(forTimeInterval: 0.2)
            releaseRetrust.signal()
            _ = backgroundDone.wait(timeout: .now() + 5)
            // b88 SEC HOLD on #24, must 1: Re-trust holds the vault flock like every other vault
            // operation, so a refresh tick in this or another process waits for the dialog.
            final class FlockProbe: ClaudeSeatKeychain {
                let gate: KeychainDialogGate
                let lockPath: String
                var flockFreeDuringAllowedRead: Bool?
                var allowedAtBackgroundRead: [Bool] = []
                init(gate: KeychainDialogGate, lockPath: String) { self.gate = gate; self.lockPath = lockPath }
                func readSeats(interaction: ClaudeSeatReadInteraction) -> Result<ClaudeSeatKeychainReadout, ClaudeSeatVaultError> {
                    if interaction == .allowed {
                        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
                        defer { close(fd) }
                        let got = flock(fd, LOCK_EX | LOCK_NB) == 0
                        if got { flock(fd, LOCK_UN) }
                        flockFreeDuringAllowedRead = got
                    } else {
                        allowedAtBackgroundRead.append(gate.dialogsAllowed)
                    }
                    return .success(ClaudeSeatKeychainReadout())
                }
                func writeSeat(service: String, account: String, label: String, data: Data) -> String? { nil }
                func removeSeat(service: String, account: String, label: String) -> String? { nil }
                func purgeAll() -> String? { nil }
            }
            let flockPath = demoDir.appendingPathComponent("flock-probe.lock")
            let flockSpy = FlockProbe(gate: KeychainDialogGate(set: { _ in errSecSuccess }), lockPath: flockPath.path)
            let flockVault = ClaudeSeatVault(keychain: flockSpy, lockURL: flockPath,
                                             stateURL: demoDir.appendingPathComponent("flock-state.plist"),
                                             retentionEnabled: { true }, setRetentionEnabled: { _ in },
                                             log: { _ in }, mayPrompt: { true }, dialogGate: flockSpy.gate)
            _ = flockVault.retrust()
            _ = flockVault.credentials(active: nil)
            check("Re-trust holds the vault lock, so a refresh tick waits and still reads with dialogs off",
                  flockSpy.flockFreeDuringAllowedRead == false && !flockSpy.allowedAtBackgroundRead.contains(true),
                  "lock free during Re-trust \(String(describing: flockSpy.flockFreeDuringAllowedRead)), background \(flockSpy.allowedAtBackgroundRead)")
            // must 2: the Cursor sign-in item's reads, deletes and adds run inside the window too.
            let cursorGate = KeychainDialogGate(set: { _ in errSecSuccess })
            var cursorSeen: [String] = []
            var cursorStore = KeychainCursorTokenStore()
            cursorStore.gate = cursorGate
            cursorStore.ops = .init(
                delete: { _ in cursorSeen.append("delete \(cursorGate.dialogsAllowed)"); return errSecItemNotFound },
                add: { _ in cursorSeen.append("add \(cursorGate.dialogsAllowed)"); return errSecSuccess },
                makeAccess: { var a: SecAccess?; _ = SecAccessCreate("tower-selftest" as CFString, nil, &a); return a },
                read: { _, _ in cursorSeen.append("read \(cursorGate.dialogsAllowed)"); return errSecItemNotFound })
            _ = cursorStore.load()
            _ = cursorStore.save(CursorSignIn.Tokens(accessToken: "a", refreshToken: "r"))
            cursorStore.clear()
            check("Cursor sign-in Keychain reads and writes run with dialogs off",
                  cursorSeen == ["read false", "delete false", "add false", "delete false"], "\(cursorSeen)")
            overlapBox.withLock {
                check("a background read during Re-trust waits, never switching dialogs off under it",
                      allowedAtRetrustEnd && !backgroundSawDialogs,
                      "retrust end allowed \(allowedAtRetrustEnd), background saw \(backgroundSawDialogs)")
            }
            let retrustSpec = TowerMCPService.tools.first { $0.name == "tower_retrust" }
            check("tower_retrust is listed as a user-interactive write, not idempotent",
                  retrustSpec?.annotations.readOnlyHint == false && retrustSpec?.annotations.idempotentHint == false
                      && (retrustSpec?.description.contains("Always Allow") ?? false))
            // After a CLI retrust grants access, the running app finds the seat by itself:
            // while any seat is unreadable its silent read is due again after the backoff.
            let pickup = ClaudeSeatLaunchCache()
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            pickup.keep(ClaudeSeatKeychainReadout(records: [], unreadable: [ClaudeSeatUnreadableItem(service: "s", account: "a", label: "l", status: -25293)]),
                        now: t0, interaction: .suppressed)
            check("the app re-reads an unreadable seat after the backoff, so a CLI retrust is picked up",
                  !pickup.readDue(now: t0.addingTimeInterval(30), backoff: ClaudeSeatVault.readRetryBackoff)
                      && pickup.readDue(now: t0.addingTimeInterval(ClaudeSeatVault.readRetryBackoff + 1),
                                        backoff: ClaudeSeatVault.readRetryBackoff))
            // A demo panel shows the invented Pi lane only when the demo names its directory.
            check("demo shows no agent lanes without TOWER_PI_DIR", DemoMode.lanes(env: demoEnv).isEmpty)
            let demoPi = demoDir.appendingPathComponent("pi")
            try? FileManager.default.createDirectory(at: demoPi, withIntermediateDirectories: true)
            let demoLanes = DemoMode.lanes(env: demoEnv.merging([PiLane.rootEnvKey: demoPi.path]) { $1 })
            check("demo with TOWER_PI_DIR shows only the Pi lane, read from that directory",
                  Set(demoLanes.keys) == [.pi] && demoLanes[.pi] != .notConfigured, "\(demoLanes)")
            // TOWER_PI_DIR must stay inside the demo store: a path outside it, or a symlink
            // in the store that points out, would put real Pi spend in a demo shot.
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("tower-selftest-realpi-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: outside) }
            try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            check("demo ignores a TOWER_PI_DIR outside the demo store",
                  DemoMode.lanes(env: demoEnv.merging([PiLane.rootEnvKey: outside.path]) { $1 }).isEmpty)
            let escape = demoDir.appendingPathComponent("pi-escape")
            try? FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
            check("demo ignores a symlink in the store that points outside it",
                  DemoMode.lanes(env: demoEnv.merging([PiLane.rootEnvKey: escape.path]) { $1 }).isEmpty)
            check("demo ignores TOWER_PI_DIR when there is no demo store",
                  DemoMode.lanes(env: [PiLane.rootEnvKey: demoPi.path]).isEmpty)
            // `panelshot sessions` runs `claude agents --json`: a demo shot must not list real sessions.
            check("demo panelshot never runs the live session probe",
                  !DemoMode.runsLiveSessionProbe(env: demoEnv) && DemoMode.runsLiveSessionProbe(env: [:]))
            // Inside a confined Pi root, a session link that points out is not read: a demo
            // Pi directory cannot pull real spend in through a symlink below its root.
            let outsideSessions = outside.appendingPathComponent("sessions/--real--")
            try? FileManager.default.createDirectory(at: outsideSessions, withIntermediateDirectories: true)
            let outsideLog = outsideSessions.appendingPathComponent("real.jsonl")
            let realTurn = #"{"type":"message","id":"r1","timestamp":"\#(ISO8601DateFormatter().string(from: demoNow))","message":{"role":"assistant","provider":"openrouter","model":"m","usage":{"cost":{"total":7.5}}}}"#
            try? Data((realTurn + "\n").utf8).write(to: outsideLog)
            let linkedPi = demoDir.appendingPathComponent("pi-linked")
            try? FileManager.default.createDirectory(at: linkedPi.appendingPathComponent("sessions/--demo--"),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(
                at: linkedPi.appendingPathComponent("sessions/--demo--/link.jsonl"), withDestinationURL: outsideLog)
            try? FileManager.default.createSymbolicLink(
                at: linkedPi.appendingPathComponent("sessions/--out--"), withDestinationURL: outsideSessions)
            let linkedLanes = DemoMode.lanes(env: demoEnv.merging([PiLane.rootEnvKey: linkedPi.path]) { $1 })
            if case .ok(let r)? = linkedLanes[.pi], case .spend(let s) = r.usage {
                check("demo Pi lane reads no session file linked from outside its root",
                      s.monthUSD == 0 && s.files == 0, "\(s)")
            } else {
                check("demo Pi lane reads no session file linked from outside its root", false, "\(linkedLanes)")
            }
            // A demo store of "/" would make every path "inside" it.
            check("a demo store of / is no demo store",
                  DemoMode.supportDirectory(env: ["TOWER_DEMO": "1", "TOWER_SUPPORT_DIR": "/"]) == nil
                      && DemoMode.supportDirectory(env: ["TOWER_DEMO": "1", "TOWER_SUPPORT_DIR": "/./"]) == nil)
            // Panelshot hydration reads no timestamp from this Mac's real settings in a demo.
            let demoPrefsSuite = "tower-selftest-demo-prefs-\(UUID().uuidString)"
            let demoPrefs = UserDefaults(suiteName: demoPrefsSuite)!
            defer { demoPrefs.removePersistentDomain(forName: demoPrefsSuite) }
            OpenRouter.recordSuccess(now: demoNow, defaults: demoPrefs)
            check("demo panelshot reads no OpenRouter success time from the real settings",
                  DemoMode.openRouterLastSuccess(env: demoEnv, defaults: demoPrefs) == nil
                      && DemoMode.openRouterLastSuccess(env: [:], defaults: demoPrefs) != nil)
            // Same contract as MCPSurfaceTests.testEveryCLIVerbHasATool, runnable without XCTest.
            let cliVerbs = DemoMode.Verb.allCases.filter { $0 != .app }
            let toolNames = Set(TowerMCPService.tools.map(\.name))
            check("every CLI verb dispatches to itself and maps to a listed MCP tool",
                  cliVerbs.allSatisfy { DemoMode.dispatched(args: [$0.rawValue]) == $0 }
                      && cliVerbs.allSatisfy { TowerMCPService.verbToTool[$0.rawValue].map(toolNames.contains) == true }
                      && Set(TowerMCPService.verbToTool.keys) == Set(cliVerbs.map(\.rawValue)))
        }

        // First run and Settings (approved-design/onboarding-mockup.txt).
        OnboardingSelfTest.run(check)

        // Tower's own app icon and menu-bar glyph (the Beacon). The bundle half (Info.plist
        // keys, AppIcon.icns) is checked on a built bundle by scripts/test-bundle-icon.sh;
        // the glyph half is checked here against the repo's art.
        // A release build was compiled on CI, so #filePath names a path on that machine;
        // a bundle that ships the glyph is checked in its own Resources instead.
        let glyphDir = StatusGlyph.selftestDirectory(
            bundleResources: ProductIdentity.runningBundle()?.resourceURL, sourceFile: #filePath)
        let glyph = StatusGlyph.image(in: glyphDir)
        let fakeBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-selftest-glyph-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fakeBundle, withIntermediateDirectories: true)
        for file in ["\(StatusGlyph.name).png", "\(StatusGlyph.name)@2x.png"] {
            FileManager.default.createFile(atPath: fakeBundle.appendingPathComponent(file).path, contents: Data([0x89]))
        }
        let ciSource = "/Users/runner/work/tower/tower/Sources/Tower/CLI.swift"
        check("a bundle that ships the glyph is checked in its own Resources, not the build machine's path",
              StatusGlyph.selftestDirectory(bundleResources: fakeBundle, sourceFile: ciSource).standardizedFileURL
                  == fakeBundle.standardizedFileURL)
        check("a checkout build without bundle art still checks Resources/StatusGlyph",
              StatusGlyph.selftestDirectory(bundleResources: nil, sourceFile: "/r/Sources/Tower/CLI.swift").path
                  == "/r/Resources/StatusGlyph")
        try? FileManager.default.removeItem(at: fakeBundle)
        check("the menu-bar glyph TowerGlyph loads as an 18 pt template image",
              StatusGlyph.name == "TowerGlyph" && glyph?.isTemplate == true
                  && glyph?.size == StatusGlyph.pointSize,
              "\(String(describing: glyph))")
        check("the menu-bar glyph carries a 1x and a 2x representation",
              (glyph?.representations.count ?? 0) >= 2)

        print("  " + String(repeating: "─", count: 56))
        print(failures == 0 ? "  ✅ all passed\n" : "  ❌ \(failures) failed\n")
        return failures == 0 ? 0 : 1
    }

    /// Renders the TypeSafe group from the entered figures: the heading, then one line per
    /// decision model (Jev, Clef) that has an entry, named so the two cannot be confused.
    /// There is no fetch behind this lane, so there is no capture, no error path and no
    /// store row: the only facts are each entered figure and its not-live label, and the
    /// text says exactly that. A stale figure adds the one line that fixes it, under its
    /// own model: how to re-enter.
    static func typeSafeStatusRowLines(now: Date = Date(),
                                       defaults: UserDefaults = TowerPreferences.shared) -> [String] {
        // No heading until some model has an entered balance: nothing ships by default.
        let models = TypeSafe.enteredModels(defaults: defaults)
        guard !models.isEmpty else { return [] }
        var lines = ["  " + pad("credits", 12) + "BALANCE"]
        for model in models {
            lines.append("      " + pad(model.rawValue, 6) + pad(model.vendor, 11)
                         + TypeSafe.statusRowText(model: model, now: now, defaults: defaults))
            if let hint = TypeSafe.reenterHint(model: model, now: now, defaults: defaults) {
                lines.append("            " + hint)
            }
        }
        return lines
    }

    /// Renders one persisted OpenRouter row as money rather than borrowing quota-window
    /// semantics that do not apply to a prepaid balance.
    /// A Muse, Devin or Antigravity row. The windows print under the names the row holds
    /// (`scoped` labels), never as 5h or 7d, and an unreadable lane prints "?" with its
    /// reason instead of a bar. Percentages come from the same `effective` and `trust`
    /// math as every other row, so an old Devin cache reads "~" (stale), not live.
    static func agentLaneStatusRowLines(_ account: AccountSnapshot, now: Date) -> [String] {
        let head = "  " + pad(account.nickname, 12) + pad(account.plan, 10) + "LANE"
        guard !account.scoped.isEmpty, account.capturedAt != nil else {
            return [head, "      ? " + (account.lastError ?? "no usage reading")]
        }
        var lines = [head]
        for window in account.scoped {
            let effective = AccountSnapshot.effective(
                pct: window.percent, resetsAt: window.resetsAt, now: now)
            let trust = AccountSnapshot.trust(
                pct: window.percent, resetsAt: window.resetsAt,
                capturedAt: account.capturedAt, now: now)
            let mark = trust == .stale ? "~" : ""
            let text = effective.pct.map { mark + String(Int($0.rounded())) + "% used" } ?? "?"
            let when = effective.reset ? "reset ✓"
                : (window.resetsAt.map { "resets " + clock($0) } ?? "-")
            lines.append("      " + pad(window.label, 8) + bar(effective.pct, trust: trust)
                + " " + pad(text, 11) + when)
        }
        var notes = ["read " + age(account.capturedAt, now: now)]
        if let source = account.source { notes.append(source) }
        if account.worstTrust(now: now) != .live { notes.append("stale, not counted") }
        lines.append("      " + notes.joined(separator: " · "))
        return lines
    }

    private static func openRouterStatusRowLines(
        _ account: AccountSnapshot, now: Date
    ) -> [String] {
        var facts = ["balance " + (account.balanceUSD.map { String(format: "$%.2f", $0) }
            ?? "unavailable")]
        facts.append(account.capturedAt.map { "captured " + age($0, now: now) }
            ?? "never captured")
        if let error = account.lastError { facts.append("⚠️ \(error)") }
        return [
            "  " + pad(account.nickname, 12) + "BALANCE",
            "      " + facts.joined(separator: " · "),
        ]
    }

    /// Renders one provider row for `tower status` from the persisted snapshot.
    ///
    /// OpenRouter takes a distinct monetary branch so it cannot inherit a 5h or 7d quota
    /// window, a traffic light, or a reset claim from the rankable providers.
    static func statusRowLines(
        _ account: AccountSnapshot, activeEmail: String?, refreshError: String?, now: Date
    ) -> [String] {
        if account.kind == .openrouter {
            return openRouterStatusRowLines(account, now: now)
        }
        if account.kind.isAgentLane {
            return agentLaneStatusRowLines(account, now: now)
        }

        let isActive = account.email == activeEmail && account.kind == .claude
        let fiveHour = account.effectiveFiveHour(now: now)
        let weekly = account.effectiveWeekly(now: now)
        // A light is an account-level claim, so it needs EVERY ranked window live. One
        // provably-reset window is not enough: the window we cannot see could be binding.
        let worst = account.trustedUsedPct(now: now)
        let head = (isActive ? "▶ " : "  ")
            + pad(account.nickname, 7)
            + pad(account.plan, 8)
            + light(worst, account.worstTrust(now: now))
        var lines = ["  " + head]

        if !account.isRecommendable(now: now) {
            lines.append("      " + (account.capturedAt == nil ? "never captured"
                : "unknown since " + age(account.capturedAt, now: now)))
            if let error = account.lastError, error != refreshError {
                lines.append("      ⚠️ " + error)
            }
            return lines
        }

        /// Renders one measured quota window and its freshness claim from the same clock.
        func quotaLine(_ label: String, _ value: (pct: Double?, reset: Bool), _ resetsAt: Date?,
                       _ trust: Trust) -> String {
            // "~" marks a number extrapolated from an old capture rather than read now.
            let mark = trust == .stale ? "~" : ""
            let percentage = value.pct.map { mark + String(Int($0.rounded())) + "% used" } ?? "?"
            let when = value.reset ? "reset ✓" : (resetsAt.map { "resets " + clock($0) } ?? "-")
            return "      " + pad(label, account.kind == .cursor ? 15 : 6) + bar(value.pct, trust: trust)
                + " " + pad(percentage, 11) + when
        }

        // Only windows the provider actually publishes. Codex reports a 7d window and
        // nothing else, and an absent 5h window is omitted rather than fabricated.
        if account.kind.hasFiveHourWindow {
            lines.append(quotaLine("5h", fiveHour, account.fiveHourResetsAt,
                                   account.trustFiveHour(now: now)))
        }
        if account.kind != .cursor {
            lines.append(quotaLine(account.kind.primaryWindowLabel, weekly, account.weeklyResetsAt,
                                   account.trustWeekly(now: now)))
        }
        if account.kind != .cursor, let balance = account.creditBalance {
            lines.append("      credits " + balance)
        }

        for scoped in account.scoped where account.kind == .cursor || (scoped.percent ?? 0) > 0 {
            // Same reset math as the main windows, so the number and freshness claim share
            // a basis.
            let effective = AccountSnapshot.effective(
                pct: scoped.percent, resetsAt: scoped.resetsAt, now: now)
            let label = account.kind == .cursor
                ? CursorPool.displayLabel(scoped.label) : String(scoped.label.prefix(5))
            lines.append(quotaLine(label, effective, scoped.resetsAt,
                                   AccountSnapshot.trust(pct: scoped.percent,
                                                         resetsAt: scoped.resetsAt,
                                                         capturedAt: account.capturedAt,
                                                         now: now)))
        }

        var notes: [String] = []
        if let model = account.model { notes.append("model \(model)") }
        if account.capturedAt == nil {
            notes.append("never captured, switch to it once")
        } else if !isActive {
            let suffix = account.worstTrust(now: now) == .live ? "" : " (stale, not counted)"
            notes.append("snapshot " + age(account.capturedAt, now: now) + suffix)
        }
        // The active account's row error generally matches the summary, so do not print it
        // twice. The OpenRouter branch always keeps its error because it has no refresh summary.
        if let error = account.lastError, error != refreshError { notes.append("⚠️ \(error)") }
        if !notes.isEmpty { lines.append("      " + notes.joined(separator: " · ")) }
        return lines
    }

    /// Renders one complete provider section, including its semantic heading and all rows.
    ///
    /// This is the final status-output branch so selftest can verify the same text that
    /// `run()` prints, rather than a parallel formatting approximation.
    private static func statusSectionLines(
        provider: Provider, rows: [AccountSnapshot], activeEmail: String?, refreshError: String?, now: Date
    ) -> [String] {
        guard !rows.isEmpty else { return [] }
        let noun = provider == .openrouter ? "balance" : "available"
        var lines = ["  " + provider.label.uppercased() + "  (\(rows.count) \(noun))"]
        for row in rows {
            lines.append(contentsOf: statusRowLines(
                row, activeEmail: activeEmail, refreshError: refreshError, now: now))
        }
        return lines
    }

    /// Refreshes persisted provider data once and prints the terminal status report.
    /// The two "room" lines that are not about a seat: how many sessions a full active
    /// meter stops, and whether the machine itself has room. Pure, so the wording is
    /// tested rather than eyeballed; `run()` prints exactly these.
    ///
    /// A missing reading names its cause. Before the first refresh (launch, and every
    /// panelshot) nothing was attempted, so "unavailable" and "could not be read" would
    /// report failures that never happened. After a refresh, a nil blast radius is
    /// either a probe that did not answer or no active Claude login to measure.
    /// The blast radius mark. Below the warn mark it takes the meter's own colour, so a seat
    /// the meter shows amber at 73 % is not called green beside it (2026-11-05).
    static func blastIcon(level: BlastRadius.Level, percent: Double?) -> String {
        switch level {
        case .warn: return "⚠️"
        case .stopped: return "⛔"
        case .unknown: return "❔"
        case .clear:
            guard let percent else { return "🟢" }
            switch BrailleMeterMath.level(usedPercent: percent) {
            case .high: return "🔴"
            case .watch: return "🟠"
            case .ok: return "🟢"
            }
        }
    }

    static func fleetLines(blast: BlastRadius?, machine: MachineLoad?,
                           read: FleetRead = .done(sessions: false)) -> [String] {
        var lines: [String] = []
        if let blast {
            let icon = blastIcon(level: blast.level, percent: blast.percentUsed)
            lines.append("  \(icon) Blast radius: " + blast.line)
            if blast.level == .warn || blast.level == .stopped,
               let moves = blast.moveFirstLine {
                lines.append("  " + moves)
            }
        } else {
            switch read {
            case .notYet:
                lines.append("  ❔ Blast radius: not read yet")
            case .done(sessions: false):
                lines.append("  ❔ Blast radius: session probe unavailable")
            case .done(sessions: true):
                lines.append("  ❔ Blast radius: no active Claude login to measure")
            }
        }
        if let machine {
            let icon = machine.level == .red ? "🔴" : machine.level == .amber ? "🟠" : "🟢"
            lines.append("  \(icon) Machine: " + machine.line
                + (machine.refusal.map { " (no room: \($0))" } ?? ""))
        } else if read == .notYet {
            lines.append("  ❔ Machine: load not read yet")
        } else {
            lines.append("  ❔ Machine: load could not be read")
        }
        return lines
    }

    /// Whether the fleet probes have run, so a missing reading can name its cause.
    enum FleetRead: Equatable {
        /// No refresh has run in this process: nothing was attempted, nothing failed.
        case notYet
        /// A refresh ran; `sessions` is whether the session probe answered.
        case done(sessions: Bool)
    }

    static func run() async {
        async let agentProbe = AgentProbe.fetch()
        let result = await Refresher.refreshActive()
        let agents = await agentProbe
        let accounts = result.accounts
        let activeEmail = result.activeEmail
        let now = Date()

        guard !accounts.isEmpty else {
            print("\n  No accounts captured yet.")
            print("  Claude Code keeps one credential at a time, so switch into an")
            print("  account and run this again to capture it.\n")
            return
        }

        // Lowest usage first among accounts we can vouch for, so the roomiest KNOWN account
        // is at the top and a stale number cannot jump the queue.
        let sorted = accounts.values.sorted { AccountSnapshot.ranked($0, $1, now: now) }

        // The SAME partition the menubar uses, reading the same persisted rule. `ranked`
        // already exists so the two surfaces cannot disagree about who has room; this is the
        // equivalent guarantee for who is resting.
        // The Rest-when selector was removed (issue #70 part 2), so status
        // always partitions under the default .either rule.
        let rule = AccountSnapshot.RestRule.either
        let split = AccountSnapshot.partition(Array(accounts.values), rule: rule, now: now)

        print("")
        // Width math: 2 + glyph(2) + 1 + 5 + 47 + 5 = 62, matching the
        // ruler printed right below, so the clock stays right-aligned.
        print("  📊 \(ProductIdentity.displayName.uppercased())" + pad("", 47) + clock(now))
        print("  " + String(repeating: "─", count: 62))

        // Grouped by provider. Without this the panel showed two rows both labelled "eve"
        // (the Claude max account and the Codex prolite account share one email) with
        // nothing to tell them apart. `statusSections` is the production assembly used by
        // the reachability assertion above; its renderer keeps OpenRouter monetary.
        for section in statusSections(active: split.active) {
            statusSectionLines(
                provider: section.provider, rows: section.rows, activeEmail: activeEmail,
                refreshError: result.outcome.errorText, now: now
            ).forEach { print($0) }
        }

        // The TypeSafe lane has no store row: the balance is entered by hand because
        // TypeSafe publishes no billing or usage endpoint, so its section prints as the
        // static label it is, beside the provider sections above.
        typeSafeStatusRowLines().forEach { print($0) }

        // Pi has no store row either: its spend is summed from its own session logs on
        // every cycle and set against the OpenRouter balance this same refresh read.
        PiLane.statusLines(result.lanes[.pi], openRouter: result.openRouterOutcome)
            .forEach { print($0) }

        if !split.resting.isEmpty {
            // Time-gated rows only: a stale row is not waiting on a clock.
            let opens = split.resting.filter { $0.1.isTimeGated }
                .compactMap { AccountSnapshot.reopening($0.0, now: now) }.min()
            print("  RESTING  (\(split.resting.count)"
                + (opens.map { ", first opens \(clock($0))" } ?? "") + ")")
            for (a, why) in split.resting {
                let when: String
                if why.isTimeGated, let d = AccountSnapshot.reopening(a, now: now) {
                    when = "opens " + clock(d)
                } else {
                    when = "switch to refresh"
                }
                let state = a.fiveHourUnreported(now: now) ? SeatUsagePresentation.fiveHourUnreportedText
                    : why.isStale && a.capturedAt != nil
                    ? "unknown since " + age(a.capturedAt, now: now) : why.text
                let restingRows = split.resting.map(\.0)
                print("    " + pad(AccountSnapshot.listName(a, among: restingRows), 15) + pad(state, 30) + when)
            }
        }

        print("  " + String(repeating: "─", count: 62))

        let active = accounts.values.first { $0.email == activeEmail && $0.kind == .claude }
        fleetLines(blast: BlastRadius.evaluate(active: active, sessions: agents, now: now),
                   machine: MachineLoad.sample(now: now),
                   read: .done(sessions: agents != nil)).forEach { print($0) }

        // Only accounts with a reading we can still vouch for may be recommended. Ranking a
        // live number against a day-old one is how this used to point at the wrong account.
        // Claude only. This recommendation is an answer to "what do I pass to
        // claude-switch", and a Codex row is not a candidate for that however much
        // headroom it has. Recommending one would send the user to the wrong CLI.
        let trusted = sorted.filter { $0.kind == .claude && $0.isRecommendable(now: now) }
        if let best = trusted.first, let pct = best.trustedUsedPct(now: now) {
            // Do not call a full account the roomiest one. It used to print "Most headroom:
            // x at 100% used" directly above "Exhausted: x".
            if pct >= 100 {
                print("  ⛔ Every account with a current reading is exhausted.")
            } else {
                print("  ✅ Most headroom: \(best.nickname) at \(Int(pct.rounded()))% used")
            }
        } else {
            print("  ⚠️ No account has a current enough reading to recommend.")
        }
        let blocked = trusted.filter { ($0.trustedUsedPct(now: now) ?? 0) >= 100 }
        if !blocked.isEmpty {
            print("  ⛔ Exhausted: " + blocked.map(\.nickname).joined(separator: ", "))
        }
        // An account can be fully live and still unusable for a given model, so say which.
        let scopedOut = sorted.filter { !$0.exhaustedScoped(now: now).isEmpty }
        if !scopedOut.isEmpty {
            let parts = scopedOut.map {
                "\($0.nickname) (\($0.exhaustedScoped(now: now).joined(separator: ", ")))"
            }
            // Informational, not a verdict. These accounts remain recommendable: the only
            // scoped bucket this API returns is Fable, and settings.json pins opus[1m].
            print("  ℹ️ Model limit reached: " + parts.joined(separator: ", ")
                + " (still usable for other models)")
        }
        // Claude only, because the remedy named here is Claude's. Codex freshness is not
        // fixed by switching into anything: its numbers come from session files on disk and
        // advance when a Codex session runs.
        let stale = sorted.filter {
            $0.kind == .claude && $0.capturedAt != nil && $0.worstTrust(now: now) != .live
        }
        if !stale.isEmpty {
            print("  🕑 Too stale to rank: " + stale.map(\.nickname).joined(separator: ", ")
                + " (switch into one to refresh it)")
        }
        // Cursor refreshes itself every cycle, so a stale Cursor row is not "you have not
        // switched into it" — it is "the dashboard call is failing", which is the one thing
        // a silent row would hide. Say so, with whatever the row's own error was.
        let cursorStale = sorted.filter {
            $0.kind == .cursor && ($0.capturedAt == nil || $0.worstTrust(now: now) != .live)
        }
        for c in cursorStale {
            print("  🕑 Cursor \(c.nickname): "
                + (c.lastError ?? "no current reading (last capture \(age(c.capturedAt, now: now)))"))
        }
        let uncaptured = sorted.filter { $0.capturedAt == nil }
        if !uncaptured.isEmpty {
            print("  ⚪️ Not yet captured: " + uncaptured.map(\.nickname).joined(separator: ", "))
        }
        if let err = result.outcome.errorText {
            print("  ⚠️ refresh failed: \(err)")
        }
        print("")
    }
}
