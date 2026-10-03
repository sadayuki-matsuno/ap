import AppKit
import ApClipboard
import ApCore
import Combine
import GRDB

/// The inline banner at the top of the picker that walks through the Accessibility permission
enum AccessibilityBanner: Equatable {
    /// Ask for the permission. `retry` once Settings was opened before: then the grant may need a relaunch, or a
    /// stale entry from an older (ad-hoc signed) build may have to be removed and added again
    case request(retry: Bool)
    case granted
}

/// State shared by the picker panel and the menu. All database access goes through ClipStore
@MainActor
final class PickerModel: ObservableObject {
    static let pasteOnEnterKey = "pasteOnEnter"
    /// Set once Accessibility Settings was opened from Ap (later banners add the relaunch / re-add hints)
    static let accessibilityRequestedKey = "accessibilityRequested"
    static let listLimit = 500

    let store: ClipStore
    @Published var queryText = "" {
        didSet { if queryText != oldValue { startObservation() } }
    }
    @Published private(set) var groups: [ClipGroup] = []
    @Published var selectedId: Int64? {
        didSet { if selectedId != oldValue { revealed = false } }
    }
    /// `dev.ap.clip-id` currently on the general pasteboard
    @Published private(set) var pasteboardUuid: String?
    /// Concealed content is shown while Control (alone) is held or after "Reveal" is clicked (reset on selection change)
    @Published var revealed = false
    @Published var controlHeld = false
    /// A short confirmation shown in the footer
    @Published private(set) var flash: String?
    @Published var accessibilityTrusted = AXIsProcessTrusted()
    @Published var banner: AccessibilityBanner?
    /// Shown the next time the panel opens (the grant confirmation, the first-launch request)
    var queuedBanner: AccessibilityBanner?
    @Published var pasteOnEnter = UserDefaults.standard.object(forKey: pasteOnEnterKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(pasteOnEnter, forKey: Self.pasteOnEnterKey) }
    }

    /// Made first responder each time the panel opens
    weak var searchField: NSTextField?
    private var observation: AnyDatabaseCancellable?
    private var flashGeneration = 0
    private var pasteboardChangeCount = -1

    init(store: ClipStore) {
        self.store = store
        refreshPasteboard()
        startObservation()
    }

    var clips: [Clip] { groups.flatMap(\.clips) }

    var selectedClip: Clip? { clips.first { $0.id == selectedId } }

    var selectedSession: Session? {
        groups.first { $0.clips.contains { $0.id == selectedId } }?.session
    }

    var onPasteboardId: Int64? { ClipListing.clipId(onPasteboard: pasteboardUuid, in: clips) }

    /// (Re)starts the live query. GRDB only notices writes made through this process's pool, so writes from the
    /// CLI are picked up by the app delegate's file watch, which calls this again
    func startObservation() {
        let query = ClipQuery.parse(queryText)
        let limit = Self.listLimit
        observation = ValueObservation.tracking { db in
            let clips = try ClipStore.clips(db, matching: query, limit: limit)
            return ClipListing.group(clips, sessions: try ClipStore.sessions(db, ids: Set(clips.compactMap(\.sessionId))))
        }
        // .immediate delivers the first value synchronously, so resetForOpen() selects the newest clip of the
        // unfiltered list rather than the top hit of the previous search
        .start(
            in: store.dbPool,
            scheduling: .immediate,
            onError: { error in NSLog("ap: observation failed: \(error)") },
            onChange: { [weak self] groups in
                guard let self else { return }
                self.groups = groups
                if !groups.contains(where: { $0.clips.contains { $0.id == self.selectedId } }) {
                    self.selectedId = groups.first?.clips.first?.id
                }
            })
    }

    /// Polled every second; the pasteboard is only read when its changeCount moved
    func refreshPasteboard() {
        let changeCount = NSPasteboard.general.changeCount
        if changeCount != pasteboardChangeCount {
            pasteboardChangeCount = changeCount
            let uuid = pasteboardClipId()
            if uuid != pasteboardUuid { pasteboardUuid = uuid }
        }
    }

    var accessibilityRequested: Bool { UserDefaults.standard.bool(forKey: Self.accessibilityRequestedKey) }

    /// Selection goes back to the newest clip every time the panel opens
    func resetForOpen() {
        queryText = ""
        selectedId = groups.first?.clips.first?.id
        revealed = false
        flash = nil
        accessibilityTrusted = AXIsProcessTrusted()
        banner = queuedBanner
        queuedBanner = nil
        refreshPasteboard()
    }

    func move(by offset: Int) {
        selectedId = ClipListing.clipId(from: selectedId, offset: offset, in: groups)
    }

    func jumpGroup(forward: Bool) {
        selectedId = ClipListing.groupJump(from: selectedId, forward: forward, in: groups)
    }

    /// Writes the clip to the pasteboard and counts it as pasted (like `ap paste`)
    @discardableResult
    func copy(_ clip: Clip) -> Bool {
        guard writePasteboard(content: clip.content, uuid: clip.uuid, concealed: clip.concealed) else {
            show(String(localized: "Could not write to the clipboard"))
            return false
        }
        if let id = clip.id { try? store.markPasted(id: id, now: Date()) }
        refreshPasteboard()
        return true
    }

    func togglePin() {
        guard let clip = selectedClip, let id = clip.id else { return }
        _ = try? store.setPinned(id: id, pinned: !clip.pinned)
        show(clip.pinned ? String(localized: "Unpinned") : String(localized: "Pinned"))
    }

    func deleteSelected() {
        guard let id = selectedId else { return }
        // Keep the cursor in place: select the next row (or the previous one at the end) before the row disappears
        let next = ClipListing.clipId(from: id, offset: 1, in: groups)
        selectedId = next == id ? ClipListing.clipId(from: id, offset: -1, in: groups) : next
        _ = try? store.delete(id: id)
        show(String(localized: "Deleted"))
    }

    func copyResumeCommand() {
        guard let session = selectedSession else {
            show(String(localized: "This clip has no Claude Code session"))
            return
        }
        let command = ClipListing.resumeCommand(session)
        if writePasteboard(content: command, uuid: nil, concealed: false) {
            refreshPasteboard()
            show(String(localized: "Copied: \(command)"))
        } else {
            show(String(localized: "Could not write to the clipboard"))
        }
    }

    func show(_ message: String) {
        flash = message
        flashGeneration += 1
        let generation = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                if self?.flashGeneration == generation { self?.flash = nil }
            }
        }
    }
}
