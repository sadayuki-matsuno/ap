import Foundation

/// The subset of a Claude Code transcript (~/.claude/projects/*/<session_id>.jsonl) that enrich needs.
/// Lines are streamed one at a time; the full content is never held in memory.
public struct Transcript: Sendable {
    public struct ToolUse: Sendable, Equatable {
        public let id: String
        public let command: String
        /// When the tool_use was generated (before the command ran). Epoch milliseconds
        public let timestamp: Int64
        let rowUuid: String
    }

    enum RowKind: Sendable {
        case prompt(String)
        case otherUser
        case assistant(text: String?)
        case other
    }

    struct Row: Sendable {
        let parentUuid: String?
        let kind: RowKind
    }

    static let maxSnapshotLength = 4000

    public private(set) var toolUses: [ToolUse] = []
    public private(set) var firstPrompt: String?
    public private(set) var cwd: String?
    /// The last gitBranch seen on a row (the session's current branch)
    public private(set) var gitBranch: String?
    /// tool_use_id -> timestamp of its tool_result row (when the command finished)
    public private(set) var toolResultTimestamps: [String: Int64] = [:]
    var aiTitle: String?
    var customTitle: String?
    var rows: [String: Row] = [:]
    var prompts: [(timestamp: Int64, text: String)] = []

    /// The custom-title (user-assigned name) if any, otherwise the last ai-title
    public var title: String? { customTitle ?? aiTitle }

    public init(lines: some Sequence<String>) {
        let timestampParser = TimestampParser()
        for line in lines { consume(Data(line.utf8), timestampParser) }
    }

    public init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        let timestampParser = TimestampParser()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                consume(buffer[lineStart..<newline], timestampParser)
                lineStart = buffer.index(after: newline)
            }
            buffer = Data(buffer[lineStart...])
        }
        if !buffer.isEmpty { consume(buffer, timestampParser) }
    }

    mutating func consume(_ line: Data, _ timestampParser: TimestampParser) {
        guard !line.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "ai-title":
            if let title = object["aiTitle"] as? String, !title.isEmpty { aiTitle = title }
            return
        case "custom-title":
            // The field name is unverified, so try the candidates in order
            if let title = (object["customTitle"] ?? object["title"] ?? object["name"]) as? String, !title.isEmpty {
                customTitle = title
            }
            return
        default:
            break
        }

        guard let uuid = object["uuid"] as? String else { return }
        let parentUuid = object["parentUuid"] as? String
        let timestamp = (object["timestamp"] as? String).flatMap(timestampParser.parse) ?? 0
        if cwd == nil, let rowCwd = object["cwd"] as? String { cwd = rowCwd }
        if let rowBranch = object["gitBranch"] as? String, !rowBranch.isEmpty { gitBranch = rowBranch }
        let message = object["message"] as? [String: Any]

        switch type {
        case "user":
            if let prompt = Self.promptText(object: object, message: message) {
                let truncated = String(prompt.prefix(Self.maxSnapshotLength))
                rows[uuid] = Row(parentUuid: parentUuid, kind: .prompt(truncated))
                prompts.append((timestamp, truncated))
                if firstPrompt == nil { firstPrompt = truncated }
            } else {
                for block in message?["content"] as? [[String: Any]] ?? []
                where block["type"] as? String == "tool_result" {
                    if let toolUseId = block["tool_use_id"] as? String { toolResultTimestamps[toolUseId] = timestamp }
                }
                rows[uuid] = Row(parentUuid: parentUuid, kind: .otherUser)
            }
        case "assistant":
            var texts: [String] = []
            for block in message?["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { texts.append(text) }
                case "tool_use":
                    if block["name"] as? String == "Bash", let id = block["id"] as? String,
                       let command = (block["input"] as? [String: Any])?["command"] as? String {
                        toolUses.append(ToolUse(id: id, command: command, timestamp: timestamp, rowUuid: uuid))
                    }
                default:
                    break
                }
            }
            let text = texts.isEmpty ? nil : String(texts.joined(separator: "\n\n").prefix(Self.maxSnapshotLength))
            rows[uuid] = Row(parentUuid: parentUuid, kind: .assistant(text: text))
        default:
            rows[uuid] = Row(parentUuid: parentUuid, kind: .other)
        }
    }

    /// Returns the text if this is a prompt the human typed. Excludes tool_result, meta rows and tag-wrapped text injected by the harness
    static func promptText(object: [String: Any], message: [String: Any]?) -> String? {
        if object["isMeta"] as? Bool == true || object["toolUseResult"] != nil { return nil }
        let text: String
        if let content = message?["content"] as? String {
            text = content
        } else if let blocks = message?["content"] as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("<") || trimmed.hasPrefix("[Request interrupted") { return nil }
        return trimmed
    }

    /// The first prompt found by walking parentUuid back from the tool_use row. If the chain is broken (e.g. compaction), the latest prompt by time
    func prompt(for toolUse: ToolUse) -> String? {
        var current = rows[toolUse.rowUuid]?.parentUuid
        var steps = 0
        while let id = current, let row = rows[id], steps < 100_000 {
            if case .prompt(let text) = row.kind { return text }
            current = row.parentUuid
            steps += 1
        }
        return latestPrompt(atOrBefore: toolUse.timestamp)
    }

    /// The assistant text preceding the tool_use in the same turn (walks back until a user row)
    func context(for toolUse: ToolUse) -> String? {
        var texts: [String] = []
        if case .assistant(let text?)? = rows[toolUse.rowUuid]?.kind { texts.append(text) }
        var current = rows[toolUse.rowUuid]?.parentUuid
        var steps = 0
        loop: while let id = current, let row = rows[id], steps < 100_000 {
            switch row.kind {
            case .prompt, .otherUser:
                break loop
            case .assistant(let text):
                if let text { texts.insert(text, at: 0) }
            case .other:
                break
            }
            current = row.parentUuid
            steps += 1
        }
        guard !texts.isEmpty else { return nil }
        let joined = texts.joined(separator: "\n\n")
        return joined.count > 2000 ? String(joined.suffix(2000)) : joined
    }

    func latestPrompt(atOrBefore timestamp: Int64) -> String? {
        prompts.last { $0.timestamp <= timestamp }?.text
    }
}

/// Converts transcript timestamps (ISO8601, with or without fractional seconds) to epoch milliseconds. Formatters are expensive, so one is reused per read
final class TimestampParser {
    let fractional = ISO8601DateFormatter()
    let plain = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain.formatOptions = [.withInternetDateTime]
    }

    func parse(_ text: String) -> Int64? {
        (fractional.date(from: text) ?? plain.date(from: text))?.epochMilliseconds
    }
}
