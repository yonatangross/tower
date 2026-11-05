import AppKit
import Darwin

/// One Tower per login session.
///
/// 2026-11-05: two Tower panels and two menu bar items were up at once, and a plain `open`
/// started nothing because Launch Services still listed a temp build that had exited
/// (pid 16867, "exited-with-subordinates") and sent the reopen to it. So a launch checks for
/// a LIVE other instance by pid, hands off to it, and exits; a listed but dead pid is ignored.
enum SingleInstance {
    /// The name the live instance listens on; posting it shows that instance's panel.
    static let showPanelNotification = Notification.Name("ai.yonyon.tower.show-panel")

    /// The first pid in `pids` that is not this process and is alive.
    static func liveOther(pids: [pid_t], selfPid: pid_t, alive: (pid_t) -> Bool) -> pid_t? {
        pids.first { $0 != selfPid && alive($0) }
    }

    /// kill(pid, 0): 0 or EPERM means the process exists; ESRCH means it is gone.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Another live Tower app with this bundle id, if any. Only the GUI launch asks; the
    /// CLI verbs (`tower mcp`, `tower status`) run the same binary and must never exit here.
    @MainActor
    static func otherLiveInstance() -> pid_t? {
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: ProductIdentity.bundleIdentifier)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
        return liveOther(pids: pids, selfPid: ProcessInfo.processInfo.processIdentifier, alive: isAlive)
    }
}

/// The header line for seats the Keychain refused this build: what happened and which
/// button settles it. Replaces a bare "refresh failed: Keychain read failed (-25293)".
enum KeychainRefusal {
    static func headerLine(refusedSeats: Int) -> String? {
        guard refusedSeats > 0 else { return nil }
        let noun = refusedSeats == 1 ? "remembered seat is" : "remembered seats are"
        return "🔑 \(refusedSeats) \(noun) locked to an older Tower build: press Re-trust, then Always Allow"
    }
}

/// The age at the header's right edge. "never" only when nothing at all has been read:
/// rows hydrated from disk carry their own capture ages, so the header says "cached"
/// instead of contradicting them.
enum PanelHeaderAge {
    static func text(lastRefresh: Date?, probed: Bool, failed: Bool, hasRows: Bool, now: Date) -> String {
        if let lastRefresh { return CLI.age(lastRefresh, now: now) }
        if (probed || failed) && !hasRows { return "never" }
        return "cached"
    }
}
