import Foundation
import GRDB

public enum EnrichState: String, Codable, Sendable {
    case pending, done, failed
}

/// Custom pasteboard types. Shared by the CLI and the (upcoming) menu bar app.
public enum PasteboardTypes {
    /// The uuid of the written clip. Used to tell which clip is currently on the pasteboard
    public static let clipId = "dev.ap.clip-id"
    /// Convention type that asks clipboard managers not to keep the item (nspasteboard.org)
    public static let concealed = "org.nspasteboard.ConcealedType"
}

/// All times are stored as Unix epoch milliseconds (INTEGER)
public struct Clip: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "clips"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var uuid: String
    public var content: String
    public var contentHash: String
    public var contentKind: String?
    public var label: String?
    public var sessionId: String?
    public var agent: String
    public var cwd: String?
    public var gitBranch: String?
    /// owner/name of the repository the copy was made in (may differ from the session's)
    public var repository: String?
    public var terminal: String?
    public var toolUseId: String?
    public var promptSnapshot: String?
    public var contextSnapshot: String?
    /// For copies made inside a subagent: that subagent's description (meta description, or agent-<id>)
    public var subagent: String?
    public var enrichState: String
    public var pinned: Bool
    public var concealed: Bool
    public var pasteCount: Int
    public var createdAt: Int64
    public var lastPastedAt: Int64?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Session: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sessions"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var sessionId: String
    public var agent: String
    public var title: String?
    public var firstPrompt: String?
    public var cwd: String?
    public var repository: String?
    public var gitBranch: String?
    public var transcriptPath: String?
    public var terminal: String?
    public var firstSeenAt: Int64
    public var lastSeenAt: Int64
}

extension Date {
    public var epochMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
