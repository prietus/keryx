import Foundation
import SQLite3

/// Full-text index of every message received, across networks, in SQLite
/// FTS5 with diacritic-insensitive tokenising (`camion` finds `camión`).
/// All access goes through one serial queue.
final class SearchIndex: @unchecked Sendable {
    struct Hit: Identifiable, Sendable {
        var id: Int64
        var network: UUID
        var buffer: String
        var sender: String
        var snippet: String
        var time: Date
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "im.keryx.search")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = StoragePaths.file("index.db")) {
        queue.sync {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { return }
            exec("PRAGMA journal_mode=WAL")
            exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS lines USING fts5(
                    body, sender, buffer UNINDEXED, network UNINDEXED, time UNINDEXED, msgkey UNINDEXED,
                    tokenize = 'unicode61 remove_diacritics 2')
                """)
            exec("CREATE TABLE IF NOT EXISTS seen(key TEXT PRIMARY KEY) WITHOUT ROWID")
        }
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Adds a line. `key` (msgid, else time+sender+text) keeps replays out.
    func add(network: UUID, buffer: String, sender: String, body: String, time: Date, key: String) {
        queue.async { [self] in
            guard let db else { return }
            var seen: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO seen(key) VALUES (?)", -1, &seen, nil)
            sqlite3_bind_text(seen, 1, key, -1, Self.transient)
            sqlite3_step(seen)
            sqlite3_finalize(seen)
            guard sqlite3_changes(db) > 0 else { return }
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO lines(body, sender, buffer, network, time, msgkey) VALUES (?,?,?,?,?,?)",
                               -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, body, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, sender, -1, Self.transient)
            sqlite3_bind_text(stmt, 3, buffer, -1, Self.transient)
            sqlite3_bind_text(stmt, 4, network.uuidString, -1, Self.transient)
            sqlite3_bind_double(stmt, 5, time.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 6, key, -1, Self.transient)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Newest matches first. Each word is matched as a prefix.
    func search(_ query: String, limit: Int = 200) async -> [Hit] {
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
        guard !terms.isEmpty else { return [] }
        let match = terms.joined(separator: " ")
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                var hits: [Hit] = []
                defer { continuation.resume(returning: hits) }
                guard let db else { return }
                var stmt: OpaquePointer?
                let sql = """
                    SELECT rowid, network, buffer, sender, snippet(lines, 0, '\u{2}', '\u{3}', '…', 14), time
                    FROM lines WHERE lines MATCH ? ORDER BY CAST(time AS REAL) DESC LIMIT ?
                    """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                sqlite3_bind_text(stmt, 1, match, -1, Self.transient)
                sqlite3_bind_int(stmt, 2, Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
                    guard let network = UUID(uuidString: text(1)) else { continue }
                    hits.append(Hit(id: sqlite3_column_int64(stmt, 0), network: network, buffer: text(2),
                                    sender: text(3), snippet: text(4),
                                    time: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))))
                }
                sqlite3_finalize(stmt)
            }
        }
    }

    func forget(network: UUID) {
        queue.async { [self] in
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM lines WHERE network = ?", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, network.uuidString, -1, Self.transient)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
}
