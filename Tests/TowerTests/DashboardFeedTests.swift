import Foundation
import JavaScriptCore
import XCTest
@testable import Tower

/// The full dashboard is a web view hosting the approved page. Its data is one feed built
/// from Tower's own read tools, never a network call; the page may load nothing else.
final class DashboardFeedTests: XCTestCase {
    private var fixture: MCPFixture!

    override func setUpWithError() throws { fixture = try MCPFixture() }
    override func tearDown() { fixture?.tearDown(); fixture = nil }

    // MARK: Feed

    func testFeedCarriesEveryReadToolTheDashboardShows() async throws {
        let feed = await DashboardFeed.build(service: TowerMCPService(env: fixture.environment()))
        for key in DashboardFeed.toolKeys {
            XCTAssertNotNil(feed[key].objectValue, "feed is missing \(key)")
        }
        XCTAssertEqual(DashboardFeed.toolKeys.count, 10)
        XCTAssertNotNil(feed["generatedAt"].stringValue)
    }

    /// The panel showed "Waiting for Tower's first read" for as long as the session probe ran
    /// (about 10 s with 28 live sessions): the feed was one value and waited on its slowest
    /// tool. The first paint must not wait on the probe; the page already draws an
    /// unavailable probe as "sessions unavailable", and a second, full feed fills it in.
    func testFirstPaintDoesNotWaitOnASlowSessionProbe() async throws {
        var env = fixture.environment()
        env.sessions = {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            return nil
        }
        let started = Date()
        // An explicit 1.0 s deadline keeps the margin real: the probe sleeps 6 s, the bound
        // is 3 s, so a loaded runner has about 2 s of slack, not the 0.4 s the 2.5 s default left.
        let feed = await DashboardFeed.build(service: TowerMCPService(env: env), sessionDeadline: 1.0)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3.0,"the first feed waited \(elapsed) s on the session probe")
        XCTAssertEqual(feed["sessions"]["available"].boolValue, false, "a probe that has not answered is unavailable, never zero sessions")
        XCTAssertEqual(feed["sessionsDeferred"].boolValue, true, "the controller needs to know a full feed must follow")
        for key in DashboardFeed.toolKeys {
            XCTAssertNotNil(feed[key].objectValue, "feed is missing \(key)")
        }
    }

    /// A slow open builds twice (first paint, then the full feed). The CLI session probe is
    /// uncached, so the second build must await the probe already running, not start another
    /// and throw the first away (Codex review of tower#173).
    func testASlowOpenRunsTheSessionProbeOnce() async throws {
        let calls = ProbeCalls()
        var env = fixture.environment()
        env.sessions = {
            calls.bump()
            try? await Task.sleep(nanoseconds: 700_000_000)
            return nil
        }
        let service = TowerMCPService(env: env)
        let probe = DashboardFeed.SessionsProbe()
        let first = await DashboardFeed.build(service: service, sessionDeadline: 0.2, probe: probe)
        XCTAssertEqual(first["sessionsDeferred"].boolValue, true, "the probe must still be running for this test to mean anything")
        _ = await DashboardFeed.build(service: service, sessionDeadline: nil, probe: probe)
        XCTAssertEqual(calls.count, 1, "the full feed started a second session probe")
    }

    private final class ProbeCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    /// `tower dashboard-feed` builds once and prints: it never follows with a second build, so
    /// the default must wait for the whole probe. Only the panel's first paint passes a
    /// deadline (Codex review of tower#173). The probe sleeps past the old 2.5 s default.
    func testTheDefaultBuildWaitsForASlowProbeForTheCLI() async throws {
        var env = fixture.environment()
        env.sessions = {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return nil
        }
        let started = Date()
        let feed = await DashboardFeed.build(service: TowerMCPService(env: env))
        XCTAssertEqual(feed["sessionsDeferred"].boolValue, false, "the CLI feed gave up on the probe and never builds again")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 2.9, "the default build did not wait for the probe")
    }

    /// The full feed, with no deadline, still waits for the probe and says so.
    func testFullFeedWaitsForTheSessionProbe() async throws {
        var env = fixture.environment()
        env.sessions = {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return nil
        }
        let started = Date()
        let feed = await DashboardFeed.build(service: TowerMCPService(env: env), sessionDeadline: nil)
        // Explicit false, so a missing key fails; and it really waited for the 0.3 s probe.
        XCTAssertEqual(feed["sessionsDeferred"].boolValue, false)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25, "the full feed did not wait for the probe")
    }

    func testFeedNeverCarriesAnEmail() async throws {
        let feed = await DashboardFeed.build(service: TowerMCPService(env: fixture.environment()))
        let text = String(decoding: feed.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains(MCPFixture.activeEmail), "the active login's email leaked into the page feed")
        XCTAssertFalse(text.contains(MCPFixture.staleEmail))
        XCTAssertNil(text.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}"#, options: .regularExpression),
                     "no email shape may reach the web view")
    }

    func testFeedNeverCallsAWriteOrRefreshTool() {
        let writes: Set<String> = ["tower_refresh", "tower_rotate", "tower_retrust", "tower_forget_seats",
                                   "tower_config_set", "tower_alert_ack", "tower_seats", "tower_panelshot", "tower_selftest"]
        XCTAssertTrue(Set(DashboardFeed.toolNames).isDisjoint(with: writes), "the feed is reads only")
    }

    func testScrubReplacesEmailsInsideNestedStrings() {
        let raw: JSON = .object(["a": .array([.string("16 sessions ride a.b@c.io at 72 %")]), "b": .string("x")])
        let clean = DashboardFeed.scrub(raw)
        XCTAssertEqual(clean["a"].arrayValue?.first?.stringValue, "16 sessions ride seat at 72 %")
        XCTAssertEqual(clean["b"].stringValue, "x")
    }

    func testSessionOwnerIsNamedBeforeTheScrubHidesTheEmail() {
        let accounts: JSON = .object(["accounts": .array([
            .object(["provider": .string("claude"), "email": .string("a@x.io"), "nickname": .string("ops1")]),
            .object(["provider": .string("claude"), "email": .string("b@x.io"), "nickname": .string("ops2")]),
        ])])
        let sessions: JSON = .object(["interactive": .array([
            .object(["label": .string("lane-1"), "accountEmail": .string("b@x.io")]),
            .object(["label": .string("lane-2"), "accountEmail": .null]),
        ])])
        let named = DashboardFeed.nameSessionOwners(sessions, accounts: accounts)
        XCTAssertEqual(named["interactive"][0]["accountNickname"].stringValue, "ops2", "the owner is the seat whose email matched, not the first seat")
        XCTAssertTrue(named["interactive"][1]["accountNickname"].isNull)
        XCTAssertEqual(DashboardFeed.scrub(named)["interactive"][0]["accountNickname"].stringValue, "ops2")
    }

    // MARK: Into the page

    func testJSLiteralCannotCloseTheScriptOrBreakALine() throws {
        let hostile: JSON = .object(["t": .string("</script><script>alert(1)</script>\u{2028}\u{2029}")])
        let literal = DashboardFeed.jsLiteral(hostile)
        XCTAssertFalse(literal.lowercased().contains("</script"))
        XCTAssertFalse(literal.contains("\u{2028}"))
        XCTAssertFalse(literal.contains("\u{2029}"))
        // Still the same JSON once a JS engine reads the escapes back.
        let back = literal.replacingOccurrences(of: "<\\/", with: "</")
            .replacingOccurrences(of: "\\u2028", with: "\u{2028}").replacingOccurrences(of: "\\u2029", with: "\u{2029}")
        XCTAssertEqual(try JSON.parse(Data(back.utf8)), hostile)
    }

    // MARK: No network

    func testNavigationPolicyAllowsOnlyThePageItself() {
        XCTAssertTrue(DashboardFeed.NavigationPolicy.allows(URL(string: "about:blank")!))
        for s in ["https://example.com/", "http://localhost:8080/", "file:///etc/hosts", "ws://127.0.0.1/", "wss://x.io/", "ftp://x/"] {
            XCTAssertFalse(DashboardFeed.NavigationPolicy.allows(URL(string: s)!), "\(s) must be refused")
        }
        XCTAssertFalse(DashboardFeed.NavigationPolicy.allows(nil))
    }

    func testContentRulesBlockEveryNetworkScheme() throws {
        let rules = try JSON.parse(Data(DashboardFeed.contentRules.utf8))
        let filters = rules.arrayValue?.compactMap { $0["trigger"]["url-filter"].stringValue } ?? []
        for scheme in ["https?", "wss?", "file", "ftp"] {
            XCTAssertTrue(filters.contains { $0.hasPrefix("^" + scheme + ":") }, "no block rule for \(scheme)")
        }
        XCTAssertTrue(rules.arrayValue?.allSatisfy { $0["action"]["type"].stringValue == "block" } ?? false)
    }

    // MARK: The page

    private func page() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(DashboardFeed.pageRepoPath), encoding: .utf8)
    }

    func testPageLoadsNothingFromOutside() throws {
        let html = try page()
        for banned in ["http://", "https://", "fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "import(", "sendBeacon", "<link", "@import", "src=\"//"] {
            XCTAssertFalse(html.contains(banned), "page holds \(banned)")
        }
    }

    func testPageTakesTheFeedAndDrawsTheApprovedViews() throws {
        let html = try page()
        XCTAssertTrue(html.contains("window.towerUpdate="), "Swift pushes the feed through window.towerUpdate")
        XCTAssertTrue(html.contains("['dash',"), "the full dashboard view")
        XCTAssertTrue(html.contains("['dial',"), "the week dial behind the switcher")
        XCTAssertFalse(html.contains("/*SNAPSHOT*/"), "no build placeholder left in the shipped page")
        XCTAssertFalse(html.contains("—") || html.contains("–"), "no em or en dash")
    }

    // MARK: The page, executed
    //
    // The shipped page script runs in JavaScriptCore against a stub DOM, a feed goes through
    // window.towerUpdate, and the stage markup is read back. Codex and review b114 on #152
    // found four defects that a string check on the file could never fail.

    /// Just enough DOM for the page: elements that keep their innerHTML, no layout.
    private static let domStub = """
    var els = {};
    function el(id) { return els[id] || (els[id] = {id: id, innerHTML: '', textContent: '', style: {}, insertAdjacentHTML: function() {}, querySelectorAll: function() { return []; }, addEventListener: function() {}, remove: function() {}}); }
    var window = {};
    var document = {getElementById: el, addEventListener: function() {}};
    var performance = {now: function() { return 0; }};
    var requestAnimationFrame = function() {};
    var matchMedia = function() { return {matches: false}; };
    var innerWidth = 1000;
    """

    /// Feed builders, one per scenario. `now` is fixed so the output does not depend on the clock.
    private static let feedKit = """
    var now = Date.parse('2026-11-07T10:00:00Z');
    function iso(ms) { return new Date(ms).toISOString(); }
    function wins(pct, trust) { return [{name: '7d', percentUsed: pct, resetsAt: iso(now + 3 * 864e5), trust: trust || 'live'}, {name: '5h', percentUsed: pct, resetsAt: iso(now + 3 * 36e5), trust: trust || 'live'}]; }
    function seat(nick, provider, windows, active) { return {nickname: nick, provider: provider, plan: 'Max', tier: 't', model: 'm', isActive: !!active, capturedAt: iso(now - 60000), lastError: null, windows: windows}; }
    function feed(adviceOver, sessionsOver) {
      var f = {generatedAt: iso(now),
        accounts: {accounts: [seat('main', 'claude', wins(40), true), seat('alt', 'claude', wins(10), false)]},
        advice: {kind: 'stay', nickname: 'main', percentUsed: 40, roomPct: null, next: null, earliestReset: null},
        sessions: {available: true, interactive: [], backgroundCount: 0},
        status: {}, room: {}, alerts: {accounts: []}, lanes: {lanes: []}, freshness: {rules: {}}, openrouterHistory: {samples: []}, icons: {}};
      if (adviceOver) { for (var k in adviceOver) f.advice[k] = adviceOver[k]; }
      if (sessionsOver) { for (var s in sessionsOver) f.sessions[s] = sessionsOver[s]; }
      return f;
    }
    """

    /// The page measures ages against window.towerClock. By default the clock reads the moment of the feed it
    /// was last given, so a feed is fresh unless a test sets its own clock (stage(_:clock:)).
    private static let clockKit = """
    window.towerClock = function() { return (window.__feedAt || 0); };
    (function() { var take = window.towerUpdate; window.towerUpdate = function(f) { window.__feedAt = Date.parse(f.generatedAt); return take(f); }; })();
    """

    /// Draws `feedExpression` (JS that yields a feed) on one surface and returns the stage markup.
    private func stage(_ feedExpression: String, surface: String = "dash", clock: String? = nil) throws -> String {
        let html = try page()
        let open = try XCTUnwrap(html.range(of: "<script>"))
        let close = try XCTUnwrap(html.range(of: "</script>", options: .backwards))
        let script = String(html[open.upperBound..<close.lowerBound])
        let context = try XCTUnwrap(JSContext())
        var thrown: [String] = []
        context.exceptionHandler = { _, error in thrown.append(error?.toString() ?? "unknown") }
        context.evaluateScript(Self.domStub)
        context.evaluateScript(Self.feedKit)
        context.evaluateScript(script)
        context.evaluateScript(Self.clockKit)
        // The wall clock is injected the way the page asks for it (window.towerClock), in the feed's own
        // milliseconds, so an age is measured against it and not against the feed's generatedAt.
        if let clock { context.evaluateScript("window.towerClock = function() { return \(clock); };") }
        context.evaluateScript("window.towerSurface('\(surface)'); window.towerUpdate(\(feedExpression)); window.towerSurface('\(surface)');")
        XCTAssertEqual(thrown, [], "the page threw while drawing")
        return context.evaluateScript("els.stage.innerHTML")?.toString() ?? ""
    }

    private let surfaces = ["dash", "dial"]

    /// P1 (Codex): one account with no quota windows (a Cursor row without pool readings) used to
    /// throw in seat() and replace the whole dashboard with an error notice.
    func testPageDrawsAnAccountWithNoWindows() throws {
        for surface in surfaces {
            let markup = try stage("(function() { var f = feed(); f.accounts.accounts.push(seat('cur', 'cursor', [], false)); return f; })()", surface: surface)
            XCTAssertFalse(markup.contains("could not draw"), "\(surface): one windowless account blanked the page")
            XCTAssertTrue(markup.contains("YES"), "\(surface): the healthy active seat still reads YES")
        }
    }

    /// P1 (Codex, b114): the verdict follows tower_advice, and a used-up seat never reads YES.
    func testPageVerdictFollowsTheAdviceKind() throws {
        for surface in surfaces {
            let stay = try stage("feed()", surface: surface)
            XCTAssertTrue(stay.contains("YES") && stay.contains("Stay on main"), "\(surface): stay reads YES and Stay on")

            let toSwitch = try stage("feed({kind: 'switch', nickname: 'alt', percentUsed: 10})", surface: surface)
            XCTAssertTrue(toSwitch.contains("SWITCH") && toSwitch.contains("Switch to alt"), "\(surface): switch advice reads SWITCH")
            XCTAssertFalse(toSwitch.contains("YES"), "\(surface): a switch is not a YES")

            let resting = try stage("feed({kind: 'allResting', nickname: null, percentUsed: null, earliestReset: iso(now + 5 * 36e5)})", surface: surface)
            XCTAssertTrue(resting.contains("WAIT") && resting.contains("Nothing has room"), "\(surface): allResting reads WAIT")
            XCTAssertFalse(resting.contains("YES"), "\(surface): nothing has room is not a YES")

            let unknown = try stage("feed({kind: 'activeUnknown', nickname: 'alt', percentUsed: null, roomPct: 90})", surface: surface)
            XCTAssertTrue(unknown.contains("CAN'T TELL"), "\(surface): an unverified active seat reads CAN'T TELL")
            XCTAssertFalse(unknown.contains("YES"), "\(surface): unknown is not a YES")

            let exhausted = try stage("(function() { var f = feed(); f.accounts.accounts[0].windows = [{name: '7d', percentUsed: 100, resetsAt: iso(now + 3 * 864e5), trust: 'live'}]; return f; })()", surface: surface)
            XCTAssertTrue(exhausted.contains("WAIT") && exhausted.contains("is used up"), "\(surface): a used up active seat reads WAIT")
            XCTAssertFalse(exhausted.contains("YES"), "\(surface): an exhausted seat is not a YES")

            let stale = try stage("(function() { var f = feed(); f.accounts.accounts[0].windows = wins(40, 'stale'); return f; })()", surface: surface)
            // Approved mockup: the headline seat must be live. A stale active seat is no longer PROBABLY a seat
            // with a number; it is CAN'T TELL with its age and a Refresh.
            XCTAssertTrue(stale.contains("CAN'T TELL") && stale.contains("Press Refresh"), "\(surface): a stale read reads CAN'T TELL")
            XCTAssertFalse(stale.contains("PROBABLY"), "\(surface): a stale read is not a PROBABLY")
        }
    }

    /// 2026-11-09, ops6 after /login: 7d live, 5h absent from the reply. The dial said CAN'T TELL,
    /// offered a Refresh that returns the same reply, and printed the live week as an upper bound.
    private static let weekLiveFiveHourAbsent = """
    (function() { var f = feed({kind: 'stay', nickname: 'main', percentUsed: 2, roomPct: null});
      f.accounts.accounts[0].model = null;
      f.accounts.accounts[0].windows = [{name: '5h', percentUsed: null, resetsAt: null, trust: 'notReported'},
        {name: '7d', percentUsed: 2, resetsAt: iso(now + 6 * 864e5), trust: 'live'}];
      return f; })()
    """

    func testALiveWeekWithNoFiveHourReadingIsNotCantTell() throws {
        for surface in surfaces {
            let markup = try stage(Self.weekLiveFiveHourAbsent, surface: surface)
            XCTAssertFalse(markup.contains("CAN'T TELL"), "\(surface): the week is known, only 5h is not")
            XCTAssertFalse(markup.contains("Refresh now"), "\(surface): a refresh returns the same reply")
            XCTAssertFalse(markup.contains("PROBABLY"), "\(surface): a window not reported is not a PROBABLY (2026-11-18)")
            XCTAssertTrue(markup.contains("YES"), "\(surface): the live week is a verdict")
        }
    }

    func testALiveWeekIsAnExactNumberWithoutAFiveHourReading() throws {
        for surface in surfaces {
            let markup = try stage(Self.weekLiveFiveHourAbsent, surface: surface)
            XCTAssertTrue(markup.contains("98 %"), "\(surface): the live week is printed")
            XCTAssertFalse(markup.contains("≤98"), "\(surface): a live reading is not an upper bound")
        }
    }

    func testAnAgedReadingStaysAnUpperBound() throws {
        let aged = """
        (function() { var f = feed(); f.accounts.accounts[0].windows = [{name: '5h', percentUsed: 1, resetsAt: iso(now + 36e5), trust: 'stale'},
          {name: '7d', percentUsed: 2, resetsAt: iso(now + 6 * 864e5), trust: 'live'}]; return f; })()
        """
        for surface in surfaces {
            XCTAssertTrue(try stage(aged, surface: surface).contains("≤98"), "\(surface): a stale window still bounds the number")
        }
    }

    func testASeatWithNoFiveHourReadingStillDoesNotCountAsReady() throws {
        let other = """
        (function() { var f = feed(); f.accounts.accounts[1].windows = [{name: '5h', percentUsed: null, resetsAt: null, trust: 'unknown'},
          {name: '7d', percentUsed: 2, resetsAt: iso(now + 6 * 864e5), trust: 'live'}]; return f; })()
        """
        XCTAssertTrue(try stage(other).contains("1 of 2 usable"), "the 08-03 rule: an unread 5h window does not rank")
    }

    func testTheDialRowDoesNotPrintAQuestionMarkForAnUnknownModel() throws {
        let markup = try stage(Self.weekLiveFiveHourAbsent, surface: "dial")
        XCTAssertFalse(markup.contains("<b>main</b><span class=\"dim\">?</span>"), "no model known means nothing to print")
    }

    // MARK: The Week dial list says room left, in one form (tower-loop round 1, 2026-11-11)
    //
    // His screenshot of 12:20: the dial list printed used percent with a plus sign ("+95 %"),
    // in green, beside "100 %" and "≤100 %" in the same column. A full seat read as the safest
    // one, and a signed-out seat read "open ≤100 %".

    /// The dial row of `nick` in the stage markup (from its name to the end of its row).
    private func dialRow(_ markup: String, _ nick: String) -> String {
        guard let start = markup.range(of: "<b>\(nick)</b>") else { return "" }
        let rest = markup[start.lowerBound...]
        let end = rest.range(of: "</div>")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func testTheDialListPrintsRoomLeftNotUsedWithAPlusSign() throws {
        let markup = try stage("feed()", surface: "dial")
        let alt = dialRow(markup, "alt")
        XCTAssertFalse(alt.contains("+10 %"), "used percent with a plus sign: \(alt)")
        XCTAssertTrue(alt.contains("90 %"), "alt has 90 % room left: \(alt)")
        XCTAssertTrue(markup.contains("Room left"), "the column says what its number is")
    }

    func testANearlyFullSeatIsNeverGreenInTheDialList() throws {
        // 94 % used: one point under Tower's cap (95), so it is still a number, not "full".
        let nearlyFull = "(function() { var f = feed(); f.accounts.accounts[1].windows = wins(94); return f; })()"
        let alt = dialRow(try stage(nearlyFull, surface: "dial"), "alt")
        XCTAssertTrue(alt.contains("6 %"), "6 % room left: \(alt)")
        XCTAssertTrue(alt.contains("t-warn"), "6 % room reads amber: \(alt)")
        XCTAssertFalse(alt.contains("t-good") || alt.contains("gain"), "a nearly full seat is never green: \(alt)")
    }

    func testASignedOutSeatSaysLoginNotOpen() throws {
        let signedOut = "(function() { var f = feed(); f.accounts.accounts[1].lastError = 'needs login'; f.accounts.accounts[1].windows = wins(0, 'stale'); return f; })()"
        let alt = dialRow(try stage(signedOut, surface: "dial"), "alt")
        XCTAssertTrue(alt.contains("signed out"), "the reset column names the state: \(alt)")
        XCTAssertTrue(alt.contains("/login"), "the room column names the fix: \(alt)")
        XCTAssertFalse(alt.contains("open"), "a signed-out seat is not open: \(alt)")
    }

    func testTheDialListExplainsTheUpperBoundMark() throws {
        let cached = "(function() { var f = feed(); f.accounts.accounts[1].windows = wins(10, 'stale'); return f; })()"
        let markup = try stage(cached, surface: "dial")
        XCTAssertTrue(markup.contains("≤90 %"), "a cached reading stays an upper bound")
        XCTAssertTrue(markup.contains("≤ cached, at most"), "the list says what ≤ means")
        XCTAssertFalse(try stage("feed()", surface: "dial").contains("≤ cached"), "no note when nothing is cached")
    }

    func testTheFooterNamesTheAlertsAndTheUnknownOwners() throws {
        let alerted = """
        (function() { var f = feed(null, {interactive: [{label: 'lane-a', busy: true}, {label: 'lane-b', busy: false}]});
          f.alerts.accounts = [{nickname: 'main', provider: 'claude', crossing: 'red', announced: [], pending: []}]; return f; })()
        """
        let markup = try stage(alerted, surface: "dial")
        XCTAssertFalse(markup.contains("owner ?"), "a bare question mark says nothing")
        // Round 4 (critic E 4): "account not known for 2" and "over the red rail" were jargon.
        XCTAssertTrue(markup.contains("2 with no known account"), "the footer says what is unknown")
        XCTAssertTrue(markup.contains("main used 90 % or more"), "the footer names the alert and its mark")
        XCTAssertFalse(markup.contains("rail"), "no rail jargon")
    }

    // MARK: Round 4 (tower-loop, critic on 056611f)

    /// E: "$11.10, $0.58/d" in the footer did not say what it was.
    func testTheFooterSaysWhatTheMoneyIs() throws {
        let funded = "(function() { var f = feed(); f.openrouterHistory = {samples: [{capturedAt: iso(now - 864e5), available: 12.5, totalCredits: 20}, {capturedAt: iso(now - 6e4), available: 11.1, totalCredits: 20}]}; return f; })()"
        let markup = try stage(funded, surface: "dial")
        XCTAssertTrue(markup.contains("OpenRouter $11.10 left, $"), "the balance names its service: \(markup.suffix(900))")
        XCTAssertTrue(markup.contains(" a day"), "spend a day")
        XCTAssertFalse(markup.contains("/d<"), "no bare /d")
        let unread = try stage("feed()", surface: "dial")
        XCTAssertTrue(unread.contains("OpenRouter balance not read"), "no balance says so in words")
        XCTAssertFalse(unread.contains("OpenRouter ? left"), "no bare ?")
    }

    /// C: "12.4× pace" in the verdict line never said what the multiple is of.
    func testTheVerdictLineSaysWhatThePaceMultipleMeans() throws {
        let fiveBinds = "(function() { var f = feed(); f.accounts.accounts[0].windows = [{name: '7d', percentUsed: 30, resetsAt: iso(now + 3 * 864e5), trust: 'live'}, {name: '5h', percentUsed: 60, resetsAt: iso(now + 3 * 36e5), trust: 'live'}]; return f; })()"
        let markup = try stage(fiveBinds, surface: "dial")
        XCTAssertTrue(markup.contains("× the even rate"), "the multiple names its base")
        XCTAssertFalse(markup.contains("× pace,"), "no bare pace multiple")
    }

    // MARK: Round 5 (critic on 0d3fa14, I 4)

    /// The footer listed ops7 as "used 90 % or more" while its row said signed out. A signed-out seat's
    /// fix is the sign-in, so the alert names only seats you can use.
    func testTheFooterAlertSkipsASignedOutSeat() throws {
        let both = """
        (function() { var f = feed(); f.accounts.accounts[1].lastError = 'needs login'; f.accounts.accounts[1].windows = wins(0, 'stale');
          f.alerts.accounts = [{nickname: 'main', provider: 'claude', crossing: 'red', announced: [], pending: []},
                               {nickname: 'alt', provider: 'claude', crossing: 'red', announced: [], pending: []}]; return f; })()
        """
        let markup = try stage(both, surface: "dial")
        XCTAssertTrue(markup.contains("main used 90 % or more"), "the usable seat is named")
        XCTAssertFalse(markup.contains("alt used"), "the signed-out seat is not")
    }

    /// Live capture 2026-11-11 (round 6): yai2g needed a login but its row said "full", because the page
    /// checked the old full reading before the error. The fix for a signed-out seat is the sign-in.
    func testASignedOutSeatWithAFullReadingAsksForTheLogin() throws {
        let out = """
        (function() { var f = feed(); f.accounts.accounts[1].lastError = 'needs login';
          f.accounts.accounts[1].windows = [{name: '7d', percentUsed: 100, resetsAt: iso(now + 2 * 864e5), trust: 'stale'}]; return f; })()
        """
        let markup = try stage(out, surface: "dial")
        XCTAssertTrue(markup.contains("class=\"n act\">/login<"), "the row names the sign-in")
        // b146 P3 on #184: the sign-in comes first, but the seat may still be full after it.
        XCTAssertTrue(markup.contains(">full till "), "the row keeps the old full reading as a note")
    }

    /// I (critic on 445340b, 4): the header said "First back Wed 20:30" from Tower's advice while the dial
    /// centre named another seat at Wed 20:00. Both now name one seat, the one the centre names.
    func testTheHeaderAndTheCentreNameTheSameFirstSeatBack() throws {
        let wait = """
        (function() { var f = feed({kind: 'allResting', nickname: null, percentUsed: null, earliestReset: iso(now + 5 * 36e5)});
          f.accounts.accounts[1].windows = [{name: '7d', percentUsed: 100, resetsAt: iso(now + 2 * 36e5), trust: 'live'}]; return f; })()
        """
        let markup = try stage(wait, surface: "dial")
        XCTAssertTrue(markup.contains("First back alt"), "the header names the seat the centre names")
    }

    /// H (critic on b19a3a1, 7; runner 2026-11-11): a row read 4 days ago looked like one read 2 minutes ago.
    /// A row Tower cannot trust (any window past the 15 minute line) says "stale" beside its read age.
    func testAStaleRowSaysStaleAndAFreshOneDoesNot() throws {
        let stale = "(function() { var f = feed(); f.accounts.accounts[1].windows = wins(40, 'stale'); return f; })()"
        let markup = try stage(stale, surface: "dial")
        let row = try NSRegularExpression(pattern: "<div class=\"drow [^\"]*\"[^>]*><span class=\"nm\"><b>(\\w+)</b>.*?</div>")
        let ns = markup as NSString
        var said: [String: String] = [:]
        for hit in row.matches(in: markup, range: NSRange(location: 0, length: ns.length)) {
            said[ns.substring(with: hit.range(at: 1))] = ns.substring(with: hit.range)
        }
        XCTAssertTrue(try XCTUnwrap(said["alt"]).contains("stale"), "the stale row says so")
        XCTAssertFalse(try XCTUnwrap(said["main"]).contains("stale"), "a live row does not")
    }

    /// E (critic on b19a3a1, 6): the active ops7 had no 5h reading, and only the header said so; its row and
    /// its room read like a full answer. A Claude row with no 5h reading says so, and a row that has one does not.
    func testAClaudeRowWithNoFiveHourReadingSaysSo() throws {
        let noFive = "(function() { var f = feed(); f.accounts.accounts[0].windows = [{name: '5h', percentUsed: null, resetsAt: null, trust: 'unknown'}, {name: '7d', percentUsed: 65, resetsAt: iso(now + 2 * 864e5), trust: 'live'}]; return f; })()"
        let markup = try stage(noFive, surface: "dial")
        let row = try NSRegularExpression(pattern: "<div class=\"drow [^\"]*\"[^>]*><span class=\"nm\"><b>(\\w+)</b>.*?</div>")
        let ns = markup as NSString
        var said: [String: String] = [:]
        for hit in row.matches(in: markup, range: NSRange(location: 0, length: ns.length)) {
            said[ns.substring(with: hit.range(at: 1))] = ns.substring(with: hit.range)
        }
        XCTAssertTrue(try XCTUnwrap(said["main"]).contains("no 5h"), "the row names the gap")
        XCTAssertFalse(try XCTUnwrap(said["alt"]).contains("no 5h"), "a row with a 5h reading does not")
        XCTAssertFalse(try XCTUnwrap(said["main"]).contains("stale"), "a missing 5h reading is not a stale one")
    }

    /// G (critic on b19a3a1, 6): "ops2, ops4, ops3 +1 used 90 % or more" hid a seat behind "+1". Every seat
    /// over a mark is named.
    func testTheFooterAlertNamesEverySeatOverAMark() throws {
        let many = """
        (function() { var f = feed(); var names = ['main', 'alt', 'c1', 'c2', 'c3'];
          names.slice(2).forEach(function(n) { f.accounts.accounts.push(seat(n, 'claude', wins(10, 'live'), false)); });
          f.alerts.accounts = names.map(function(n) { return {nickname: n, provider: 'claude', crossing: 'red', announced: [], pending: []}; });
          return f; })()
        """
        let markup = try stage(many, surface: "dial")
        XCTAssertTrue(markup.contains("main, alt, c1, c2, c3 used 90 % or more"), "all five are named")
        XCTAssertFalse(markup.contains(" +2 used"), "none hides behind a count")
    }

    /// The centre named the first full seat to come back under "next reset", while another seat reset sooner.
    func testTheDialCentreSaysWhichResetItNames() throws {
        let full = "(function() { var f = feed(); f.accounts.accounts[1].windows = [{name: '7d', percentUsed: 100, resetsAt: iso(now + 2 * 864e5), trust: 'live'}]; return f; })()"
        let markup = try stage(full, surface: "dial")
        XCTAssertTrue(markup.contains("next full seat back"), "the centre says it names a full seat")
        XCTAssertTrue(try stage("feed()", surface: "dial").contains(">next reset<"), "with none full it is the next reset")
    }

    /// D: a ring with no reset due was drawn in the green of room even when its reading was weeks old.
    func testARingWithNoResetDueIsGreenOnlyWhenItsReadingIsLive() throws {
        let cached = "(function() { var f = feed(); f.accounts.accounts[1].windows = [{name: '7d', percentUsed: 0, resetsAt: null, trust: 'stale'}]; return f; })()"
        let markup = try stage(cached, surface: "dial")
        let start = try XCTUnwrap(markup.range(of: "<g data-tip=\"alt (claude)"), "the alt ring group")
        let rest = markup[start.lowerBound...]
        let ring = String(rest[..<(rest.range(of: "</g>")?.lowerBound ?? rest.endIndex)])
        XCTAssertFalse(ring.contains("#62c073"), "an old reading is not green: \(ring)")
        XCTAssertTrue(ring.contains("#aab2c0"), "grey: \(ring)")
    }

    /// D: the "signed out" chip wore an alarm colour; it is a state to fix, not a failure.
    func testTheSignedOutChipIsNeutral() throws {
        let signedOut = "(function() { var f = feed(); f.accounts.accounts[1].lastError = 'needs login'; f.accounts.accounts[1].windows = wins(0, 'stale'); return f; })()"
        let markup = try stage(signedOut, surface: "dial")
        XCTAssertTrue(markup.contains("p-idle\">1 signed out"), "neutral chip")
        XCTAssertFalse(markup.contains("p-out\">1 signed out"), "no alarm colour")
    }

    // MARK: Round 2 (tower-loop, 2026-11-11): the Week dial is the face

    /// Stage markup with no surface chosen: what the page opens on.
    private func firstStage(_ feedExpression: String) throws -> String {
        let html = try page()
        let open = try XCTUnwrap(html.range(of: "<script>"))
        let close = try XCTUnwrap(html.range(of: "</script>", options: .backwards))
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(Self.domStub)
        context.evaluateScript(Self.feedKit)
        context.evaluateScript(String(html[open.upperBound..<close.lowerBound]))
        context.evaluateScript(Self.clockKit)
        context.evaluateScript("window.towerUpdate(\(feedExpression));")
        return context.evaluateScript("els.stage.innerHTML")?.toString() ?? ""
    }

    func testThePageOpensOnTheWeekDial() throws {
        let markup = try firstStage("feed()")
        XCTAssertTrue(markup.contains("dialhero"), "the Week dial is the view that opens first")
    }

    func testAFullSeatSaysFullNotAnUpperBoundOfZero() throws {
        let full = "(function() { var f = feed(); f.accounts.accounts[1].windows = wins(100, 'stale'); return f; })()"
        let alt = dialRow(try stage(full, surface: "dial"), "alt")
        XCTAssertFalse(alt.contains("≤0"), "an upper bound of zero is not a reading: \(alt)")
        // 18.11.2026: the bare word "full" was read as 100 %. The word is "capped" and the number is always there.
        XCTAssertTrue(alt.contains(">0 % left, capped<") && alt.contains("t-crit"), "a capped seat says its number in red: \(alt)")
    }

    /// Round 2 critic: the dial said "full" where the Dashboard said "5 %" for the same seat.
    func testBothViewsCallAFullSeatFull() throws {
        let full = "(function() { var f = feed(); f.accounts.accounts[1].windows = wins(96); return f; })()"
        let dash = try stage(full, surface: "dash")
        XCTAssertTrue(dash.contains("<td class=\"n t-crit\">4 % left, capped</td>"), "the Dashboard Room cell says the same as the dial")
        XCTAssertFalse(dash.contains(">4 %<"), "not a bare number the dial does not show")
    }

    func testASessionWithAnEmailButNoSeatNamePrintsNoQuestionMark() throws {
        let tagged = "feed(null, {interactive: [{label: 'lane-a', busy: true, accountEmail: 'x'}]})"
        XCTAssertFalse(try stage(tagged, surface: "dash").contains("<span class=\"dim\">?</span>"), "a known email with no seat name is not a question mark")
    }

    // MARK: Round 3 (c): the critic's four on the Week dial

    /// D: a signed-out seat's ring was drawn in the green of room. It now reads grey and dashed.
    func testASignedOutRingIsGreyAndDashedNotGreen() throws {
        let signedOut = "(function() { var f = feed(); f.accounts.accounts[1].lastError = 'needs login'; f.accounts.accounts[1].windows = wins(0, 'stale'); return f; })()"
        let markup = try stage(signedOut, surface: "dial")
        let start = try XCTUnwrap(markup.range(of: "<g data-tip=\"alt (claude)"), "the alt ring group")
        let rest = markup[start.lowerBound...]
        let ring = String(rest[..<(rest.range(of: "</g>")?.lowerBound ?? rest.endIndex)])
        XCTAssertFalse(ring.contains("#62c073"), "no green on a signed-out ring: \(ring)")
        XCTAssertTrue(ring.contains("#aab2c0") && ring.contains("stroke-dasharray"), "grey and dashed: \(ring)")
    }

    /// H: the dial list said nothing about how old each seat's number is.
    func testEachDialRowSaysHowOldItsReadingIs() throws {
        let markup = try stage("(function() { var f = feed(); f.accounts.accounts[1].capturedAt = iso(now - 4 * 36e5); f.accounts.accounts[1].windows = wins(10, 'stale'); return f; })()", surface: "dial")
        XCTAssertTrue(dialRow(markup, "main").contains("read 1m ago"), dialRow(markup, "main"))
        XCTAssertTrue(dialRow(markup, "alt").contains("read 4h ago"), dialRow(markup, "alt"))
    }

    /// The verdict line printed "40 % left, 5h," with nothing saying what 5h is.
    func testTheVerdictLineSaysWhatTheWindowIs() throws {
        let fiveBinds = "(function() { var f = feed(); f.accounts.accounts[0].windows = [{name: '7d', percentUsed: 30, resetsAt: iso(now + 3 * 864e5), trust: 'live'}, {name: '5h', percentUsed: 60, resetsAt: iso(now + 3 * 36e5), trust: 'live'}]; return f; })()"
        let markup = try stage(fiveBinds, surface: "dial")
        XCTAssertTrue(markup.contains("40 % left of the 5 hour window"), "the window is named in words")
        XCTAssertFalse(markup.contains("left, 5h,"), "no bare 5h in the verdict line")
    }

    /// 2026-11-18 18:2x, the operator on the Week dial: "why stale wtf?". The active seat, read a minute earlier,
    /// 7d live and no 5h window in the reply. The window is "notReported", which does not lower a live seat, so the
    /// headline is a verdict (YES) with the week named, never PROBABLY or CAN'T TELL.
    func testALiveSeatWithNoFiveHourWindowReadsAVerdictNotProbably() throws {
        let notReported = """
        (function() { var f = feed({kind: 'stay', nickname: 'main', percentUsed: 6, roomPct: null});
          f.accounts.accounts[0].windows = [{name: '5h', percentUsed: null, resetsAt: null, trust: 'notReported'},
            {name: '7d', percentUsed: 6, resetsAt: iso(now + 4 * 864e5), trust: 'live'}];
          return f; })()
        """
        for surface in surfaces {
            let markup = try stage(notReported, surface: surface)
            XCTAssertFalse(markup.isEmpty, "\(surface): the page drew nothing")
            XCTAssertTrue(markup.contains("YES"), "\(surface): a live week with no 5h window is a YES")
            XCTAssertFalse(markup.contains("PROBABLY"), "\(surface): not reported is not a PROBABLY")
            XCTAssertFalse(markup.contains("CAN'T TELL"), "\(surface): the week is known")
            XCTAssertFalse(markup.contains("Tower stopped reading"), "\(surface): the seat was read a minute ago")
        }
    }

    /// The dial lists every Claude seat's next reset, soonest first, so the switch plan reads at a glance
    /// (operator, 2026-11-18). A seat with no known reset says "?", never a guess.
    func testTheDialListsNextResetsSoonestFirstWithAQuestionMarkForUnknown() throws {
        let three = """
        (function() { var f = feed(); f.accounts.accounts = [
          seat('late', 'claude', [{name: '7d', percentUsed: 20, resetsAt: iso(now + 5 * 864e5), trust: 'live'}], true),
          seat('soon', 'claude', [{name: '7d', percentUsed: 30, resetsAt: iso(now + 2 * 36e5), trust: 'live'}], false),
          seat('none', 'claude', [{name: '7d', percentUsed: null, resetsAt: null, trust: 'unknown'}], false)];
          return f; })()
        """
        let markup = try stage(three, surface: "dial")
        let start = try XCTUnwrap(markup.range(of: "Next resets, soonest first"), "the dial has no reset plan")
        let plan = String(markup[start.lowerBound...].prefix(700))
        let soon = try XCTUnwrap(plan.range(of: "<b>soon</b>")), late = try XCTUnwrap(plan.range(of: "<b>late</b>"))
        let none = try XCTUnwrap(plan.range(of: "<b>none</b>"))
        XCTAssertTrue(soon.lowerBound < late.lowerBound && late.lowerBound < none.lowerBound, "soonest first, unknown last")
        let noneRow = String(plan[none.lowerBound...].prefix(120))
        XCTAssertTrue(noneRow.contains(">?<"), "an unknown reset time is a question mark: \(noneRow)")
    }

    /// The control: the same seat with a truly old capture still reads CAN'T TELL with a Refresh.
    func testTheSameSeatWithAnOldCaptureStillReadsCantTell() throws {
        let old = """
        (function() { var f = feed({kind: 'stay', nickname: 'main', percentUsed: 6, roomPct: null});
          f.accounts.accounts[0].windows = [{name: '5h', percentUsed: null, resetsAt: null, trust: 'notReported'},
            {name: '7d', percentUsed: 6, resetsAt: iso(now + 4 * 864e5), trust: 'stale'}];
          return f; })()
        """
        for surface in surfaces {
            let markup = try stage(old, surface: surface)
            XCTAssertTrue(markup.contains("CAN'T TELL"), "\(surface): an old read is not a verdict")
            XCTAssertFalse(markup.contains("YES"), "\(surface): an old read is not a YES")
        }
    }

    func testTheFooterGivesTheMachineLimits() throws {
        let sampled = "(function() { var f = feed(); f.room = {machine: {load1: 47, compressorGiB: 12, swapUsedGiB: 2, swapTotalGiB: 4, gate: {load1: 120, compressorGiB: 25}, level: 'ok', line: ''}}; return f; })()"
        let markup = try stage(sampled, surface: "dial")
        // 2026-11-17 live: "mem 29 of 25 GB" read as used of total. A reading names its gate, it is not a fraction of it.
        XCTAssertTrue(markup.contains("load 47, gate 120"), "load says its gate")
        // A feed with no total memory says compressed and its gate; it never sets compressed against a gate as "of".
        XCTAssertTrue(markup.contains("mem compressed 12 GB, gate 25"), "memory says its gate")
        XCTAssertFalse(markup.contains(" of 25 GB"), "never a fraction of the gate")
    }

    func testTheDashboardPrintsNoBareQuestionMarkForModelOrSessionOwner() throws {
        let unknown = """
        (function() { var f = feed(null, {interactive: [{label: 'lane-a', busy: true}]});
          f.accounts.accounts[1].model = null; return f; })()
        """
        let markup = try stage(unknown, surface: "dash")
        XCTAssertFalse(markup.contains("<span class=\"mchip\">?</span>"), "an unknown model is not a question mark")
        XCTAssertFalse(markup.contains("<span class=\"dim\">?</span>"), "an unknown session owner is not a question mark")
    }

    /// P2 (Codex, b114): a failed session probe is "unavailable", not an idle machine.
    func testPageSaysUnavailableWhenTheSessionProbeFailed() throws {
        for surface in surfaces {
            let ok = try stage("feed()", surface: surface)
            XCTAssertFalse(ok.contains("unavailable"), "\(surface): a working probe with no sessions is not unavailable")
            XCTAssertTrue(ok.contains("owner inferred"), "\(surface): a working probe says how it read the owners")
            let failed = try stage("feed(null, {available: false})", surface: surface)
            XCTAssertTrue(failed.contains("unavailable"), "\(surface): a failed probe says unavailable")
            XCTAssertFalse(failed.contains("owner inferred"), "\(surface): a failed probe reads no owners")
        }
    }

    /// P1 (Codex round 3): with no verified Claude login the page threw the whole dashboard away,
    /// including valid Codex, Cursor, money and session data. It draws an unknown active seat.
    func testPageDrawsWithoutAVerifiedClaudeLogin() throws {
        let noActive = """
        (function() { var f = feed(); f.accounts.accounts.forEach(function(s) { s.isActive = false; });
          f.accounts.accounts.push(seat('cx', 'codex', wins(30), false)); return f; })()
        """
        for surface in surfaces {
            let markup = try stage(noActive, surface: surface)
            XCTAssertFalse(markup.contains("has not verified"), "\(surface): an unverified login hid the dashboard")
            XCTAssertFalse(markup.contains("could not draw"), "\(surface): the page failed to draw")
            XCTAssertTrue(markup.contains("CAN'T TELL"), "\(surface): the verdict says Tower cannot tell")
            XCTAssertTrue(markup.contains("cx"), "\(surface): the independent Codex seat is still drawn")
            XCTAssertFalse(markup.contains("null") || markup.contains("undefined") || markup.contains("NaN"),
                           "\(surface): the unknown seat leaks a raw value into the page")
        }
    }

    /// P2 (Codex round 3): a seat at 90 to 94 percent is usable. The cap is Tower's own
    /// `AccountSnapshot.cappedPct` (95), carried in the feed, not a threshold of the page's own.
    func testPageUsesTowersCappedThreshold() async throws {
        let feed = await DashboardFeed.build(service: TowerMCPService(env: fixture.environment()))
        XCTAssertEqual(feed["cappedPct"], .number(AccountSnapshot.cappedPct), "the feed carries Tower's cap")
        XCTAssertEqual(AccountSnapshot.cappedPct, 95)

        let at92 = "(function() { var f = feed(); f.cappedPct = 95; f.accounts.accounts[1].windows = wins(92); return f; })()"
        let usable = try stage(at92)
        XCTAssertTrue(usable.contains("2 of 2 usable"), "a live seat at 92 percent is usable")
        let at96 = "(function() { var f = feed(); f.cappedPct = 95; f.accounts.accounts[1].windows = wins(96); return f; })()"
        XCTAssertTrue(try stage(at96).contains("1 of 2 usable"), "a seat at 96 percent is capped")
    }

    /// P2 (Codex round 3): a failed machine sample is unavailable, not a healthy zero.
    func testPageKeepsMachineReadingsUnavailable() throws {
        for surface in surfaces {
            let missing = try stage("feed()", surface: surface)
            XCTAssertTrue(missing.contains("load ?"), "\(surface): no machine sample reads load ?")
            XCTAssertFalse(missing.contains("load 0"), "\(surface): a missing sample is not a zero load")
        }
        let sampled = "(function() { var f = feed(); f.room = {machine: {load1: 2, compressorGiB: 1, swapUsedGiB: 0, swapTotalGiB: 4, gate: {load1: 10, compressorGiB: 8}, level: 'ok', line: ''}}; return f; })()"
        for surface in surfaces {
            let markup = try stage(sampled, surface: surface)
            XCTAssertTrue(markup.contains("load 2"), "\(surface): a real sample is drawn")
            XCTAssertFalse(markup.contains("load ?"), "\(surface): a real sample is not unavailable")
        }
    }

    // MARK: The buttons

    /// The page's buttons used to be labels: a click went nowhere, so a locked seat meant
    /// "log in again and restart". A click now posts one word from a closed list to Swift.
    /// Returns the words posted after `clicks` page clicks on the elements `targets` names.
    private func posted(feedExpression: String, clickOn dataAct: String?) throws -> [String] {
        let html = try page()
        let open = try XCTUnwrap(html.range(of: "<script>"))
        let close = try XCTUnwrap(html.range(of: "</script>", options: .backwards))
        let script = String(html[open.upperBound..<close.lowerBound])
        let context = try XCTUnwrap(JSContext())
        var thrown: [String] = []
        context.exceptionHandler = { _, error in thrown.append(error?.toString() ?? "unknown") }
        context.evaluateScript(Self.domStub)
        context.evaluateScript("""
        var posts = [], listeners = [];
        document.addEventListener = function(type, fn) { listeners.push([type, fn]); };
        window.webkit = {messageHandlers: {tower: {postMessage: function(m) { posts.push(m); }}}};
        """)
        context.evaluateScript(Self.feedKit)
        context.evaluateScript(script)
        context.evaluateScript(Self.clockKit)
        context.evaluateScript("window.towerUpdate(\(feedExpression));")
        if let dataAct {
            context.evaluateScript("""
            var target = {closest: function(sel) { return sel === '[data-act]' ? {dataset: {act: '\(dataAct)'}} : null; }};
            listeners.forEach(function(l) { if (l[0] === 'click') l[1]({target: target}); });
            """)
        }
        XCTAssertEqual(thrown, [], "the page threw")
        return context.evaluateScript("JSON.stringify(posts)")?.toString()
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
    }

    private static let lockedSeats = """
    (function() { var f = feed(); f.accounts.accounts.forEach(function(s) { if (!s.isActive) { s.windows = []; s.lastError = 'needs login: Keychain item unreadable (-25308)'; } }); return f; })()
    """

    func testAClickOnARetrustButtonPostsRetrust() throws {
        XCTAssertEqual(try posted(feedExpression: Self.lockedSeats, clickOn: "retrust"), ["retrust"])
    }

    func testAClickOnARefreshButtonPostsRefresh() throws {
        XCTAssertEqual(try posted(feedExpression: "feed()", clickOn: "refresh"), ["refresh"])
    }

    func testAnUnknownActionPostsNothing() throws {
        XCTAssertEqual(try posted(feedExpression: "feed()", clickOn: "rm -rf"), [], "only the closed list reaches Swift")
        XCTAssertEqual(try posted(feedExpression: "feed()", clickOn: nil), [])
    }

    func testLockedSeatsOfferOneRetrustForAllOfThem() throws {
        let markup = try stage(Self.lockedSeats)
        XCTAssertTrue(markup.contains("data-act=\"retrust\""), "the Re-trust button is a real control")
        XCTAssertTrue(markup.contains("Re-trust"), "it says Re-trust")
        // One button for every seat, not a /login per seat.
        XCTAssertFalse(markup.contains("data-act=\"login\""), "no per seat /login control")
    }

    func testTheRefreshButtonOnAStaleReadIsAControl() throws {
        let stale = "(function() { var f = feed(); f.accounts.accounts[0].windows = wins(40, 'stale'); return f; })()"
        XCTAssertTrue(try stage(stale).contains("data-act=\"refresh\""))
    }

    /// Yonatan's screenshot: no ready seat, four seats the Keychain would hand back after one approval.
    /// The headline said WAIT and "Nothing has room" with nothing to press, so the one click that
    /// fixes it was only in the table. When Re-trust can recover seats it is the headline action.
    func testTheHeadlineOffersRetrustWhenSeatsAreLocked() throws {
        let locked = """
        (function() { var f = feed({kind: 'allResting', nickname: null, percentUsed: null, earliestReset: null});
          f.accounts.accounts.forEach(function(s) { s.isActive = false; s.windows = wins(40, 'stale'); });
          f.accounts.accounts.push((function() { var g = seat('lockedA', 'claude', [], false); g.lastError = 'needs login: Keychain item unreadable (-25308)'; return g; })());
          f.accounts.accounts.push((function() { var g = seat('lockedB', 'claude', [], false); g.lastError = 'needs login: Keychain item unreadable (-25308)'; return g; })());
          return f; })()
        """
        for surface in surfaces {
            let markup = try stage(locked, surface: surface)
            XCTAssertTrue(markup.contains("data-act=\"retrust\""), "\(surface): the headline carries the Re-trust control")
            XCTAssertTrue(markup.contains("Re-trust 2 seats"), "\(surface): it says how many seats one click brings back")
        }
        XCTAssertEqual(try posted(feedExpression: locked, clickOn: "retrust"), ["retrust"])
    }

    /// A Re-trust that fails or leaves seats unreadable used to say nothing on the dashboard (the
    /// message only reached the classic panel), so a click that did nothing looked like a dead button.
    func testTheDashboardShowsWhatARetrustDid() throws {
        let failed = "(function() { var f = feed(); f.notice = 'Re-trust needs the signed Tower app'; return f; })()"
        for surface in surfaces {
            let markup = try stage(failed, surface: surface)
            XCTAssertTrue(markup.contains("Re-trust needs the signed Tower app"), "\(surface): the notice is shown")
        }
        XCTAssertFalse(try stage("feed()").contains("class=\"notice\""), "no notice, no notice row")
    }

    func testTheFeedCarriesTheRetrustNotice() async throws {
        var feed = await DashboardFeed.build(service: TowerMCPService(env: fixture.environment()), notice: "2 remembered seat(s) still not readable")
        XCTAssertEqual(feed["notice"].stringValue, "2 remembered seat(s) still not readable")
        feed = await DashboardFeed.build(service: TowerMCPService(env: fixture.environment()), notice: nil)
        XCTAssertTrue(feed["notice"].isNull, "no notice is null, not an empty string")
    }

    /// The closed list of words the native side accepts from the page.
    func testTheNativeBridgeAcceptsOnlyTheClosedList() {
        XCTAssertEqual(DashboardBridge.Action(word: "retrust"), .retrust)
        XCTAssertEqual(DashboardBridge.Action(word: "refresh"), .refresh)
        XCTAssertNil(DashboardBridge.Action(word: "login"), "a login is a terminal command, never a button")
        XCTAssertNil(DashboardBridge.Action(word: "quit"))
        XCTAssertNil(DashboardBridge.Action(word: ""))
        XCTAssertNil(DashboardBridge.Action(word: "retrust; rm"))
        XCTAssertNil(DashboardBridge.Action(body: ["retrust"]), "a non string message is refused")
        XCTAssertEqual(DashboardBridge.Action(body: "retrust"), .retrust)
    }

    /// First open of a build whose store is still empty (the first refresh has not finished): the
    /// page said WAIT and "Nothing has room", which is a verdict about seats nobody has read.
    func testPageSaysNoReadingsYetOnAnEmptyStore() throws {
        let empty = """
        (function() { var f = feed({kind: 'allResting', nickname: null, percentUsed: null, earliestReset: null});
          f.accounts.accounts = []; return f; })()
        """
        for surface in surfaces {
            let markup = try stage(empty, surface: surface)
            XCTAssertTrue(markup.contains("NO READINGS"), "\(surface): an empty store reads NO READINGS")
            XCTAssertTrue(markup.contains("first read"), "\(surface): the next move says the first read is under way")
            XCTAssertFalse(markup.contains("WAIT"), "\(surface): nothing was read, so nothing is waiting")
            XCTAssertFalse(markup.contains("Nothing has room"), "\(surface): no verdict about room that nobody read")
            XCTAssertFalse(markup.contains("NaN"), "\(surface): an empty store drew NaN coordinates")
        }
        // Seats that exist but were never read are the same state.
        let unread = """
        (function() { var f = feed(); f.accounts.accounts.forEach(function(s) { s.windows = []; s.isActive = false; }); return f; })()
        """
        XCTAssertTrue(try stage(unread).contains("NO READINGS"), "seats with no reading at all read NO READINGS")
        // And one real reading is enough to leave that state.
        XCTAssertFalse(try stage("feed()").contains("NO READINGS"), "a store with a reading is not empty")
    }

    /// Codex P2 (#155): every seat unread AND Keychain-locked is the case Re-trust exists for. NO READINGS
    /// took precedence and offered only Refresh, which never prompts the Keychain, so it could not recover.
    func testNoReadingsWithLockedSeatsOffersReTrust() throws {
        let locked = """
        (function() { var f = feed({kind: 'allResting'}); f.accounts.accounts.forEach(function(s) {
          s.isActive = false; s.windows = []; s.lastError = 'needs login: Keychain item unreadable (-25308)'; });
          return f; })()
        """
        for surface in surfaces {
            let markup = try stage(locked, surface: surface)
            XCTAssertTrue(markup.contains("NO READINGS"), "\(surface): the empty-reading message stays")
            XCTAssertTrue(markup.contains("data-act=\"retrust\""), "\(surface): locked unread seats offer Re-trust")
            XCTAssertFalse(markup.contains("making its first read"), "\(surface): the next move is Re-trust, not wait a minute")
        }
        let sent = try posted(feedExpression: locked, clickOn: "retrust")
        XCTAssertEqual(sent, ["retrust"], "the control posts the retrust word")
        // Unread seats with no Keychain error still get Refresh only.
        let unread = """
        (function() { var f = feed(); f.accounts.accounts.forEach(function(s) { s.windows = []; s.isActive = false; }); return f; })()
        """
        XCTAssertFalse(try stage(unread).contains("data-act=\"retrust\""), "no locked seat, no Re-trust in the headline")
    }

    /// A seat that was never captured has no capture time (epoch 0 on the wire); the Read column
    /// said "20764d 7h".
    func testPageReadsNeverForASeatThatWasNeverCaptured() throws {
        let ghost = """
        (function() { var f = feed(); var g = seat('ghost', 'claude', [], false);
          g.capturedAt = '1970-01-01T00:00:00.000Z'; f.accounts.accounts.push(g); return f; })()
        """
        let markup = try stage(ghost)
        XCTAssertTrue(markup.contains("never"), "a never captured seat reads never")
        XCTAssertNil(markup.range(of: #"[0-9]{4,}d"#, options: .regularExpression),
                     "no read age of thousands of days")
        let dial = try stage(ghost, surface: "dial")
        XCTAssertNil(dial.range(of: #"[0-9]{4,}d"#, options: .regularExpression), "dial: no read age of thousands of days")
    }

    /// Betty/Yonatan 2026-11-07: a seat Tower has not read yet showed "?", which reads as a broken number.
    /// A seat with no reading says "not yet seen"; "?" stays for a number that is genuinely unknown.
    func testASeatNeverReadSaysNotYetSeenNotAQuestionMark() throws {
        let ghost = """
        (function() { var f = feed(); var g = seat('ghost', 'claude', [], false);
          g.capturedAt = '1970-01-01T00:00:00.000Z'; f.accounts.accounts.push(g); return f; })()
        """
        for surface in surfaces {
            let markup = try stage(ghost, surface: surface)
            XCTAssertTrue(markup.contains("not yet seen"), "\(surface): a seat with no reading says not yet seen")
        }
        XCTAssertFalse(try stage("feed()").contains("not yet seen"), "a feed where every seat was read never says it")
    }

    /// P2 (Codex round 4, #153): the active seat is "in use", but an exhausted one is not usable.
    func testPageDoesNotCountAnExhaustedActiveSeatAsUsable() throws {
        let exhausted = "(function() { var f = feed(); f.cappedPct = 95; f.accounts.accounts[0].windows = [{name: '7d', percentUsed: 100, resetsAt: iso(now + 3 * 864e5), trust: 'live'}]; return f; })()"
        let markup = try stage(exhausted)
        XCTAssertTrue(markup.contains("1 of 2 usable"), "an exhausted active seat plus one ready seat is 1 of 2 usable")
        XCTAssertFalse(markup.contains("2 of 2 usable"))
        let healthy = try stage("(function() { var f = feed(); f.cappedPct = 95; return f; })()")
        XCTAssertTrue(healthy.contains("2 of 2 usable"), "a healthy active seat still counts")
    }

    /// P2 (Codex round 4, #153): two samples with the same balance have no value range; the
    /// sparkline is a flat line, never NaN coordinates.
    func testPageDrawsAConstantBalanceAsAFlatLine() throws {
        let flat = "(function() { var f = feed(); f.openrouterHistory = {samples: [{capturedAt: iso(now - 864e5), available: 10, totalCredits: 20}, {capturedAt: iso(now), available: 10, totalCredits: 20}]}; return f; })()"
        for surface in surfaces {
            let markup = try stage(flat, surface: surface)
            XCTAssertFalse(markup.contains("NaN"), "\(surface): a constant balance drew NaN coordinates")
        }
        let same = "(function() { var f = feed(); f.openrouterHistory = {samples: [{capturedAt: iso(now), available: 10, totalCredits: 20}, {capturedAt: iso(now), available: 10, totalCredits: 20}]}; return f; })()"
        XCTAssertFalse(try stage(same).contains("NaN"), "two samples at the same instant drew NaN coordinates")
    }

    /// P2 (Codex round 4, #153): no OpenRouter history is an unknown balance, not zero dollars.
    func testPageKeepsAnUnknownBalanceUnknown() throws {
        for surface in surfaces {
            let none = try stage("feed()", surface: surface)
            XCTAssertFalse(none.contains("$0.00"), "\(surface): no history drew a zero dollar balance")
        }
        let measured = "(function() { var f = feed(); f.openrouterHistory = {samples: [{capturedAt: iso(now - 864e5), available: 10, totalCredits: 20}, {capturedAt: iso(now), available: 10, totalCredits: 20}]}; return f; })()"
        XCTAssertTrue(try stage(measured, surface: "dial").contains("$10.00"), "a measured balance is still drawn")
    }

    /// P2 (Codex round 3): the model's published surface follows the stored one, so the
    /// visible switch names the right destination after an external change.
    func testApplyingTheStoredSurfacePublishesIt() {
        XCTAssertEqual(PanelSurface.decide(shown: .dashboard, stored: .classic),
                       PanelSurface.Decision(swapContent: true, publish: .classic))
        XCTAssertEqual(PanelSurface.decide(shown: .classic, stored: .dashboard),
                       PanelSurface.Decision(swapContent: true, publish: .dashboard))
        XCTAssertEqual(PanelSurface.decide(shown: nil, stored: .dashboard),
                       PanelSurface.Decision(swapContent: true, publish: .dashboard))
        // Nothing to swap, and the model is still told: it may have drifted.
        XCTAssertEqual(PanelSurface.decide(shown: .classic, stored: .classic),
                       PanelSurface.Decision(swapContent: false, publish: .classic))
    }

    /// P2 (Codex round 3): `tower dashboardshot` run through the installed PATH symlink has no
    /// Info.plist in Bundle.main, so the page must be found through the enclosing app bundle.
    func testPageResolvesThroughTheInstalledSymlink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tower-bundle-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Tower.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let dashboard = app.appendingPathComponent("Contents/Resources/Dashboard")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: dashboard, withIntermediateDirectories: true)
        try "<html><!--installed-page--></html>".write(to: dashboard.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: macOS.appendingPathComponent("Tower"), atomically: true, encoding: .utf8)
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("tower"), withDestinationURL: macOS.appendingPathComponent("Tower"))

        let page = DashboardFeed.bundledPage(executablePath: bin.appendingPathComponent("tower").path)
        XCTAssertEqual(page?.contains("installed-page"), true, "the page was not found through the symlink")
    }

    // MARK: A stale picture, a headline seat that is not live, a title that disagrees
    //
    // A panel can draw a picture built a day earlier: SWITCH, one seat, 3 % left, while the menu bar names another.
    // Three rules, from the approved design: a feed older than the
    // freshness line draws CAN'T TELL with its age; the headline seat is active AND live; the headline seat
    // is the seat the menu bar title names. Ages are measured against the wall clock, injected as
    // window.towerClock, never against the feed's own generatedAt.

    /// The headline region of the stage: the Week dial header, or the Dashboard's first cell.
    private func headline(_ markup: String, surface: String) throws -> String {
        let pattern = surface == "dial"
            ? "<div class=\"dhead\">(.*?)<div class=\"dbody\">"
            : "<div class=\"cell c-a\">(.*?)<div class=\"cell c-b\">"
        let re = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = markup as NSString
        let hit = try XCTUnwrap(re.firstMatch(in: markup, range: NSRange(location: 0, length: ns.length)), "\(surface): no headline region in the markup")
        return ns.substring(with: hit.range(at: 1))
    }

    /// Canary: the stage drew its rows. A headline test that reads an empty stage would pass without proving anything.
    private func assertDrawn(_ markup: String, _ nicks: [String], _ surface: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(markup.count, 500, "\(surface): the stage is empty", file: file, line: line)
        for nick in nicks {
            XCTAssertTrue(markup.contains("<b>\(nick)</b>") || markup.contains(">\(nick)<") || markup.contains(">\(nick) "),
                          "\(surface): the stage is missing the \(nick) row, so a headline check on it proves nothing", file: file, line: line)
        }
    }

    /// A picture built a day earlier: alpha was the login, its 5h window at 97 percent, advice said switch.
    private static let oldPicture = """
    (function() { var f = feed({kind: 'switch', nickname: 'charlie', percentUsed: 0, roomPct: 100});
      f.accounts.accounts = [
        seat('alpha', 'claude', [{name: '5h', percentUsed: 97, resetsAt: iso(now + 3 * 36e5), trust: 'live'}, {name: '7d', percentUsed: 16, resetsAt: iso(now + 5 * 864e5), trust: 'live'}], true),
        seat('bravo', 'claude', wins(79), false), seat('charlie', 'claude', wins(0), false)];
      f.status = {menubarTitle: '\u{1F534}alpha 97%'};
      return f; })()
    """

    func testAFeedOlderThanTheFreshnessLineDrawsCantTellWithItsAge() throws {
        for surface in surfaces {
            let markup = try stage(Self.oldPicture, surface: surface, clock: "now + 22 * 36e5")
            assertDrawn(markup, ["bravo", "charlie"], surface)
            let head = try headline(markup, surface: surface)
            XCTAssertTrue(head.contains("CAN'T TELL"), "\(surface): an old picture reads CAN'T TELL: \(head)")
            XCTAssertTrue(head.contains("22h"), "\(surface): the headline says how old the picture is: \(head)")
            XCTAssertTrue(head.contains("Refresh now") && head.contains("data-act=\"refresh\""), "\(surface): the one action is a wired Refresh: \(head)")
            XCTAssertFalse(head.contains("alpha"), "\(surface): no seat name in the headline of an old picture: \(head)")
            XCTAssertFalse(head.contains("%") || head.contains("97"), "\(surface): no percent in the headline of an old picture: \(head)")
            XCTAssertFalse(head.contains("SWITCH") || head.contains("YES"), "\(surface): an old picture gives no verdict: \(head)")
            XCTAssertTrue(markup.contains("oldfeed"), "\(surface): the body is dimmed")
        }
    }

    /// Control: the same feed, one minute old, is trusted and says what it knew.
    func testTheSameFeedOneMinuteOldKeepsItsVerdictAndItsSeat() throws {
        for surface in surfaces {
            let markup = try stage(Self.oldPicture, surface: surface, clock: "now + 60000")
            assertDrawn(markup, ["bravo", "charlie"], surface)
            let head = try headline(markup, surface: surface)
            XCTAssertTrue(head.contains("SWITCH") && head.contains("alpha"), "\(surface): a fresh feed names its seat and its verdict: \(head)")
            XCTAssertFalse(markup.contains("oldfeed"), "\(surface): a fresh feed is not dimmed")
        }
    }

    /// The line is the TTL the feed carries (rules.freshnessTTLSeconds), 15 minutes when it carries none.
    func testTheFreshnessLineIsTheFeedsOwnTTLAndFifteenMinutesWithoutOne() throws {
        let atLine = try stage("feed()", surface: "dial", clock: "now + 900 * 1000")
        let pastLine = try stage("feed()", surface: "dial", clock: "now + 901 * 1000")
        assertDrawn(atLine, ["main", "alt"], "dial")
        XCTAssertFalse(try headline(atLine, surface: "dial").contains("CAN'T TELL"), "exactly 15 minutes is still fresh")
        XCTAssertTrue(try headline(pastLine, surface: "dial").contains("CAN'T TELL"), "15 minutes and a second is old")
        let short = "(function() { var f = feed(); f.freshness = {rules: {freshnessTTLSeconds: 60}}; return f; })()"
        XCTAssertTrue(try headline(try stage(short, surface: "dial", clock: "now + 120 * 1000"), surface: "dial").contains("CAN'T TELL"), "the feed's own TTL (60 s) draws the line")
        XCTAssertFalse(try headline(try stage(short, surface: "dial", clock: "now + 30 * 1000"), surface: "dial").contains("CAN'T TELL"), "inside the feed's own TTL it is fresh")
    }

    /// An active seat whose reading is past the line is never the headline seat, whatever the advice says.
    func testAnActiveSeatWithAStaleReadingNeverNamesItselfInTheHeadline() throws {
        let stale = "(function() { var f = feed({kind: 'switch', nickname: 'alt', percentUsed: 10}); f.accounts.accounts[0].windows = wins(97, 'stale'); f.accounts.accounts[0].capturedAt = iso(now - 19 * 36e5); return f; })()"
        for surface in surfaces {
            let markup = try stage(stale, surface: surface)
            assertDrawn(markup, ["main", "alt"], surface)
            let head = try headline(markup, surface: surface)
            XCTAssertTrue(head.contains("CAN'T TELL"), "\(surface): a stale active seat reads CAN'T TELL: \(head)")
            XCTAssertTrue(head.contains("19h"), "\(surface): with the age of its reading: \(head)")
            XCTAssertFalse(head.contains("main") || head.contains("%") || head.contains("SWITCH"), "\(surface): no seat and no percent beside it: \(head)")
        }
    }

    /// A window the reply did not carry is not reported, not stale: a live week without a 5h reading is a YES that names its seat.
    func testAnActiveSeatWithALiveWeekAndNoFiveHourReadingStillNamesItself() throws {
        let markup = try stage(Self.weekLiveFiveHourAbsent, surface: "dial")
        assertDrawn(markup, ["main", "alt"], "dial")
        let head = try headline(markup, surface: "dial")
        XCTAssertTrue(head.contains("YES") && head.contains("main"), "a live week with no 5h window is a YES that names its seat: \(head)")
        XCTAssertFalse(head.contains("PROBABLY"), "a window not reported is not a PROBABLY (a56baab, 2026-11-18): \(head)")
    }

    /// The headline seat is the seat the menu bar title names. Disagreement is CAN'T TELL, never a guess.
    func testTheHeadlineSeatIsTheSeatTheMenuBarTitleNames() throws {
        let titled = { (title: String) in "(function() { var f = feed(); f.status = {menubarTitle: '\(title)'}; return f; })()" }
        for surface in surfaces {
            let agree = try headline(try stage(titled("\u{1F7E2}main 40%"), surface: surface), surface: surface)
            XCTAssertTrue(agree.contains("main") && agree.contains("YES"), "\(surface): title and headline name main: \(agree)")
            let bare = try headline(try stage(titled("\u{26A0}\u{FE0F}main"), surface: surface), surface: surface)
            XCTAssertTrue(bare.contains("main"), "\(surface): a title with no percent still names main: \(bare)")
            let markup = try stage(titled("\u{1F7E2}alt 10%"), surface: surface)
            assertDrawn(markup, ["main", "alt"], surface)
            let differ = try headline(markup, surface: surface)
            XCTAssertTrue(differ.contains("CAN'T TELL"), "\(surface): the title says alt, the feed says main: \(differ)")
            XCTAssertFalse(differ.contains("main") || differ.contains("alt") || differ.contains("%"), "\(surface): no name when they differ: \(differ)")
            let blind = try headline(try stage(titled("CC ??"), surface: surface), surface: surface)
            XCTAssertTrue(blind.contains("CAN'T TELL"), "\(surface): a title that names no seat is not a match: \(blind)")
        }
    }

    // The same rules against a store written the way Tower's own store is written.

    private func seedStore(_ rows: [AccountSnapshot]) throws {
        let map = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        if let error = fixture.store.save(map) { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
    }

    private func claudeRow(_ email: String, _ nick: String, fiveHour: Double?, week: Double, readAgo: TimeInterval, error: String? = nil) -> AccountSnapshot {
        var r = AccountSnapshot(email: email, nickname: nick, plan: "max", tier: "default_claude_max_20x")
        r.fiveHourPct = fiveHour
        r.fiveHourResetsAt = fiveHour == nil ? nil : fixture.now.addingTimeInterval(3 * 3600)
        r.weeklyPct = week
        r.weeklyResetsAt = fixture.now.addingTimeInterval(5 * 86_400)
        r.capturedAt = fixture.now.addingTimeInterval(-readAgo)
        r.lastError = error
        return r
    }

    private func feedLiteral(activeEmail: String) async -> String {
        var env = fixture.environment(verifiedActiveEmail: .some(activeEmail))
        // The live credential names the same login the verified record does, so the bound active seat is that one.
        let live = fixture.activeCredential()
        env.activeCredential = {
            ClaudeCredential(service: live.service, accessToken: live.accessToken, subscriptionType: live.subscriptionType,
                             rateLimitTier: live.rateLimitTier, expiresAt: live.expiresAt, emailHint: activeEmail,
                             refreshToken: live.refreshToken, scopes: live.scopes)
        }
        let feed = await DashboardFeed.build(service: TowerMCPService(env: env))
        return DashboardFeed.jsLiteral(feed)
    }

    private var fixtureNowMillis: String { "\(Int(fixture.now.timeIntervalSince1970 * 1000))" }

    /// The login is at 97 percent of its 5h window. The feed built then, drawn 22 hours later.
    func testARealStoreFeedFromTheDayBeforeDrawsNoSeatAndNoPercent() async throws {
        try seedStore([
            claudeRow("alpha@example.com", "alpha", fiveHour: 97, week: 16, readAgo: 60),
            claudeRow("charlie@example.com", "charlie", fiveHour: 0, week: 0, readAgo: 120),
            claudeRow("bravo@example.com", "bravo", fiveHour: nil, week: 79, readAgo: 300),
        ])
        let feed = await feedLiteral(activeEmail: "alpha@example.com")
        XCTAssertTrue(feed.contains("alpha 97%"), "canary: the menu bar title of the store's own feed names the login alpha")
        for surface in surfaces {
            let old = try stage(feed, surface: surface, clock: "\(fixtureNowMillis) + 22 * 36e5")
            assertDrawn(old, ["bravo", "charlie"], surface)
            let head = try headline(old, surface: surface)
            XCTAssertTrue(head.contains("CAN'T TELL") && head.contains("22h"), "\(surface): \(head)")
            XCTAssertFalse(head.contains("alpha") || head.contains("%"), "\(surface): the day-old picture named a seat and a percent: \(head)")
            let fresh = try headline(try stage(feed, surface: surface, clock: "\(fixtureNowMillis) + 60000"), surface: surface)
            XCTAssertTrue(fresh.contains("alpha"), "\(surface): the control (a one minute old feed) names the login: \(fresh)")
        }
    }

    /// The login is bravo (week 79 percent, no 5h reading); alpha rests, 19 hours stale. The headline
    /// names bravo, the seat the menu bar title names, and never alpha.
    func testARealStoreFeedOfTodayNamesTheLoginTheMenuBarNames() async throws {
        try seedStore([
            claudeRow("alpha@example.com", "alpha", fiveHour: 0, week: 16, readAgo: 19.8 * 3600, error: "needs login"),
            claudeRow("bravo@example.com", "bravo", fiveHour: nil, week: 79, readAgo: 120),
            claudeRow("charlie@example.com", "charlie", fiveHour: 0, week: 0, readAgo: 180),
        ])
        let feed = await feedLiteral(activeEmail: "bravo@example.com")
        XCTAssertTrue(feed.contains("bravo 79%"), "canary: the menu bar title of the store's own feed names the login bravo")
        for surface in surfaces {
            let markup = try stage(feed, surface: surface, clock: "\(fixtureNowMillis) + 60000")
            assertDrawn(markup, ["bravo", "alpha", "charlie"], surface)
            let head = try headline(markup, surface: surface)
            XCTAssertTrue(head.contains("bravo"), "\(surface): the headline names the login: \(head)")
            XCTAssertFalse(head.contains("alpha"), "\(surface): the headline never names the stale resting seat: \(head)")
            XCTAssertFalse(head.contains("CAN'T TELL"), "\(surface): a feed one minute old is trusted: \(head)")
        }
    }

    // MARK: The Week dial, approved mockup
    //
    // Beads closer than one bead width merge into one stack marker with a count; single beads are plain dots;
    // a stale seat is a dashed ring with no bead; provider labels and ring names leave the dial; only the
    // active seat glows. The geometry below mirrors the page's own: the big dial is 520 wide, rings run from
    // 0.915 to 0.34 of the radius, a bead is 18 px and its marker 1.24 times that across.

    private let dialRadius = 260.0 * 0.915
    private let dialInner = 260.0 * 0.34
    private let beadWidth = 18.0 * 1.24

    /// Twelve Claude rings, the way the real dial has about a dozen: `bead` seats carry a week reset (the first of
    /// them is the active one), the others have no reading to draw a bead from. `resets` are ms after the feed.
    private func crowdedDial(_ resets: [Double]) -> String {
        let beads = resets.enumerated().map { i, ms in
            "seat('s\(i)', 'claude', [{name: '7d', percentUsed: \(10 + i * 5), resetsAt: iso(now + \(ms)), trust: 'live'}], \(i == 0 ? "true" : "false"))"
        }
        let bare = (resets.count..<12).map { i in
            "seat('s\(i)', 'claude', [{name: '7d', percentUsed: null, resetsAt: null, trust: 'unknown'}], false)"
        }
        return "(function() { var f = feed(); f.accounts.accounts = [\((beads + bare).joined(separator: ", "))]; return f; })()"
    }

    private func dialSVG(_ markup: String) throws -> String {
        let re = try NSRegularExpression(pattern: "<div class=\"dstage\">(<svg.*?</svg>)", options: [.dotMatchesLineSeparators])
        let ns = markup as NSString
        let hit = try XCTUnwrap(re.firstMatch(in: markup, range: NSRange(location: 0, length: ns.length)), "no dial in the markup")
        return ns.substring(with: hit.range(at: 1))
    }

    private func occurrences(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    /// The angle gap that puts two beads on neighbouring rings `distance` px apart.
    private func gapMillis(forBeadDistance distance: Double, firstRing: Int) -> Double {
        let step = (dialRadius - dialInner) / 12
        let r1 = dialRadius - Double(firstRing) * step, r2 = r1 - step
        let cosGap = (r1 * r1 + r2 * r2 - distance * distance) / (2 * r1 * r2)
        return acos(cosGap) * 180 / .pi / 360 * 7 * 86_400_000
    }

    func testTwoBeadsCloserThanOneBeadWidthMergeIntoOneMarkerWithACount() throws {
        let t0 = 3.0 * 86_400_000
        let markup = try stage(crowdedDial([t0, t0 + gapMillis(forBeadDistance: beadWidth * 0.8, firstRing: 0)]), surface: "dial")
        assertDrawn(markup, ["s0", "s1", "s11"], "dial")
        let dial = try dialSVG(markup)
        XCTAssertEqual(occurrences("class=\"stack\"", in: dial), 1, "two close beads are one marker")
        XCTAssertEqual(occurrences("class=\"bead\"", in: dial), 0, "no loose bead is left beside the marker")
        XCTAssertTrue(dial.contains(">2</text>"), "the marker carries the count")
        XCTAssertTrue(dial.contains("s0") && dial.contains("s1"), "the marker's hover names both seats")
    }

    func testTwoBeadsJustFartherApartThanOneBeadWidthStayTwoMarkers() throws {
        let t0 = 3.0 * 86_400_000
        let markup = try stage(crowdedDial([t0, t0 + gapMillis(forBeadDistance: beadWidth * 1.2, firstRing: 0)]), surface: "dial")
        assertDrawn(markup, ["s0", "s1", "s11"], "dial")
        let dial = try dialSVG(markup)
        XCTAssertEqual(occurrences("class=\"bead\"", in: dial), 2, "two beads one width and a bit apart stay two")
        XCTAssertEqual(occurrences("class=\"stack\"", in: dial), 0, "no marker, no count")
    }

    /// Six seats on one reset, the shape of the real week: one marker that says 6.
    func testSixSeatsOnOneResetDrawOneMarkerThatSaysSix() throws {
        let t0 = 6.75 * 86_400_000
        let dial = try dialSVG(try stage(crowdedDial(Array(repeating: t0, count: 6)), surface: "dial"))
        XCTAssertEqual(occurrences("class=\"stack\"", in: dial), 1)
        XCTAssertEqual(occurrences("class=\"bead\"", in: dial), 0)
        XCTAssertTrue(dial.contains(">6</text>"))
    }

    func testProviderLabelsAndRingNamesLeaveTheDial() throws {
        let dial = try dialSVG(try stage("feed()", surface: "dial"))
        XCTAssertFalse(dial.contains("<use "), "no provider icon on the dial; the legend names the providers")
        XCTAssertFalse(dial.contains("class=\"rl\""), "the names live in the list beside the dial, not on the rings")
    }

    func testAStaleSeatIsADashedRingWithNoBeadAndOnlyTheActiveSeatGlows() throws {
        let staleAlt = "(function() { var f = feed(); f.accounts.accounts[1].windows = wins(40, 'stale'); f.accounts.accounts[1].capturedAt = iso(now - 19 * 36e5); f.accounts.accounts[0].windows = wins(85); return f; })()"
        let markup = try stage(staleAlt, surface: "dial")
        assertDrawn(markup, ["main", "alt"], "dial")
        let dial = try dialSVG(markup)
        XCTAssertEqual(occurrences("class=\"stalering\"", in: dial), 1, "the stale seat is one dashed ring")
        XCTAssertTrue(dial.contains("stale"), "and its hover says stale, not colour alone")
        XCTAssertEqual(occurrences("class=\"bead\"", in: dial), 1, "only the live seat keeps a bead")
        XCTAssertEqual(occurrences("halo", in: dial), 1, "only the active seat glows")
    }

    // MARK: What the menu bar opens

    func testMenuBarOpensTheDashboardByDefaultAndClassicStaysOneSettingAway() {
        let d = UserDefaults(suiteName: "dash-surface-\(UUID().uuidString)")!
        XCTAssertEqual(PanelSurface.current(defaults: d), .dashboard)
        PanelSurface.set(.classic, defaults: d)
        XCTAssertEqual(PanelSurface.current(defaults: d), .classic)
        d.set("garbage", forKey: PanelSurface.defaultsKey)
        XCTAssertEqual(PanelSurface.current(defaults: d), .dashboard)
    }

    // MARK: Seat state truth, 18.11.2026 (his screens 09:09 to 09:11 against Tower)
    //
    // The fixture clock is Sat 07.11.2026 10:00 UTC (12:00 in Jerusalem). Each test names the seat it
    // stands for; the numbers (48 %, 100 %, 96 %, 99 %, 170.88, 30 of 25) are the ones on his screens.

    private func altRow(_ markup: String) -> String { dialRow(markup, "alt") }

    /// Row 1, ops7: 48 % used, usable, no longer the login. Tower said "/login" and "signed out".
    func testASeatTheLoginLeftKeepsItsNumberAndIsNotSignedOut() throws {
        let ops7 = "(function() { var f = feed(); var a = f.accounts.accounts[1]; a.lastError = 'not polled'; a.windows = wins(48, 'stale'); a.capturedAt = iso(now - 16 * 6e4); return f; })()"
        let alt = altRow(try stage(ops7, surface: "dial"))
        XCTAssertTrue(alt.contains("≤52 %"), "the 09:01 reading stays, as an upper bound: \(alt)")
        XCTAssertTrue(alt.contains("stale since Sat 11:44"), "the time of the last read, not a guess: \(alt)")
        XCTAssertFalse(alt.contains("/login"), "no sign-in asked of a usable seat: \(alt)")
        XCTAssertFalse(alt.contains("signed out"), alt)
    }

    /// Row 2, ops6: 100 % used, read 2 h 25 m ago, no token Tower can poll. It shows its number and "stale since".
    func testAStaleFullSeatSaysStaleSinceAndKeepsItsNumber() throws {
        let ops6 = "(function() { var f = feed(); var a = f.accounts.accounts[1]; a.lastError = 'not polled'; a.windows = [{name: '7d', percentUsed: 100, resetsAt: iso(now + 2 * 864e5), trust: 'stale'}]; a.capturedAt = iso(now - 145 * 6e4); return f; })()"
        let alt = altRow(try stage(ops6, surface: "dial"))
        XCTAssertTrue(alt.contains(">0 % left, capped<"), alt)
        XCTAssertTrue(alt.contains("stale since Sat 09:35"), alt)
        XCTAssertFalse(alt.contains("/login"), alt)
    }

    /// Control for rows 1 and 2: a seat whose sign-in really failed still asks for the login.
    func testASeatWhoseSignInFailedStillAsksForTheLogin() throws {
        let out = "(function() { var f = feed(); var a = f.accounts.accounts[1]; a.lastError = 'needs login: refresh token rejected'; a.windows = wins(48, 'stale'); return f; })()"
        let alt = altRow(try stage(out, surface: "dial"))
        XCTAssertTrue(alt.contains("signed out"), alt)
        XCTAssertTrue(alt.contains("class=\"n act\">/login<"), alt)
    }

    /// Rows 3 and 4, ops5 96 % and ops4 99 %: the word is "capped" and the number is always printed.
    func testACappedSeatPrintsItsNumberOnBothViews() throws {
        for (used, left) in [(96, 4), (99, 1)] {
            let f = "(function() { var f = feed(); f.accounts.accounts[1].windows = wins(\(used)); return f; })()"
            let dial = altRow(try stage(f, surface: "dial"))
            XCTAssertTrue(dial.contains(">\(left) % left, capped<"), "dial, \(used) % used: \(dial)")
            XCTAssertFalse(dial.contains(">full<"), dial)
            let dash = try stage(f, surface: "dash")
            XCTAssertTrue(dash.contains("<td class=\"n t-crit\">\(left) % left, capped</td>"), "dashboard, \(used) % used")
        }
    }

    /// Control for rows 3 and 4: 94 % used is under the cap and reads as before.
    func testASeatUnderTheCapIsUnchanged() throws {
        let f = "(function() { var f = feed(); f.accounts.accounts[1].windows = wins(94); return f; })()"
        let alt = altRow(try stage(f, surface: "dial"))
        XCTAssertTrue(alt.contains(">6 %<") && !alt.contains("capped"), alt)
    }

    /// Row 6, yai2g: the live active seat at 76 % used reads as it did before (24 % left, no stale, no capped).
    func testTheLiveActiveSeatRowIsUnchanged() throws {
        let f = "(function() { var f = feed(); f.accounts.accounts[0].windows = wins(76); return f; })()"
        let markup = try stage(f, surface: "dial")
        let main = dialRow(markup, "main")
        XCTAssertTrue(main.contains(">24 %<"), main)
        XCTAssertFalse(main.contains("stale") || main.contains("capped") || main.contains("/login"), main)
    }

    /// Row 9, the footer: ops6 (100 %) is named with the other seats over the mark.
    func testTheFooterNamesAStaleFullSeatToo() throws {
        let both = """
        (function() { var f = feed(); var a = f.accounts.accounts[1]; a.lastError = 'not polled';
          a.windows = [{name: '7d', percentUsed: 100, resetsAt: iso(now + 2 * 864e5), trust: 'stale'}]; a.capturedAt = iso(now - 145 * 6e4);
          f.alerts.accounts = [{nickname: 'main', provider: 'claude', crossing: 'red', announced: [], pending: []},
                               {nickname: 'alt', provider: 'claude', crossing: 'red', announced: [], pending: []}]; return f; })()
        """
        XCTAssertTrue(try stage(both, surface: "dial").contains("main, alt used 90 % or more"))
    }

    /// Row 10: memory used and total, and compressed apart. "30 of 25 GB" set compressed memory against a gate mark.
    func testMemoryReadsUsedOfTotalAndCompressedApart() throws {
        let machine = """
        (function() { var f = feed(); f.room = {machine: {load1: 8, compressorGiB: 30, swapUsedGiB: 0, swapTotalGiB: 1, memUsedGiB: 41, memTotalGiB: 64, level: 'red', line: '', gate: {load1: 120, compressorGiB: 25}}}; return f; })()
        """
        for surface in surfaces {
            let markup = try stage(machine, surface: surface)
            XCTAssertTrue(markup.contains("mem 41 of 64 GB, compressed 30 GB"), "\(surface): \(markup.suffix(600))")
            XCTAssertFalse(markup.contains("30 of 25"), surface)
        }
    }

    /// Row 10, an old feed with no total memory: compressed memory with its gate, never "of" a gate as if it were the total.
    func testMemoryWithoutATotalSaysCompressedAndItsGate() throws {
        let machine = "(function() { var f = feed(); f.room = {machine: {load1: 8, compressorGiB: 30, swapUsedGiB: 0, swapTotalGiB: 1, level: 'red', line: '', gate: {load1: 120, compressorGiB: 25}}}; return f; })()"
        let markup = try stage(machine, surface: "dial")
        XCTAssertTrue(markup.contains("mem compressed 30 GB, gate 25"), String(markup.suffix(600)))
        XCTAssertFalse(markup.contains("30 of 25"))
    }

    /// Row 11: "runs out lasts". The headline is a sentence in every case.
    func testTheHeadlineIsNeverRunsOutLasts() throws {
        let slow = try stage("feed()", surface: "dial")
        XCTAssertFalse(slow.contains("runs out lasts"), "broken text")
        XCTAssertTrue(slow.contains("burning 0.7× the even rate, lasts past its reset"), String(slow.prefix(1500)))
        let fast = "(function() { var f = feed(); f.accounts.accounts[0].windows = wins(80); return f; })()"
        let markup = try stage(fast, surface: "dial")
        XCTAssertTrue(markup.contains("burning 1.4× the even rate, runs out in ~24h"), String(markup.prefix(1500)))
        XCTAssertFalse(markup.contains("runs out ~"))
    }

    // MARK: Rows 7 and 8, the manual entry

    private static let manualFeed = """
    (function() { var f = feed(); f.manual = {source: 'manual entry, his screens, 18.11.2026 09:09 to 09:11', live: false, enteredAt: iso(now - 3 * 36e5),
      resets: [{nickname: 'ops3', kind: 'Fable', count: 2, expires: '2027-03-09'}, {nickname: 'ops3', kind: 'New model', count: 2, expires: '2027-03-09'},
               {nickname: 'ops5', kind: 'Fable', count: 2, expires: '2027-03-09'}, {nickname: 'ops5', kind: 'New model', count: 2, expires: '2027-03-09'},
               {nickname: 'ops6', kind: 'Fable', count: 1, expires: '2027-03-09'}, {nickname: 'ops7', kind: 'Fable', count: 1, expires: '2027-03-09'}],
      credits: [{nickname: 'ops7', balanceUSD: 170.88, switch: 'off'}]}; return f; })()
    """

    func testTheManualEntryIsDrawnWithItsLabelAndAge() throws {
        for surface in surfaces {
            let markup = try stage(Self.manualFeed, surface: surface)
            XCTAssertTrue(markup.contains("Free resets and credits: manual entry, his screens, 18.11.2026 09:09 to 09:11, entered 3h 0m ago, not a live reading"), surface)
            XCTAssertTrue(markup.contains("ops3: 2 Fable, 2 New model, expire 9.3.2027"), surface)
            XCTAssertTrue(markup.contains("ops5: 2 Fable, 2 New model, expire 9.3.2027"), surface)
            XCTAssertTrue(markup.contains("ops6: 1 Fable, expire 9.3.2027"), surface)
            XCTAssertTrue(markup.contains("ops7: 1 Fable, expire 9.3.2027"), surface)
            XCTAssertTrue(markup.contains("ops7: credits $170.88, switch off"), surface)
        }
    }

    /// Control: no manual entry in the feed, nothing drawn and nothing invented.
    func testNoManualEntryDrawsNothing() throws {
        for surface in surfaces {
            XCTAssertFalse(try stage("feed()", surface: surface).contains("Free resets and credits"), surface)
        }
    }

    // MARK: Row 12, readings older than the resting line

    private static let oldCursor = """
    (function() { var f = feed(); var c = seat('alt', 'cursor', [{name: 'Cursor Models', percentUsed: 0, resetsAt: iso(now + 20 * 864e5), trust: 'stale'}], false);
      c.capturedAt = '2026-10-23T16:38:00Z'; c.lastError = 'Cursor session refused (HTTP 401) on the editor usage route'; f.accounts.accounts = [f.accounts.accounts[0], c]; return f; })()
    """

    func testAReadingOlderThanADayShowsStaleSinceAndNoNumber() throws {
        let markup = try stage(Self.oldCursor, surface: "dial")
        let alt = altRow(markup)
        XCTAssertTrue(alt.contains("stale since Fri 23.10 19:38"), alt)
        XCTAssertTrue(alt.contains("class=\"n sec\">?<"), "an unreadable value is a question mark: \(alt)")
        XCTAssertFalse(alt.contains("100 %") || alt.contains("≤0") , alt)
        XCTAssertTrue(markup.contains("refresh: sign in again in Cursor"), "the one step that refreshes it")
    }

    func testDevinsStaleReadingNamesItsOwnStep() throws {
        let devin = "(function() { var f = feed(); var d = seat('alt', 'devin', [{name: 'Weekly', percentUsed: 0, resetsAt: iso(now + 5 * 864e5), trust: 'stale'}], false); d.capturedAt = iso(now - 2 * 864e5); f.accounts.accounts = [f.accounts.accounts[0], d]; return f; })()"
        let markup = try stage(devin, surface: "dial")
        XCTAssertTrue(markup.contains("refresh: start a Devin session"), String(markup.prefix(800)))
        XCTAssertTrue(altRow(markup).contains("stale since Thu 05.11 12:00"), altRow(markup))
    }

    /// Control: a reading 19 hours old keeps its number as an upper bound (the existing rule), with "stale since".
    func testAReadingUnderADayKeepsItsUpperBound() throws {
        let f = "(function() { var f = feed(); var a = f.accounts.accounts[1]; a.windows = wins(40, 'stale'); a.capturedAt = iso(now - 19 * 36e5); return f; })()"
        let alt = altRow(try stage(f, surface: "dial"))
        XCTAssertTrue(alt.contains("≤60 %"), alt)
    }
}
