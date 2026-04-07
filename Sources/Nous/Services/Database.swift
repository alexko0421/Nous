import Foundation
import SQLite3

// MARK: - Errors

enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg):   return "Database open failed: \(msg)"
        case .prepareFailed(let msg): return "Statement prepare failed: \(msg)"
        case .stepFailed(let msg):   return "Statement step failed: \(msg)"
        case .bindFailed(let msg):   return "Bind failed: \(msg)"
        case .closed:                return "Database is closed"
        }
    }
}

// MARK: - Database

final class Database {

    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw DatabaseError.openFailed(msg)
        }
        // Enable WAL mode for better concurrent read performance
        try exec("PRAGMA journal_mode=WAL;")
        // Enforce foreign key constraints
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Execute raw SQL

    func exec(_ sql: String) throws {
        guard let db else { throw DatabaseError.closed }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw DatabaseError.stepFailed(msg)
        }
    }

    // MARK: - Prepare statement

    func prepare(_ sql: String) throws -> Statement {
        guard let db else { throw DatabaseError.closed }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(msg)
        }
        return Statement(stmt: stmt)
    }

    // MARK: - Last insert rowid

    var lastInsertRowid: Int64 {
        guard let db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }
}

// MARK: - Statement

final class Statement {

    private let stmt: OpaquePointer

    fileprivate init(stmt: OpaquePointer) {
        self.stmt = stmt
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    // MARK: - Binding

    @discardableResult
    func bind(_ value: String?, at index: Int32) throws -> Statement {
        let rc: Int32
        if let value {
            // SQLITE_TRANSIENT = -1 cast to sqlite3_destructor_type — SQLite copies the data
            rc = sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            rc = sqlite3_bind_null(stmt, index)
        }
        guard rc == SQLITE_OK else {
            throw DatabaseError.bindFailed("bind text at \(index): rc=\(rc)")
        }
        return self
    }

    @discardableResult
    func bind(_ value: Int, at index: Int32) throws -> Statement {
        let rc = sqlite3_bind_int64(stmt, index, Int64(value))
        guard rc == SQLITE_OK else {
            throw DatabaseError.bindFailed("bind int at \(index): rc=\(rc)")
        }
        return self
    }

    @discardableResult
    func bind(_ value: Double, at index: Int32) throws -> Statement {
        let rc = sqlite3_bind_double(stmt, index, value)
        guard rc == SQLITE_OK else {
            throw DatabaseError.bindFailed("bind double at \(index): rc=\(rc)")
        }
        return self
    }

    @discardableResult
    func bind(_ value: Float, at index: Int32) throws -> Statement {
        let rc = sqlite3_bind_double(stmt, index, Double(value))
        guard rc == SQLITE_OK else {
            throw DatabaseError.bindFailed("bind float at \(index): rc=\(rc)")
        }
        return self
    }

    @discardableResult
    func bind(_ value: Data?, at index: Int32) throws -> Statement {
        let rc: Int32
        if let value {
            rc = value.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(value.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            rc = sqlite3_bind_null(stmt, index)
        }
        guard rc == SQLITE_OK else {
            throw DatabaseError.bindFailed("bind blob at \(index): rc=\(rc)")
        }
        return self
    }

    // MARK: - Stepping

    /// Returns true if a row is available, false when done.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:  return true
        case SQLITE_DONE: return false
        default:
            throw DatabaseError.stepFailed("sqlite3_step rc=\(rc)")
        }
    }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    // MARK: - Reading columns

    func text(at column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: ptr)
    }

    func int(at column: Int32) -> Int {
        return Int(sqlite3_column_int64(stmt, column))
    }

    func double(at column: Int32) -> Double {
        return sqlite3_column_double(stmt, column)
    }

    func blob(at column: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, column) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return Data(bytes: ptr, count: count)
    }

    func isNull(at column: Int32) -> Bool {
        return sqlite3_column_type(stmt, column) == SQLITE_NULL
    }
}
