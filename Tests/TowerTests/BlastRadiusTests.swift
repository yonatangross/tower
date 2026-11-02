import Foundation
import XCTest
@testable import Tower

/// 2026-09-22: one `/login` moved 30 sessions, and all of them stop together when the
/// active login reaches 100 %. Tower ranked seats but never said how much work a full
/// meter takes down, and never warned before it happened.
final class BlastRadiusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func active(fiveHour: Double, weekly: Double, capturedAgo: TimeInterval = 60) -> AccountSnapshot {
        var a = AccountSnapshot(email: "user-a@example.com", nickname: "cal", plan: "max")
        a.fiveHourPct = fiveHour
        a.fiveHourResetsAt = now.addingTimeInterval(3 * 3600)
        a.weeklyPct = weekly
        a.weeklyResetsAt = now.addingTimeInterval(4 * 86_400)
        a.capturedAt = now.addingTimeInterval(-capturedAgo)
        return a
    }

    private func sessions(interactive: Int, background: Int) -> AgentSummary {
        var s = AgentSummary()
        s.interactive = (0..<interactive).map {
            AgentInfo(kind: "interactive", status: "busy", cwd: "/lane/\($0)", sessionId: "s\($0)",
                      accountEmail: "user-a@example.com")
        }
        s.backgroundCount = background
        return s
    }

    func testMeasuredSessionsOnOneLoginAt86PercentWarn() throws {
        let blast = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 86, weekly: 40), sessions: sessions(interactive: 24, background: 6), now: now))
        XCTAssertEqual(blast.riders, 24, "background ownership is unknown")
        XCTAssertEqual(blast.interactive, 24)
        XCTAssertEqual(blast.level, .warn, "85 % is the warn mark, not the 95 % cap")
        XCTAssertEqual(blast.line, "24 sessions ride cal at 86 %: rotate before 100 % stops them all · 6 unknown")
    }

    func testWarnMarkIsInclusiveAtExactly85() throws {
        let at85 = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 85, weekly: 10), sessions: sessions(interactive: 1, background: 0), now: now))
        XCTAssertEqual(at85.level, .warn)
        let below = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 84.9, weekly: 10), sessions: sessions(interactive: 1, background: 0), now: now))
        XCTAssertEqual(below.level, .clear)
        XCTAssertEqual(below.line, "1 session ride cal at 85 %, all stop together at 100 %")
    }

    func testFullLoginStopsEveryRider() throws {
        let blast = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 30, weekly: 100), sessions: sessions(interactive: 5, background: 1), now: now))
        XCTAssertEqual(blast.level, .stopped, "the weekly window binds as much as the 5h one")
        XCTAssertEqual(blast.line, "5 sessions stopped: cal is at 100 % · 1 unknown")
    }

    func testStaleActiveReadingIsUnknownNeverClear() throws {
        let blast = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 99, weekly: 99, capturedAgo: 3600),
            sessions: sessions(interactive: 3, background: 0), now: now))
        XCTAssertNil(blast.percentUsed, "an hour-old capture is not a present-tense number")
        XCTAssertEqual(blast.level, .unknown)
        XCTAssertFalse(blast.line.contains("%"), "unknown usage never prints a percentage")
    }

    func testNoProbeOrNoActiveLoginIsNilNotZeroRiders() {
        XCTAssertNil(BlastRadius.evaluate(active: active(fiveHour: 90, weekly: 10), sessions: nil, now: now),
                     "a failed session probe must not read as nothing at risk")
        XCTAssertNil(BlastRadius.evaluate(active: nil, sessions: sessions(interactive: 3, background: 0), now: now))
        var codex = active(fiveHour: 90, weekly: 90)
        codex.provider = .codex
        XCTAssertNil(BlastRadius.evaluate(active: codex, sessions: sessions(interactive: 3, background: 0), now: now),
                     "a Codex row is not the Claude login sessions ride")
    }

    func testToastAnnouncesOnlyARise() throws {
        let warn = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 88, weekly: 10), sessions: sessions(interactive: 2, background: 0), now: now))
        XCTAssertTrue(warn.announces(after: nil))
        XCTAssertTrue(warn.announces(after: .clear))
        XCTAssertTrue(warn.announces(after: .unknown))
        XCTAssertFalse(warn.announces(after: .warn), "one crossing, one toast")
        XCTAssertFalse(warn.announces(after: .stopped), "falling back is silent")
        let stopped = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 100, weekly: 10), sessions: sessions(interactive: 2, background: 0), now: now))
        XCTAssertTrue(stopped.announces(after: .warn))
        let clear = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 10, weekly: 10), sessions: sessions(interactive: 2, background: 0), now: now))
        XCTAssertFalse(clear.announces(after: nil))
    }

    /// Review HOLD at e9fc976f: no live session carries an owner record today, so a level
    /// read from measured riders alone never warns. The level follows the live usage
    /// whenever any session may ride the seat, measured or unknown.
    func testAllUnknownSessionsOnAHotSeatWarnAndAnnounce() throws {
        var summary = AgentSummary()
        summary.interactive = (0..<20).map { AgentInfo(kind: "interactive", sessionId: "u\($0)") }
        let warn = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 90, weekly: 10), sessions: summary, now: now))
        XCTAssertEqual(warn.riders, 0)
        XCTAssertEqual(warn.unknown, 20)
        XCTAssertEqual(warn.level, .warn)
        XCTAssertTrue(warn.announces(after: nil))
        XCTAssertEqual(warn.line, "0 confirmed, 20 unknown sessions on cal at 90 %: rotate before 100 % may stop them all")
        let stopped = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 100, weekly: 10), sessions: summary, now: now))
        XCTAssertEqual(stopped.level, .stopped)
        XCTAssertEqual(stopped.line, "0 confirmed, 20 unknown sessions may be stopped: cal is at 100 %")
        let clear = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 71, weekly: 10), sessions: summary, now: now))
        XCTAssertEqual(clear.level, .clear)
        XCTAssertFalse(clear.announces(after: nil))
        let stale = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 99, weekly: 99, capturedAgo: 3600), sessions: summary, now: now))
        XCTAssertEqual(stale.level, .unknown, "unknown means no live reading, never unknown ownership")
        XCTAssertEqual(stale.line, "0 confirmed, 20 unknown sessions on cal, usage unknown (no live reading)")
        let empty = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 100, weekly: 10), sessions: AgentSummary(), now: now))
        XCTAssertEqual(empty.level, .clear, "nothing rides the seat")
        XCTAssertEqual(empty.line, "no confirmed sessions ride cal")
    }

    func testMoveFirstExcludesOtherSeatsAndKeepsUnknownSessionsExplicit() throws {
        var summary = AgentSummary()
        summary.interactive = [
            AgentInfo(kind: "interactive", status: "busy", cwd: "/lane/build", sessionId: "z", name: "build",
                      accountEmail: "user-a@example.com"),
            AgentInfo(kind: "interactive", status: "idle", cwd: "/lane/review", sessionId: "b", name: "review",
                      accountEmail: "user-a@example.com"),
            AgentInfo(kind: "interactive", status: "idle", cwd: "/lane/alpha", sessionId: "c", name: "alpha"),
            AgentInfo(kind: "interactive", status: "idle", cwd: "/lane/review", sessionId: "a", name: "review",
                      accountEmail: "user-a@example.com"),
            AgentInfo(kind: "interactive", status: "idle", cwd: "/lane/other", sessionId: "other", name: "other",
                      accountEmail: "other@example.com"),
        ]

        let blast = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 90, weekly: 10), sessions: summary, now: now))
        XCTAssertEqual(blast.interactive, 3, "the confirmed other seat is outside this login's radius")
        XCTAssertEqual(blast.riders, 3, "unknown ownership is separate from measured riders")
        XCTAssertEqual(blast.moveFirst.map(\.id), ["a", "b", "c", "z"])
        XCTAssertEqual(blast.moveFirst.map(\.accountKnown), [true, true, false, true])
        XCTAssertEqual(blast.moveFirstLine, "move first: review [a], review [b], alpha [c] (account uncertain)")
    }

    func testStatusPrintsBlastAndMachineLines() throws {
        let blast = BlastRadius.evaluate(
            active: active(fiveHour: 90, weekly: 10), sessions: sessions(interactive: 29, background: 1), now: now)
        let machine = MachineLoad(load1: 297, compressorBytes: 24 * 1_073_741_824, swapUsedBytes: 3 * 1_073_741_824,
                                  swapTotalBytes: 4 * 1_073_741_824, physicalBytes: 64 * 1_073_741_824, sampledAt: now)
        let lines = CLI.fleetLines(blast: blast, machine: machine)
        XCTAssertEqual(lines, [
            "  ⚠️ Blast radius: 29 sessions ride cal at 90 %: rotate before 100 % stops them all · 1 unknown",
            "  move first: 0 [s0], 1 [s1], 10 [s10]",
            "  🔴 Machine: load1 297 · compressed 24.0 GB · swap 3.0 of 4.0 GB (no room: load1 297 over 120)",
        ])
        XCTAssertEqual(CLI.fleetLines(blast: nil, machine: nil), [
            "  ❔ Blast radius: session probe unavailable",
            "  ❔ Machine: load could not be read",
        ])
    }

    func testBridgeStartupOwnerCannotExcludeASessionAfterLogin() throws {
        var summary = AgentSummary()
        summary.interactive = [
            AgentInfo(kind: "interactive", status: "idle", sessionId: "seat", name: "review",
                      accountEmail: "old@example.com", accountEvidence: "bridge owner"),
        ]
        let blast = try XCTUnwrap(BlastRadius.evaluate(
            active: active(fiveHour: 90, weekly: 10), sessions: summary, now: now))
        XCTAssertEqual(blast.riders, 0)
        XCTAssertEqual(blast.moveFirst.first?.accountKnown, false)
        XCTAssertEqual(blast.moveFirstLine, "move first: review [seat] (account uncertain)")
    }
}

/// 2026-09-22: load1 180 to 320 and 14 to 34 GB compressed were the real ceiling while
/// the dispatch gate refused at load1 120. "Room" has to mean the machine too.
final class MachineLoadTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    private func load(_ load1: Double, compressedGiB: Double, swapUsed: UInt64? = 0, swapTotal: UInt64? = 0) -> MachineLoad {
        MachineLoad(load1: load1, compressorBytes: UInt64(compressedGiB * Double(gib)),
                    swapUsedBytes: swapUsed, swapTotalBytes: swapTotal, physicalBytes: 64 * gib,
                    sampledAt: Date(timeIntervalSince1970: 0))
    }

    func testLevelsFollowTheDispatchGateMarks() {
        XCTAssertEqual(load(40, compressedGiB: 5).level, .green)
        XCTAssertEqual(load(91, compressedGiB: 5).level, .amber, "three quarters of load1 120")
        XCTAssertEqual(load(40, compressedGiB: 19).level, .amber, "three quarters of 25 GiB")
        XCTAssertEqual(load(120, compressedGiB: 5).level, .amber, "the gate refuses strictly over 120")
        XCTAssertEqual(load(120.1, compressedGiB: 5).level, .red)
        XCTAssertEqual(load(40, compressedGiB: 25.5).level, .red)
        XCTAssertEqual(load(320, compressedGiB: 34).level, .red, "tonight's peak")
    }

    func testRoomAndRefusalAreTheGatesWords() {
        XCTAssertTrue(load(90, compressedGiB: 10).hasRoom)
        XCTAssertNil(load(90, compressedGiB: 10).refusal)
        XCTAssertFalse(load(180, compressedGiB: 14).hasRoom)
        XCTAssertEqual(load(180, compressedGiB: 14).refusal, "load1 180 over 120")
        XCTAssertEqual(load(50, compressedGiB: 30).refusal, "compressor 30.0 GB over 25")
    }

    func testLineShowsLoadCompressorAndSwap() {
        XCTAssertEqual(load(12.4, compressedGiB: 2, swapUsed: gib / 2, swapTotal: 2 * gib).line,
                       "load1 12 · compressed 2.0 GB · swap 0.5 of 2.0 GB")
        XCTAssertEqual(load(3, compressedGiB: 0).line, "load1 3 · compressed 0.0 GB · swap 0")
        XCTAssertEqual(load(3, compressedGiB: 0, swapUsed: nil, swapTotal: nil).line,
                       "load1 3 · compressed 0.0 GB · swap ?", "a refused swap read is unknown, never zero")
    }

    func testLiveSampleReadsThisMachine() throws {
        // Load and the compressor always answer; swap may be refused (EPERM under Claude
        // Code, measured 2026-09-23) and must then be nil rather than sink the sample.
        let sample = try XCTUnwrap(MachineLoad.sample(), "getloadavg and host_statistics64 answer on macOS")
        XCTAssertGreaterThan(sample.physicalBytes, 0)
        XCTAssertGreaterThanOrEqual(sample.load1, 0)
        XCTAssertEqual(sample.swapUsedBytes == nil, sample.swapTotalBytes == nil, "swap is read whole or not at all")
        if let used = sample.swapUsedBytes, let total = sample.swapTotalBytes {
            XCTAssertGreaterThanOrEqual(total, used)
        }
    }
}
