import Foundation
import Testing
@testable import ApCore

@Suite struct ClipQueryParseTests {
    @Test func plainTextIsKeptAsOnePhrase() {
        #expect(ClipQuery.parse("  double   launch ") == ClipQuery(text: "double launch"))
        #expect(ClipQuery.parse("") == ClipQuery())
    }

    @Test func filtersAreExtracted() {
        let query = ClipQuery.parse("repo:genome slack kind:CODE pinned session:1745 reply")
        #expect(query == ClipQuery(
            text: "slack reply", repository: "genome", session: "1745", kind: "code", pinnedOnly: true))
    }

    @Test func quotedValuesMayContainSpaces() {
        #expect(ClipQuery.parse(#"session:"api refactor" "a  b""#) == ClipQuery(text: "a  b", session: "api refactor"))
    }

    @Test func emptyFilterValuesAreIgnoredWhileTyping() {
        #expect(ClipQuery.parse("repo: kind:") == ClipQuery())
    }

    @Test func unknownPrefixesAreText() {
        #expect(ClipQuery.parse("http://x.test agent:human") == ClipQuery(text: "http://x.test agent:human"))
    }
}

@Suite struct ClipQuerySearchTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let genomeContext = CaptureContext(
        sessionId: "session-2", agent: "claude-code", cwd: "/work/genome", gitBranch: "fix/1745",
        repository: "omeroid/genome", terminal: nil)

    /// session-1 (ap, title "ap design"): reply, sql. session-2 (genome, title "genome issue 1745"): url, secret
    func seed() throws -> (ClipStore, [String: Clip]) {
        let store = try makeTemporaryStore()
        var clips: [String: Clip] = [:]
        clips["reply"] = try store.record(
            content: "Hi team, the root cause was a double launch", label: "Slack reply", concealed: false,
            uuid: "1", context: claudeContext, now: base)
        clips["sql"] = try store.record(
            content: "SELECT id, status FROM orders WHERE id = 1;", label: nil, concealed: false,
            uuid: "2", context: claudeContext, now: base.addingTimeInterval(10))
        clips["url"] = try store.record(
            content: "https://example.com/a_b", label: nil, concealed: false,
            uuid: "3", context: genomeContext, now: base.addingTimeInterval(20))
        clips["secret"] = try store.record(
            content: "token sk-ant-" + String(repeating: "x", count: 30), label: "api key", concealed: false,
            uuid: "4", context: genomeContext, now: base.addingTimeInterval(30))
        try store.applyEnrichment(
            clipId: clips["sql"]!.id!, state: .done, toolUseId: nil, promptSnapshot: "write the orders query",
            contextSnapshot: nil)
        try store.updateSession(sessionId: "session-1", title: "ap design", firstPrompt: nil, transcriptPath: nil)
        try store.updateSession(sessionId: "session-2", title: "genome issue 1745", firstPrompt: nil, transcriptPath: nil)
        return (store, clips)
    }

    func contents(_ store: ClipStore, _ input: String) throws -> [String] {
        try store.clips(matching: ClipQuery.parse(input), limit: 100).map(\.content)
    }

    @Test func emptyQueryReturnsEverythingNewestFirst() throws {
        let (store, clips) = try seed()
        #expect(try store.clips(matching: ClipQuery(), limit: 100).map(\.id) ==
            [clips["secret"]!.id, clips["url"]!.id, clips["sql"]!.id, clips["reply"]!.id])
        #expect(try store.clips(matching: ClipQuery(), limit: 2).count == 2)
    }

    @Test func longTextUsesFullTextOverContentLabelAndPrompt() throws {
        let (store, clips) = try seed()
        #expect(try contents(store, "double launch") == [clips["reply"]!.content])
        #expect(try contents(store, "slack") == [clips["reply"]!.content])
        #expect(try contents(store, "orders query") == [clips["sql"]!.content])
    }

    @Test func shortTextUsesLikeWithEscapedWildcards() throws {
        let (store, clips) = try seed()
        #expect(try contents(store, "_b") == [clips["url"]!.content])
        #expect(try contents(store, "%").isEmpty)
        #expect(Set(try contents(store, "id")) == [clips["sql"]!.content])
    }

    @Test func concealedContentIsNotSearchableButItsLabelIs() throws {
        let (store, clips) = try seed()
        #expect(try contents(store, "token").isEmpty)
        #expect(try contents(store, "sk").isEmpty)
        #expect(try contents(store, "api key") == [clips["secret"]!.content])
    }

    @Test func filtersCombineWithText() throws {
        let (store, clips) = try seed()
        #expect(try contents(store, "repo:genome") == [clips["secret"]!.content, clips["url"]!.content])
        #expect(try contents(store, "session:design kind:code") == [clips["sql"]!.content])
        #expect(try contents(store, "kind:url") == [clips["url"]!.content])
        #expect(try contents(store, "repo:genome double").isEmpty)

        _ = try store.setPinned(id: clips["reply"]!.id!, pinned: true)
        #expect(try contents(store, "pinned") == [clips["reply"]!.content])
    }

    @Test func repoFilterMatchesTheClipsOwnRepositoryToo() throws {
        let store = try makeTemporaryStore()
        let elsewhere = CaptureContext(
            sessionId: "session-1", agent: "claude-code", cwd: "/work/other", gitBranch: "main",
            repository: "someone/other", terminal: nil)
        _ = try store.record(content: "first", label: nil, concealed: false, uuid: "1", context: claudeContext, now: base)
        _ = try store.record(content: "second", label: nil, concealed: false, uuid: "2", context: elsewhere, now: base)
        #expect(try contents(store, "repo:other") == ["second"])
        #expect(try contents(store, "repo:sadayuki").count == 2)
    }

    @Test func japaneseShortAndLongQueries() throws {
        let store = try makeTemporaryStore()
        // "The root cause was a double launch" in Japanese
        let content = "\u{539F}\u{56E0}\u{306F}\u{4E8C}\u{91CD}\u{8D77}\u{52D5}\u{3067}\u{3057}\u{305F}"
        _ = try store.record(content: content, label: nil, concealed: false, uuid: "1", context: humanContext, now: base)
        // two characters (LIKE) and four characters (trigram)
        #expect(try contents(store, "\u{539F}\u{56E0}") == [content])
        #expect(try contents(store, "\u{4E8C}\u{91CD}\u{8D77}\u{52D5}") == [content])
        #expect(try contents(store, "\u{4E09}\u{91CD}").isEmpty)
    }
}

@Suite struct SessionDisplayTests {
    @Test func titleFallsBackToTheFirstPromptOnOneLine() throws {
        let store = try makeTemporaryStore()
        _ = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: claudeContext, now: Date())
        var session = try #require(try store.sessions(ids: ["session-1"])["session-1"])
        #expect(ClipListing.displayTitle(session) == nil)

        session.firstPrompt = "  Summarize   the\nlogs from yesterday " + String(repeating: "x", count: 80)
        let title = try #require(ClipListing.displayTitle(session))
        #expect(title.hasPrefix("Summarize the logs from yesterday x"))
        #expect(title.count <= 60)
        #expect(title.hasSuffix("\u{2026}"))

        session.firstPrompt = "short prompt"
        #expect(ClipListing.displayTitle(session) == "short prompt")
        session.title = "Real title"
        #expect(ClipListing.displayTitle(session) == "Real title")
        #expect(ClipListing.displayTitle(nil) == nil)
    }

    @Test func headBranchIsHiddenFromLocations() throws {
        let store = try makeTemporaryStore()
        let headContext = CaptureContext(
            sessionId: "s-h", agent: "claude-code", cwd: "/tmp", gitBranch: "HEAD", repository: "tmp", terminal: nil)
        let clip = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: headContext, now: Date())
        let session = try #require(try store.sessions(ids: ["s-h"])["s-h"])
        #expect(ClipListing.sessionLocation(session) == "tmp")
        #expect(ClipListing.clipLocation(clip, session: nil) == "tmp")
    }

    @Test func sessionFilterMatchesThePromptWhenThereIsNoTitle() throws {
        let store = try makeTemporaryStore()
        _ = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: claudeContext, now: Date())
        try store.updateSession(sessionId: "session-1", title: nil, firstPrompt: "fix the login bug", transcriptPath: nil)
        #expect(try store.clips(matching: ClipQuery.parse("session:login"), limit: 10).count == 1)
        try store.updateSession(sessionId: "session-1", title: "Auth work", firstPrompt: nil, transcriptPath: nil)
        #expect(try store.clips(matching: ClipQuery.parse("session:login"), limit: 10).isEmpty)
        #expect(try store.clips(matching: ClipQuery.parse("session:auth"), limit: 10).count == 1)
    }
}

@Suite struct RevealGateTests {
    @Test func controlPressedAloneArmsTheReveal() {
        var gate = RevealGate(controlDown: false)
        let changed1 = gate.modifiersChanged(control: true, others: false)

        #expect(changed1)
        #expect(gate.isArmed)
        _ = gate.modifiersChanged(control: false, others: false)
        #expect(!gate.isArmed)
    }

    @Test func controlCarriedOverFromTheHotkeyDoesNotArm() {
        // Opened with Control-Command-P: Command is released while Control stays down
        var gate = RevealGate(controlDown: true)
        let changed2 = gate.modifiersChanged(control: true, others: false)

        #expect(!changed2)
        #expect(!gate.isArmed)
        // Pressing Control again does
        _ = gate.modifiersChanged(control: false, others: false)
        let changed3 = gate.modifiersChanged(control: true, others: false)

        #expect(changed3)
    }

    @Test func aKeyOrAnotherModifierDuringTheHoldCancels() {
        var gate = RevealGate(controlDown: false)
        _ = gate.modifiersChanged(control: true, others: false)
        gate.keyPressed()  // Control-A in the search field
        #expect(!gate.isArmed)
        let changed4 = gate.modifiersChanged(control: true, others: false)

        #expect(!changed4)
        #expect(!gate.isArmed)

        var other = RevealGate(controlDown: false)
        _ = other.modifiersChanged(control: true, others: false)
        _ = other.modifiersChanged(control: true, others: true)
        #expect(!other.isArmed)
        _ = other.modifiersChanged(control: true, others: false)
        #expect(!other.isArmed)
    }

    @Test func controlWithAnotherModifierNeverArms() {
        var gate = RevealGate(controlDown: false)
        let changed5 = gate.modifiersChanged(control: true, others: true)

        #expect(!changed5)
        #expect(!gate.isArmed)
    }
}

@Suite struct PickerNavigationTests {
    /// Groups [s1: 4, 1] [human: 3] [s2: 2]
    func groups() throws -> [ClipGroup] {
        let store = try makeTemporaryStore()
        let otherContext = CaptureContext(
            sessionId: "session-2", agent: "claude-code", cwd: "/w", gitBranch: nil, repository: nil, terminal: nil)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.record(content: "1", label: nil, concealed: false, uuid: "1", context: claudeContext, now: base)
        _ = try store.record(content: "2", label: nil, concealed: false, uuid: "2", context: otherContext, now: base.addingTimeInterval(1))
        _ = try store.record(content: "3", label: nil, concealed: false, uuid: "3", context: humanContext, now: base.addingTimeInterval(2))
        _ = try store.record(content: "4", label: nil, concealed: false, uuid: "4", context: claudeContext, now: base.addingTimeInterval(3))
        let clips = try store.clips(sessionId: nil, limit: nil)
        return ClipListing.group(clips, sessions: try store.sessions(ids: Set(clips.compactMap(\.sessionId))))
    }

    @Test func movesThroughTheFlatOrderAndClampsAtTheEnds() throws {
        let groups = try groups()
        #expect(groups.flatMap(\.clips).map(\.content) == ["4", "1", "3", "2"])
        let ids = groups.flatMap(\.clips).map(\.id!)
        #expect(ClipListing.clipId(from: nil, offset: 1, in: groups) == ids[0])
        #expect(ClipListing.clipId(from: ids[0], offset: 1, in: groups) == ids[1])
        #expect(ClipListing.clipId(from: ids[1], offset: 1, in: groups) == ids[2])
        #expect(ClipListing.clipId(from: ids[3], offset: 1, in: groups) == ids[3])
        #expect(ClipListing.clipId(from: ids[0], offset: -1, in: groups) == ids[0])
        #expect(ClipListing.clipId(from: 999, offset: 1, in: groups) == ids[0])
        #expect(ClipListing.clipId(from: nil, offset: 1, in: []) == nil)
    }

    @Test func jumpsToTheFirstClipOfTheNextOrPreviousGroup() throws {
        let groups = try groups()
        let ids = groups.flatMap(\.clips).map(\.id!)
        #expect(ClipListing.groupJump(from: ids[0], forward: true, in: groups) == ids[2])
        #expect(ClipListing.groupJump(from: ids[1], forward: true, in: groups) == ids[2])
        #expect(ClipListing.groupJump(from: ids[2], forward: true, in: groups) == ids[3])
        #expect(ClipListing.groupJump(from: ids[3], forward: true, in: groups) == ids[3])
        #expect(ClipListing.groupJump(from: ids[3], forward: false, in: groups) == ids[2])
        #expect(ClipListing.groupJump(from: ids[1], forward: false, in: groups) == ids[1])
        #expect(ClipListing.groupJump(from: nil, forward: true, in: groups) == ids[0])
    }

    @Test func findsTheClipOnThePasteboard() throws {
        let clips = try groups().flatMap(\.clips)
        #expect(ClipListing.clipId(onPasteboard: "3", in: clips) == clips.first { $0.uuid == "3" }?.id)
        #expect(ClipListing.clipId(onPasteboard: "unknown", in: clips) == nil)
        #expect(ClipListing.clipId(onPasteboard: nil, in: clips) == nil)
    }

    @Test func resumeCommandQuotesTheDirectory() throws {
        let store = try makeTemporaryStore()
        let spaced = CaptureContext(
            sessionId: "s-1", agent: "claude-code", cwd: "/Users/me/it's here", gitBranch: nil, repository: nil,
            terminal: nil)
        _ = try store.record(content: "a", label: nil, concealed: false, uuid: "1", context: claudeContext, now: Date())
        _ = try store.record(content: "b", label: nil, concealed: false, uuid: "2", context: spaced, now: Date())
        let sessions = try store.sessions(ids: ["session-1", "s-1"])
        #expect(ClipListing.resumeCommand(sessions["session-1"]!) == "cd /work/ap && claude --resume session-1")
        #expect(ClipListing.resumeCommand(sessions["s-1"]!) == #"cd '/Users/me/it'\''s here' && claude --resume s-1"#)
    }
}
