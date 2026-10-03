import Foundation
import Testing
@testable import ApCore
import GRDB

func makeTemporaryStore() throws -> ClipStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ap-tests-\(UUID().uuidString)", isDirectory: true)
    return try ClipStore(path: directory.appendingPathComponent("ap.db").path)
}

let claudeContext = CaptureContext(
    sessionId: "session-1", agent: "claude-code", cwd: "/work/ap", gitBranch: "main",
    repository: "sadayuki-matsuno/ap", terminal: "ghostty")
let humanContext = CaptureContext(
    sessionId: nil, agent: "human", cwd: "/work", gitBranch: nil, repository: nil, terminal: nil)

@Suite struct ClipStoreTests {
    @Test func createsDatabaseFileWithMode600() throws {
        let store = try makeTemporaryStore()
        let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func recordInsertsClipAndSession() throws {
        let store = try makeTemporaryStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clip = try store.record(
            content: "https://example.com", label: "URL", concealed: false,
            uuid: "uuid-1", context: claudeContext, now: now)
        #expect(clip.id != nil)
        #expect(clip.uuid == "uuid-1")
        #expect(clip.contentKind == "url")
        #expect(clip.enrichState == "pending")
        #expect(clip.terminal == "ghostty")
        #expect(clip.createdAt == 1_800_000_000_000)
        #expect(!clip.contentHash.isEmpty)

        let sessions = try store.sessions(ids: ["session-1"])
        #expect(sessions["session-1"]?.repository == "sadayuki-matsuno/ap")
        #expect(sessions["session-1"]?.agent == "claude-code")
    }

    @Test func clipWithoutSessionIsDone() throws {
        let store = try makeTemporaryStore()
        let clip = try store.record(
            content: "hello", label: nil, concealed: false, uuid: "u", context: humanContext, now: Date())
        #expect(clip.enrichState == "done")
        #expect(clip.sessionId == nil)
    }

    @Test func secretMarksConcealed() throws {
        let store = try makeTemporaryStore()
        let clip = try store.record(
            content: "AKIAIOSFODNN7EXAMPLE", label: nil, concealed: false, uuid: "u",
            context: humanContext, now: Date())
        #expect(clip.concealed)
    }

    @Test func pruneDeletesOldUnpinnedClipsAndEmptySessions() throws {
        let store = try makeTemporaryStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try store.record(
            content: "old", label: nil, concealed: false, uuid: "a", context: claudeContext,
            now: now.addingTimeInterval(-25 * 3600))
        let oldPinned = try store.record(
            content: "old pinned", label: nil, concealed: false, uuid: "b", context: humanContext,
            now: now.addingTimeInterval(-25 * 3600))
        _ = try store.setPinned(id: oldPinned.id!, pinned: true)
        let recent = try store.record(
            content: "recent", label: nil, concealed: false, uuid: "c", context: humanContext,
            now: now.addingTimeInterval(-3600))

        let deleted = try store.prune(olderThan: 24 * 3600, now: now)
        #expect(deleted == 1)
        let remaining = try store.clips(sessionId: nil, limit: nil).map(\.id)
        #expect(Set(remaining) == Set([oldPinned.id, recent.id]))
        #expect(!remaining.contains(old.id))
        #expect(try store.sessions(ids: ["session-1"]).isEmpty)
    }

    @Test func recordPrunesExpiredClips() throws {
        let store = try makeTemporaryStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.record(
            content: "old", label: nil, concealed: false, uuid: "a", context: humanContext,
            now: now.addingTimeInterval(-48 * 3600))
        _ = try store.record(content: "new", label: nil, concealed: false, uuid: "b", context: humanContext, now: now)
        #expect(try store.clips(sessionId: nil, limit: nil).map(\.content) == ["new"])
    }

    @Test func clipsAreNewestFirstAndNthNewest() throws {
        let store = try makeTemporaryStore()
        let now = Date()
        for index in 0..<3 {
            _ = try store.record(
                content: "clip \(index)", label: nil, concealed: false, uuid: "u\(index)",
                context: humanContext, now: now.addingTimeInterval(Double(index)))
        }
        #expect(try store.clips(sessionId: nil, limit: nil).map(\.content) == ["clip 2", "clip 1", "clip 0"])
        #expect(try store.clips(sessionId: nil, limit: 2).count == 2)
        #expect(try store.clip(nth: 1)?.content == "clip 2")
        #expect(try store.clip(nth: 3)?.content == "clip 0")
        #expect(try store.clip(nth: 4) == nil)
    }

    @Test func markPastedIncrementsCount() throws {
        let store = try makeTemporaryStore()
        let clip = try store.record(content: "x", label: nil, concealed: false, uuid: "u", context: humanContext, now: Date())
        let pastedAt = Date(timeIntervalSince1970: 1_900_000_000)
        try store.markPasted(id: clip.id!, now: pastedAt)
        try store.markPasted(id: clip.id!, now: pastedAt)
        let updated = try store.clip(id: clip.id!)
        #expect(updated?.pasteCount == 2)
        #expect(updated?.lastPastedAt == 1_900_000_000_000)
    }

    @Test func setPinnedReturnsFalseForUnknownId() throws {
        let store = try makeTemporaryStore()
        #expect(try store.setPinned(id: 999, pinned: true) == false)
    }

    @Test func fullTextSearchFollowsInsertUpdateAndPrune() throws {
        let store = try makeTemporaryStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clip = try store.record(
            content: "Hi team. The root cause was a double launch", label: "Slack reply", concealed: false, uuid: "u",
            context: claudeContext, now: now.addingTimeInterval(-25 * 3600))
        #expect(try store.search("double launch") == [clip.id!])
        #expect(try store.search("Slack") == [clip.id!])

        try store.applyEnrichment(
            clipId: clip.id!, state: .done, toolUseId: "toolu_1",
            promptSnapshot: "draft a reply please", contextSnapshot: nil)
        #expect(try store.search("draft a reply") == [clip.id!])

        try store.applyEnrichment(
            clipId: clip.id!, state: .done, toolUseId: "toolu_1",
            promptSnapshot: "another request", contextSnapshot: nil)
        #expect(try store.search("draft a reply").isEmpty)
        #expect(try store.search("another req").count == 1)

        _ = try store.prune(olderThan: 24 * 3600, now: now)
        #expect(try store.search("double launch").isEmpty)
    }

    @Test func deleteRemovesClipFromSearchAndEmptySession() throws {
        let store = try makeTemporaryStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try store.record(
            content: "the double launch fix", label: nil, concealed: false, uuid: "a", context: claudeContext, now: now)
        let second = try store.record(
            content: "pinned note", label: nil, concealed: false, uuid: "b", context: claudeContext, now: now)
        _ = try store.setPinned(id: second.id!, pinned: true)

        #expect(try store.delete(id: first.id!))
        #expect(try store.clip(id: first.id!) == nil)
        #expect(try store.search("double launch").isEmpty)
        #expect(try store.sessions(ids: ["session-1"]).count == 1)

        // Pinned clips can be deleted too; the session goes with its last clip
        #expect(try store.delete(id: second.id!))
        #expect(try store.sessions(ids: ["session-1"]).isEmpty)
        #expect(try store.delete(id: second.id!) == false)
    }

    @Test func countsByEnrichState() throws {
        let store = try makeTemporaryStore()
        _ = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: claudeContext, now: Date())
        _ = try store.record(content: "b", label: nil, concealed: false, uuid: "2", context: humanContext, now: Date())
        let counts = try store.countsByEnrichState()
        #expect(counts["pending"] == 1)
        #expect(counts["done"] == 1)
    }
}

@Suite struct ClipStoreRobustnessTests {
    @Test func enrichmentNeverDowngradesDoneOrErasesSnapshots() throws {
        let store = try makeTemporaryStore()
        let clip = try store.record(content: "x", label: nil, concealed: false, uuid: "u", context: claudeContext, now: Date())
        try store.applyEnrichment(clipId: clip.id!, state: .done, toolUseId: "toolu_1",
                                  promptSnapshot: "the prompt", contextSnapshot: "the context")
        try store.applyEnrichment(clipId: clip.id!, state: .failed, toolUseId: nil, promptSnapshot: nil, contextSnapshot: nil)
        let enriched = try store.clip(id: clip.id!)
        #expect(enriched?.enrichState == "done")
        #expect(enriched?.toolUseId == "toolu_1")
        #expect(enriched?.promptSnapshot == "the prompt")
        #expect(enriched?.contextSnapshot == "the context")
    }

    @Test func reopeningExistingDatabaseKeepsDataAndMode() throws {
        let store = try makeTemporaryStore()
        _ = try store.record(content: "keep", label: nil, concealed: false, uuid: "u", context: humanContext, now: Date())
        let reopened = try ClipStore(path: store.path)
        #expect(try reopened.clips(sessionId: nil, limit: nil).map(\.content) == ["keep"])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test(arguments: [("24h", 86400.0), ("90m", 5400.0), ("7d", 604800.0), ("3600s", 3600.0), ("1.5h", 5400.0)])
    func parsesRetention(_ text: String, _ expected: Double) {
        #expect(ClipStore.retentionInterval(from: text) == expected)
    }

    @Test(arguments: ["0s", "-1h", "nanh", "infh", "-infd", "24", "h", "10x", ""])
    func rejectsInvalidRetention(_ text: String) {
        #expect(ClipStore.retentionInterval(from: text) == nil)
    }
}

@Suite struct ClipStoreJapaneseTests {
    /// Trigram FTS must match Japanese text (written as escapes to keep the source ASCII)
    @Test func fullTextSearchMatchesJapanese() throws {
        let store = try makeTemporaryStore()
        // "The root cause was a double launch" in Japanese
        let content = "\u{539F}\u{56E0}\u{306F}\u{4E8C}\u{91CD}\u{8D77}\u{52D5}\u{3067}\u{3057}\u{305F}"
        let clip = try store.record(content: content, label: nil, concealed: false, uuid: "u", context: humanContext, now: Date())
        #expect(try store.search("\u{4E8C}\u{91CD}\u{8D77}\u{52D5}") == [clip.id!])
        #expect(try store.clip(id: clip.id!)?.content == content)
    }
}

@Suite struct ClipStoreIdentityTests {
    @Test func idsAreNotReusedAfterPrune() throws {
        let store = try makeTemporaryStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = try store.record(content: "kept", label: nil, concealed: false, uuid: "1", context: humanContext, now: now)
        let old1 = try store.record(content: "old 1", label: nil, concealed: false, uuid: "2", context: humanContext,
                                    now: now.addingTimeInterval(-48 * 3600))
        let old2 = try store.record(content: "old 2", label: nil, concealed: false, uuid: "3", context: humanContext,
                                    now: now.addingTimeInterval(-48 * 3600))
        try store.prune(olderThan: 24 * 3600, now: now)
        let next = try store.record(content: "next", label: nil, concealed: false, uuid: "4", context: humanContext, now: now)
        #expect(try store.clips(sessionId: nil, limit: nil).map(\.content).sorted() == ["kept", "next"])
        #expect(next.id! > max(kept.id!, old1.id!, old2.id!))
    }

    @Test func migrationFromV2PreservesDataAndSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ap-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("ap.db").path
        do {
            let pool = try DatabasePool(path: path)
            try ClipStore.migrator.migrate(pool, upTo: "v2-subagent")
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO sessions (session_id, agent, first_seen_at, last_seen_at) VALUES ('s', 'claude-code', 1, 1);
                    INSERT INTO clips (id, uuid, content, content_hash, session_id, agent, enrich_state, created_at, subagent)
                    VALUES (7, 'u7', 'migrated content here', 'h', 's', 'claude-code', 'done', 9999999999999, 'sub');
                    """)
            }
        }
        let store = try ClipStore(path: path)
        let clip = try #require(try store.clip(id: 7))
        #expect(clip.content == "migrated content here")
        #expect(clip.subagent == "sub")
        #expect(try store.search("migrated") == [7])
        let next = try store.record(content: "new", label: nil, concealed: false, uuid: "n", context: humanContext,
                                    now: Date(timeIntervalSince1970: 9_999_999_999))
        #expect(next.id == 8)
    }

    @Test func largeContentIsSearchableAtTheStart() throws {
        let store = try makeTemporaryStore()
        let content = "needle at the start " + String(repeating: "lorem ipsum ", count: 100_000)
        let clip = try store.record(content: content, label: nil, concealed: false, uuid: "u", context: humanContext, now: Date())
        #expect(try store.search("needle at") == [clip.id!])
        #expect(try store.clip(id: clip.id!)?.content == content)
        try store.prune(olderThan: 1, now: Date().addingTimeInterval(10))
        #expect(try store.search("needle at").isEmpty)
    }
}

@Suite struct SessionOriginTests {
    @Test func sessionKeepsFirstSeenRepositoryAndClipKeepsItsOwn() throws {
        let store = try makeTemporaryStore()
        let elsewhere = CaptureContext(
            sessionId: "session-1", agent: "claude-code", cwd: "/work/shepherd", gitBranch: "main",
            repository: "sadayuki-matsuno/shepherd", terminal: nil)
        _ = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: claudeContext, now: Date())
        let other = try store.record(content: "b", label: nil, concealed: false, uuid: "2", context: elsewhere, now: Date())
        let session = try store.sessions(ids: ["session-1"])["session-1"]
        #expect(session?.repository == "sadayuki-matsuno/ap")
        #expect(session?.cwd == "/work/ap")
        #expect(session?.gitBranch == "main")
        #expect(other.repository == "sadayuki-matsuno/shepherd")
    }

    @Test func clipLocationShownOnlyWhenDifferentFromSession() throws {
        let store = try makeTemporaryStore()
        let elsewhere = CaptureContext(
            sessionId: "session-1", agent: "claude-code", cwd: "/work/shepherd", gitBranch: "main",
            repository: "sadayuki-matsuno/shepherd", terminal: nil)
        let same = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: claudeContext, now: Date())
        let other = try store.record(content: "b", label: nil, concealed: false, uuid: "2", context: elsewhere, now: Date())
        let session = try #require(try store.sessions(ids: ["session-1"])["session-1"])
        #expect(ClipListing.sessionLocation(session) == "sadayuki-matsuno/ap | main")
        #expect(ClipListing.clipLocation(same, session: session) == nil)
        #expect(ClipListing.clipLocation(other, session: session) == "sadayuki-matsuno/shepherd | main")
    }
}

@Suite struct ClipStoreConcurrencyTests {
    /// Parallel `| ap` calls on a fresh machine all open and migrate the same new database at once
    @Test func concurrentFirstOpensAllRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ap-concurrent-\(UUID().uuidString)")
        let path = directory.appendingPathComponent("ap.db").path
        let failures = OSAllocatedUnfairLockCounter()
        DispatchQueue.concurrentPerform(iterations: 10) { index in
            do {
                let store = try ClipStore(path: path)
                try store.record(content: "concurrent \(index)", label: nil, concealed: false, uuid: "u\(index)",
                                 context: humanContext, now: Date())
            } catch {
                failures.increment()
            }
        }
        #expect(failures.value == 0)
        #expect(try ClipStore(path: path).clips(sessionId: nil, limit: nil).count == 10)
    }
}

final class OSAllocatedUnfairLockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Suite struct SessionLocationUnitTests {
    static let noRemoteSession = CaptureContext(
        sessionId: "session-1", agent: "claude-code", cwd: "/work/ap", gitBranch: "main", repository: nil, terminal: nil)
    static let shepherd = CaptureContext(
        sessionId: "session-1", agent: "claude-code", cwd: "/work/shepherd", gitBranch: "main",
        repository: "sadayuki-matsuno/shepherd", terminal: nil)

    @Test func clipFromAnotherDirectoryNeverFillsSessionLocation() throws {
        let store = try makeTemporaryStore()
        _ = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: Self.noRemoteSession, now: Date())
        _ = try store.record(content: "b", label: nil, concealed: false, uuid: "2", context: Self.shepherd, now: Date())
        let session = try #require(try store.sessions(ids: ["session-1"])["session-1"])
        #expect(session.cwd == "/work/ap")
        #expect(session.repository == nil)
        #expect(session.gitBranch == "main")
    }

    @Test func sameDirectoryClipFillsMissingRepository() throws {
        let store = try makeTemporaryStore()
        var later = Self.noRemoteSession
        later.repository = "ap"
        _ = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: Self.noRemoteSession, now: Date())
        _ = try store.record(content: "b", label: nil, concealed: false, uuid: "2", context: later, now: Date())
        #expect(try store.sessions(ids: ["session-1"])["session-1"]?.repository == "ap")
    }

    @Test func headerAndClipLinesWithDirectoryNameFallback() throws {
        let store = try makeTemporaryStore()
        var apContext = Self.noRemoteSession
        apContext.repository = "ap"
        let first = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: apContext, now: Date())
        let second = try store.record(content: "b", label: nil, concealed: false, uuid: "2", context: Self.shepherd, now: Date())
        let session = try #require(try store.sessions(ids: ["session-1"])["session-1"])
        #expect(ClipListing.sessionLocation(session) == "ap | main")
        #expect(ClipListing.clipLocation(first, session: session) == nil)
        #expect(ClipListing.clipLocation(second, session: session) == "sadayuki-matsuno/shepherd | main")
    }
}

@Suite struct EnrichSessionLocationTests {
    func enrich(store: ClipStore, resolver: @escaping @Sendable (String) -> CaptureContext.Location?) throws {
        var fixture = TranscriptFixture.standard()
        fixture.lines = fixture.lines.map { $0.replacingOccurrences(of: "\"cwd\":\"\\/work\\/ap\"", with: "\"cwd\":\"\\/work\\/real\"") }
        let projects = try writeProjects(main: fixture.lines)
        try Enricher.enrichPending(
            store: store, projectsDirectory: projects, now: TranscriptFixture.base.addingTimeInterval(80),
            resolveLocation: resolver)
    }

    @Test func gitFailureDoesNotCommitTranscriptCwd() throws {
        let store = try makeTemporaryStore()
        _ = try store.record(content: "x", label: nil, concealed: false, uuid: "1", context: claudeContext,
                             now: TranscriptFixture.base.addingTimeInterval(72))
        try enrich(store: store) { _ in nil }
        let session = try #require(try store.sessions(ids: ["session-1"])["session-1"])
        #expect(session.cwd == "/work/ap")
        #expect(session.repository == "sadayuki-matsuno/ap")
    }

    @Test func resolvedLocationReplacesSessionLocationAsAUnit() throws {
        let store = try makeTemporaryStore()
        _ = try store.record(content: "x", label: nil, concealed: false, uuid: "1", context: claudeContext,
                             now: TranscriptFixture.base.addingTimeInterval(72))
        try enrich(store: store) { cwd in
            cwd == "/work/real" ? CaptureContext.Location(repository: "real", gitBranch: "dev") : nil
        }
        let session = try #require(try store.sessions(ids: ["session-1"])["session-1"])
        #expect(session.cwd == "/work/real")
        #expect(session.repository == "real")
    }

    @Test func missingRepositoryIsResolvedEvenWhenCwdMatches() throws {
        let store = try makeTemporaryStore()
        let noRepository = CaptureContext(
            sessionId: "session-1", agent: "claude-code", cwd: "/work/real", gitBranch: nil, repository: nil, terminal: nil)
        _ = try store.record(content: "x", label: nil, concealed: false, uuid: "1", context: noRepository,
                             now: TranscriptFixture.base.addingTimeInterval(72))
        try enrich(store: store) { _ in CaptureContext.Location(repository: "real", gitBranch: "main") }
        #expect(try store.sessions(ids: ["session-1"])["session-1"]?.repository == "real")
    }
}
