import Foundation
import XCTest
@testable import Tower

/// Records, at every seat read, whether the process would let the Keychain show its dialog.
final class DialogSpyKeychain: ClaudeSeatKeychain {
    let gate: KeychainDialogGate
    var dialogsAllowedAtRead: [Bool] = []
    init(gate: KeychainDialogGate) { self.gate = gate }

    func readSeats(interaction: ClaudeSeatReadInteraction) -> Result<ClaudeSeatKeychainReadout, ClaudeSeatVaultError> {
        dialogsAllowedAtRead.append(gate.dialogsAllowed)
        return .success(ClaudeSeatKeychainReadout())
    }
    func writeSeat(service: String, account: String, label: String, data: Data) -> String? { nil }
    func removeSeat(service: String, account: String, label: String) -> String? { nil }
    func purgeAll() -> String? { nil }
}

final class KeychainDialogGateTests: XCTestCase {
    private var switches: [Bool] = []

    private func makeVault(_ spy: DialogSpyKeychain) -> ClaudeSeatVault {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tower-dialog-gate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ClaudeSeatVault(
            keychain: spy,
            lockURL: dir.appendingPathComponent("lock"),
            stateURL: dir.appendingPathComponent("state.plist"),
            retentionEnabled: { true },
            setRetentionEnabled: { _ in },
            log: { _ in },
            mayPrompt: { true },
            dialogGate: spy.gate)
    }

    private func recordingGate() -> KeychainDialogGate {
        KeychainDialogGate(set: { [unowned self] allowed in self.switches.append(allowed); return errSecSuccess })
    }

    /// 2026-11-04: LAContext.interactionNotAllowed did not stop a legacy keychain dialog. A
    /// background read must run with the process switch off, even in a process whose entry
    /// point never closed it.
    func testBackgroundSeatReadRunsWithDialogsOff() {
        let spy = DialogSpyKeychain(gate: recordingGate())
        _ = makeVault(spy).credentials(active: nil)
        XCTAssertEqual(spy.dialogsAllowedAtRead, [false])
        XCTAssertEqual(switches.first, false)
    }

    func testRetrustIsTheOnlyReadWithDialogsOnAndClosesAfter() {
        let spy = DialogSpyKeychain(gate: recordingGate())
        let vault = makeVault(spy)
        _ = vault.retrust()
        XCTAssertEqual(spy.dialogsAllowedAtRead, [true])
        XCTAssertFalse(spy.gate.dialogsAllowed)
        XCTAssertEqual(switches.suffix(2), [true, false])
    }

    func testAFailedSwitchIsNeverReportedAsOff() {
        var calls = 0
        let gate = KeychainDialogGate(set: { _ in calls += 1; return errSecParam })
        XCTAssertEqual(gate.closeForProcess(), errSecParam)
        XCTAssertTrue(gate.dialogsAllowed, "a failed switch must not report dialogs as off")
        XCTAssertEqual(calls, 1)
    }
}
