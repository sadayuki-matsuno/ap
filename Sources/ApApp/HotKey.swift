import Carbon.HIToolbox

/// A global hotkey through Carbon's RegisterEventHotKey (no Accessibility permission needed)
@MainActor
final class HotKey {
    /// The Carbon callback is a C function pointer and cannot capture, so the handler lives here
    private static var handler: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// keyCode is a virtual key code (kVK_*), modifiers are Carbon masks (cmdKey | controlKey ...)
    init?(keyCode: Int, modifiers: Int, handler: @escaping @MainActor () -> Void) {
        Self.handler = handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                // Carbon delivers application events on the main thread
                MainActor.assumeIsolated { HotKey.handler?() }
                return noErr
            },
            1, &eventType, nil, &eventHandlerRef)
        // "apv1" identifies our hotkey
        let hotKeyId = EventHotKeyID(signature: 0x6170_7631, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyId, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard installStatus == noErr, registerStatus == noErr else { return nil }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        hotKeyRef = nil
        eventHandlerRef = nil
    }
}
