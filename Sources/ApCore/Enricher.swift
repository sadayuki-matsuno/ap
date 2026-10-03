import Foundation

public struct EnrichmentResult: Sendable, Equatable {
    public var state: EnrichState
    public var toolUseId: String?
    public var promptSnapshot: String?
    public var contextSnapshot: String?
}

/// Fills in context (prompt, preceding assistant text, tool_use_id, session title) for pending clips from the transcript, after the fact.
/// The running Bash command's tool_use row is written to the transcript only after the command exits (observed on 2.1.288), so this cannot happen at copy time.
public enum Enricher {
    /// Clips older than this whose tool_use cannot be found are marked failed
    public static let giveUpAfter: TimeInterval = 10 * 60
    /// A tool_use is generated before the command runs, so it precedes created_at; allow only for clock jitter
    static let slackMilliseconds: Int64 = 1000

    static let nonCopySubcommands: Set<String> = [
        "list", "paste", "pin", "unpin", "enrich", "prune", "doctor", "pick", "open", "help", "--help", "-h", "--version",
    ]
    // `ap` in command position (line start or right after | ; & ( ), optionally preceded by `env` and/or
    // NAME=value assignments (AP_DB_PATH=/p ap ...). A path prefix (.build/release/ap) is allowed
    static let apInvocation = try! NSRegularExpression(
        pattern: #"(?:^|[|;&(])\s*(?:env\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|[^\s|;&()'"]*)\s+)*(?:[^\s|;&()]*/)?ap(?=$|[\s|;&)])[ \t]*([^\s|;&()]*)"#,
        options: [.anchorsMatchLines])

    /// AP_CLAUDE_PROJECTS_DIR if set, otherwise ~/.claude/projects
    public static func defaultProjectsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["AP_CLAUDE_PROJECTS_DIR"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Whether the command copies via `| ap` / `ap copy` etc., or via pbcopy as a fallback
    public static func invokesCopy(_ command: String) -> Bool {
        invokesAp(command) || command.range(of: #"(^|[\s|;&(])pbcopy($|[\s|;&)])"#, options: .regularExpression) != nil
    }

    static func invokesAp(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return apInvocation.matches(in: command, range: range).contains { match in
            guard let argumentRange = Range(match.range(at: 1), in: command) else { return true }
            return !nonCopySubcommands.contains(String(command[argumentRange]))
        }
    }

    /// Finds the Bash tool_use that produced the clip.
    /// Candidates are ap / pbcopy invocations generated before created_at that have not finished yet or finished after created_at.
    /// This rules out long-finished commands (e.g. a heredoc that merely mentions `| ap`).
    /// A candidate whose command contains the clip's first line wins; otherwise the one generated closest to created_at.
    /// With parallel calls or several `ap` invocations in one command, multiple clips may map to the same tool_use
    static func findToolUse(content: String, createdAt: Int64, transcript: Transcript) -> Transcript.ToolUse? {
        let candidates = transcript.toolUses.filter { toolUse in
            toolUse.timestamp <= createdAt + slackMilliseconds && invokesCopy(toolUse.command)
                && (transcript.toolResultTimestamps[toolUse.id].map { $0 >= createdAt } ?? true)
        }
        // Stable sort by generation time in transcript order and take the last (= closest to created_at)
        func closest(_ toolUses: [Transcript.ToolUse]) -> Transcript.ToolUse? {
            toolUses.enumerated().max { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }?.element
        }
        let firstLine = content.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let firstLine, firstLine.count >= 4,
           let matched = closest(candidates.filter { $0.command.contains(firstLine) }) {
            return matched
        }
        return closest(candidates.filter { invokesAp($0.command) }) ?? closest(candidates)
    }

    /// nil when nothing was found yet and it is still worth waiting (stays pending)
    public static func match(content: String, createdAt: Int64, transcript: Transcript, now: Date) -> EnrichmentResult? {
        if let toolUse = findToolUse(content: content, createdAt: createdAt, transcript: transcript) {
            return EnrichmentResult(
                state: .done, toolUseId: toolUse.id,
                promptSnapshot: transcript.prompt(for: toolUse), contextSnapshot: transcript.context(for: toolUse))
        }
        if now.epochMilliseconds - createdAt > Int64(giveUpAfter * 1000) {
            return EnrichmentResult(
                state: .failed, toolUseId: nil,
                promptSnapshot: transcript.latestPrompt(atOrBefore: createdAt), contextSnapshot: nil)
        }
        return nil
    }

    /// `<projects>/*/<session_id>.jsonl` (the parent session's transcript)
    public static func transcriptURL(sessionId: String, projectsDirectory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let projectNames = try? fileManager.contentsOfDirectory(atPath: projectsDirectory.path) else { return nil }
        return projectNames
            .map { projectsDirectory.appendingPathComponent($0).appendingPathComponent("\(sessionId).jsonl") }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    struct SubagentTranscript {
        let agentId: String
        let transcript: Transcript
        let agentType: String?
        let description: String?
    }

    /// `<projects>/*/<session_id>/subagents/agent-<id>.jsonl` plus the sibling `.meta.json` (agentType / description).
    /// A subagent's Bash also inherits the parent's CLAUDE_CODE_SESSION_ID, but its tool_use is written here (observed 2026-10-03).
    /// tool_use rows are written after the command exits, so files last modified before modifiedSince are skipped
    static func subagentTranscripts(sessionId: String, projectsDirectory: URL, modifiedSince: Date) -> [SubagentTranscript] {
        let fileManager = FileManager.default
        guard let projectNames = try? fileManager.contentsOfDirectory(atPath: projectsDirectory.path) else { return [] }
        var subagents: [SubagentTranscript] = []
        for projectName in projectNames {
            let directory = projectsDirectory.appendingPathComponent(projectName)
                .appendingPathComponent(sessionId).appendingPathComponent("subagents")
            guard let fileNames = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for fileName in fileNames.sorted() where fileName.hasPrefix("agent-") && fileName.hasSuffix(".jsonl") {
                let url = directory.appendingPathComponent(fileName)
                guard let modifiedAt = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      modifiedAt >= modifiedSince,
                      let transcript = try? Transcript(contentsOf: url)
                else { continue }
                let baseName = String(fileName.dropLast(".jsonl".count))
                let meta = (try? Data(contentsOf: directory.appendingPathComponent(baseName + ".meta.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                subagents.append(SubagentTranscript(
                    agentId: String(baseName.dropFirst("agent-".count)), transcript: transcript,
                    agentType: meta?["agentType"] as? String,
                    description: (meta?["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        return subagents
    }

    @discardableResult
    public static func enrichPending(
        store: ClipStore, projectsDirectory: URL, now: Date,
        resolveLocation: (String) -> CaptureContext.Location? = CaptureContext.resolveLocation
    ) throws -> Int {
        try enrich(
            clips: store.pendingClips(), store: store, projectsDirectory: projectsDirectory, now: now,
            resolveLocation: resolveLocation)
    }

    /// Returns the number of updated clips. Each session's transcript is read once (subagent transcripts only when needed)
    @discardableResult
    public static func enrich(
        clips: [Clip], store: ClipStore, projectsDirectory: URL, now: Date,
        resolveLocation: (String) -> CaptureContext.Location? = CaptureContext.resolveLocation
    ) throws -> Int {
        var updated = 0
        let clipsBySession = Dictionary(grouping: clips.filter { $0.sessionId != nil }, by: { $0.sessionId! })
        for (sessionId, sessionClips) in clipsBySession {
            let transcriptURL = transcriptURL(sessionId: sessionId, projectsDirectory: projectsDirectory)
            let transcript = transcriptURL.flatMap { try? Transcript(contentsOf: $0) }
            if let transcript, let transcriptURL {
                try store.updateSession(
                    sessionId: sessionId, title: transcript.title, firstPrompt: transcript.firstPrompt,
                    gitBranch: transcript.gitBranch, transcriptPath: transcriptURL.path)
                // The session's own directory comes from the transcript (the first copy may have run elsewhere).
                // Re-resolve when it differs or no repository is known, and commit cwd + repository + branch
                // together only when git answered; a failed resolution keeps what was there and retries next time
                let session = try store.sessions(ids: [sessionId])[sessionId]
                if let cwd = transcript.cwd, cwd != session?.cwd || session?.repository == nil,
                   let location = resolveLocation(cwd) {
                    try store.setSessionLocation(sessionId: sessionId, cwd: cwd, location: location)
                }
            }
            let earliestCreatedAt = sessionClips.map(\.createdAt).min() ?? 0
            var subagents: [SubagentTranscript]?

            for clip in sessionClips.sorted(by: { ($0.createdAt, $0.id ?? 0) < ($1.createdAt, $1.id ?? 0) }) {
                guard let clipId = clip.id else { continue }
                var result: EnrichmentResult?
                var subagentName: String?
                if let transcript,
                   let toolUse = findToolUse(content: clip.content, createdAt: clip.createdAt, transcript: transcript) {
                    result = EnrichmentResult(
                        state: .done, toolUseId: toolUse.id,
                        promptSnapshot: transcript.prompt(for: toolUse), contextSnapshot: transcript.context(for: toolUse))
                } else {
                    if subagents == nil {
                        subagents = subagentTranscripts(
                            sessionId: sessionId, projectsDirectory: projectsDirectory,
                            modifiedSince: Date(timeIntervalSince1970: Double(earliestCreatedAt - slackMilliseconds) / 1000))
                    }
                    for subagent in subagents ?? [] {
                        guard let toolUse = findToolUse(
                            content: clip.content, createdAt: clip.createdAt, transcript: subagent.transcript)
                        else { continue }
                        let name = subagent.description ?? "agent-\(subagent.agentId)"
                        // The prompt is what the human asked in the parent session; the subagent's task goes into the context
                        let context = [
                            "Subagent (\(subagent.agentType ?? "agent")): \(name)",
                            subagent.transcript.firstPrompt.map { "Task: " + String($0.prefix(300)) },
                            subagent.transcript.context(for: toolUse),
                        ].compactMap { $0 }.joined(separator: "\n\n")
                        result = EnrichmentResult(
                            state: .done, toolUseId: toolUse.id,
                            promptSnapshot: transcript?.latestPrompt(atOrBefore: clip.createdAt), contextSnapshot: context)
                        subagentName = name
                        break
                    }
                }
                if result == nil, now.epochMilliseconds - clip.createdAt > Int64(giveUpAfter * 1000) {
                    result = EnrichmentResult(
                        state: .failed, toolUseId: nil,
                        promptSnapshot: transcript?.latestPrompt(atOrBefore: clip.createdAt), contextSnapshot: nil)
                }
                guard let result else { continue }
                try store.applyEnrichment(
                    clipId: clipId, state: result.state, toolUseId: result.toolUseId,
                    promptSnapshot: result.promptSnapshot, contextSnapshot: result.contextSnapshot, subagent: subagentName)
                updated += 1
            }
        }
        return updated
    }
}
