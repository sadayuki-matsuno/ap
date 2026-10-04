import AppKit
import ApCore
import SwiftUI

enum BannerAction {
    case openSettings, relaunch, dismiss
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    /// Paste (or copy) a clip, as Enter does
    let onActivate: (Int64) -> Void
    let onBanner: (BannerAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                SearchField(model: model)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if let banner = model.banner {
                AccessibilityBannerView(banner: banner, onAction: onBanner) { model.banner = nil }
                Divider()
            }
            HStack(spacing: 0) {
                ClipList(model: model, onActivate: onActivate)
                    .frame(width: 360)
                Divider()
                ClipDetail(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Footer(model: model)
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 400, idealHeight: 520)
        .background(.regularMaterial)
        // The panel keeps a (hidden) title bar for its rounded corners; don't leave room for it
        .ignoresSafeArea()
    }
}

/// An NSTextField so the panel can make it first responder on every open (FocusState is unreliable in a reused panel)
struct SearchField: NSViewRepresentable {
    @ObservedObject var model: PickerModel

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = String(localized: "Search   repo:  session:  kind:code  pinned")
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        model.searchField = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != model.queryText { field.stringValue = model.queryText }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: PickerModel

        init(model: PickerModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            model.queryText = (notification.object as? NSTextField)?.stringValue ?? ""
        }
    }
}

struct ClipList: View {
    @ObservedObject var model: PickerModel
    let onActivate: (Int64) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups, id: \.sessionId) { group in
                        GroupHeader(group: group)
                        ForEach(group.clips, id: \.id) { clip in
                            ClipRow(
                                clip: clip, selected: clip.id == model.selectedId,
                                onPasteboard: clip.id == model.onPasteboardId
                            )
                            .id(clip.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { if let id = clip.id { onActivate(id) } }
                            .onTapGesture { model.selectedId = clip.id }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: model.selectedId) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .overlay {
                if model.groups.isEmpty {
                    Text(model.queryText.isEmpty
                        ? String(localized: "No clips yet.\nPipe text into ap to record it.")
                        : String(localized: "No matches"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct GroupHeader: View {
    let group: ClipGroup

    var body: some View {
        let latest = group.clips[0]
        let title = sessionDisplayName(group.session, sessionId: group.sessionId, agent: latest.agent)
        let detail = ([group.session.flatMap(ClipListing.sessionLocation)] + [formatTime(latest.createdAt)])
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 4)
            Text(detail).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct ClipRow: View {
    let clip: Clip
    let selected: Bool
    let onPasteboard: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(clip.concealed
                    ? String(localized: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022} (concealed, \(clip.content.count) chars)")
                    : ClipListing.preview(clip, maxLength: 120))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if clip.pinned { Image(systemName: "pin.fill").font(.caption2) }
                if let badge = ClipListing.usageBadge(pasteCount: clip.pasteCount) {
                    Text(badge)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                }
            }
            HStack(spacing: 6) {
                if let label = clip.label { Text(label).fontWeight(.medium) }
                Text(clip.contentKind ?? "text")
                if clip.subagent != nil { Label("subagent", systemImage: "arrow.turn.down.right") }
                Text(formatTime(clip.createdAt))
                if onPasteboard {
                    Label("on clipboard", systemImage: "doc.on.clipboard")
                        .foregroundStyle(selected ? Color.white : Color.accentColor)
                }
            }
            .font(.caption2)
            .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            .lineLimit(1)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .opacity(clip.pasteCount > 0 && !selected ? 0.8 : 1)
        .padding(.vertical, 5)
        .padding(.leading, 22)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }
}

struct ClipDetail: View {
    @ObservedObject var model: PickerModel
    /// SwiftUI Text gets slow on very large strings, so the preview shows the start of huge clips
    static let previewLimit = 20_000

    var body: some View {
        if let clip = model.selectedClip {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content(clip)
                    if let prompt = clip.promptSnapshot {
                        TitledSection(title: "Prompt") {
                            Text(prompt)
                                .font(.callout)
                                .italic()
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Color.accentColor).frame(width: 3)
                                }
                        }
                    }
                    if let context = clip.contextSnapshot {
                        ContextSnapshot(text: context).id(clip.id)
                    }
                    metadata(clip)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    func content(_ clip: Clip) -> some View {
        if clip.concealed && !(model.revealed || model.controlHeld) {
            HStack(spacing: 10) {
                Text(String(localized: "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022} (concealed, \(clip.content.count) chars)"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Reveal") { model.revealed = true }
                Text("or hold \u{2303}").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        } else {
            let truncated = clip.content.count > Self.previewLimit
            VStack(alignment: .leading, spacing: 4) {
                Text(truncated ? String(clip.content.prefix(Self.previewLimit)) : clip.content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if truncated {
                    Text(String(localized: "\u{2026} \(clip.content.count - Self.previewLimit) more characters (the whole clip is pasted)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    func metadata(_ clip: Clip) -> some View {
        let session = model.selectedSession
        let sessionText = sessionDisplayName(session, sessionId: clip.sessionId, agent: clip.agent)
            + (clip.sessionId == nil ? "" : " (\(clip.agent))")
        let location = [
            clip.repository ?? session?.repository, ClipListing.branch(clip.gitBranch ?? session?.gitBranch),
            clip.terminal ?? session?.terminal,
        ].compactMap { $0 }.joined(separator: " | ")
        let pasted = clip.pasteCount == 1 ? String(localized: "pasted once") : String(localized: "pasted \(clip.pasteCount) times")
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            row("Session", sessionText)
            if let subagent = clip.subagent { row("Subagent", subagent) }
            if !location.isEmpty { row("Location", location) }
            row("Copied", formatFullTime(clip.createdAt) + " \u{00B7} " + pasted)
            if clip.enrichState != EnrichState.done.rawValue {
                row("Enrich", String(localized: String.LocalizationValue(clip.enrichState)))
            }
        }
        .font(.caption)
    }

    func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
    }
}

struct TitledSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

/// Collapsed when long (subagent task + preceding assistant text can be a few paragraphs)
struct ContextSnapshot: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        let isLong = text.count > 300 || text.split(separator: "\n").count > 6
        TitledSection(title: "Context") {
            Text(isLong && !expanded ? String(text.prefix(300)) + "\u{2026}" : text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(isLong && !expanded ? 6 : nil)
            if isLong {
                Button(expanded ? String(localized: "Show less") : String(localized: "Show more")) { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

/// Inline onboarding for the Accessibility permission (shown on Enter without it, and once on first launch)
struct AccessibilityBannerView: View {
    let banner: AccessibilityBanner
    let onAction: (BannerAction) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: banner == .granted ? "checkmark.circle.fill" : "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(banner == .granted ? Color.green : Color.accentColor)
            switch banner {
            case .granted:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Direct paste is on").font(.headline)
                    Text("Enter now pastes the clip into the app you were using.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("OK", action: onClose)
            case .request(let retry):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Ap to paste into other apps").font(.headline)
                    Text("The clip was copied. To paste it directly with Enter, turn on Ap in System Settings > Privacy & Security > Accessibility.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if retry {
                        Text("If Ap is already listed, remove it with \u{2212} and add it again (a rebuilt Ap is a new app to macOS). If the switch is on, relaunch Ap.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Open Accessibility Settings") { onAction(.openSettings) }
                            .buttonStyle(.borderedProminent)
                        if retry { Button("Relaunch Ap") { onAction(.relaunch) } }
                        Button("Not now") { onAction(.dismiss) }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
    }
}

struct Footer: View {
    @ObservedObject var model: PickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                hint("\u{21A9}", model.pasteOnEnter ? LocalizedStringKey("Paste") : LocalizedStringKey("Copy"))
                hint("\u{2318}\u{21A9}", "Copy only")
                hint("\u{21E5}", "Next session")
                hint("\u{2318}P", "Pin")
                hint("\u{2318}\u{232B}", "Delete")
                hint("\u{2318}O", "Copy resume command")
                hint("\u{2318},", "Settings")
                hint("esc", "Close")
            }
            if let flash = model.flash {
                Text(flash).foregroundStyle(Color.accentColor).lineLimit(1).truncationMode(.middle)
            } else if model.pasteOnEnter && !model.accessibilityTrusted && model.banner == nil {
                Text("Enter copies only until Ap is allowed in Privacy & Security > Accessibility")
                    .foregroundStyle(.orange).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func hint(_ key: String, _ action: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.tertiary))
            Text(action)
        }
    }
}

func formatTime(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    let formatter = DateFormatter()
    let calendar = Calendar.current
    formatter.dateFormat = calendar.isDateInToday(date) || calendar.isDateInYesterday(date) ? "HH:mm" : "MM/dd HH:mm"
    let time = formatter.string(from: date)
    return calendar.isDateInYesterday(date) ? String(localized: "Yesterday \(time)") : time
}

/// Session title (or first prompt), else a short session id, else "No session (agent)"
func sessionDisplayName(_ session: Session?, sessionId: String?, agent: String) -> String {
    ClipListing.displayTitle(session)
        ?? sessionId.map { String(localized: "session \(String($0.prefix(8)))") }
        ?? String(localized: "No session (\(agent))")
}

func formatFullTime(_ milliseconds: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
}
