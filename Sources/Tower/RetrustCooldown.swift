import Foundation

/// `tower_retrust` can raise the Keychain dialog on the operator's screen, so an agent may
/// call it at most once per `window` per `tower mcp` process (b87 on #22). The panel's
/// Re-trust button and `tower retrust` are the operator's own actions and are not limited.
final class RetrustCooldown: @unchecked Sendable {
    static let shared = RetrustCooldown()
    static let window: TimeInterval = 60

    private let lock = NSLock()
    private var lastAt: Date?

    /// nil = allowed, and the call is recorded. Otherwise the whole seconds left to wait;
    /// a refused call does not restart the window.
    func refusal(now: Date) -> Int? {
        lock.withLock {
            if let lastAt, now.timeIntervalSince(lastAt) < Self.window {
                return max(1, Int((Self.window - now.timeIntervalSince(lastAt)).rounded(.up)))
            }
            lastAt = now
            return nil
        }
    }
}
