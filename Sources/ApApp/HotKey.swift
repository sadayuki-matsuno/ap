import ApCore
import Carbon.HIToolbox

/// A global hotkey through Carbon's RegisterEventHotKey (no Accessibility permission needed). The event handler is
/// installed once; the key itself can be re-registered (Settings) or released (recording, relaunch)
@MainActor
final class HotKey {
    /// The Carbon callback is a C function pointer and cannot capture, so the handler lives here
    private static var handler: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(handler: @escaping @MainActor () -> Void) {
        Self.handler = handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                // Carbon delivers application events on the main thread
                MainActor.assumeIsolated { HotKey.handler?() }
                return noErr
            },
            1, &eventType, nil, &eventHandlerRef)
    }

    /// Replaces the registered key. false when macOS refuses it (taken by another app or the system); nothing is
    /// registered then
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        // "apv1" identifies our hotkey
        let hotKeyId = EventHotKeyID(signature: 0x6170_7631, id: 1)
        return RegisterEventHotKey(
            UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), hotKeyId, GetApplicationEventTarget(), 0, &hotKeyRef
        ) == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
