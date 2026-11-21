import XCTest
@testable import Tower

/// Operator word 2026-11-06: "why don't you tell me at 80 %, it should be configurable in Tower".
/// Tower's advice said stay on a seat at 93 % of its 5h window while another seat had 66 % room.
/// From `alerts.switchThresholdPct` (default 80, range 50 to 99) the active seat's binding window
/// is a reason to move: `advise` names the roomiest recommendable seat, and the app raises one
/// notification per window crossing.
final class SwitchThresholdTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func seat(_ nick: String, fiveHour: Double, weekly: Double = 10, age: TimeInterval = 30) -> AccountSnapshot {
        var row = AccountSnapshot(email: "\(nick)@example.com", nickname: nick, plan: "max")
        row.capturedAt = now.addingTimeInterval(-age)
        row.fiveHourPct = fiveHour
        row.weeklyPct = weekly
        row.fiveHourResetsAt = now.addingTimeInterval(3_600)
        row.weeklyResetsAt = now.addingTimeInterval(86_400)
        return row
    }

    /// The incident shape: Tower holds a Chrome profile for the active seat only. The older rule
    /// ("move to the best switchable seat that is an improvement") cannot see any other seat then,
    /// so only the threshold path can name one.
    private func only(_ s: AccountSnapshot) -> [String: ChromeProfileHint] {
        [s.email: ChromeProfileHint(displayName: s.nickname.uppercased(), chooserEmail: nil)]
    }

    // MARK: advise

    func testTheDefaultIsEightyAndTheRangeIsFiftyToNinetyNine() {
        XCTAssertEqual(SwitchThreshold.defaultPct, 80)
        XCTAssertNil(SwitchThreshold.parse(49.9), "below the range")
        XCTAssertEqual(SwitchThreshold.parse(50), 50)
        XCTAssertEqual(SwitchThreshold.parse(99), 99)
        XCTAssertNil(SwitchThreshold.parse(100), "100 is the cap, not a warning")
        XCTAssertNil(SwitchThreshold.parse(.nan))
    }

    func testSeventyNineStaysOnTheActiveSeat() {
        let active = seat("yonata", fiveHour: 79)
        let other = seat("ops1", fiveHour: 34)
        let advice = AccountSnapshot.advise(activeEmail: active.email, accounts: [active, other], switchProfiles: only(active), now: now)
        guard case .stay(let nick, _, _) = advice else { return XCTFail("79 is below 80, got \(advice)") }
        XCTAssertEqual(nick, "yonata")
    }

    func testEightyNamesTheRoomiestSeat() {
        let active = seat("yonata", fiveHour: 80)
        let other = seat("ops1", fiveHour: 34)
        let advice = AccountSnapshot.advise(activeEmail: active.email, accounts: [active, other], switchProfiles: only(active), now: now)
        XCTAssertEqual(advice, .switchTo(nick: "ops1", pct: 34, via: nil))
        XCTAssertEqual(advice.command, "/login")
    }

    /// The 2026-11-06 report: 93 % on the 5h window, another seat with 66 % room.
    func testNinetyThreeSwitchesAndPicksTheRoomiestOfSeveral() {
        let active = seat("yonata", fiveHour: 93, weekly: 46)
        let ops1 = seat("ops1", fiveHour: 34)
        let ops3 = seat("ops3", fiveHour: 61)
        let advice = AccountSnapshot.advise(activeEmail: active.email, accounts: [ops3, active, ops1], switchProfiles: only(active), now: now)
        XCTAssertEqual(advice, .switchTo(nick: "ops1", pct: 34, via: nil))
    }

    /// The target does not have to be one Tower holds a Chrome profile for: `/login` works for any
    /// seat, and a missing profile only drops the hint. Filtering on it kept the 93 % seat as "best".
    func testATargetWithNoChromeProfileIsStillNamed() {
        let active = seat("yonata", fiveHour: 93)
        let ops1 = seat("ops1", fiveHour: 34)
        let advice = AccountSnapshot.advise(
            activeEmail: active.email, accounts: [active, ops1], switchProfiles: only(active), now: now)
        XCTAssertEqual(advice, .switchTo(nick: "ops1", pct: 34, via: nil))
    }

    func testNoRecommendableTargetStaysInsteadOfNamingAStaleSeat() {
        let active = seat("yonata", fiveHour: 93)
        let stale = seat("ops1", fiveHour: 10, age: AccountSnapshot.freshnessTTL + 60)
        let advice = AccountSnapshot.advise(activeEmail: active.email, accounts: [active, stale], switchProfiles: only(active), now: now)
        guard case .stay(let nick, _, _) = advice else { return XCTFail("no live target, got \(advice)") }
        XCTAssertEqual(nick, "yonata")
        XCTAssertNil(advice.command, "nothing to run when there is nowhere to go")
    }

    func testNoRecommendableTargetStaysWhenEveryOtherSeatIsBusier() {
        let active = seat("yonata", fiveHour: 81)
        let busier = seat("ops1", fiveHour: 90)
        let advice = AccountSnapshot.advise(activeEmail: active.email, accounts: [active, busier], switchProfiles: only(active), now: now)
        guard case .stay(let nick, _, _) = advice else { return XCTFail("a worse seat is not a switch, got \(advice)") }
        XCTAssertEqual(nick, "yonata")
    }

    func testARestingTargetIsNotNamed() {
        let active = seat("yonata", fiveHour: 93)
        let capped = seat("ops1", fiveHour: 100)
        let advice = AccountSnapshot.advise(activeEmail: active.email, accounts: [active, capped], switchProfiles: only(active), now: now)
        guard case .stay = advice else { return XCTFail("a capped seat is resting, got \(advice)") }
    }

    func testTheWeeklyWindowBindsToo() {
        let active = seat("yonata", fiveHour: 10, weekly: 88)
        let other = seat("ops1", fiveHour: 10, weekly: 20)
        let advice = AccountSnapshot.advise(activeEmail: active.email, accounts: [active, other], switchProfiles: only(active), now: now)
        XCTAssertEqual(advice, .switchTo(nick: "ops1", pct: 20, via: nil))
    }

    func testAHigherThresholdHoldsTheAdviceBack() {
        let active = seat("yonata", fiveHour: 85)
        let other = seat("ops1", fiveHour: 34)
        let at90 = AccountSnapshot.advise(
            activeEmail: active.email, accounts: [active, other], switchProfiles: only(active), switchThresholdPct: 90, now: now)
        guard case .stay = at90 else { return XCTFail("85 is below a 90 threshold, got \(at90)") }
        let at50 = AccountSnapshot.advise(
            activeEmail: active.email, accounts: [active, other], switchProfiles: only(active), switchThresholdPct: 50, now: now)
        XCTAssertEqual(at50, .switchTo(nick: "ops1", pct: 34, via: nil))
    }

    // MARK: the notification

    func testTheNotificationFiresOncePerWindowCrossing() {
        var active = seat("yonata", fiveHour: 93)
        let ops1 = seat("ops1", fiveHour: 34)
        let first = SwitchAlert.evaluate(&active, among: [active, ops1], thresholdPct: 80, now: now)
        XCTAssertEqual(first?.nickname, "yonata")
        XCTAssertEqual(first?.window, "5h")
        XCTAssertEqual(first?.pct, 93)
        XCTAssertEqual(first?.target, "ops1")
        XCTAssertNil(SwitchAlert.evaluate(&active, among: [active, ops1], thresholdPct: 80, now: now),
                     "the same window does not announce twice")
    }

    func testTheNotificationIsSilentBelowTheThreshold() {
        var active = seat("yonata", fiveHour: 79)
        XCTAssertNil(SwitchAlert.evaluate(&active, among: [active], thresholdPct: 80, now: now))
        active.fiveHourPct = 80
        XCTAssertNotNil(SwitchAlert.evaluate(&active, among: [active], thresholdPct: 80, now: now), "80 crosses")
    }

    func testTheNotificationRearmsForTheNextWindow() {
        var active = seat("yonata", fiveHour: 93)
        XCTAssertNotNil(SwitchAlert.evaluate(&active, among: [active], thresholdPct: 80, now: now))
        active.fiveHourResetsAt = now.addingTimeInterval(3_600 + 5 * 3_600)
        XCTAssertNotNil(SwitchAlert.evaluate(&active, among: [active], thresholdPct: 80, now: now),
                        "a new 5h window is a new crossing")
    }

    func testTheNotificationSaysSoWhenNoSeatHasRoom() {
        var active = seat("yonata", fiveHour: 93)
        let alert = SwitchAlert.evaluate(&active, among: [active], thresholdPct: 80, now: now)
        XCTAssertNotNil(alert, "the crossing is still worth saying")
        XCTAssertNil(alert?.target)
        XCTAssertTrue(alert?.body.contains("No other seat") == true)
    }

    func testTheNotificationNeedsALiveReading() {
        var stale = seat("yonata", fiveHour: 93, age: AccountSnapshot.freshnessTTL + 60)
        XCTAssertNil(SwitchAlert.evaluate(&stale, among: [stale], thresholdPct: 80, now: now),
                     "a stale number is not a crossing")
    }

    // MARK: b111 HOLD 6691214425 on #150

    /// Must: the panel's published mark was read once at launch and never again, so after
    /// `tower_config_set` the panel and its Stepper showed the old value and a Stepper tap wrote
    /// it back over the MCP one. The refresh now takes the stored value through this seam.
    func testTheRefreshReadsWhatTowerConfigSetStored() throws {
        let suite = "SwitchThresholdTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LimitsModel.currentSwitchThreshold(defaults), 80, "nothing stored reads as the default")
        defaults.set(90.0, forKey: SwitchThreshold.key)
        XCTAssertEqual(LimitsModel.currentSwitchThreshold(defaults), 90, "a value set from outside the panel")
        defaults.set(3.0, forKey: SwitchThreshold.key)
        XCTAssertEqual(LimitsModel.currentSwitchThreshold(defaults), 80, "a hand edited out of range value reads as 80")
    }

    /// Should (Codex P2-2): with a custom mark below 80 the switch notice came first, then the plain
    /// 80 % toast for the same window in a later cycle. Once the notice has announced a window, a
    /// plain toast below 95 adds nothing; 95 and 100 still say something new.
    func testALaterPlainEightyToastIsSupersededByTheSwitchNotice() {
        var active = seat("yonata", fiveHour: 55)
        XCTAssertNotNil(SwitchAlert.evaluate(&active, among: [active], thresholdPct: 50, now: now))
        active.fiveHourPct = 82
        let plain = Thresholds.evaluate(&active, now: now)
        XCTAssertEqual(plain.count, 1, "the plain 80 toast is due in this cycle")
        XCTAssertTrue(SwitchAlert.supersedes(plain[0], on: active), "the switch notice already covered this window")
        active.fiveHourPct = 96
        let nearFull = Thresholds.evaluate(&active, now: now)
        XCTAssertEqual(nearFull.count, 1)
        XCTAssertFalse(SwitchAlert.supersedes(nearFull[0], on: active), "95 is new information")
    }

    func testAPlainToastIsKeptWhenNoSwitchNoticeCoveredTheWindow() {
        var active = seat("yonata", fiveHour: 82)
        let plain = Thresholds.evaluate(&active, now: now)
        XCTAssertEqual(plain.count, 1)
        XCTAssertFalse(SwitchAlert.supersedes(plain[0], on: active))
    }

    /// Should: an active seat with a live 5h reading over the mark and NO weekly reading is not
    /// recommendable, so the old branch skipped the stay and moved to the best seat, which was
    /// busier. No better live seat means stay.
    func testAnActiveSeatWithNoWeeklyReadingStaysWhenNoSeatIsBetter() {
        var active = seat("yonata", fiveHour: 85)
        active.weeklyPct = nil
        active.weeklyResetsAt = nil
        let busier = seat("ops1", fiveHour: 90)
        let advice = AccountSnapshot.advise(activeEmail: active.email, accounts: [active, busier], now: now)
        guard case .stay(let nick, let pct, _) = advice else { return XCTFail("a busier seat is no move, got \(advice)") }
        XCTAssertEqual(nick, "yonata")
        XCTAssertEqual(pct, 85)
    }

    /// The stay is for a seat that still has room. A capped active seat with nowhere to go keeps the
    /// older answer, which is not "stay".
    func testACappedActiveSeatWithNowhereToGoIsNotAStay() {
        let active = seat("yonata", fiveHour: 100)
        let advice = AccountSnapshot.advise(activeEmail: active.email, accounts: [active], now: now)
        if case .stay = advice { XCTFail("a full seat is not a place to stay, got \(advice)") }
    }

    /// b111 HOLD 6691664074: the roster was copied from the refresh result before the store lock was
    /// taken, so a seat the CLI or another process wrote in between was judged on an old reading.
    /// The notices now read the roster from the copy the lock hands over.
    func testTheNoticeMeasuresAgainstTheLockedCopyNotAnEarlierRead() {
        let active = seat("yonata", fiveHour: 93)
        let earlier = seat("ops1", fiveHour: 95)
        var locked = seat("ops1", fiveHour: 34)
        locked.capturedAt = now
        var accounts = [active.email: active, locked.email: locked]
        _ = earlier
        let out = SwitchAlert.notices(
            in: &accounts, keys: [active.email], activeEmail: active.email, thresholdPct: 80, now: now)
        XCTAssertEqual(out.switches.first?.target, "ops1", "the locked copy says ops1 has room")
    }

    func testTheNoticeSkipsASeatThatIsNotTheActiveOne() {
        let quiet = seat("ops1", fiveHour: 93)
        var accounts = [quiet.email: quiet]
        let out = SwitchAlert.notices(
            in: &accounts, keys: [quiet.email], activeEmail: "someone@example.com", thresholdPct: 80, now: now)
        XCTAssertTrue(out.switches.isEmpty)
    }

    func testTheBookkeepingSurvivesTheGenericPruner() {
        var active = seat("yonata", fiveHour: 93)
        _ = SwitchAlert.evaluate(&active, among: [active], thresholdPct: 80, now: now)
        _ = Thresholds.evaluate(&active, now: now)
        XCTAssertNil(SwitchAlert.evaluate(&active, among: [active], thresholdPct: 80, now: now),
                     "Thresholds.evaluate migrates and prunes the same dictionary; the key must live through it")
    }
}
