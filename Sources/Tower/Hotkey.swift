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

    static func register() {
        os_log("PanelHotkey.register reached", log: hotkeyLog, type: .default)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
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
        RegisterEventHotKey(keyCode, modifiers,
                            EventHotKeyID(signature: sig, id: panelHotkeyID),
                            GetApplicationEventTarget(), 0, &hotKeyRef)
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
