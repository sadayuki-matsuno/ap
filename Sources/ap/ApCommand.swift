import AppKit
import ApCore
import ArgumentParser
import Foundation
import GRDB

@main
struct Ap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ap",
        abstract: "Copy to the clipboard like pbcopy, and record AI copies with where they came from",
        discussion: "When stdin is piped, plain `ap` acts as `ap copy` (e.g. echo hello | ap --label note)",
        version: apVersion,
        subcommands: [Copy.self, List.self, Paste.self, Pin.self, Unpin.self, Enrich.self, Prune.self, Doctor.self])

    @OptionGroup var copyOptions: CopyOptions

    mutating func run() throws {
        guard isatty(STDIN_FILENO) == 0 else {
            print(Ap.helpMessage())
            return
        }
        try performCopy(copyOptions)
    }
}

struct CopyOptions: ParsableArguments {
    @Option(help: "A short label for the copy (e.g. \"Slack reply\")")
    var label: String?

    @Flag(help: "Treat as sensitive: clipboard managers are asked not to keep it, and lists mask it")
    var concealed = false
}

struct Copy: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Copy stdin to the clipboard and record it (same as `... | ap`)")

    @OptionGroup var copyOptions: CopyOptions

    mutating func run() throws {
        try performCopy(copyOptions)
    }
}

/// 1. write the pasteboard (non-zero exit on failure) -> 2. record (failure only warns, exit 0) -> 3. prune expired clips (inside record)
func performCopy(_ options: CopyOptions) throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let content = String(decoding: data, as: UTF8.self)
    // Don't clear the clipboard when invoked without input (stdin is /dev/null etc.)
    guard !content.isEmpty else {
        printError("ap: input is empty; clipboard left unchanged (see ap --help)")
        return
    }
    let uuid = UUID().uuidString.lowercased()
    let concealed = options.concealed || SecretDetector.containsSecret(content)

    guard writePasteboard(content: content, uuid: uuid, concealed: concealed) else {
        printError("ap: failed to write to the clipboard")
        throw ExitCode.failure
    }
    do {
        let environment = ProcessInfo.processInfo.environment
        let store = try ClipStore(path: ClipStore.defaultPath(environment: environment))
        let context = CaptureContext.fromEnvironment(environment, cwd: FileManager.default.currentDirectoryPath)
        try store.record(
            content: content, label: options.label, concealed: concealed, uuid: uuid, context: context, now: Date())
    } catch {
        printError("ap: warning: failed to record history (the clipboard was still updated): \(error)")
    }
}

/// Writes one NSPasteboardItem holding every type. Another process can clear the pasteboard between our
/// clearContents and writeObjects (parallel `| ap` calls do exactly that), which makes writeObjects fail,
/// so retry a few times with a short backoff
func writePasteboard(content: String, uuid: String, concealed: Bool) -> Bool {
    let pasteboard = NSPasteboard.general
    // AppKit NSLogs every failed attempt to stderr ("_setData:forType: returns false"); keep that out of the
    // caller's output while retrying. Our own error message is printed after stderr is restored
    let savedStandardError = dup(STDERR_FILENO)
    let devNull = open("/dev/null", O_WRONLY)
    if savedStandardError >= 0, devNull >= 0 { dup2(devNull, STDERR_FILENO) }
    defer {
        if savedStandardError >= 0 { dup2(savedStandardError, STDERR_FILENO); close(savedStandardError) }
        if devNull >= 0 { close(devNull) }
    }
    for attempt in 0..<8 {
        if attempt > 0 { usleep(useconds_t(5_000 << min(attempt - 1, 4))) }
        let item = NSPasteboardItem()
        guard item.setString(content, forType: .string),
              item.setString(uuid, forType: NSPasteboard.PasteboardType(PasteboardTypes.clipId))
        else { return false }
        if concealed {
            _ = item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardTypes.concealed))
        }
        pasteboard.clearContents()
        if pasteboard.writeObjects([item]) { return true }
    }
    return false
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func openStore() throws -> ClipStore {
    try ClipStore(path: ClipStore.defaultPath())
}

/// Lazy enrich. The list is printed even if this fails
func enrichPendingQuietly(_ store: ClipStore) {
    do {
        try Enricher.enrichPending(store: store, projectsDirectory: Enricher.defaultProjectsDirectory(), now: Date())
    } catch {
        printError("ap: warning: enrich failed: \(error)")
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List history grouped by session (runs pending enrich first)")

    @Option(help: "Only show clips from this session ID")
    var session: String?

    @Option(help: "Maximum number of clips")
    var limit = 50

    @Flag(help: "Print JSON")
    var json = false

    mutating func run() throws {
        let store = try openStore()
        enrichPendingQuietly(store)
        let clips = try store.clips(sessionId: session, limit: limit)
        let sessions = try store.sessions(ids: Set(clips.compactMap(\.sessionId)))
        // N for `ap paste N` (omitted with --session, where positions are not global)
        let numbers: [Int64: Int] = session == nil
            ? Dictionary(uniqueKeysWithValues: clips.enumerated().compactMap { index, clip in clip.id.map { ($0, index + 1) } })
            : [:]

        if json {
            try printJSON(clips: clips, sessions: sessions, numbers: numbers)
            return
        }
        if clips.isEmpty {
            print("(no history)")
            return
        }
        for group in ClipListing.group(clips, sessions: sessions) {
            let latest = group.clips[0]
            var heading = group.session?.title ?? group.sessionId.map { "session \($0.prefix(8))" } ?? "no session (\(latest.agent))"
            if let location = group.session.flatMap(ClipListing.sessionLocation) { heading += "  \(location)" }
            heading += "  \(formatTime(latest.createdAt))"
            print("■ \(heading)")
            if let sessionId = group.sessionId { print("  session: \(sessionId)") }
            for clip in group.clips {
                let number = clip.id.flatMap { numbers[$0] }.map { String(format: "%3d.", $0) } ?? "    "
                var line = "\(number) #\(clip.id ?? 0) \(formatTime(clip.createdAt)) [\(clip.contentKind ?? "text")]"
                if let label = clip.label { line += " \"\(label)\"" }
                if clip.pinned { line += " 📌" }
                if let location = ClipListing.clipLocation(clip, session: group.session) { line += " @ \(location)" }
                if let subagent = clip.subagent { line += " <- subagent: \(subagent.prefix(40))" }
                if clip.enrichState != EnrichState.done.rawValue { line += " (\(clip.enrichState))" }
                print(line)
                print("       \(ClipListing.preview(clip, maxLength: 80))")
                if let prompt = clip.promptSnapshot {
                    print("       prompt: \(prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(70))")
                }
            }
            print("")
        }
    }

    func printJSON(clips: [Clip], sessions: [String: Session], numbers: [Int64: Int]) throws {
        struct Entry: Encodable {
            let number: Int?
            let id: Int64?
            let uuid: String
            let content: String
            let preview: String
            let contentKind: String?
            let label: String?
            let concealed: Bool
            let pinned: Bool
            let agent: String
            let cwd: String?
            let gitBranch: String?
            let repository: String?
            let terminal: String?
            let enrichState: String
            let toolUseId: String?
            let promptSnapshot: String?
            let contextSnapshot: String?
            let subagent: String?
            let pasteCount: Int
            let createdAt: String
            let session: Session?
        }
        let formatter = ISO8601DateFormatter()
        let entries = clips.map { clip in
            Entry(
                number: clip.id.flatMap { numbers[$0] }, id: clip.id, uuid: clip.uuid,
                content: clip.concealed ? "" : clip.content, preview: ClipListing.preview(clip, maxLength: 80),
                contentKind: clip.contentKind, label: clip.label, concealed: clip.concealed, pinned: clip.pinned,
                agent: clip.agent, cwd: clip.cwd, gitBranch: clip.gitBranch, repository: clip.repository,
                terminal: clip.terminal,
                enrichState: clip.enrichState, toolUseId: clip.toolUseId, promptSnapshot: clip.promptSnapshot,
                contextSnapshot: clip.contextSnapshot, subagent: clip.subagent, pasteCount: clip.pasteCount,
                createdAt: formatter.string(from: Date(timeIntervalSince1970: Double(clip.createdAt) / 1000)),
                session: clip.sessionId.flatMap { sessions[$0] })
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(entries), as: UTF8.self))
    }
}

func formatTime(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    let formatter = DateFormatter()
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM/dd HH:mm"
    return formatter.string(from: date)
}

struct Paste: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Put the Nth newest clip back on the clipboard (1 = newest)")

    @Argument(help: "Position, newest first (1 = newest)")
    var number: Int

    mutating func run() throws {
        let store = try openStore()
        guard let clip = try store.clip(nth: number), let clipId = clip.id else {
            printError("ap: no clip at position \(number)")
            throw ExitCode.failure
        }
        guard writePasteboard(content: clip.content, uuid: clip.uuid, concealed: clip.concealed) else {
            printError("ap: failed to write to the clipboard")
            throw ExitCode.failure
        }
        try store.markPasted(id: clipId, now: Date())
    }
}

struct Pin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pin a clip (kept past the retention period)")

    @Argument(help: "Clip ID (the #number in ap list)")
    var id: Int64

    mutating func run() throws {
        guard try openStore().setPinned(id: id, pinned: true) else {
            printError("ap: no clip #\(id)")
            throw ExitCode.failure
        }
    }
}

struct Unpin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unpin a clip")

    @Argument(help: "Clip ID (the #number in ap list)")
    var id: Int64

    mutating func run() throws {
        guard try openStore().setPinned(id: id, pinned: false) else {
            printError("ap: no clip #\(id)")
            throw ExitCode.failure
        }
    }
}

struct Enrich: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run (or re-run) context enrichment")

    @Argument(help: "Clip ID (omit to behave like --pending)")
    var id: Int64?

    @Flag(help: "Process all pending clips")
    var pending = false

    mutating func run() throws {
        let store = try openStore()
        let projectsDirectory = Enricher.defaultProjectsDirectory()
        let updated: Int
        if let id {
            guard let clip = try store.clip(id: id) else {
                printError("ap: no clip #\(id)")
                throw ExitCode.failure
            }
            updated = try Enricher.enrich(clips: [clip], store: store, projectsDirectory: projectsDirectory, now: Date())
        } else {
            updated = try Enricher.enrichPending(store: store, projectsDirectory: projectsDirectory, now: Date())
        }
        print("updated \(updated) clip(s)")
    }
}

struct Prune: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete clips past the retention period (pinned clips are kept)")

    @Option(help: "Retention period (e.g. 24h, 90m, 7d, 3600s)")
    var olderThan = "24h"

    mutating func run() throws {
        guard let interval = ClipStore.retentionInterval(from: olderThan) else {
            throw ValidationError("--older-than must be a positive duration such as 24h, 90m, 7d or 3600s")
        }
        let deleted = try openStore().prune(olderThan: interval, now: Date())
        print("deleted \(deleted) clip(s)")
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Diagnose the database")

    mutating func run() throws {
        let store = try openStore()
        print("DB: \(store.path)")
        print("transcript: \(Enricher.defaultProjectsDirectory().path)")
        let counts = try store.countsByEnrichState()
        print("clips: " + ["pending", "done", "failed"].map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " "))
        let (sqliteVersion, journalMode) = try store.dbPool.read { db in
            (try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "?",
             try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "?")
        }
        print("SQLite: \(sqliteVersion) (journal_mode=\(journalMode))")
        let trigramWorks: Bool
        do {
            let probe = try DatabaseQueue()
            trigramWorks = try probe.write { db in
                try db.execute(sql: "CREATE VIRTUAL TABLE probe USING fts5(body, tokenize='trigram')")
                // CJK text ("Japanese search" in Japanese) to confirm trigram matching works beyond ASCII
                try db.execute(sql: "INSERT INTO probe(body) VALUES (?)", arguments: ["\u{65E5}\u{672C}\u{8A9E}\u{306E}\u{691C}\u{7D22}"])
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe WHERE probe MATCH ?", arguments: ["\"\u{65E5}\u{672C}\u{8A9E}\""]) == 1
            }
        } catch {
            trigramWorks = false
        }
        print("FTS5 trigram: \(trigramWorks ? "OK" : "NG")")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? Int)
            .map { String($0, radix: 8) } ?? "?"
        print("file mode: \(permissions)")
    }
}
