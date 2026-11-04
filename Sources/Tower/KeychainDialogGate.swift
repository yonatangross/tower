import Foundation
import Security

/// The one switch that keeps the Keychain dialog off screen.
///
/// The legacy (file based) login keychain ignores `LAContext.interactionNotAllowed`.
/// Measured 2026-11-04 on a throwaway keychain: a read of an item whose access list names
/// another build, carrying only that LAContext, showed the dialog, blocked 100 s and returned
/// -128 after Deny, while the same read after `SecKeychainSetUserInteractionAllowed(false)`
/// failed at once with -25293 and no dialog. That switch is per process, so every Tower
/// process (app, CLI, MCP) turns it off before its first Keychain call and turns it on only
/// inside the operator's Re-trust (panel button, `tower retrust`, `tower_retrust`).
///
/// Not a substitute for the LAContext the reads still attach: that one is what the data
/// protection keychain honours, this one is what the file keychain honours.
final class KeychainDialogGate: @unchecked Sendable {
    static let shared = KeychainDialogGate()

    /// Guards `allowed` only, never held across a caller's code.
    private let lock = NSLock()
    /// Serializes Re-trust windows. Separate from `lock`: the body of a window reads
    /// `dialogsAllowed`, and NSLock is not recursive.
    private let window = NSLock()
    private let set: (Bool) -> OSStatus
    /// macOS starts every process with interaction allowed.
    private var allowed = true

    init(set: @escaping (Bool) -> OSStatus = { SecKeychainSetUserInteractionAllowed($0) }) {
        self.set = set
    }

    var dialogsAllowed: Bool { lock.withLock { allowed } }

    /// Idempotent. Called at process start and again before every background read, so a
    /// path that skipped main (a test host, a future entry point) is still covered.
    /// Waits for a Re-trust in progress, like every background read.
    @discardableResult
    func closeForProcess() -> OSStatus {
        window.lock()
        defer { window.unlock() }
        return closeLocked()
    }

    /// Caller holds `window`.
    @discardableResult
    private func closeLocked() -> OSStatus {
        lock.withLock {
            let status = set(false)
            if status == errSecSuccess { allowed = false }
            return status
        }
    }

    /// Runs a background Keychain call with dialogs off. It takes the same window as
    /// Re-trust, so it waits for an operator read in progress instead of switching dialogs
    /// off under it, and a Re-trust cannot switch them on while it runs.
    func withDialogsOff<T>(_ body: () -> T) -> T {
        window.lock()
        defer { window.unlock() }
        closeLocked()
        return body()
    }

    /// The only way to show the dialog: runs `body` with interaction allowed and switches it
    /// off again before returning, whatever `body` did. Re-trusts never overlap.
    func withDialogAllowed<T>(_ body: () -> T) -> T {
        window.lock()
        defer { window.unlock() }
        lock.withLock {
            _ = set(true)
            allowed = true
        }
        defer {
            lock.withLock {
                if set(false) == errSecSuccess { allowed = false }
            }
        }
        return body()
    }
}
