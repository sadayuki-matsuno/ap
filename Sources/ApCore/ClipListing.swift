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

    /// "repository | branch" of the session itself (not of its latest clip)
    public static func sessionLocation(_ session: Session) -> String? {
        let location = [session.repository, session.gitBranch].compactMap { $0 }.joined(separator: " | ")
        return location.isEmpty ? nil : location
    }

    /// "repository | branch" of a clip, only when it differs from its session's
    public static func clipLocation(_ clip: Clip, session: Session?) -> String? {
        let location = [clip.repository, clip.gitBranch].compactMap { $0 }.joined(separator: " | ")
        guard !location.isEmpty else { return nil }
        return location == session.flatMap(sessionLocation) ? nil : location
    }

    /// One-line preview. Concealed clips are masked
    public static func preview(_ clip: Clip, maxLength: Int) -> String {
        if clip.concealed { return "•••••••• (concealed, \(clip.content.count) chars)" }
        let collapsed = clip.content.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > maxLength ? String(collapsed.prefix(max(maxLength - 1, 0))) + "…" : collapsed
    }
}
