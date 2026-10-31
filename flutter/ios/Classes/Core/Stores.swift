import Foundation

struct QueuedRecord: Equatable {
    let id: Int64
    let uuid: String
    let recordedAt: EpochMs
    let json: String
    let attempts: Int
}

/// The upload queue (DESIGN.md, "Upload"): one row per record, oldest first.
final class RecordQueue {
    struct PruneResult: Equatable {
        var overLimit = 0
        var expired = 0
        var total: Int { overLimit + expired }
    }

    private let db: SQLiteDatabase
    /// Keeps `IN (…)` lists under sqlite's bound-variable limit on any version.
    private static let chunkSize = 500

    init(db: SQLiteDatabase) throws {
        self.db = db
        try db.execute("""
            CREATE TABLE IF NOT EXISTS queue (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              uuid TEXT NOT NULL UNIQUE,
              recorded_at INTEGER NOT NULL,
              json TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS queue_recorded_at ON queue (recorded_at, id);
            """)
    }

    /// Returns false when a record with this uuid is already queued.
    @discardableResult
    func insert(uuid: String, recordedAt: EpochMs, json: String) throws -> Bool {
        try db.run("INSERT OR IGNORE INTO queue (uuid, recorded_at, json, attempts) VALUES (?, ?, ?, 0)",
                   [.text(uuid), .int(recordedAt), .text(json)]) > 0
    }

    /// Beyond `maxRecords` (oldest deleted) and older than `maxDays`.
    func prune(maxRecords: Int, maxDays: Int, now: EpochMs) throws -> PruneResult {
        try db.transaction {
            var result = PruneResult()
            result.expired = try db.run("DELETE FROM queue WHERE recorded_at < ?",
                                        [.int(now - EpochMs(maxDays) * .dayMs)])
            let excess = try db.scalarInt("SELECT COUNT(*) FROM queue") - Int64(maxRecords)
            if excess > 0 {
                result.overLimit = try db.run(
                    "DELETE FROM queue WHERE id IN (SELECT id FROM queue ORDER BY recorded_at ASC, id ASC LIMIT ?)",
                    [.int(excess)])
            }
            return result
        }
    }

    func oldest(limit: Int) throws -> [QueuedRecord] {
        try db.query("SELECT id, uuid, recorded_at, json, attempts FROM queue ORDER BY recorded_at ASC, id ASC LIMIT ?",
                     [.int(Int64(max(0, limit)))]) {
            QueuedRecord(id: $0.int64(0), uuid: $0.text(1), recordedAt: $0.int64(2), json: $0.text(3), attempts: $0.int(4))
        }
    }

    @discardableResult
    func delete(ids: [Int64]) throws -> Int {
        try db.transaction {
            var deleted = 0
            for chunk in ids.chunked(Self.chunkSize) {
                deleted += try db.run("DELETE FROM queue WHERE id IN (\(placeholders(chunk.count)))", chunk.map { .int($0) })
            }
            return deleted
        }
    }

    /// `attempts += 1` on the sent records; deletes those reaching `maxAttempts`. Returns the dropped uuids.
    func recordFailedAttempt(ids: [Int64], maxAttempts: Int) throws -> [String] {
        try db.transaction {
            var dropped: [String] = []
            for chunk in ids.chunked(Self.chunkSize) {
                let list = placeholders(chunk.count)
                let bindings = chunk.map { SQLiteValue.int($0) }
                try db.run("UPDATE queue SET attempts = attempts + 1 WHERE id IN (\(list))", bindings)
                dropped += try db.query("SELECT uuid FROM queue WHERE attempts >= ? AND id IN (\(list))",
                                        [.int(Int64(maxAttempts))] + bindings) { $0.text(0) }
                try db.run("DELETE FROM queue WHERE attempts >= ? AND id IN (\(list))", [.int(Int64(maxAttempts))] + bindings)
            }
            return dropped
        }
    }

    func count() throws -> Int { Int(try db.scalarInt("SELECT COUNT(*) FROM queue")) }

    /// `recorded_at` of the newest queued record; nil when the queue is empty.
    func newestRecordedAt() throws -> EpochMs? {
        try db.query("SELECT recorded_at FROM queue ORDER BY recorded_at DESC LIMIT 1") { $0.int64(0) }.first
    }

    @discardableResult
    func clear() throws -> Int { try db.run("DELETE FROM queue") }

    private func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
}

struct LogEntry: Equatable {
    var time: EpochMs
    var level: LogLevel
    var tag: String
    var message: String

    /// `2026-10-26T12:00:00.123Z INFO  [tag] message`
    var line: String { "\(Timestamp.iso8601(time)) \(level.label) [\(tag)] \(message)" }
}

/// The on-device log behind `getLog()`.
final class LogStore {
    /// Hard ceiling so a 1 s interval with debug logging cannot fill the disk within `logMaxDays`.
    static let maxRows = 100_000

    private let db: SQLiteDatabase

    init(db: SQLiteDatabase) throws {
        self.db = db
        try db.execute("""
            CREATE TABLE IF NOT EXISTS log (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts INTEGER NOT NULL,
              level INTEGER NOT NULL,
              tag TEXT NOT NULL,
              message TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS log_ts ON log (ts, id);
            """)
    }

    func append(_ entry: LogEntry) throws {
        // One entry per line in getLog() output.
        let message = entry.message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        try db.run("INSERT INTO log (ts, level, tag, message) VALUES (?, ?, ?, ?)",
                   [.int(entry.time), .int(Int64(entry.level.verbosity)), .text(entry.tag), .text(message)])
    }

    /// The newest `limit` entries at or after `since`, returned in the requested order.
    func entries(since: EpochMs, limit: Int, ascending: Bool) throws -> [LogEntry] {
        let newest = try db.query("SELECT ts, level, tag, message FROM log WHERE ts >= ? ORDER BY ts DESC, id DESC LIMIT ?",
                                  [.int(since), .int(Int64(max(0, limit)))]) { row in
            LogEntry(time: row.int64(0), level: LogLevel.fromVerbosity(row.int(1)), tag: row.text(2), message: row.text(3))
        }
        return ascending ? newest.reversed() : newest
    }

    /// Drops entries older than `olderThan` and anything beyond `maxRows`. Returns the number deleted.
    @discardableResult
    func prune(olderThan: EpochMs, maxRows: Int = LogStore.maxRows) throws -> Int {
        try db.transaction {
            var deleted = try db.run("DELETE FROM log WHERE ts < ?", [.int(olderThan)])
            let excess = try db.scalarInt("SELECT COUNT(*) FROM log") - Int64(maxRows)
            if excess > 0 {
                deleted += try db.run("DELETE FROM log WHERE id IN (SELECT id FROM log ORDER BY ts ASC, id ASC LIMIT ?)",
                                      [.int(excess)])
            }
            return deleted
        }
    }

    func count() throws -> Int { Int(try db.scalarInt("SELECT COUNT(*) FROM log")) }

    func clear() throws { try db.run("DELETE FROM log") }
}

extension LogLevel {
    static func fromVerbosity(_ v: Int) -> LogLevel {
        LogLevel.allCases.first { $0.verbosity == v } ?? .info
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [self[...]] }
        return stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
