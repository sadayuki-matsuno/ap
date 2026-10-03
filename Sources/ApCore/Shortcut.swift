/// A global hotkey: a virtual key code (kVK_*) plus Carbon modifier masks, as RegisterEventHotKey takes them
public struct Shortcut: Sendable, Equatable {
    // Carbon's cmdKey / shiftKey / optionKey / controlKey (ApCore doesn't import Carbon)
    public static let command = 1 << 8
    public static let shift = 1 << 9
    public static let option = 1 << 11
    public static let control = 1 << 12

    /// Control-Command-P
    public static let `default` = Shortcut(keyCode: 35, modifiers: control | command)

    public var keyCode: Int
    public var modifiers: Int

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public enum Rejection: Sendable, Equatable {
        /// No Command / Control / Option: plain keys and Shift-only combos would swallow typing
        case noModifier
        /// Command (with or without Shift) alone: a Carbon hotkey takes the key before any app sees it, so it would
        /// break the picker's own keys (Command-P / O / , / Return / Delete), the synthetic Command-V paste, and the
        /// same shortcut in every other app. Command-Space and F-keys are allowed
        case commandOnly
    }

    /// F1-F20
    static let functionKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
    static let space = 49

    /// Why this combination can't be a hotkey; nil when it can
    public var rejection: Rejection? {
        let primary = modifiers & (Self.command | Self.control | Self.option)
        if primary == 0 { return .noModifier }
        // Command-V (the synthetic paste) is covered here too: it only ever has Command
        if primary == Self.command, keyCode != Self.space, !Self.functionKeyCodes.contains(keyCode) {
            return .commandOnly
        }
        return nil
    }

    public var isValid: Bool { rejection == nil }

    public enum RecorderAction: Sendable, Equatable {
        case cancel
        case reset
        case rejected(Rejection)
        case record(Shortcut)
    }

    /// What a key press means to the shortcut recorder: Escape cancels and Delete resets to the default (both only
    /// without modifiers), anything else is recorded if it is a valid shortcut
    public static func interpret(keyCode: Int, modifiers: Int) -> RecorderAction {
        let relevant = modifiers & (command | shift | option | control)
        if relevant == 0, keyCode == 53 { return .cancel }
        if relevant == 0, keyCode == 51 { return .reset }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: relevant)
        if let rejection = shortcut.rejection { return .rejected(rejection) }
        return .record(shortcut)
    }

    public var userDefaultsValue: [String: Int] { ["keyCode": keyCode, "modifiers": modifiers] }

    /// nil when missing, malformed, out of range (RegisterEventHotKey takes UInt32s; virtual key codes are 0-127)
    /// or not a valid shortcut
    public init?(userDefaultsValue: Any?) {
        let knownModifiers = Self.command | Self.shift | Self.option | Self.control
        guard let dictionary = userDefaultsValue as? [String: Any],
              let keyCode = dictionary["keyCode"] as? Int, let modifiers = dictionary["modifiers"] as? Int,
              (0...127).contains(keyCode), modifiers >= 0, modifiers & ~knownModifiers == 0
        else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
        guard isValid else { return nil }
    }

    /// Keys whose layout character is invisible or misleading
    static let specialKeyLabels: [Int: String] = [
        36: "\u{21A9}", 48: "\u{21E5}", 49: "Space", 51: "\u{232B}", 53: "\u{238B}", 117: "\u{2326}", 76: "\u{2324}",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}", 115: "\u{2196}", 119: "\u{2198}",
        116: "\u{21DE}", 121: "\u{21DF}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        90: "F20",
    ]

    /// "⌃⌥⇧⌘" (macOS order) plus the key: `keyLabel` is the character the key types in the current layout
    public func symbols(keyLabel: String?) -> String {
        var text = ""
        if modifiers & Self.control != 0 { text += "\u{2303}" }
        if modifiers & Self.option != 0 { text += "\u{2325}" }
        if modifiers & Self.shift != 0 { text += "\u{21E7}" }
        if modifiers & Self.command != 0 { text += "\u{2318}" }
        if let special = Self.specialKeyLabels[keyCode] { return text + special }
        if let keyLabel, let scalar = keyLabel.unicodeScalars.first, keyLabel.unicodeScalars.count == 1,
           !scalar.properties.isWhitespace, scalar.value >= 0x20 {
            return text + keyLabel.uppercased()
        }
        return text + "Key \(keyCode)"
    }
}
