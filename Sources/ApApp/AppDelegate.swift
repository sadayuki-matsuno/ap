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
    static let hotKeyDefaultsKey = "hotKey"
    /// The global hotkey (Settings can change it; stored as keyCode + Carbon modifiers)
    var shortcut = Shortcut(userDefaultsValue: UserDefaults.standard.object(forKey: hotKeyDefaultsKey)) ?? .default
    let settings = SettingsModel()
    var settingsWindow: NSWindow?
    /// false when RegisterEventHotKey refused both the saved hotkey and the default: no global hotkey works
    var hotKeyRegistered = false
    /// The hotkey that failed to register at the last attempt (the default may be active in its place)
    var failedShortcut: Shortcut?
    /// The app that was frontmost when Settings opened; it gets the focus back when Settings closes
    var appBeforeSettings: NSRunningApplication?
    /// The last app other than Ap that became active: the paste target when Ap itself is frontmost at open time
    var lastOtherApp: NSRunningApplication?

    init(store: ClipStore) {
        self.store = store
        model = PickerModel(store: store)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The Ap mark (mark.png / mark@2x.png in Contents/Resources) as a template image, so it follows the menu bar's
        // light / dark appearance. Falls back to an SF Symbol when run outside the bundle (swift run)
        if let mark = Bundle.main.image(forResource: "mark") {
            mark.isTemplate = true
            mark.size = NSSize(width: 18, height: 18)
            mark.accessibilityDescription = "Ap"
            item.button?.image = mark
        } else {
            item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Ap")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        registerHotKey()

        lastOtherApp = NSWorkspace.shared.frontmostApplication.flatMap(Self.isOtherApp)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let other = app.flatMap(Self.isOtherApp) { self?.lastOtherApp = other }
            }
        }

        // Local monitors run on the main thread (older SDKs don't annotate the closure as main-actor)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                // The shortcut recorder takes the next key press, whichever window has focus
                if self.settings.isRecording, event.type == .keyDown {
                    self.record(event)
                    return true
                }
                guard event.window === self.panel else { return false }
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
        } else if environment["AP_OPEN_SETTINGS_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.openSettings() }
            }
        } else if environment["AP_OPEN_MENU_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.statusItem?.button?.performClick(nil) }
            }
        }
    }

    /// Registers the current hotkey. When macOS refuses it (another app owns it), falls back to the default if that
    /// is free (in memory only, so the saved choice is tried again at the next launch). The outcome is shown in the
    /// menu and in Settings
    func registerHotKey() {
        let hotKey = hotKey ?? HotKey { [weak self] in self?.togglePicker() }
        self.hotKey = hotKey
        failedShortcut = nil
        hotKeyRegistered = hotKey.register(shortcut)
        if !hotKeyRegistered {
            NSLog("ap: could not register the hotkey \(shortcutSymbols(shortcut)) (in use by another app?)")
            failedShortcut = shortcut
            if shortcut != .default, hotKey.register(.default) {
                shortcut = .default
                hotKeyRegistered = true
            }
        }
        refreshHotKeyStatus()
    }

    func refreshHotKeyStatus() {
        settings.shortcutText = shortcutSymbols(shortcut)
        settings.resetText = shortcutSymbols(.default)
        if !hotKeyRegistered {
            settings.warning = String(localized:
                "\(shortcutSymbols(shortcut)) couldn\u{2019}t be registered \u{2014} another app may be using it. Record a different shortcut.")
        } else if let failedShortcut {
            settings.warning = String(localized:
                "\(shortcutSymbols(failedShortcut)) couldn\u{2019}t be registered \u{2014} another app may be using it. Using \(shortcutSymbols(shortcut)) instead.")
        } else {
            settings.warning = nil
        }
    }

    /// nil for Ap itself
    nonisolated static func isOtherApp(_ app: NSRunningApplication) -> NSRunningApplication? {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }

    func shortcutSymbols(_ shortcut: Shortcut) -> String {
        shortcut.symbols(keyLabel: KeyboardLayout.character(for: shortcut.keyCode))
    }

    // MARK: - Settings

    @objc func openSettings() {
        // The picker is non-activating, so the app the user was in is still frontmost here
        if settingsWindow?.isVisible != true {
            appBeforeSettings = NSWorkspace.shared.frontmostApplication.flatMap(Self.isOtherApp) ?? lastOtherApp
        }
        hidePicker()
        refreshSettings()
        let window = settingsWindow ?? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = String(localized: "Ap Settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            let hosting = NSHostingView(rootView: SettingsView(
                settings: settings, model: model,
                actions: SettingsActions(
                    beginRecording: { [weak self] in self?.beginRecording() },
                    cancelRecording: { [weak self] in self?.endRecording() },
                    resetShortcut: { [weak self] in self?.applyShortcut(.default) },
                    setLaunchAtLogin: { [weak self] in self?.setLaunchAtLogin($0) },
                    setLanguage: { [weak self] in self?.setLanguage($0) },
                    allowAccessibility: { [weak self] in self?.requestAccessibility() })))
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.center()
            return window
        }()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func refreshSettings() {
        refreshHotKeyStatus()
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        settings.language = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[
            "AppleLanguages"] as? [String])?.first
        model.accessibilityTrusted = AXIsProcessTrusted()
    }

    /// The global hotkey is released while recording, so the current combination can be recorded again
    func beginRecording() {
        settings.message = nil
        settings.isRecording = true
        hotKey?.unregister()
    }

    func endRecording() {
        settings.isRecording = false
        registerHotKey()
    }

    func record(_ event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.command) { modifiers |= Shortcut.command }
        if flags.contains(.shift) { modifiers |= Shortcut.shift }
        if flags.contains(.option) { modifiers |= Shortcut.option }
        if flags.contains(.control) { modifiers |= Shortcut.control }
        switch Shortcut.interpret(keyCode: Int(event.keyCode), modifiers: modifiers) {
        case .cancel: endRecording()
        case .reset: applyShortcut(.default)
        case .rejected(.noModifier): settings.message = String(localized: "Use at least one of \u{2318}, \u{2303} or \u{2325}")
        case .rejected(.commandOnly):
            settings.message = String(localized: "Add \u{2303} or \u{2325} \u{2014} \u{2318}-only shortcuts clash with app shortcuts")
        case .record(let shortcut): applyShortcut(shortcut)
        }
    }

    /// Registers the new hotkey and saves it; when macOS refuses it, the old one stays
    func applyShortcut(_ newShortcut: Shortcut) {
        settings.isRecording = false
        if hotKey?.register(newShortcut) == true {
            shortcut = newShortcut
            hotKeyRegistered = true
            failedShortcut = nil
            UserDefaults.standard.set(newShortcut.userDefaultsValue, forKey: Self.hotKeyDefaultsKey)
            settings.message = nil
            refreshHotKeyStatus()
        } else {
            registerHotKey()
            settings.message = String(localized: "This shortcut is used by another app or macOS")
        }
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
        // When Ap itself is frontmost (Settings or an alert just had the focus), paste into the last other app instead
        // of sending Command-V to Ap
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap(Self.isOtherApp) ?? lastOtherApp
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

    /// Closing Settings hands the focus back to the app that had it, so the accessory app doesn't stay active
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        if settings.isRecording { endRecording() }
        if NSApp.isActive { (appBeforeSettings ?? lastOtherApp)?.activate() }
        appBeforeSettings = nil
    }

    /// Clicking elsewhere closes the picker, like Spotlight. Leaving Settings stops a recording in progress
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel {
            hidePicker()
        } else if settings.isRecording {
            endRecording()
        }
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
        case kVK_ANSI_Comma where command: openSettings()
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
        let keyCode = CGKeyCode(KeyboardLayout.keyCode(for: "v") ?? kVK_ANSI_V)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
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
                formatTime(clip.createdAt), ClipListing.usageBadge(pasteCount: clip.pasteCount),
            ]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
            title.append(NSAttributedString(
                string: "\n" + detail,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Shows the current hotkey. A key without a plain character (F5, arrows, Space) gets it in the title instead
        let keyCharacter = KeyboardLayout.character(for: shortcut.keyCode)
        let symbols = shortcutSymbols(shortcut)
        let plainKey = keyCharacter.map { $0.count == 1 && symbols.hasSuffix($0.uppercased()) } ?? false
        let open: NSMenuItem
        if hotKeyRegistered {
            open = NSMenuItem(
                title: plainKey ? String(localized: "Open Picker") : String(localized: "Open Picker") + "  " + symbols,
                action: #selector(openPickerFromMenu), keyEquivalent: plainKey ? (keyCharacter ?? "") : "")
        } else {
            // No key equivalent: showing one would claim a hotkey that doesn't work
            open = NSMenuItem(
                title: String(localized: "Open Picker (shortcut unavailable)"), action: #selector(openPickerFromMenu),
                keyEquivalent: "")
        }
        var modifierMask: NSEvent.ModifierFlags = []
        if shortcut.modifiers & Shortcut.command != 0 { modifierMask.insert(.command) }
        if shortcut.modifiers & Shortcut.shift != 0 { modifierMask.insert(.shift) }
        if shortcut.modifiers & Shortcut.option != 0 { modifierMask.insert(.option) }
        if shortcut.modifiers & Shortcut.control != 0 { modifierMask.insert(.control) }
        open.keyEquivalentModifierMask = modifierMask
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
        let settingsItem = NSMenuItem(
            title: String(localized: "Settings\u{2026}"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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
        setLanguage(sender.representedObject as? String)
    }

    /// nil follows the system
    func setLanguage(_ code: String?) {
        settings.language = code
        if let code {
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
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        defer { settings.launchAtLogin = SMAppService.mainApp.status == .enabled }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
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
