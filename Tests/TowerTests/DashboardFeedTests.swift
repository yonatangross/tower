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

    /// Draws `feedExpression` (JS that yields a feed) on one surface and returns the stage markup.
    private func stage(_ feedExpression: String, surface: String = "dash") throws -> String {
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
            XCTAssertTrue(stale.contains("PROBABLY") && stale.contains("Press Refresh"), "\(surface): a stale read reads PROBABLY")
        }
    }

    /// 2026-11-09, alt3 after /login: 7d live, 5h absent from the reply. The dial said CAN'T TELL,
    /// offered a Refresh that returns the same reply, and printed the live week as an upper bound.
    private static let weekLiveFiveHourAbsent = """
    (function() { var f = feed({kind: 'activeFiveHourUnknown', nickname: 'main', percentUsed: null, roomPct: 98});
      f.accounts.accounts[0].model = null;
      f.accounts.accounts[0].windows = [{name: '5h', percentUsed: null, resetsAt: null, trust: 'unknown'},
        {name: '7d', percentUsed: 2, resetsAt: iso(now + 6 * 864e5), trust: 'live'}];
      return f; })()
    """

    func testALiveWeekWithNoFiveHourReadingIsNotCantTell() throws {
        for surface in surfaces {
            let markup = try stage(Self.weekLiveFiveHourAbsent, surface: surface)
            XCTAssertFalse(markup.contains("CAN'T TELL"), "\(surface): the week is known, only 5h is not")
            XCTAssertFalse(markup.contains("Refresh now"), "\(surface): a refresh returns the same reply")
            XCTAssertTrue(markup.contains("PROBABLY"), "\(surface): the gap keeps the verdict short of YES")
            XCTAssertFalse(markup.contains("YES"), "\(surface): an unknown 5h window is not a YES")
            XCTAssertTrue(markup.contains("no 5h reading"), "\(surface): the verdict names what is missing")
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
        let nearlyFull = "(function() { var f = feed(); f.accounts.accounts[1].windows = wins(97); return f; })()"
        let alt = dialRow(try stage(nearlyFull, surface: "dial"), "alt")
        XCTAssertTrue(alt.contains("3 %"), "3 % room left: \(alt)")
        XCTAssertTrue(alt.contains("t-crit"), "3 % room reads red: \(alt)")
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
        XCTAssertTrue(markup.contains("account not known for 2"), "the footer says what is unknown")
        XCTAssertTrue(markup.contains("main over the red rail"), "the footer names the alert")
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

    /// User's screenshot: no ready seat, four seats the Keychain would hand back after one approval.
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

    /// Betty/User 2026-11-07: a seat Tower has not read yet showed "?", which reads as a broken number.
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

    // MARK: What the menu bar opens

    func testMenuBarOpensTheDashboardByDefaultAndClassicStaysOneSettingAway() {
        let d = UserDefaults(suiteName: "dash-surface-\(UUID().uuidString)")!
        XCTAssertEqual(PanelSurface.current(defaults: d), .dashboard)
        PanelSurface.set(.classic, defaults: d)
        XCTAssertEqual(PanelSurface.current(defaults: d), .classic)
        d.set("garbage", forKey: PanelSurface.defaultsKey)
        XCTAssertEqual(PanelSurface.current(defaults: d), .dashboard)
    }
}
