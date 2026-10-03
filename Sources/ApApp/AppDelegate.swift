import AppKit
import ApCore
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Can become key without activating the app, so the frontmost app stays frontmost while the search field takes typing
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let store: ClipStore
    let model: PickerModel
    let projectsDirectory = Enricher.defaultProjectsDirectory()
    /// Enrichment and prune run here, off the main thread
    let workQueue = DispatchQueue(label: "dev.ap.work", qos: .utility)
    var statusItem: NSStatusItem?
    var panel: PickerPanel?
    var hotKey: HotKey?
    var eventMonitor: Any?
    var timers: [Timer] = []
    /// The app that was frontmost when the picker opened; Enter pastes into it
    var previousApp: NSRunningApplication?
    var isEnriching = false
    /// (size, mtime) of ap.db and ap.db-wal, to notice writes from other processes (the CLI)
    var databaseSignature: [Double] = []
    /// Accessibility Settings was opened from Ap and the grant hasn't been seen yet: AXIsProcessTrusted is polled
    var awaitingGrant = false
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let firstLaunchBannerKey = "accessibilityBannerShown"
    /// Decides when holding Control reveals a concealed clip (reset on every open)
    var revealGate = RevealGate(controlDown: false)

    init(store: ClipStore) {
        self.store = store
        model = PickerModel(store: store)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Ap")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        registerHotKey()

        // Local monitors run on the main thread (older SDKs don't annotate the closure as main-actor)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }

        databaseSignature = currentDatabaseSignature()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            },
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.enrichIfPending() }
            },
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.prune() }
            },
        ]
        prune()
        enrichIfPending()

        // Debug / demo hooks (the hotkey and the status item can't be clicked from a script)
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        if !AXIsProcessTrusted(), model.pasteOnEnter, !defaults.bool(forKey: Self.firstLaunchBannerKey) {
            // First launch: open the picker once with the Accessibility request on top
            defaults.set(true, forKey: Self.firstLaunchBannerKey)
            model.queuedBanner = .request(retry: model.accessibilityRequested)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.showPicker() }
            }
        } else if environment["AP_OPEN_PICKER_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.showPicker() }
            }
        } else if environment["AP_OPEN_MENU_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.statusItem?.button?.performClick(nil) }
            }
        }
    }

    func registerHotKey() {
        hotKey = HotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey | controlKey) { [weak self] in self?.togglePicker() }
        if hotKey == nil { NSLog("ap: could not register the Control-Command-P hotkey (in use by another app?)") }
    }

    // MARK: - Background work

    func tick() {
        let signature = currentDatabaseSignature()
        if signature != databaseSignature {
            databaseSignature = signature
            model.startObservation()
        }
        model.refreshPasteboard()
        if awaitingGrant, AXIsProcessTrusted() {
            awaitingGrant = false
            model.accessibilityTrusted = true
            model.pasteOnEnter = true
            if panel?.isVisible == true { model.banner = .granted } else { model.queuedBanner = .granted }
        }
    }

    func currentDatabaseSignature() -> [Double] {
        [store.path, store.path + "-wal"].flatMap { path -> [Double] in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return [
                (attributes?[.size] as? NSNumber)?.doubleValue ?? -1,
                (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1,
            ]
        }
    }

    /// Runs the enricher while pending clips exist. Writes go through the store, so the observation updates the list
    func enrichIfPending() {
        guard !isEnriching else { return }
        isEnriching = true
        let store = store
        let projectsDirectory = projectsDirectory
        workQueue.async {
            do {
                if try !store.pendingClips().isEmpty {
                    try Enricher.enrichPending(store: store, projectsDirectory: projectsDirectory, now: Date())
                }
            } catch {
                NSLog("ap: enrich failed: \(error)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.isEnriching = false } }
        }
    }

    func prune() {
        let store = store
        workQueue.async {
            do { try store.prune(olderThan: ClipStore.retention, now: Date()) } catch { NSLog("ap: prune failed: \(error)") }
        }
    }

    // MARK: - Picker panel

    func togglePicker() {
        if panel?.isVisible == true { hidePicker() } else { showPicker() }
    }

    func showPicker() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let panel = panel ?? makePanel()
        self.panel = panel
        // Settings was opened but the grant never showed up: the switch may need a relaunch to apply, or an entry from
        // an older build may be stale
        if awaitingGrant, !AXIsProcessTrusted(), model.queuedBanner == nil { model.queuedBanner = .request(retry: true) }
        model.resetForOpen()
        // Control may still be down from the Control-Command-P hotkey; that hold must not reveal anything
        revealGate = RevealGate(controlDown: NSEvent.modifierFlags.contains(.control))

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2 + visible.height * 0.08))
        }
        panel.makeKeyAndOrderFront(nil)
        if let field = model.searchField { panel.makeFirstResponder(field) }
        enrichIfPending()
    }

    func hidePicker() {
        model.controlHeld = false
        panel?.orderOut(nil)
    }

    func makePanel() -> PickerPanel {
        let panel = PickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PickerView(
            model: model,
            onActivate: { [weak self] id in
                self?.model.selectedId = id
                self?.activateSelection(copyOnly: false)
            },
            onBanner: { [weak self] action in
                switch action {
                case .openSettings: self?.requestAccessibility()
                case .relaunch: self?.relaunch()
                case .dismiss:
                    self?.model.banner = nil
                    self?.hidePicker()
                }
            }))
        panel.setContentSize(NSSize(width: 820, height: 520))
        // Creates the SwiftUI views now, so the search field exists when the panel is first shown
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel
    }

    /// Clicking elsewhere closes the picker, like Spotlight
    func windowDidResignKey(_ notification: Notification) {
        hidePicker()
    }

    /// true when the event was handled (and must not reach the search field)
    func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            // Reveal after Control has been held alone for a moment, so pressing Control-Command-P (Control first) to
            // close the panel doesn't flash the secret
            let flags = event.modifierFlags
            let pressed = revealGate.modifiersChanged(
                control: flags.contains(.control), others: !flags.intersection([.command, .option, .shift]).isEmpty)
            if !revealGate.isArmed { model.controlHeld = false }
            if pressed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    MainActor.assumeIsolated {
                        if self?.revealGate.isArmed == true { self?.model.controlHeld = true }
                    }
                }
            }
            return false
        }
        // Typing during the hold (Control-A / Control-E in the search field) cancels the reveal
        revealGate.keyPressed()
        model.controlHeld = false
        // Let an input method finish its composition (Enter commits the marked text, arrows move the candidate)
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape: hidePicker()
        case kVK_DownArrow: model.move(by: 1)
        case kVK_UpArrow: model.move(by: -1)
        case kVK_Tab: model.jumpGroup(forward: !flags.contains(.shift))
        case kVK_Return, kVK_ANSI_KeypadEnter: activateSelection(copyOnly: command)
        // Control-Command-P is the global hotkey (normally consumed by Carbon first); here it closes, like the toggle
        case kVK_ANSI_P where command && flags.contains(.control): hidePicker()
        case kVK_ANSI_P where command: model.togglePin()
        // With text in the search field, Command-Delete keeps its text meaning (delete to the line start)
        case kVK_Delete where command && model.queryText.isEmpty: model.deleteSelected()
        case kVK_ANSI_O where command: model.copyResumeCommand()
        // There is no main menu (no Edit menu key equivalents), so route the text editing shortcuts by hand
        case kVK_ANSI_X where command: panel?.firstResponder?.tryToPerform(#selector(NSText.cut(_:)), with: nil)
        case kVK_ANSI_C where command: panel?.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        case kVK_ANSI_V where command: panel?.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: nil)
        case kVK_ANSI_A where command: panel?.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
        default: return false
        }
        return true
    }

    /// Enter: copy, close, re-activate the previous app and synthesize Cmd+V. Copy only when asked or when the
    /// setting says so. Without the Accessibility permission the clip is copied and the panel stays open with the
    /// banner that asks for it
    func activateSelection(copyOnly: Bool) {
        guard let clip = model.selectedClip, model.copy(clip) else { return }
        let paste = !copyOnly && model.pasteOnEnter
        if paste, !AXIsProcessTrusted() {
            model.accessibilityTrusted = false
            model.banner = .request(retry: model.accessibilityRequested)
            model.show(String(localized: "Copied to the clipboard"))
            return
        }
        hidePicker()
        guard paste else { return }
        previousApp?.activate()
        let keyCode = keyCodeForV()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// The key code that types "v" in the current keyboard layout (Dvorak and AZERTY move it), else the ANSI position
    func keyCodeForV() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return CGKeyCode(kVK_ANSI_V) }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return CGKeyCode(kVK_ANSI_V) }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
                if status == noErr, length == 1, characters[0] == UniChar(0x76) { return CGKeyCode(keyCode) }
            }
            return CGKeyCode(kVK_ANSI_V)
        }
    }

    // MARK: - Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        model.refreshPasteboard()
        let clips = (try? store.clips(sessionId: nil, limit: 10)) ?? []
        let sessions = (try? store.sessions(ids: Set(clips.compactMap(\.sessionId)))) ?? [:]
        let onPasteboard = ClipListing.clipId(onPasteboard: model.pasteboardUuid, in: clips)
        if clips.isEmpty {
            menu.addItem(disabledItem(String(localized: "No clips yet")))
        } else {
            menu.addItem(disabledItem(String(localized: "Recent clips")))
        }
        for clip in clips {
            let item = NSMenuItem(title: "", action: #selector(copyFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(clip.id ?? 0)
            item.state = clip.id == onPasteboard ? .on : .off
            let title = NSMutableAttributedString(
                string: clip.concealed
                    ? String(localized: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022} (concealed, \(clip.content.count) chars)")
                    : ClipListing.preview(clip, maxLength: 60),
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
            let session = clip.sessionId.flatMap { sessions[$0] }
            let detail = [
                sessionDisplayName(session, sessionId: clip.sessionId, agent: clip.agent), clip.label,
                formatTime(clip.createdAt),
            ]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
            title.append(NSAttributedString(
                string: "\n" + detail,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let open = NSMenuItem(title: String(localized: "Open Picker"), action: #selector(openPickerFromMenu), keyEquivalent: "p")
        open.keyEquivalentModifierMask = [.command, .control]
        open.target = self
        menu.addItem(open)
        let trusted = AXIsProcessTrusted()
        model.accessibilityTrusted = trusted
        let pasteToggle = NSMenuItem(
            title: trusted
                ? String(localized: "Enter pastes into the frontmost app")
                : String(localized: "Enter pastes into the frontmost app (needs Accessibility)"),
            action: #selector(togglePasteOnEnter), keyEquivalent: "")
        pasteToggle.target = self
        pasteToggle.state = model.pasteOnEnter ? .on : .off
        menu.addItem(pasteToggle)
        if !trusted {
            let grant = NSMenuItem(
                title: String(localized: "Allow Direct Paste\u{2026}"), action: #selector(requestAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        let login = NSMenuItem(
            title: String(localized: "Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // System / English / Japanese. Stored as AppleLanguages in Ap's own defaults, applied on the next launch
        let languageMenu = NSMenu()
        let override = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[
            "AppleLanguages"] as? [String])?.first
        for (code, title) in [
            (nil, String(localized: "System")), ("en", "English"), ("ja", "\u{65E5}\u{672C}\u{8A9E}"),
        ] as [(String?, String)] {
            let item = NSMenuItem(title: title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = override == code ? .on : .off
            languageMenu.addItem(item)
        }
        let language = NSMenuItem(title: String(localized: "Language"), action: nil, keyEquivalent: "")
        language.submenu = languageMenu
        menu.addItem(language)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Ap"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func copyFromMenu(_ sender: NSMenuItem) {
        if let clip = try? store.clip(id: Int64(sender.tag)) { model.copy(clip) }
    }

    @objc func openPickerFromMenu() {
        // Let the menu finish closing first so the panel can become key
        DispatchQueue.main.async { MainActor.assumeIsolated { self.showPicker() } }
    }

    @objc func togglePasteOnEnter() {
        model.pasteOnEnter.toggle()
    }

    /// Registers Ap in the Accessibility list with the system prompt, opens the pane directly and starts watching
    /// for the grant. The panel closes so it doesn't float over System Settings
    @objc func requestAccessibility() {
        model.banner = nil
        hidePicker()
        // kAXTrustedCheckOptionPrompt is a mutable global, which Swift 6 rejects; its value is this string
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
        UserDefaults.standard.set(true, forKey: PickerModel.accessibilityRequestedKey)
        awaitingGrant = true
    }

    /// For a grant that only applies to a new process: start a new instance (same environment, so AP_DB_PATH
    /// carries over) and quit. The hotkey is released first so the new instance can register it
    func relaunch() {
        hotKey?.unregister()
        hotKey = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ProcessInfo.processInfo.environment
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        NSLog("ap: relaunch failed: \(error)")
                        self.registerHotKey()
                        self.model.show(String(localized: "Could not relaunch Ap: \(error.localizedDescription)"))
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    @objc func chooseLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        // Bundle strings are resolved at launch, so the change applies to a new process
        let alert = NSAlert()
        alert.messageText = String(localized: "Relaunch Ap to change the language?")
        alert.addButton(withTitle: String(localized: "Relaunch Ap"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Could not change Launch at Login")
            alert.informativeText = String(localized: "\(error.localizedDescription)\nMove Ap.app to /Applications and try again.")
            NSApp.activate()
            alert.runModal()
        }
    }
}
