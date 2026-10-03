import Carbon.HIToolbox

/// Characters of the current keyboard layout (Dvorak, AZERTY and others move keys away from their ANSI positions)
@MainActor
enum KeyboardLayout {
    /// The character a key types without modifiers, or nil when the layout can't be read
    static func character(for keyCode: Int) -> String? {
        withLayout { layout in translate(layout, keyCode) }.flatMap { $0 }
    }

    /// The key code that types `character`, if any key does
    static func keyCode(for character: String) -> Int? {
        withLayout { layout in (0..<128).first { translate(layout, $0) == character } }.flatMap { $0 }
    }

    private static func withLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>) -> T) -> T? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1, body)
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ keyCode: Int) -> String? {
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
