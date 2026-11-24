import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseChangeEvent: Sendable {
    case bookmarks
    case watchProgress
    case searchHistory
}

public enum SQLiteError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .execFailed(let msg): return "SQLite exec failed: \(msg)"
        case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
        }
    }
}

/// Actor-isolated native SQLite3 database configured with WAL journaling and low-fsync pragmas.
public actor SQLiteDatabase {
    nonisolated(unsafe) private var db: OpaquePointer?
    private var changeContinuations: [UUID: AsyncStream<DatabaseChangeEvent>.Continuation] = [:]

    public init(path: String) throws {
        if path != ":memory:" {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.openFailed(msg)
        }
        do {
            try Self.configureAndMigrate(db: handle, isInMemory: path == ":memory:")
            self.db = handle
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func observeChanges() -> AsyncStream<DatabaseChangeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            changeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
    }

    private func notify(_ event: DatabaseChangeEvent) {
        for cont in changeContinuations.values {
            cont.yield(event)
        }
    }

    private static func configureAndMigrate(db: OpaquePointer, isInMemory: Bool) throws {
        try execRaw(db, "PRAGMA busy_timeout = 5000;")
        if !isInMemory {
            try execRaw(db, "PRAGMA journal_mode = WAL;")
            try execRaw(db, "PRAGMA synchronous = NORMAL;")
        }
        try execRaw(db, "PRAGMA temp_store = MEMORY;")
        try execRaw(db, "PRAGMA cache_size = -4000;")

        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &versionStatement, nil) == SQLITE_OK,
              let versionStatement else { throw SQLiteError.prepareFailed("user_version") }
        let status = sqlite3_step(versionStatement)
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard status == SQLITE_ROW, version <= 1 else { throw SQLiteError.execFailed("Unsupported schema version \(version)") }
        if version == 1 { return }

        try execRaw(db, """
            BEGIN IMMEDIATE;
            CREATE TABLE IF NOT EXISTS bookmarks (
                animeId TEXT NOT NULL PRIMARY KEY,
                title TEXT NOT NULL,
                coverUrl TEXT NOT NULL,
                lastEpisodeLabel TEXT NOT NULL,
                addedAt INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS watch_progress (
                episodeKey TEXT NOT NULL PRIMARY KEY,
                animeId TEXT NOT NULL,
                animeTitle TEXT NOT NULL,
                coverUrl TEXT NOT NULL,
                episodeLabel TEXT NOT NULL,
                positionMs INTEGER NOT NULL,
                durationMs INTEGER NOT NULL,
                isWatched INTEGER NOT NULL,
                nextEpisodeKey TEXT,
                nextEpisodeLabel TEXT,
                updatedAt INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS index_watch_progress_animeId_updatedAt
                ON watch_progress (animeId, updatedAt);
            CREATE INDEX IF NOT EXISTS index_watch_progress_updatedAt
                ON watch_progress (updatedAt);
            CREATE TABLE IF NOT EXISTS search_history (
                query TEXT NOT NULL PRIMARY KEY,
                searchedAt INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS web_cache (
                cacheKey TEXT NOT NULL PRIMARY KEY,
                payload TEXT NOT NULL,
                fetchedAt INTEGER NOT NULL,
                parsedJson TEXT
            );
            CREATE INDEX IF NOT EXISTS index_web_cache_fetchedAt
                ON web_cache (fetchedAt);
            PRAGMA user_version = 1;
            COMMIT;
        """)
    }

    private static func execRaw(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw SQLiteError.execFailed(message)
        }
    }

    // MARK: - Bookmarks

    public func getAllBookmarks() -> [BookmarkRecord] {
        guard let db else { return [] }
        let sql = "SELECT animeId, title, coverUrl, lastEpisodeLabel, addedAt FROM bookmarks ORDER BY addedAt DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [BookmarkRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(BookmarkRecord(
                animeId: columnString(stmt, 0),
                title: columnString(stmt, 1),
                coverUrl: columnString(stmt, 2),
                lastEpisodeLabel: columnString(stmt, 3),
                addedAt: sqlite3_column_int64(stmt, 4)
            ))
        }
        return out
    }

    public func getBookmarkedIds() -> Set<String> {
        guard let db else { return [] }
        let sql = "SELECT animeId FROM bookmarks;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var ids = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.insert(columnString(stmt, 0))
        }
        return ids
    }

    public func isBookmarked(animeId: String) -> Bool {
        guard let db else { return false }
        let sql = "SELECT 1 FROM bookmarks WHERE animeId = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, animeId)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    public func upsertBookmark(_ record: BookmarkRecord) {
        guard let db else { return }
        let sql = """
            INSERT OR REPLACE INTO bookmarks (animeId, title, coverUrl, lastEpisodeLabel, addedAt)
            VALUES (?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, record.animeId)
        bindText(stmt, 2, record.title)
        bindText(stmt, 3, record.coverUrl)
        bindText(stmt, 4, record.lastEpisodeLabel)
        sqlite3_bind_int64(stmt, 5, record.addedAt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        notify(.bookmarks)
    }

    public func deleteBookmark(animeId: String) {
        guard let db else { return }
        let sql = "DELETE FROM bookmarks WHERE animeId = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, animeId)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        notify(.bookmarks)
    }

    // MARK: - Watch Progress

    public func getLatestWatchProgressPerAnime(limit: Int = 30) -> [WatchProgressRecord] {
        guard let db else { return [] }
        let sql = """
            SELECT wp.episodeKey, wp.animeId, wp.animeTitle, wp.coverUrl, wp.episodeLabel,
                   wp.positionMs, wp.durationMs, wp.isWatched, wp.nextEpisodeKey, wp.nextEpisodeLabel,
                   wp.updatedAt
            FROM watch_progress wp
            WHERE wp.animeId != '' AND wp.episodeKey = (
                SELECT latest.episodeKey FROM watch_progress latest
                WHERE latest.animeId = wp.animeId
                ORDER BY latest.updatedAt DESC, latest.episodeKey DESC LIMIT 1
            )
            ORDER BY wp.updatedAt DESC, wp.episodeKey DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(clamping: max(0, limit)))
        return readWatchProgressRows(stmt)
    }

    public func getWatchProgressByAnime(animeId: String) -> [WatchProgressRecord] {
        guard let db else { return [] }
        let sql = """
            SELECT episodeKey, animeId, animeTitle, coverUrl, episodeLabel,
                   positionMs, durationMs, isWatched, nextEpisodeKey, nextEpisodeLabel, updatedAt
            FROM watch_progress WHERE animeId = ? ORDER BY updatedAt DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, animeId)
        return readWatchProgressRows(stmt)
    }

    public func getWatchProgress(episodeKey: String) -> WatchProgressRecord? {
        guard let db else { return nil }
        let sql = """
            SELECT episodeKey, animeId, animeTitle, coverUrl, episodeLabel,
                   positionMs, durationMs, isWatched, nextEpisodeKey, nextEpisodeLabel, updatedAt
            FROM watch_progress WHERE episodeKey = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, episodeKey)
        return readWatchProgressRows(stmt).first
    }

    public func upsertWatchProgress(_ record: WatchProgressRecord) {
        guard let db else { return }
        let sql = """
            INSERT OR REPLACE INTO watch_progress
            (episodeKey, animeId, animeTitle, coverUrl, episodeLabel, positionMs, durationMs,
             isWatched, nextEpisodeKey, nextEpisodeLabel, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, record.episodeKey)
        bindText(stmt, 2, record.animeId)
        bindText(stmt, 3, record.animeTitle)
        bindText(stmt, 4, record.coverUrl)
        bindText(stmt, 5, record.episodeLabel)
        sqlite3_bind_int64(stmt, 6, record.positionMs)
        sqlite3_bind_int64(stmt, 7, record.durationMs)
        sqlite3_bind_int(stmt, 8, record.isWatched ? 1 : 0)
        bindOptionalText(stmt, 9, record.nextEpisodeKey)
        bindOptionalText(stmt, 10, record.nextEpisodeLabel)
        sqlite3_bind_int64(stmt, 11, record.updatedAt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        notify(.watchProgress)
    }

    public func clearWatchHistory() {
        guard let db else { return }
        do {
            try Self.execRaw(db, "DELETE FROM watch_progress;")
            notify(.watchProgress)
        } catch { return }
    }

    // MARK: - Search History

    public func getRecentSearches(limit: Int = 10) -> [String] {
        guard let db else { return [] }
        let sql = "SELECT query FROM search_history ORDER BY searchedAt DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(columnString(stmt, 0))
        }
        return out
    }

    public func upsertSearchHistory(query: String, searchedAt: Int64) {
        guard let db else { return }
        let sql = "INSERT OR REPLACE INTO search_history (query, searchedAt) VALUES (?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, query)
        sqlite3_bind_int64(stmt, 2, searchedAt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        notify(.searchHistory)
    }

    public func deleteSearchHistory(query: String) {
        guard let db else { return }
        let sql = "DELETE FROM search_history WHERE query = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, query)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        notify(.searchHistory)
    }

    public func clearSearchHistory() {
        guard let db else { return }
        do {
            try Self.execRaw(db, "DELETE FROM search_history;")
            notify(.searchHistory)
        } catch { return }
    }

    // MARK: - Web Cache

    public func getWebCache(cacheKey: String) -> WebCacheRecord? {
        guard let db else { return nil }
        let sql = "SELECT cacheKey, payload, fetchedAt, parsedJson FROM web_cache WHERE cacheKey = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, cacheKey)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return WebCacheRecord(
            cacheKey: columnString(stmt, 0),
            payload: columnString(stmt, 1),
            fetchedAt: sqlite3_column_int64(stmt, 2),
            parsedJson: columnOptionalString(stmt, 3)
        )
    }

    public func getRecentCachedDetails(limit: Int = 12) -> [WebCacheRecord] {
        guard let db else { return [] }
        let sql = """
            SELECT cacheKey, payload, fetchedAt, parsedJson FROM web_cache
            WHERE cacheKey LIKE 'detail:%' AND parsedJson IS NOT NULL
            ORDER BY fetchedAt DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [WebCacheRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(WebCacheRecord(
                cacheKey: columnString(stmt, 0),
                payload: columnString(stmt, 1),
                fetchedAt: sqlite3_column_int64(stmt, 2),
                parsedJson: columnOptionalString(stmt, 3)
            ))
        }
        return out
    }

    func getRecentArtwork(since: Int64, limit: Int = 128) -> [WebCacheRecord] {
        guard let db else { return [] }
        let sql = """
            SELECT cacheKey, payload, fetchedAt FROM web_cache
            WHERE cacheKey LIKE 'artwork:ah:%' AND fetchedAt >= ?
            ORDER BY fetchedAt DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var rows: [WebCacheRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(WebCacheRecord(cacheKey: columnString(stmt, 0), payload: columnString(stmt, 1),
                                       fetchedAt: sqlite3_column_int64(stmt, 2)))
        }
        return rows
    }

    public func upsertWebCache(_ record: WebCacheRecord) {
        guard let db else { return }
        let sql = """
            INSERT OR REPLACE INTO web_cache (cacheKey, payload, fetchedAt, parsedJson)
            VALUES (?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, record.cacheKey)
        bindText(stmt, 2, record.payload)
        sqlite3_bind_int64(stmt, 3, record.fetchedAt)
        bindOptionalText(stmt, 4, record.parsedJson)
        sqlite3_step(stmt)
    }

    public func pruneWebCacheOlderThan(cutoffMs: Int64) {
        guard let db else { return }
        let sql = "DELETE FROM web_cache WHERE fetchedAt < ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffMs)
        sqlite3_step(stmt)
    }

    public func clearWebCache() {
        guard let db else { return }
        try? Self.execRaw(db, "DELETE FROM web_cache;")
    }

    public func webCacheStats() -> (pages: Int, bytes: Int64) {
        guard let db else { return (0, 0) }
        let sql = """
            SELECT COUNT(*), COALESCE(SUM(LENGTH(payload) + COALESCE(LENGTH(parsedJson), 0)), 0)
            FROM web_cache;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int(stmt, 0)), sqlite3_column_int64(stmt, 1))
    }

    // MARK: - Helpers

    private func readWatchProgressRows(_ stmt: OpaquePointer) -> [WatchProgressRecord] {
        var out: [WatchProgressRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(WatchProgressRecord(
                episodeKey: columnString(stmt, 0),
                animeId: columnString(stmt, 1),
                animeTitle: columnString(stmt, 2),
                coverUrl: columnString(stmt, 3),
                episodeLabel: columnString(stmt, 4),
                positionMs: sqlite3_column_int64(stmt, 5),
                durationMs: sqlite3_column_int64(stmt, 6),
                isWatched: sqlite3_column_int(stmt, 7) != 0,
                nextEpisodeKey: columnOptionalString(stmt, 8),
                nextEpisodeLabel: columnOptionalString(stmt, 9),
                updatedAt: sqlite3_column_int64(stmt, 10)
            ))
        }
        return out
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    private func columnOptionalString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }
}
