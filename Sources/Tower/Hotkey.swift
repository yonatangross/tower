import AppKit
import Carbon.HIToolbox
import os.log

private let hotkeyLog = OSLog(subsystem: ProductIdentity.bundleIdentifier, category: "hotkey")

/// Global hotkey that toggles the panel. Carbon RegisterEventHotKey rather
/// than a CGEventTap or NSEvent monitor because it is the one mechanism that
/// needs NO accessibility permission and can still CONSUME the keystroke.
///
/// Default is cmd+period per the operator's request. Worth knowing: cmd+. is
/// also macOS's universal "cancel" key, and a registered global hotkey wins
/// over in-app handling, so cancel-by-keyboard in other apps is sacrificed
/// while this app runs. If that bites, change `keyCode`/`modifiers` here.
enum PanelHotkey {
    private static let keyCode = UInt32(kVK_ANSI_Period)
    private static let modifiers = UInt32(cmdKey)
    private static var hotKeyRef: EventHotKeyRef?
    private static var escMonitor: Any?

    /// Hotkey id inside the shared handler: 1 = panel toggle.
    private static let panelHotkeyID: UInt32 = 1

    // Carbon status values (CarbonEventsCore.h); Swift does not import these constants.
    private static let hotKeyExists: OSStatus = -9878
    private static let handlerAlreadyInstalled: OSStatus = -9866

    static func isRegistered(status: OSStatus) -> Bool { status == noErr }

    /// A registration result in words. Carbon returns only a number, and the call's result
    /// used to be discarded, so a failed registration left no trace anywhere.
    ///
    /// What this log can and cannot show. Tower registers with kEventHotKeyExclusive, so
    /// -9878 (eventHotKeyExistsErr) now has two causes: the key is already registered in
    /// THIS process, or another process holds it. The status does not say which one, and
    /// nothing in it identifies the other process.
    ///
    /// The SDK headers disagree on how far the second cause reaches. CarbonEventsCore.h and
    /// RegisterEventHotKey's result note require the holder to be exclusive too; the
    /// kEventHotKeyExclusive note says any existing registration for the key is enough. The
    /// wording here holds under both, so "registered" does not prove nobody else had the key:
    /// under the first reading a non-exclusive registrant elsewhere goes undetected.
    /// A non-exclusive app that registers after Tower is never reported on either reading;
    /// its registration succeeds and it receives no events while Tower holds the key.
    static func describe(status: OSStatus) -> String {
        switch status {
        case noErr: return "registered"
        case hotKeyExists: return "not registered: already registered in this process, or another process holds it (\(status))"
        case handlerAlreadyInstalled: return "handler already installed (\(status))"
        default: return "not registered: Carbon status \(status)"
        }
    }

    static func register() {
        os_log("PanelHotkey.register reached", log: hotkeyLog, type: .default)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                PanelHotkey.toggle()
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let sig = OSType(0x484C_4D54) // "HLMT"
        os_log("PanelHotkey event handler: %{public}@", log: hotkeyLog, type: .default,
               installStatus == noErr ? "installed" : "failed, status \(installStatus)")
        // Exclusive because with options 0 another process holding the key is not an error,
        // so a conflict would be logged as "registered" and stay invisible.
        let status = RegisterEventHotKey(keyCode, modifiers,
                                         EventHotKeyID(signature: sig, id: panelHotkeyID),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive),
                                         &hotKeyRef)
        os_log("PanelHotkey cmd+period: %{public}@", log: hotkeyLog,
               type: isRegistered(status: status) ? .default : .error, describe(status: status))
        // Esc closes an open panel. Local monitor: only fires while THIS app
        // has key focus, so it cannot eat Esc anywhere else.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) {
                var handled = false
                MainActor.assumeIsolated {
                    if AppDelegate.shared?.panel?.isVisible == true {
                        AppDelegate.shared?.hidePanel()
                        handled = true
                    }
                }
                if handled { return nil }
            }
            return e
        }
    }

    @MainActor
    static func toggle() {
        let wasVisible = AppDelegate.shared?.panel?.isVisible == true
        os_log("PanelHotkey.toggle reached, wasVisible: %{public}d", log: hotkeyLog, type: .default, wasVisible ? 1 : 0)
        AppDelegate.shared?.togglePanel()
        let isVisibleNow = AppDelegate.shared?.panel?.isVisible == true
        os_log("PanelHotkey.toggle completed, isVisibleNow: %{public}d", log: hotkeyLog, type: .default, isVisibleNow ? 1 : 0)
    }
}
