import ApCore
import SwiftUI

/// State of the Settings window that isn't already in PickerModel
@MainActor
final class SettingsModel: ObservableObject {
    /// The current hotkey as symbols in the current keyboard layout (⌃⌘P)
    @Published var shortcutText = ""
    /// The default hotkey in the current layout, for the Reset button (⌃⌘L on Dvorak)
    @Published var resetText = ""
    /// The hotkey couldn't be registered at the last attempt (shown until a shortcut registers)
    @Published var warning: String?
    @Published var isRecording = false
    /// Why the last recorded shortcut was not taken
    @Published var message: String?
    @Published var launchAtLogin = false
    /// AppleLanguages override: nil follows the system
    @Published var language: String?
}

struct SettingsActions {
    let beginRecording: () -> Void
    let cancelRecording: () -> Void
    let resetShortcut: () -> Void
    let setLaunchAtLogin: (Bool) -> Void
    let setLanguage: (String?) -> Void
    let allowAccessibility: () -> Void
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var model: PickerModel
    let actions: SettingsActions

    var body: some View {
        Form {
            Section {
                LabeledContent("Hotkey") {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 8) {
                            Button {
                                settings.isRecording ? actions.cancelRecording() : actions.beginRecording()
                            } label: {
                                Text(settings.isRecording ? String(localized: "Type shortcut\u{2026}") : settings.shortcutText)
                                    .frame(minWidth: 110)
                            }
                            Button(String(localized: "Reset to \(settings.resetText)")) {
                                actions.resetShortcut()
                            }
                        }
                        if let message = settings.message {
                            Text(message).font(.caption).foregroundStyle(.red)
                        } else if settings.isRecording {
                            Text("Esc cancels, Delete resets to the default").font(.caption).foregroundStyle(.secondary)
                        } else if let warning = settings.warning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Toggle("Enter pastes into the frontmost app", isOn: $model.pasteOnEnter)
                LabeledContent("Accessibility") {
                    if model.accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(String(localized: "Allow\u{2026}")) { actions.allowAccessibility() }
                    }
                }
            } header: {
                Text("Picker")
            }
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { settings.launchAtLogin }, set: { actions.setLaunchAtLogin($0) }))
                Picker("Language", selection: Binding(get: { settings.language }, set: { actions.setLanguage($0) })) {
                    Text("System").tag(String?.none)
                    Text(verbatim: "English").tag(String?.some("en"))
                    Text(verbatim: "\u{65E5}\u{672C}\u{8A9E}").tag(String?.some("ja"))
                }
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
