import Foundation
import Testing
@testable import ApCore

@Suite struct ShortcutTests {
    let commandP = Shortcut(keyCode: 35, modifiers: Shortcut.command)

    @Test func defaultIsControlCommandP() {
        #expect(Shortcut.default == Shortcut(keyCode: 35, modifiers: Shortcut.control | Shortcut.command))
    }

    @Test func recorderInterpretsKeys() {
        // Escape and Delete without modifiers cancel / reset; with modifiers they are ordinary combos
        #expect(Shortcut.interpret(keyCode: 53, modifiers: 0) == .cancel)
        #expect(Shortcut.interpret(keyCode: 51, modifiers: 0) == .reset)
        #expect(Shortcut.interpret(keyCode: 51, modifiers: Shortcut.control | Shortcut.command)
            == .record(Shortcut(keyCode: 51, modifiers: Shortcut.control | Shortcut.command)))
        #expect(Shortcut.interpret(keyCode: 35, modifiers: Shortcut.control | Shortcut.command) == .record(.default))
        #expect(Shortcut.interpret(keyCode: 9, modifiers: Shortcut.option | Shortcut.shift)
            == .record(Shortcut(keyCode: 9, modifiers: Shortcut.option | Shortcut.shift)))
    }

    @Test func plainKeysAndShiftOnlyAreRejected() {
        #expect(Shortcut.interpret(keyCode: 35, modifiers: 0) == .rejected(.noModifier))
        #expect(Shortcut.interpret(keyCode: 35, modifiers: Shortcut.shift) == .rejected(.noModifier))
        #expect(!Shortcut(keyCode: 35, modifiers: Shortcut.shift).isValid)
        #expect(Shortcut(keyCode: 35, modifiers: Shortcut.control).isValid)
    }

    @Test func commandOnlyCombosAreRejected() {
        // A Carbon hotkey takes the key before any app sees it: Command-P / O / , / Return / Delete would break the
        // picker's own keys, Command-V the synthetic paste, and Command-C / X / A every app's
        for keyCode in [35, 31, 43, 36, 51, 8, 7, 0] {
            #expect(Shortcut.interpret(keyCode: keyCode, modifiers: Shortcut.command) == .rejected(.commandOnly))
            #expect(Shortcut.interpret(keyCode: keyCode, modifiers: Shortcut.command | Shortcut.shift)
                == .rejected(.commandOnly))
        }
        #expect(Shortcut(keyCode: 9, modifiers: Shortcut.command).rejection == .commandOnly)
        #expect(!commandP.isValid)
        // Adding Control or Option makes them fine
        #expect(Shortcut(keyCode: 9, modifiers: Shortcut.option | Shortcut.command).isValid)
        #expect(Shortcut(keyCode: 35, modifiers: Shortcut.control).rejection == nil)
    }

    @Test func commandSpaceAndFunctionKeysAreAllowedWithCommandOnly() {
        #expect(Shortcut(keyCode: 49, modifiers: Shortcut.command).isValid)
        #expect(Shortcut(keyCode: 49, modifiers: Shortcut.command | Shortcut.shift).isValid)
        for keyCode in [122, 120, 99, 96, 111, 105, 90] {
            #expect(Shortcut.interpret(keyCode: keyCode, modifiers: Shortcut.command)
                == .record(Shortcut(keyCode: keyCode, modifiers: Shortcut.command)))
        }
    }

    @Test func roundTripsThroughUserDefaults() throws {
        let suite = "ap-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let optionCommandP = Shortcut(keyCode: 35, modifiers: Shortcut.option | Shortcut.command)
        defaults.set(optionCommandP.userDefaultsValue, forKey: "hotkey")
        #expect(Shortcut(userDefaultsValue: defaults.object(forKey: "hotkey")) == optionCommandP)
        #expect(Shortcut(userDefaultsValue: nil) == nil)
        #expect(Shortcut(userDefaultsValue: ["keyCode": 35]) == nil)
        // A stored value that is no longer valid (no modifier) is ignored
        #expect(Shortcut(userDefaultsValue: ["keyCode": 35, "modifiers": 0]) == nil)
        // Saved by an older version before Command-only combos were rejected
        #expect(Shortcut(userDefaultsValue: commandP.userDefaultsValue) == nil)
    }

    @Test func outOfRangeStoredValuesAreIgnored() {
        let controlCommand = Shortcut.control | Shortcut.command
        #expect(Shortcut(userDefaultsValue: ["keyCode": -1, "modifiers": controlCommand]) == nil)
        #expect(Shortcut(userDefaultsValue: ["keyCode": 128, "modifiers": controlCommand]) == nil)
        #expect(Shortcut(userDefaultsValue: ["keyCode": 0x1_0000, "modifiers": controlCommand]) == nil)
        #expect(Shortcut(userDefaultsValue: ["keyCode": 35, "modifiers": -1]) == nil)
        #expect(Shortcut(userDefaultsValue: ["keyCode": 35, "modifiers": 0x1_0000 | controlCommand]) == nil)
        // A bit outside Command / Shift / Option / Control (alphaLock)
        #expect(Shortcut(userDefaultsValue: ["keyCode": 35, "modifiers": (1 << 10) | controlCommand]) == nil)
        #expect(Shortcut(userDefaultsValue: ["keyCode": 127, "modifiers": controlCommand])
            == Shortcut(keyCode: 127, modifiers: controlCommand))
    }

    @Test func symbolsUseTheLayoutLabelInMacOSOrder() {
        let all = Shortcut(keyCode: 35, modifiers: Shortcut.command | Shortcut.shift | Shortcut.option | Shortcut.control)
        #expect(all.symbols(keyLabel: "p") == "\u{2303}\u{2325}\u{21E7}\u{2318}P")
        #expect(Shortcut.default.symbols(keyLabel: "p") == "\u{2303}\u{2318}P")
        // Dvorak: the key at the ANSI P position types "l"
        #expect(Shortcut.default.symbols(keyLabel: "l") == "\u{2303}\u{2318}L")
    }

    @Test func specialKeysHaveFixedLabels() {
        #expect(Shortcut(keyCode: 49, modifiers: Shortcut.option).symbols(keyLabel: " ") == "\u{2325}Space")
        #expect(Shortcut(keyCode: 96, modifiers: Shortcut.command).symbols(keyLabel: "\u{10}") == "\u{2318}F5")
        #expect(Shortcut(keyCode: 126, modifiers: Shortcut.control).symbols(keyLabel: nil) == "\u{2303}\u{2191}")
        #expect(Shortcut(keyCode: 200, modifiers: Shortcut.control).symbols(keyLabel: nil) == "\u{2303}Key 200")
    }
}
