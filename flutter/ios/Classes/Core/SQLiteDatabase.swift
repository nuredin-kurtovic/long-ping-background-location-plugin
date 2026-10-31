import Foundation
import SQLite3

struct SQLiteError: Error, Equatable, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "sqlite \(code): \(message)" }
}

enum SQLiteValue: Equatable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

/// Read access to the current row of a stepping statement.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func text(_ column: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: cString)
    }
}

/// Thin, thread-safe wrapper over one sqlite3 connection with a prepared-statement cache.
final class SQLiteDatabase {
    // SQLITE_TRANSIENT is a C macro Swift cannot import: tells sqlite to copy bound text immediately.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let lock = NSRecursiveLock()

    /// `extraOpenFlags` lets the iOS engine pass a data-protection class.
    init(path: String, extraOpenFlags: Int32 = 0) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | extraOpenFlags
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        if path != ":memory:" {
            // WAL + NORMAL: one fsync per checkpoint instead of per insert; safe against app crashes.
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
        }
    }

    static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:") }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close_v2(handle) }
    }

    func execute(_ sql: String) throws {
        try locked {
            var error: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &error)
            if rc != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(error)
                throw SQLiteError(code: rc, message: message)
            }
        }
    }

    /// Runs a statement that returns no rows; returns the number of rows changed.
    @discardableResult
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        try locked {
            let statement = try prepared(sql, bindings)
            defer { sqlite3_reset(statement) }
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError(rc) }
            return Int(sqlite3_changes(handle))
        }
    }

    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> T) throws -> [T] {
        try locked {
            let statement = try prepared(sql, bindings)
            defer { sqlite3_reset(statement) }
            var rows: [T] = []
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw lastError(rc) }
                rows.append(try map(SQLiteRow(statement: statement)))
            }
            return rows
        }
    }

    func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int64 {
        try query(sql, bindings) { $0.int64(0) }.first ?? 0
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    var userVersion: Int {
        get { Int((try? scalarInt("PRAGMA user_version")) ?? 0) }
    }

    func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }

    // MARK: - Private

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func prepared(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
        } else {
            var created: OpaquePointer?
            let rc = sqlite3_prepare_v2(handle, sql, -1, &created, nil)
            guard rc == SQLITE_OK, let created else { throw lastError(rc) }
            statements[sql] = created
            statement = created
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(statement, index, v)
            case .double(let v): rc = sqlite3_bind_double(statement, index, v)
            case .text(let v): rc = sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .null: rc = sqlite3_bind_null(statement, index)
            }
            guard rc == SQLITE_OK else { throw lastError(rc) }
        }
        return statement
    }

    private func lastError(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }
}
