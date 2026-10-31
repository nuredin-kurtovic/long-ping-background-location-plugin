import Foundation
import SQLite3

/// Owns the sqlite file (queue + log), confined to the io queue. Opening is lazy and retried, because
/// before the first unlock after a reboot the file is unreadable (data protection) and the app may still
/// be relaunched in the background by region / significant-change monitoring.
final class LocalStore {
    let queue: DispatchQueue
    private var database: SQLiteDatabase?
    private(set) var records: RecordQueue?
    private var logs: LogStore?
    /// Log lines written before the database could be opened.
    private var pendingLogs: [LogEntry] = []
    private static let pendingLogLimit = 1000
    private var lastOpenError: String?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Application Support/LongPing/longping.sqlite, excluded from backup.
    static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = base.appendingPathComponent("LongPing", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            // Files created inside inherit this class. "Until first unlock" keeps the queue writable while the
            // phone sits locked in a pocket, even if the host app's default is NSFileProtectionComplete.
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory.appendingPathComponent("longping.sqlite")
    }

    /// io queue only. Returns false while the file cannot be opened yet.
    @discardableResult
    func openIfNeeded() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        if database != nil { return true }
        do {
            let url = try Self.databaseURL()
            let db = try SQLiteDatabase(path: url.path,
                                        extraOpenFlags: SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION)
            let records = try RecordQueue(db: db)
            let logs = try LogStore(db: db)
            try db.setUserVersion(1)
            database = db
            self.records = records
            self.logs = logs
            lastOpenError = nil
            for entry in pendingLogs { try? logs.append(entry) }
            pendingLogs.removeAll()
            return true
        } catch {
            let message = "database unavailable: \(error)"
            if message != lastOpenError {
                lastOpenError = message
                pendingLogs.append(LogEntry(time: SystemClock().nowMs, level: .error, tag: "storage", message: message))
            }
            return false
        }
    }

    // MARK: - Async API (any thread)

    func appendLog(_ entry: LogEntry) {
        queue.async {
            guard self.openIfNeeded(), let logs = self.logs else {
                if self.pendingLogs.count < Self.pendingLogLimit { self.pendingLogs.append(entry) }
                return
            }
            try? logs.append(entry)
        }
    }

    /// Inserts and prunes. Completion (io queue) gets the prune result, or nil when the insert failed.
    func enqueue(_ record: LocationRecord, persistence: PersistenceConfig, now: EpochMs,
                 completion: @escaping (Result<RecordQueue.PruneResult, Error>) -> Void) {
        let json = record.json.serialized()
        queue.async {
            guard self.openIfNeeded(), let records = self.records else {
                return completion(.failure(SQLiteError(code: SQLITE_CANTOPEN, message: self.lastOpenError ?? "not open")))
            }
            do {
                try records.insert(uuid: record.uuid, recordedAt: record.fix.time, json: json)
                completion(.success(try records.prune(maxRecords: persistence.maxRecords, maxDays: persistence.maxDays, now: now)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func queueCount(_ completion: @escaping (Int) -> Void) {
        queue.async {
            guard self.openIfNeeded(), let records = self.records else { return completion(0) }
            completion((try? records.count()) ?? 0)
        }
    }

    /// `recorded_at` of the newest queued record, for the recording clock at engine start. Blocks until the io
    /// queue runs it (its work is short sqlite and Keychain calls); never call it from the io queue.
    func newestQueuedRecordedAt() -> EpochMs? {
        queue.sync {
            guard openIfNeeded(), let records else { return nil }
            return try? records.newestRecordedAt()
        }
    }

    func clearQueue(_ completion: @escaping (Result<Int, Error>) -> Void) {
        queue.async {
            guard self.openIfNeeded(), let records = self.records else {
                return completion(.failure(SQLiteError(code: SQLITE_CANTOPEN, message: self.lastOpenError ?? "not open")))
            }
            completion(Result { try records.clear() })
        }
    }

    func logText(since: EpochMs, limit: Int, ascending: Bool, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            guard self.openIfNeeded(), let logs = self.logs else {
                return completion(.failure(SQLiteError(code: SQLITE_CANTOPEN, message: self.lastOpenError ?? "not open")))
            }
            completion(Result { try logs.entries(since: since, limit: limit, ascending: ascending).map(\.line).joined(separator: "\n") })
        }
    }

    func clearLog(_ completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.openIfNeeded(), let logs = self.logs else {
                return completion(.failure(SQLiteError(code: SQLITE_CANTOPEN, message: self.lastOpenError ?? "not open")))
            }
            completion(Result { try logs.clear() })
        }
    }

    func pruneLog(olderThan: EpochMs, completion: ((Int) -> Void)? = nil) {
        queue.async {
            guard self.openIfNeeded(), let logs = self.logs else { return }
            let deleted = (try? logs.prune(olderThan: olderThan)) ?? 0
            completion?(deleted)
        }
    }
}
