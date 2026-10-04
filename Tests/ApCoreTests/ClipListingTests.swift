import Foundation
import Testing
@testable import ApCore

@Suite struct ClipListingTests {
    @Test func usageBadgeShowsOnlyForUsedClips() {
        #expect(ClipListing.usageBadge(pasteCount: 0) == nil)
        #expect(ClipListing.usageBadge(pasteCount: 1) == "\u{2713} 1")
        #expect(ClipListing.usageBadge(pasteCount: 12) == "\u{2713} 12")
    }

    @Test func groupsBySessionNewestFirst() throws {
        let store = try makeTemporaryStore()
        let otherContext = CaptureContext(
            sessionId: "session-2", agent: "claude-code", cwd: "/work/genome", gitBranch: "fix/1745",
            repository: "omeroid/genome", terminal: nil)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.record(content: "s1-a", label: nil, concealed: false, uuid: "1", context: claudeContext, now: base)
        _ = try store.record(content: "s2-a", label: nil, concealed: false, uuid: "2", context: otherContext, now: base.addingTimeInterval(10))
        _ = try store.record(content: "h-a", label: nil, concealed: false, uuid: "3", context: humanContext, now: base.addingTimeInterval(15))
        _ = try store.record(content: "s1-b", label: nil, concealed: false, uuid: "4", context: claudeContext, now: base.addingTimeInterval(20))

        let clips = try store.clips(sessionId: nil, limit: nil)
        let sessions = try store.sessions(ids: Set(clips.compactMap(\.sessionId)))
        let groups = ClipListing.group(clips, sessions: sessions)

        #expect(groups.map(\.sessionId) == ["session-1", nil, "session-2"])
        #expect(groups[0].clips.map(\.content) == ["s1-b", "s1-a"])
        #expect(groups[0].session?.repository == "sadayuki-matsuno/ap")
        #expect(groups[2].session?.repository == "omeroid/genome")
    }

    @Test func previewMasksConcealedAndTruncates() throws {
        let store = try makeTemporaryStore()
        let secret = try store.record(
            content: "ghp_" + String(repeating: "a", count: 36), label: nil, concealed: false, uuid: "1",
            context: humanContext, now: Date())
        #expect(!ClipListing.preview(secret, maxLength: 40).contains("ghp_"))

        let long = try store.record(
            content: "line1\n  line2 " + String(repeating: "x", count: 100), label: nil, concealed: false, uuid: "2",
            context: humanContext, now: Date())
        let preview = ClipListing.preview(long, maxLength: 20)
        #expect(preview.hasPrefix("line1 line2"))
        #expect(preview.count <= 20)
        #expect(!preview.contains("\n"))
    }
}
