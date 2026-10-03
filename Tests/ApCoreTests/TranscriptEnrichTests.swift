import Foundation
import Testing
@testable import ApCore

/// Synthetic fixture mirroring the real transcript structure (type / uuid / parentUuid / timestamp / message.content blocks).
struct TranscriptFixture {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    var lines: [String] = []

    static func timestamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(offset))
    }

    static func milliseconds(_ offset: TimeInterval) -> Int64 {
        Int64((base.timeIntervalSince1970 + offset) * 1000)
    }

    mutating func append(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        lines.append(String(data: data, encoding: .utf8)!)
    }

    mutating func userPrompt(_ uuid: String, parent: String?, at offset: TimeInterval, _ text: String, promptId: String, asBlocks: Bool = false) {
        let content: Any = asBlocks ? [["type": "text", "text": text]] : text
        append([
            "type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "timestamp": Self.timestamp(offset),
            "isSidechain": false, "promptId": promptId, "cwd": "/work/ap", "gitBranch": "main",
            "sessionId": "session-1", "message": ["role": "user", "content": content],
        ])
    }

    mutating func metaUser(_ uuid: String, parent: String?, at offset: TimeInterval, _ text: String) {
        append([
            "type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "timestamp": Self.timestamp(offset),
            "isMeta": true, "message": ["role": "user", "content": text],
        ])
    }

    mutating func attachment(_ uuid: String, parent: String, at offset: TimeInterval) {
        append(["type": "attachment", "uuid": uuid, "parentUuid": parent, "timestamp": Self.timestamp(offset), "attachment": ["type": "x"]])
    }

    mutating func assistant(_ uuid: String, parent: String?, at offset: TimeInterval, blocks: [[String: Any]]) {
        append([
            "type": "assistant", "uuid": uuid, "parentUuid": parent ?? NSNull(), "timestamp": Self.timestamp(offset),
            "isSidechain": false, "message": ["role": "assistant", "id": "msg_\(uuid)", "content": blocks],
        ])
    }

    mutating func text(_ uuid: String, parent: String?, at offset: TimeInterval, _ text: String) {
        assistant(uuid, parent: parent, at: offset, blocks: [["type": "text", "text": text]])
    }

    mutating func bash(_ uuid: String, parent: String?, at offset: TimeInterval, id: String, command: String) {
        assistant(uuid, parent: parent, at: offset, blocks: [
            ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": command, "description": "x"]],
        ])
    }

    mutating func toolResult(_ uuid: String, parent: String, at offset: TimeInterval, toolUseId: String, promptId: String) {
        append([
            "type": "user", "uuid": uuid, "parentUuid": parent, "timestamp": Self.timestamp(offset), "promptId": promptId,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolUseId, "content": "ok"]]],
            "toolUseResult": ["stdout": "ok"],
        ])
    }

    mutating func aiTitle(_ title: String) {
        append(["type": "ai-title", "aiTitle": title, "sessionId": "session-1"])
    }

    /// A typical session with two prompts
    static func standard() -> TranscriptFixture {
        var fixture = TranscriptFixture()
        fixture.userPrompt("u1", parent: nil, at: 0, "First request: write the Slack reply", promptId: "p1")
        fixture.aiTitle("Old title")
        fixture.attachment("a1", parent: "u1", at: 0.1)
        fixture.attachment("a2", parent: "a1", at: 0.1)
        fixture.assistant("t1", parent: "a2", at: 5, blocks: [["type": "thinking", "thinking": ""]])
        fixture.text("x1", parent: "t1", at: 6, "I will draft the reply.")
        fixture.bash("b1", parent: "x1", at: 10, id: "toolu_A",
                     command: "cat <<'EOF' | ap --label Slack\nHello team,\nhere is the body\nEOF")
        fixture.toolResult("r1", parent: "b1", at: 11, toolUseId: "toolu_A", promptId: "p1")
        fixture.bash("b2", parent: "r1", at: 20, id: "toolu_B", command: "cd ../ap-main && make apply")
        fixture.toolResult("r2", parent: "b2", at: 21, toolUseId: "toolu_B", promptId: "p1")
        fixture.userPrompt("u2", parent: "r2", at: 60, "Second request", promptId: "p2", asBlocks: true)
        fixture.metaUser("m1", parent: "u2", at: 60.5, "<local-command-stdout>x</local-command-stdout>")
        fixture.text("x2", parent: "m1", at: 65, "Copying the command.")
        fixture.bash("b3", parent: "x2", at: 70, id: "toolu_C", command: "echo hello | ap")
        fixture.toolResult("r3", parent: "b3", at: 71, toolUseId: "toolu_C", promptId: "p2")
        fixture.aiTitle("New title")
        return fixture
    }
}

@Suite struct TranscriptParseTests {
    @Test func gitBranchIsLastSeen() {
        var fixture = TranscriptFixture.standard()
        fixture.append([
            "type": "user", "uuid": "u9", "parentUuid": "r3", "timestamp": TranscriptFixture.timestamp(90),
            "cwd": "/work/ap", "gitBranch": "feat/x", "message": ["role": "user", "content": "switched branch"],
        ])
        #expect(Transcript(lines: fixture.lines).gitBranch == "feat/x")
        #expect(Transcript(lines: TranscriptFixture.standard().lines).gitBranch == "main")
    }

    /// Outside a git repository Claude Code writes gitBranch "HEAD"; that is not a branch
    @Test func headIsNotABranch() {
        var fixture = TranscriptFixture.standard()
        fixture.append([
            "type": "user", "uuid": "u9", "parentUuid": "r3", "timestamp": TranscriptFixture.timestamp(90),
            "cwd": "/tmp", "gitBranch": "HEAD", "message": ["role": "user", "content": "elsewhere"],
        ])
        #expect(Transcript(lines: fixture.lines).gitBranch == "main")
        var headOnly = TranscriptFixture()
        headOnly.append([
            "type": "user", "uuid": "u1", "timestamp": TranscriptFixture.timestamp(0),
            "cwd": "/tmp", "gitBranch": "HEAD", "message": ["role": "user", "content": "hi"],
        ])
        #expect(Transcript(lines: headOnly.lines).gitBranch == nil)
    }

    @Test func titleIsLastAiTitle() {
        let transcript = Transcript(lines: TranscriptFixture.standard().lines)
        #expect(transcript.title == "New title")
        #expect(transcript.firstPrompt == "First request: write the Slack reply")
        #expect(transcript.cwd == "/work/ap")
    }

    @Test func customTitleTakesPrecedence() {
        var fixture = TranscriptFixture.standard()
        fixture.append(["type": "custom-title", "customTitle": "Manual title", "sessionId": "session-1"])
        fixture.aiTitle("An even newer AI title")
        #expect(Transcript(lines: fixture.lines).title == "Manual title")
    }

    @Test func toleratesMalformedLines() {
        var fixture = TranscriptFixture.standard()
        fixture.lines.insert("{not json", at: 3)
        fixture.lines.insert("", at: 4)
        #expect(Transcript(lines: fixture.lines).toolUses.count == 3)
    }

    @Test func readsFileWithoutTrailingNewline() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        try TranscriptFixture.standard().lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let transcript = try Transcript(contentsOf: url)
        #expect(transcript.toolUses.map(\.id) == ["toolu_A", "toolu_B", "toolu_C"])
        #expect(transcript.title == "New title")
    }

    @Test(arguments: [
        ("echo hi | ap", true),
        ("echo hi |ap --label x", true),
        ("ap copy < file", true),
        ("cat <<'EOF' | ap --concealed\nx\nEOF", true),
        ("printf x | pbcopy", true),
        ("cd ../ap-main && make apply", false),
        ("ls ap/", false),
        ("swift build && .build/release/ap list", false),
        ("echo x | ap list", false),
        ("cd x && AP_DB_PATH=/p /path/ap --label L <<'EOF'\nbody\nEOF", true),
        ("env FOO=1 ap", true),
        ("FOO='a b' BAR=\"c d\" ap copy", true),
        ("echo x | LANG=C ap", true),
        ("AP_DB_PATH=/p ap list", false),
        ("FOO=ap make", false),
        ("ap delete 3", false),
        ("echo x | ap -c --label y", true),
        ("ap --clipboard <<'EOF'\nbody\nEOF", true),
    ])
    func invokesCopy(_ command: String, _ expected: Bool) {
        #expect(Enricher.invokesCopy(command) == expected)
    }
}

@Suite struct EnricherMatchTests {
    let transcript = Transcript(lines: TranscriptFixture.standard().lines)

    @Test func heredocMatchesByContentLineWithPromptAndContext() {
        let result = Enricher.match(
            content: "\nHello team,\nhere is the body\n", createdAt: TranscriptFixture.milliseconds(10.5), transcript: transcript, now: TranscriptFixture.base.addingTimeInterval(30))
        #expect(result?.state == .done)
        #expect(result?.toolUseId == "toolu_A")
        #expect(result?.promptSnapshot == "First request: write the Slack reply")
        #expect(result?.contextSnapshot == "I will draft the reply.")
    }

    @Test func latestCopyToolUseBeforeCreatedAt() {
        let result = Enricher.match(
            content: "hello\n", createdAt: TranscriptFixture.milliseconds(70.3), transcript: transcript,
            now: TranscriptFixture.base.addingTimeInterval(90))
        #expect(result?.toolUseId == "toolu_C")
        #expect(result?.promptSnapshot == "Second request")
        #expect(result?.contextSnapshot == "Copying the command.")
    }

    @Test func contentMatchWinsAmongParallelToolUses() {
        // Parallel Bash calls from one message; both run across created_at
        var fixture = TranscriptFixture()
        fixture.userPrompt("u1", parent: nil, at: 0, "copy two things", promptId: "p1")
        fixture.bash("b1", parent: "u1", at: 100, id: "toolu_Y", command: "cat <<'EOF' | ap\nbar baz\nEOF")
        fixture.bash("b2", parent: "b1", at: 100, id: "toolu_X", command: "echo foo | ap")
        fixture.toolResult("r1", parent: "b2", at: 102, toolUseId: "toolu_Y", promptId: "p1")
        fixture.toolResult("r2", parent: "r1", at: 102, toolUseId: "toolu_X", promptId: "p1")
        let result = Enricher.match(
            content: "bar baz\n", createdAt: TranscriptFixture.milliseconds(101),
            transcript: Transcript(lines: fixture.lines), now: TranscriptFixture.base.addingTimeInterval(110))
        #expect(result?.toolUseId == "toolu_Y")
    }

    @Test func ignoresToolUseThatFinishedBeforeClip() {
        // Don't bind to a long-finished command whose heredoc merely mentions `| ap` (seen in real data)
        var fixture = TranscriptFixture()
        fixture.userPrompt("u1", parent: nil, at: 0, "fix the design doc", promptId: "p1")
        fixture.bash("b1", parent: "u1", at: 5, id: "toolu_OLD", command: "python3 - <<'EOF'\nrewrite the rule to | ap\nEOF")
        fixture.toolResult("r1", parent: "b1", at: 6, toolUseId: "toolu_OLD", promptId: "p1")
        let transcript = Transcript(lines: fixture.lines)
        #expect(Enricher.match(
            content: "secret", createdAt: TranscriptFixture.milliseconds(100),
            transcript: transcript, now: TranscriptFixture.base.addingTimeInterval(110)) == nil)
        let failed = Enricher.match(
            content: "secret", createdAt: TranscriptFixture.milliseconds(100),
            transcript: transcript, now: TranscriptFixture.base.addingTimeInterval(100 + 11 * 60))
        #expect(failed?.state == .failed)
        #expect(failed?.toolUseId == nil)
        #expect(failed?.promptSnapshot == "fix the design doc")
    }

    @Test func doesNotReuseFinishedToolUseOfPreviousClip() {
        // Own tool_use not written yet (still running): don't bind to the previous clip's finished tool_use
        let result = Enricher.match(
            content: "world", createdAt: TranscriptFixture.milliseconds(12), transcript: transcript,
            now: TranscriptFixture.base.addingTimeInterval(13))
        #expect(result == nil)
    }

    @Test func notFoundAndYoungStaysPending() {
        let result = Enricher.match(
            content: "zzz", createdAt: TranscriptFixture.milliseconds(3), transcript: transcript, now: TranscriptFixture.base.addingTimeInterval(60))
        #expect(result == nil)
    }

    @Test func notFoundAndOlderThanTenMinutesFails() {
        let result = Enricher.match(
            content: "zzz", createdAt: TranscriptFixture.milliseconds(62), transcript: transcript,
            now: TranscriptFixture.base.addingTimeInterval(62 + 11 * 60))
        #expect(result?.state == .failed)
        #expect(result?.toolUseId == nil)
        #expect(result?.promptSnapshot == "Second request")
    }

    @Test func pbcopyFallback() {
        var fixture = TranscriptFixture()
        fixture.userPrompt("u1", parent: nil, at: 0, "copy it", promptId: "p1")
        fixture.bash("b1", parent: "u1", at: 5, id: "toolu_P", command: "printf 'abc' | pbcopy")
        let result = Enricher.match(
            content: "abc", createdAt: TranscriptFixture.milliseconds(5.2),
            transcript: Transcript(lines: fixture.lines), now: TranscriptFixture.base.addingTimeInterval(10))
        #expect(result?.toolUseId == "toolu_P")
        #expect(result?.promptSnapshot == "copy it")
    }

    @Test func brokenParentChainFallsBackToLatestPrompt() {
        var fixture = TranscriptFixture()
        fixture.userPrompt("u1", parent: nil, at: 0, "old request", promptId: "p1")
        fixture.userPrompt("u2", parent: nil, at: 30, "request after compaction", promptId: "p2")
        fixture.bash("b1", parent: "missing-row", at: 40, id: "toolu_X", command: "echo a | ap")
        let result = Enricher.match(
            content: "a", createdAt: TranscriptFixture.milliseconds(40.2),
            transcript: Transcript(lines: fixture.lines), now: TranscriptFixture.base.addingTimeInterval(50))
        #expect(result?.toolUseId == "toolu_X")
        #expect(result?.promptSnapshot == "request after compaction")
    }
}

@Suite struct EnrichPendingTests {
    @Test func enrichesPendingClipsFromTranscriptFile() throws {
        let store = try makeTemporaryStore()
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("ap-projects-\(UUID().uuidString)")
        let projectDirectory = projects.appendingPathComponent("-work-ap")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcriptURL = projectDirectory.appendingPathComponent("session-1.jsonl")
        try TranscriptFixture.standard().lines.joined(separator: "\n").appending("\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        // An unrelated, empty subagent transcript (under the same-named directory)
        let subagents = projectDirectory.appendingPathComponent("session-1/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try "".write(to: subagents.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)

        let first = try store.record(
            content: "Hello team,\nhere is the body\n", label: "Slack", concealed: false, uuid: "1",
            context: claudeContext, now: TranscriptFixture.base.addingTimeInterval(10.5))
        let second = try store.record(
            content: "hello\n", label: nil, concealed: false, uuid: "2",
            context: claudeContext, now: TranscriptFixture.base.addingTimeInterval(70.3))
        let third = try store.record(
            content: "still running", label: nil, concealed: false, uuid: "3",
            context: claudeContext, now: TranscriptFixture.base.addingTimeInterval(72))

        let updated = try Enricher.enrichPending(
            store: store, projectsDirectory: projects, now: TranscriptFixture.base.addingTimeInterval(80))
        #expect(updated == 2)

        #expect(try store.clip(id: first.id!)?.toolUseId == "toolu_A")
        #expect(try store.clip(id: first.id!)?.enrichState == "done")
        #expect(try store.clip(id: second.id!)?.toolUseId == "toolu_C")
        #expect(try store.clip(id: third.id!)?.enrichState == "pending")

        let session = try store.sessions(ids: ["session-1"])["session-1"]
        #expect(session?.title == "New title")
        #expect(session?.firstPrompt == "First request: write the Slack reply")
        #expect(session?.transcriptPath == transcriptURL.path)
        #expect(session?.repository == "sadayuki-matsuno/ap")
    }

    @Test func missingTranscriptFailsAfterTenMinutes() throws {
        let store = try makeTemporaryStore()
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("ap-empty-\(UUID().uuidString)")
        let clip = try store.record(
            content: "x", label: nil, concealed: false, uuid: "1", context: claudeContext,
            now: TranscriptFixture.base)
        _ = try Enricher.enrichPending(store: store, projectsDirectory: projects, now: TranscriptFixture.base.addingTimeInterval(60))
        #expect(try store.clip(id: clip.id!)?.enrichState == "pending")
        _ = try Enricher.enrichPending(store: store, projectsDirectory: projects, now: TranscriptFixture.base.addingTimeInterval(11 * 60))
        #expect(try store.clip(id: clip.id!)?.enrichState == "failed")
    }
}

@Suite struct EnricherMultipleCopyTests {
    /// Two parallel Bash calls in one turn, each piping to ap
    static func parallelFixture() -> TranscriptFixture {
        var fixture = TranscriptFixture()
        fixture.userPrompt("u1", parent: nil, at: 0, "copy two things", promptId: "p1")
        fixture.bash("b1", parent: "u1", at: 100, id: "toolu_P1", command: "echo alpha | ap")
        fixture.bash("b2", parent: "b1", at: 100.2, id: "toolu_P2", command: "echo bravo | ap")
        fixture.toolResult("r1", parent: "b2", at: 103, toolUseId: "toolu_P1", promptId: "p1")
        fixture.toolResult("r2", parent: "r1", at: 103, toolUseId: "toolu_P2", promptId: "p1")
        return fixture
    }

    @Test func parallelToolUsesEachMatchTheirOwnCall() {
        let transcript = Transcript(lines: Self.parallelFixture().lines)
        let now = TranscriptFixture.base.addingTimeInterval(110)
        let first = Enricher.match(content: "alpha\n", createdAt: TranscriptFixture.milliseconds(100.5), transcript: transcript, now: now)
        let second = Enricher.match(content: "bravo\n", createdAt: TranscriptFixture.milliseconds(100.6), transcript: transcript, now: now)
        #expect(first?.toolUseId == "toolu_P1")
        #expect(second?.toolUseId == "toolu_P2")
    }

    @Test func parallelToolUsesWithoutContentMatchPickClosestStart() {
        let transcript = Transcript(lines: Self.parallelFixture().lines)
        let result = Enricher.match(
            content: "x", createdAt: TranscriptFixture.milliseconds(101), transcript: transcript,
            now: TranscriptFixture.base.addingTimeInterval(110))
        #expect(result?.toolUseId == "toolu_P2")
    }

    @Test func oneCommandWithTwoApInvocationsMatchesBothClips() throws {
        var fixture = TranscriptFixture()
        fixture.userPrompt("u1", parent: nil, at: 0, "copy a and b", promptId: "p1")
        fixture.bash("b1", parent: "u1", at: 10, id: "toolu_AB", command: "echo a | ap; echo b | ap")
        fixture.toolResult("r1", parent: "b1", at: 12, toolUseId: "toolu_AB", promptId: "p1")

        let store = try makeTemporaryStore()
        let projects = try writeProjects(main: fixture.lines)
        let first = try store.record(content: "a\n", label: nil, concealed: false, uuid: "1", context: claudeContext,
                                     now: TranscriptFixture.base.addingTimeInterval(10.5))
        let second = try store.record(content: "b\n", label: nil, concealed: false, uuid: "2", context: claudeContext,
                                      now: TranscriptFixture.base.addingTimeInterval(11))
        let updated = try Enricher.enrichPending(store: store, projectsDirectory: projects, now: TranscriptFixture.base.addingTimeInterval(20))
        #expect(updated == 2)
        #expect(try store.clip(id: first.id!)?.toolUseId == "toolu_AB")
        #expect(try store.clip(id: second.id!)?.toolUseId == "toolu_AB")
    }
}

/// Writes projects/-work-ap/session-1.jsonl and, if given, session-1/subagents/agent-<id>.jsonl / .meta.json
func writeProjects(main: [String]?, subagents: [(agentId: String, lines: [String], meta: String?)] = []) throws -> URL {
    let projects = FileManager.default.temporaryDirectory.appendingPathComponent("ap-projects-\(UUID().uuidString)")
    let projectDirectory = projects.appendingPathComponent("-work-ap")
    try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    if let main {
        try (main.joined(separator: "\n") + "\n")
            .write(to: projectDirectory.appendingPathComponent("session-1.jsonl"), atomically: true, encoding: .utf8)
    }
    let subagentDirectory = projectDirectory.appendingPathComponent("session-1/subagents")
    try FileManager.default.createDirectory(at: subagentDirectory, withIntermediateDirectories: true)
    for subagent in subagents {
        try (subagent.lines.joined(separator: "\n") + "\n").write(
            to: subagentDirectory.appendingPathComponent("agent-\(subagent.agentId).jsonl"), atomically: true, encoding: .utf8)
        // Like real files, modified at or after the time the tool_use was written (fixture time)
        try FileManager.default.setAttributes(
            [.modificationDate: TranscriptFixture.base.addingTimeInterval(60)],
            ofItemAtPath: subagentDirectory.appendingPathComponent("agent-\(subagent.agentId).jsonl").path)
        if let meta = subagent.meta {
            try meta.write(to: subagentDirectory.appendingPathComponent("agent-\(subagent.agentId).meta.json"),
                           atomically: true, encoding: .utf8)
        }
    }
    return projects
}

@Suite struct SubagentEnrichTests {
    static func mainFixture() -> TranscriptFixture {
        var fixture = TranscriptFixture()
        fixture.userPrompt("u1", parent: nil, at: 0, "request to the parent session", promptId: "p1")
        fixture.text("x1", parent: "u1", at: 2, "Delegating to a subagent.")
        fixture.bash("b1", parent: "x1", at: 3, id: "toolu_SPAWN", command: "ls")
        fixture.toolResult("r1", parent: "b1", at: 4, toolUseId: "toolu_SPAWN", promptId: "p1")
        fixture.aiTitle("Parent title")
        return fixture
    }

    static func subagentFixture() -> TranscriptFixture {
        var fixture = TranscriptFixture()
        fixture.userPrompt("s1", parent: nil, at: 5, "Task for the subagent: implement the CLI and report back.", promptId: "sp1")
        fixture.text("s2", parent: "s1", at: 40, "Copying the result.")
        fixture.bash("s3", parent: "s2", at: 50, id: "toolu_SUB", command: "echo sub-result | ap")
        fixture.toolResult("s4", parent: "s3", at: 52, toolUseId: "toolu_SUB", promptId: "sp1")
        return fixture
    }

    @Test func resolvesCopyMadeInsideSubagent() throws {
        let store = try makeTemporaryStore()
        let projects = try writeProjects(
            main: Self.mainFixture().lines,
            subagents: [
                (agentId: "other", lines: TranscriptFixture().lines, meta: nil),
                (agentId: "abc", lines: Self.subagentFixture().lines,
                 meta: #"{"agentType":"general-purpose","description":"Implement X"}"#),
            ])
        let clip = try store.record(content: "sub-result\n", label: nil, concealed: false, uuid: "1",
                                    context: claudeContext, now: TranscriptFixture.base.addingTimeInterval(51))
        let updated = try Enricher.enrichPending(store: store, projectsDirectory: projects, now: TranscriptFixture.base.addingTimeInterval(60))
        #expect(updated == 1)

        let enriched = try #require(try store.clip(id: clip.id!))
        #expect(enriched.enrichState == "done")
        #expect(enriched.toolUseId == "toolu_SUB")
        #expect(enriched.sessionId == "session-1")
        #expect(enriched.promptSnapshot == "request to the parent session")
        #expect(enriched.subagent == "Implement X")
        let context = try #require(enriched.contextSnapshot)
        #expect(context.contains("Implement X"))
        #expect(context.contains("Task for the subagent"))
        #expect(context.contains("Copying the result."))
        #expect(try store.sessions(ids: ["session-1"])["session-1"]?.title == "Parent title")
    }

    @Test func subagentWithoutMetaUsesTaskPrompt() throws {
        let store = try makeTemporaryStore()
        let projects = try writeProjects(main: nil, subagents: [(agentId: "abc", lines: Self.subagentFixture().lines, meta: nil)])
        let clip = try store.record(content: "sub-result\n", label: nil, concealed: false, uuid: "1",
                                    context: claudeContext, now: TranscriptFixture.base.addingTimeInterval(51))
        try Enricher.enrichPending(store: store, projectsDirectory: projects, now: TranscriptFixture.base.addingTimeInterval(60))
        let enriched = try #require(try store.clip(id: clip.id!))
        #expect(enriched.toolUseId == "toolu_SUB")
        #expect(enriched.subagent == "agent-abc")
        #expect(enriched.contextSnapshot?.contains("Task for the subagent") == true)
    }
}
