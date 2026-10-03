import CryptoKit
import Foundation
import GRDB

/// Reads and writes ap.db (SQLite / WAL). Shared by the CLI and the menu bar app
public final class ClipStore: Sendable {
    public static let retention: TimeInterval = 24 * 3600

    public let path: String
    public let dbPool: DatabasePool

    /// AP_DB_PATH if set, otherwise ~/Library/Application Support/ap/ap.db
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["AP_DB_PATH"], !path.isEmpty { return path }
        let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ap", isDirectory: true)
        return applicationSupport.appendingPathComponent("ap.db").path
    }

    public init(path: String) throws {
        self.path = path
        let fileManager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: directory) {
            try fileManager.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // SQLite creates -wal / -shm with the main file's mode, so create the file as 600 before opening.
        // O_EXCL keeps a concurrent first run from replacing an existing file; EEXIST means it already exists
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if descriptor >= 0 {
            close(descriptor)
        } else if errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var configuration = Configuration()
        // Wait on locks so concurrent copies don't drop writes
        configuration.busyMode = .timeout(5)
        // Parallel `| ap` processes on a new database would all see "not migrated" and race on CREATE TABLE,
        // so opening and migrating is serialized across processes with an flock on a sidecar file
        let lockDescriptor = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_EX) }
        defer { if lockDescriptor >= 0 { close(lockDescriptor) } }
        dbPool = try DatabasePool(path: path, configuration: configuration)
        try Self.migrator.migrate(dbPool)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  session_id      TEXT PRIMARY KEY,
                  agent           TEXT NOT NULL,
                  title           TEXT,
                  first_prompt    TEXT,
                  cwd             TEXT,
                  repository      TEXT,
                  transcript_path TEXT,
                  terminal        TEXT,
                  first_seen_at   INTEGER NOT NULL,
                  last_seen_at    INTEGER NOT NULL
                );
                CREATE TABLE clips (
                  id               INTEGER PRIMARY KEY,
                  uuid             TEXT NOT NULL UNIQUE,
                  content          TEXT NOT NULL,
                  content_hash     TEXT NOT NULL,
                  content_kind     TEXT,
                  label            TEXT,
                  session_id       TEXT REFERENCES sessions(session_id),
                  agent            TEXT NOT NULL,
                  cwd              TEXT,
                  git_branch       TEXT,
                  terminal         TEXT,
                  tool_use_id      TEXT,
                  prompt_snapshot  TEXT,
                  context_snapshot TEXT,
                  enrich_state     TEXT NOT NULL DEFAULT 'pending',
                  pinned           INTEGER NOT NULL DEFAULT 0,
                  concealed        INTEGER NOT NULL DEFAULT 0,
                  paste_count      INTEGER NOT NULL DEFAULT 0,
                  created_at       INTEGER NOT NULL,
                  last_pasted_at   INTEGER
                );
                CREATE INDEX clips_session_created ON clips(session_id, created_at DESC);
                CREATE INDEX clips_created ON clips(created_at DESC);
                CREATE INDEX clips_enrich_state ON clips(enrich_state);
                CREATE VIRTUAL TABLE clips_fts USING fts5(content, label, prompt_snapshot,
                  content='clips', content_rowid='id', tokenize='trigram');
                -- External-content FTS5 needs the original values on delete
                CREATE TRIGGER clips_fts_insert AFTER INSERT ON clips BEGIN
                  INSERT INTO clips_fts(rowid, content, label, prompt_snapshot)
                  VALUES (new.id, new.content, new.label, new.prompt_snapshot);
                END;
                CREATE TRIGGER clips_fts_delete AFTER DELETE ON clips BEGIN
                  INSERT INTO clips_fts(clips_fts, rowid, content, label, prompt_snapshot)
                  VALUES ('delete', old.id, old.content, old.label, old.prompt_snapshot);
                END;
                CREATE TRIGGER clips_fts_update AFTER UPDATE OF content, label, prompt_snapshot ON clips BEGIN
                  INSERT INTO clips_fts(clips_fts, rowid, content, label, prompt_snapshot)
                  VALUES ('delete', old.id, old.content, old.label, old.prompt_snapshot);
                  INSERT INTO clips_fts(rowid, content, label, prompt_snapshot)
                  VALUES (new.id, new.content, new.label, new.prompt_snapshot);
                END;
                """)
        }
        migrator.registerMigration("v2-subagent") { db in
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN subagent TEXT")
        }
        // AUTOINCREMENT so ids are never reused after prune (an id the user saw must keep meaning the same clip),
        // clips.repository / sessions.git_branch, and an FTS index capped to the first 64K characters of content
        // (trigram indexing is linear in size and dominated copy time for large inputs).
        migrator.registerMigration("v3-autoincrement") { db in
            try db.execute(sql: """
                DROP TRIGGER clips_fts_insert;
                DROP TRIGGER clips_fts_delete;
                DROP TRIGGER clips_fts_update;
                DROP TABLE clips_fts;
                CREATE TABLE clips_new (
                  id               INTEGER PRIMARY KEY AUTOINCREMENT,
                  uuid             TEXT NOT NULL UNIQUE,
                  content          TEXT NOT NULL,
                  content_hash     TEXT NOT NULL,
                  content_kind     TEXT,
                  label            TEXT,
                  session_id       TEXT REFERENCES sessions(session_id),
                  agent            TEXT NOT NULL,
                  cwd              TEXT,
                  git_branch       TEXT,
                  repository       TEXT,
                  terminal         TEXT,
                  tool_use_id      TEXT,
                  prompt_snapshot  TEXT,
                  context_snapshot TEXT,
                  subagent         TEXT,
                  enrich_state     TEXT NOT NULL DEFAULT 'pending',
                  pinned           INTEGER NOT NULL DEFAULT 0,
                  concealed        INTEGER NOT NULL DEFAULT 0,
                  paste_count      INTEGER NOT NULL DEFAULT 0,
                  created_at       INTEGER NOT NULL,
                  last_pasted_at   INTEGER
                );
                INSERT INTO clips_new (id, uuid, content, content_hash, content_kind, label, session_id, agent, cwd,
                  git_branch, terminal, tool_use_id, prompt_snapshot, context_snapshot, subagent, enrich_state, pinned,
                  concealed, paste_count, created_at, last_pasted_at)
                SELECT id, uuid, content, content_hash, content_kind, label, session_id, agent, cwd,
                  git_branch, terminal, tool_use_id, prompt_snapshot, context_snapshot, subagent, enrich_state, pinned,
                  concealed, paste_count, created_at, last_pasted_at FROM clips;
                DROP TABLE clips;
                ALTER TABLE clips_new RENAME TO clips;
                CREATE INDEX clips_session_created ON clips(session_id, created_at DESC);
                CREATE INDEX clips_created ON clips(created_at DESC);
                CREATE INDEX clips_enrich_state ON clips(enrich_state);
                CREATE VIRTUAL TABLE clips_fts USING fts5(content, label, prompt_snapshot,
                  content='clips', content_rowid='id', tokenize='trigram');
                -- The index holds substr(content, 1, 65536); delete must pass exactly the indexed values
                CREATE TRIGGER clips_fts_insert AFTER INSERT ON clips BEGIN
                  INSERT INTO clips_fts(rowid, content, label, prompt_snapshot)
                  VALUES (new.id, substr(new.content, 1, 65536), new.label, new.prompt_snapshot);
                END;
                CREATE TRIGGER clips_fts_delete AFTER DELETE ON clips BEGIN
                  INSERT INTO clips_fts(clips_fts, rowid, content, label, prompt_snapshot)
                  VALUES ('delete', old.id, substr(old.content, 1, 65536), old.label, old.prompt_snapshot);
                END;
                CREATE TRIGGER clips_fts_update AFTER UPDATE OF content, label, prompt_snapshot ON clips BEGIN
                  INSERT INTO clips_fts(clips_fts, rowid, content, label, prompt_snapshot)
                  VALUES ('delete', old.id, substr(old.content, 1, 65536), old.label, old.prompt_snapshot);
                  INSERT INTO clips_fts(rowid, content, label, prompt_snapshot)
                  VALUES (new.id, substr(new.content, 1, 65536), new.label, new.prompt_snapshot);
                END;
                INSERT INTO clips_fts(rowid, content, label, prompt_snapshot)
                  SELECT id, substr(content, 1, 65536), label, prompt_snapshot FROM clips;
                ALTER TABLE sessions ADD COLUMN git_branch TEXT;
                """)
        }
        return migrator
    }

    /// Upserts the session, inserts the clip and prunes expired clips in one transaction
    @discardableResult
    public func record(
        content: String, label: String?, concealed: Bool, uuid: String, context: CaptureContext, now: Date
    ) throws -> Clip {
        let createdAt = now.epochMilliseconds
        var clip = Clip(
            id: nil, uuid: uuid, content: content,
            contentHash: SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined(),
            contentKind: ContentKind.classify(content).rawValue, label: label, sessionId: context.sessionId,
            agent: context.agent, cwd: context.cwd, gitBranch: context.gitBranch, repository: context.repository,
            terminal: context.terminal,
            toolUseId: nil, promptSnapshot: nil, contextSnapshot: nil, subagent: nil,
            enrichState: (context.sessionId == nil ? EnrichState.done : .pending).rawValue,
            pinned: false, concealed: concealed || SecretDetector.containsSecret(content), pasteCount: 0,
            createdAt: createdAt, lastPastedAt: nil)
        try dbPool.write { db in
            if let sessionId = context.sessionId {
                try db.execute(
                    sql: """
                        INSERT INTO sessions (session_id, agent, cwd, repository, git_branch, terminal, first_seen_at, last_seen_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(session_id) DO UPDATE SET
                          last_seen_at = MAX(sessions.last_seen_at, excluded.last_seen_at),
                          -- cwd / repository / branch are one unit describing the session's own directory:
                          -- a copy made from another directory never fills them in
                          repository = CASE WHEN sessions.cwd IS excluded.cwd
                            THEN COALESCE(sessions.repository, excluded.repository) ELSE sessions.repository END,
                          git_branch = CASE WHEN sessions.cwd IS excluded.cwd
                            THEN COALESCE(sessions.git_branch, excluded.git_branch) ELSE sessions.git_branch END,
                          terminal = COALESCE(excluded.terminal, sessions.terminal)
                        """,
                    arguments: [
                        sessionId, context.agent, context.cwd, context.repository, context.gitBranch, context.terminal,
                        createdAt, createdAt,
                    ])
            }
            try clip.insert(db)
            try Self.prune(db, olderThan: Self.retention, now: now)
        }
        return clip
    }

    /// Deletes expired unpinned clips and sessions left without clips. Returns the number of deleted clips
    @discardableResult
    public func prune(olderThan interval: TimeInterval, now: Date) throws -> Int {
        try dbPool.write { db in try Self.prune(db, olderThan: interval, now: now) }
    }

    @discardableResult
    static func prune(_ db: Database, olderThan interval: TimeInterval, now: Date) throws -> Int {
        let cutoff = now.addingTimeInterval(-interval).epochMilliseconds
        try db.execute(sql: "DELETE FROM clips WHERE pinned = 0 AND created_at < ?", arguments: [cutoff])
        let deleted = db.changesCount
        try db.execute(sql: "DELETE FROM sessions WHERE session_id NOT IN (SELECT session_id FROM clips WHERE session_id IS NOT NULL)")
        return deleted
    }

    /// Newest first
    public func clips(sessionId: String?, limit: Int?) throws -> [Clip] {
        try dbPool.read { db in
            var request = Clip.order(Column("created_at").desc, Column("id").desc)
            if let sessionId { request = request.filter(Column("session_id") == sessionId) }
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }
    }

    /// 1 = newest
    public func clip(nth: Int) throws -> Clip? {
        guard nth >= 1 else { return nil }
        return try dbPool.read { db in
            try Clip.order(Column("created_at").desc, Column("id").desc).limit(1, offset: nth - 1).fetchOne(db)
        }
    }

    public func clip(id: Int64) throws -> Clip? {
        try dbPool.read { db in try Clip.fetchOne(db, key: id) }
    }

    /// Oldest first (enrich resolves earlier clips first)
    public func pendingClips() throws -> [Clip] {
        try dbPool.read { db in
            try Clip.filter(Column("enrich_state") == EnrichState.pending.rawValue)
                .order(Column("created_at"), Column("id")).fetchAll(db)
        }
    }

    public func sessions(ids: Set<String>) throws -> [String: Session] {
        guard !ids.isEmpty else { return [:] }
        return try dbPool.read { db in
            let sessions = try Session.filter(keys: Array(ids)).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
        }
    }

    public func markPasted(id: Int64, now: Date) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE clips SET paste_count = paste_count + 1, last_pasted_at = ? WHERE id = ?",
                arguments: [now.epochMilliseconds, id])
        }
    }

    /// false if there is no such clip
    public func setPinned(id: Int64, pinned: Bool) throws -> Bool {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE clips SET pinned = ? WHERE id = ?", arguments: [pinned, id])
            return db.changesCount > 0
        }
    }

    /// Never downgrades done to failed / pending and never overwrites existing values with nil (re-enriching never loses data)
    public func applyEnrichment(
        clipId: Int64, state: EnrichState, toolUseId: String?, promptSnapshot: String?, contextSnapshot: String?,
        subagent: String? = nil
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE clips SET
                      enrich_state = CASE WHEN enrich_state = 'done' THEN 'done' ELSE ? END,
                      tool_use_id = COALESCE(?, tool_use_id),
                      prompt_snapshot = COALESCE(?, prompt_snapshot),
                      context_snapshot = COALESCE(?, context_snapshot),
                      subagent = COALESCE(?, subagent)
                    WHERE id = ?
                    """,
                arguments: [state.rawValue, toolUseId, promptSnapshot, contextSnapshot, subagent, clipId])
        }
    }

    /// Parses "24h" / "90m" / "7d" / "3600s" into seconds. Returns nil for <= 0, non-finite or malformed values
    public static func retentionInterval(from text: String) -> TimeInterval? {
        guard let unit = text.last, let multiplier = ["s": 1.0, "m": 60, "h": 3600, "d": 86400][String(unit)],
              let value = Double(text.dropLast()), value.isFinite, value > 0
        else { return nil }
        return value * multiplier
    }

    /// Updates the session with what the transcript provides (nil fields keep their existing value)
    public func updateSession(
        sessionId: String, title: String?, firstPrompt: String?, gitBranch: String? = nil, transcriptPath: String?
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions SET title = COALESCE(?, title), first_prompt = COALESCE(?, first_prompt),
                      git_branch = COALESCE(?, git_branch), transcript_path = COALESCE(?, transcript_path)
                    WHERE session_id = ?
                    """,
                arguments: [title, firstPrompt, gitBranch, transcriptPath, sessionId])
        }
    }

    /// Replaces the session's directory and its repository / branch together (a nil repository is stored as is)
    public func setSessionLocation(sessionId: String, cwd: String, location: CaptureContext.Location) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE sessions SET cwd = ?, repository = ?, git_branch = COALESCE(?, git_branch) WHERE session_id = ?",
                arguments: [cwd, location.repository, location.gitBranch, sessionId])
        }
    }

    /// Full-text search over content, label and prompt (trigram, so 3+ characters). Returns matching clip ids
    public func search(_ query: String) throws -> [Int64] {
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return try dbPool.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM clips_fts WHERE clips_fts MATCH ? ORDER BY rowid", arguments: [phrase])
        }
    }

    public func countsByEnrichState() throws -> [String: Int] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT enrich_state, COUNT(*) AS count FROM clips GROUP BY enrich_state")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["enrich_state"] as String, $0["count"] as Int) })
        }
    }
}
