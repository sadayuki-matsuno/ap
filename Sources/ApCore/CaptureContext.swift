import Foundation

/// Origin metadata available at copy time from the environment, cwd and git
public struct CaptureContext: Sendable, Equatable {
    public var sessionId: String?
    public var agent: String
    public var cwd: String?
    public var gitBranch: String?
    public var repository: String?
    public var terminal: String?

    public init(sessionId: String?, agent: String, cwd: String?, gitBranch: String?, repository: String?, terminal: String?) {
        self.sessionId = sessionId
        self.agent = agent
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.repository = repository
        self.terminal = terminal
    }

    /// Claude Code's Bash tool subprocesses get CLAUDE_CODE_SESSION_ID / CLAUDECODE=1 / AI_AGENT (observed on 2.1.288)
    public static func fromEnvironment(_ environment: [String: String], cwd: String, runGit: Bool = true) -> CaptureContext {
        let sessionId = environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }

        let agent: String
        if let aiAgent = environment["AI_AGENT"], !aiAgent.isEmpty {
            // e.g. claude-code_2-1-288_agent -> claude-code
            agent = String(aiAgent.split(separator: "_").first ?? Substring(aiAgent))
        } else if environment["CLAUDECODE"] == "1" {
            agent = "claude-code"
        } else {
            agent = "human"
        }

        let terminal: String?
        if let zellijSession = environment["ZELLIJ_SESSION_NAME"], !zellijSession.isEmpty {
            terminal = "zellij:\(zellijSession)" + (environment["ZELLIJ_PANE_ID"].map { "#\($0)" } ?? "")
        } else {
            terminal = environment["TERM_PROGRAM"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
        }

        let location = runGit ? resolveLocation(cwd: cwd) : nil
        let gitBranch = location?.gitBranch
        let repository = location?.repository

        return CaptureContext(
            sessionId: sessionId, agent: agent, cwd: cwd, gitBranch: gitBranch, repository: repository, terminal: terminal)
    }

    /// Repository display name and branch of a directory
    public struct Location: Sendable, Equatable {
        /// owner/name from the origin remote, or the top-level directory name when there is no origin
        public var repository: String?
        public var gitBranch: String?

        public init(repository: String?, gitBranch: String?) {
            self.repository = repository
            self.gitBranch = gitBranch
        }
    }

    enum GitOutcome: Equatable {
        case success(String?)
        /// git ran and exited non-zero (not a repository, no such remote, detached HEAD, ...)
        case failure
        /// git could not be run or timed out; nothing is known
        case unavailable

        var output: String? {
            if case .success(let text) = self { return text }
            return nil
        }
    }

    /// Time budget for all git calls of one resolveLocation. git answers in about 10 ms on an idle Mac (measured
    /// 2026-10-04), but on a loaded CI runner a call took over 0.5 s, and a timeout means "couldn't tell", which is
    /// not the same as "not a repository". Only a git that hangs costs the whole budget; a quick answer returns at once
    static let locationTimeout: TimeInterval = 2

    /// nil when git could not answer (timeout, launch failure), so callers can keep what they had.
    /// A directory outside any repository (git exits non-zero) resolves to an empty Location, however long git took
    public static func resolveLocation(cwd: String) -> Location? {
        let deadline = DispatchTime.now() + locationTimeout
        let topLevel = git(["rev-parse", "--show-toplevel"], cwd: cwd, deadline: deadline)
        switch topLevel {
        case .unavailable: return nil
        case .failure: return Location(repository: nil, gitBranch: nil)
        case .success: break
        }
        let remote = git(["remote", "get-url", "origin"], cwd: cwd, deadline: deadline)
        // symbolic-ref also names an unborn branch (a repo with no commits); a detached HEAD gives nil
        let branch = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd: cwd, deadline: deadline)
        if case .unavailable = remote { return nil }
        if case .unavailable = branch { return nil }
        let repository = remote.output.flatMap(Self.repository(fromRemoteURL:))
            ?? topLevel.output.map { URL(fileURLWithPath: $0).lastPathComponent }
        return Location(repository: repository, gitBranch: branch.output)
    }

    /// Runs git synchronously until `deadline` (never blocks recording for long)
    static func git(_ arguments: [String], cwd: String, deadline: DispatchTime) -> GitOutcome {
        run("/usr/bin/git", ["-C", cwd] + arguments, deadline: deadline)
    }

    /// Runs a command and classifies it by exit status: 0 is success (trimmed stdout), non-zero is failure. Only a
    /// launch failure or still running at `deadline` is unavailable. (git gets the directory through -C, so a cwd that
    /// no longer exists is a git failure, i.e. an empty Location, not a launch failure)
    static func run(_ executable: String, _ arguments: [String], deadline: DispatchTime) -> GitOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .unavailable }
        // A process that exits right at the deadline still counts by its exit status
        if finished.wait(timeout: deadline) == .timedOut, process.isRunning {
            process.terminate()
            return .unavailable
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .failure }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(text.isEmpty ? nil : text)
    }

    /// Extracts owner/name from the origin URL
    public static func repository(fromRemoteURL remoteURL: String) -> String? {
        var trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        let components = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard components.count >= 2 else { return nil }
        return components.suffix(2).joined(separator: "/")
    }
}
