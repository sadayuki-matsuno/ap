import Foundation

public struct ClipGroup: Sendable {
    public let sessionId: String?
    public let session: Session?
    /// Newest first
    public var clips: [Clip]
}

/// Formatting for list views (shared by the CLI and the app)
public enum ClipListing {
    /// Groups clips by session, ordering groups by their newest clip. Clips without a session form a single group
    public static func group(_ clips: [Clip], sessions: [String: Session]) -> [ClipGroup] {
        let sorted = clips.sorted { ($0.createdAt, $0.id ?? 0) > ($1.createdAt, $1.id ?? 0) }
        var groups: [ClipGroup] = []
        var indexBySession: [String?: Int] = [:]
        for clip in sorted {
            if let index = indexBySession[clip.sessionId] {
                groups[index].clips.append(clip)
            } else {
                indexBySession[clip.sessionId] = groups.count
                groups.append(ClipGroup(
                    sessionId: clip.sessionId, session: clip.sessionId.flatMap { sessions[$0] }, clips: [clip]))
            }
        }
        return groups
    }

    /// The session title, or (headless sessions get no ai-title) its first prompt on one line, cut to 60 characters
    public static func displayTitle(_ session: Session?) -> String? {
        if let title = session?.title { return title }
        guard let prompt = session?.firstPrompt else { return nil }
        let line = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 60 ? String(line.prefix(59)) + "\u{2026}" : line
    }

    /// nil for "HEAD" (what Claude Code records outside a git repository) and empty strings
    public static func branch(_ name: String?) -> String? {
        name == "HEAD" || name?.isEmpty == true ? nil : name
    }

    /// "repository | branch" of the session itself (not of its latest clip)
    public static func sessionLocation(_ session: Session) -> String? {
        let location = [session.repository, branch(session.gitBranch)].compactMap { $0 }.joined(separator: " | ")
        return location.isEmpty ? nil : location
    }

    /// "repository | branch" of a clip, only when it differs from its session's
    public static func clipLocation(_ clip: Clip, session: Session?) -> String? {
        let location = [clip.repository, branch(clip.gitBranch)].compactMap { $0 }.joined(separator: " | ")
        guard !location.isEmpty else { return nil }
        return location == session.flatMap(sessionLocation) ? nil : location
    }

    /// One-line preview. Concealed clips are masked
    public static func preview(_ clip: Clip, maxLength: Int) -> String {
        if clip.concealed { return "•••••••• (concealed, \(clip.content.count) chars)" }
        let collapsed = clip.content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > maxLength ? String(collapsed.prefix(max(maxLength - 1, 0))) + "…" : collapsed
    }

    /// The clip `offset` rows away in the flat (grouped) order, clamped to the ends. An unknown or nil id selects the newest
    public static func clipId(from id: Int64?, offset: Int, in groups: [ClipGroup]) -> Int64? {
        let ids = groups.flatMap(\.clips).compactMap(\.id)
        guard let index = ids.firstIndex(where: { $0 == id }) else { return ids.first }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// The first clip of the next (or previous) group; stays put at the ends
    public static func groupJump(from id: Int64?, forward: Bool, in groups: [ClipGroup]) -> Int64? {
        guard let groupIndex = groups.firstIndex(where: { $0.clips.contains { $0.id == id } }) else {
            return groups.first?.clips.first?.id
        }
        let target = groupIndex + (forward ? 1 : -1)
        guard groups.indices.contains(target) else { return id }
        return groups[target].clips.first?.id
    }

    /// The clip whose uuid is the pasteboard's `dev.ap.clip-id`
    public static func clipId(onPasteboard uuid: String?, in clips: [Clip]) -> Int64? {
        guard let uuid else { return nil }
        return clips.first { $0.uuid == uuid }?.id
    }

    /// `cd <cwd> && claude --resume <session_id>`, with the directory single-quoted when needed
    public static func resumeCommand(_ session: Session) -> String {
        let resume = "claude --resume \(session.sessionId)"
        guard let cwd = session.cwd else { return resume }
        let safe = cwd.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+@%,:".contains($0)) }
        let quoted = safe ? cwd : "'" + cwd.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return "cd \(quoted) && \(resume)"
    }
}
