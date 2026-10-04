import Foundation
import Testing
@testable import ApCore

@Suite struct CaptureContextTests {
    @Test func claudeCodeFromAiAgent() {
        let context = CaptureContext.fromEnvironment(
            ["CLAUDE_CODE_SESSION_ID": "s-1", "AI_AGENT": "claude-code_2-1-288_agent", "TERM_PROGRAM": "ghostty"],
            cwd: "/tmp", runGit: false)
        #expect(context.sessionId == "s-1")
        #expect(context.agent == "claude-code")
        #expect(context.terminal == "ghostty")
        #expect(context.cwd == "/tmp")
    }

    @Test func claudeCodeFromClaudecodeFlag() {
        let context = CaptureContext.fromEnvironment(["CLAUDECODE": "1"], cwd: "/tmp", runGit: false)
        #expect(context.agent == "claude-code")
        #expect(context.sessionId == nil)
    }

    @Test func humanWhenNoAgentEnv() {
        let context = CaptureContext.fromEnvironment([:], cwd: "/tmp", runGit: false)
        #expect(context.agent == "human")
        #expect(context.terminal == nil)
    }

    @Test func zellijTerminal() {
        let context = CaptureContext.fromEnvironment(
            ["TERM_PROGRAM": "ghostty", "ZELLIJ_SESSION_NAME": "verdant-donkey", "ZELLIJ_PANE_ID": "71"],
            cwd: "/tmp", runGit: false)
        #expect(context.terminal == "zellij:verdant-donkey#71")
    }

    @Test(arguments: [
        ("git@github.com:omeroid/genome.git", "omeroid/genome"),
        ("https://github.com/sadayuki-matsuno/ap.git", "sadayuki-matsuno/ap"),
        ("https://github.com/sadayuki-matsuno/ap", "sadayuki-matsuno/ap"),
        ("ssh://git@github.com/owner/name.git", "owner/name"),
        ("https://user:token@example.com/group/sub/name.git", "sub/name"),
    ])
    func repositoryFromRemote(_ remote: String, _ expected: String) {
        #expect(CaptureContext.repository(fromRemoteURL: remote) == expected)
    }
}

@Suite struct GitRunnerTests {
    /// A stand-in for git that answers late: exit status decides, not timing
    @Test func slowNonZeroExitIsAFailureNotUnavailable() {
        let outcome = CaptureContext.run(
            "/bin/sh", ["-c", "sleep 0.7; echo 'fatal: not a git repository' >&2; exit 128"],
            deadline: .now() + 5)
        #expect(outcome == .failure)
    }

    @Test func slowSuccessIsReported() {
        let outcome = CaptureContext.run("/bin/sh", ["-c", "sleep 0.7; echo main"], deadline: .now() + 5)
        #expect(outcome == .success("main"))
    }

    @Test func onlyARealTimeoutIsUnavailable() {
        let started = Date()
        let outcome = CaptureContext.run("/bin/sh", ["-c", "sleep 5"], deadline: .now() + 0.3)
        #expect(outcome == .unavailable)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func spawnFailureIsUnavailable() {
        #expect(CaptureContext.run("/nonexistent/git", [], deadline: .now() + 1) == .unavailable)
    }

    /// Measured: git answers in about 10 ms on an idle Mac, but a loaded CI runner took over 0.5 s
    @Test func locationBudgetToleratesSlowMachines() {
        #expect(CaptureContext.locationTimeout >= 2)
    }
}

// Spawns git processes; serialized so a loaded CI runner doesn't run them all at once
@Suite(.serialized) struct RepositoryLocationTests {
    func makeRepository(remote: String?) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ap-repo-\(UUID().uuidString.prefix(8))").appendingPathComponent("myrepo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var commands = [["init", "-q", "-b", "main"]]
        if let remote { commands.append(["remote", "add", "origin", remote]) }
        for arguments in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path] + arguments
            try process.run()
            process.waitUntilExit()
        }
        return directory.path
    }

    @Test func fallsBackToTopLevelDirectoryNameWithoutRemote() throws {
        let path = try makeRepository(remote: nil)
        let subdirectory = path + "/sub"
        try FileManager.default.createDirectory(atPath: subdirectory, withIntermediateDirectories: true)
        let location = try #require(CaptureContext.resolveLocation(cwd: subdirectory))
        #expect(location.repository == "myrepo")
        #expect(location.gitBranch == "main")
        let context = CaptureContext.fromEnvironment([:], cwd: subdirectory)
        #expect(context.repository == "myrepo")
        #expect(context.gitBranch == "main")
    }

    @Test func usesOriginWhenPresent() throws {
        let path = try makeRepository(remote: "git@github.com:owner/name.git")
        #expect(CaptureContext.resolveLocation(cwd: path)?.repository == "owner/name")
    }

    @Test func nonRepositoryResolvesToEmptyLocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ap-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let location = try #require(CaptureContext.resolveLocation(cwd: directory.path))
        #expect(location.repository == nil)
        #expect(location.gitBranch == nil)
    }

    /// A worktree deleted since the copy: git says so (non-zero exit), which is an empty location, not "couldn't tell"
    @Test func missingDirectoryResolvesToEmptyLocation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ap-gone-\(UUID().uuidString)").path
        #expect(CaptureContext.resolveLocation(cwd: path) == CaptureContext.Location(repository: nil, gitBranch: nil))
    }
}
