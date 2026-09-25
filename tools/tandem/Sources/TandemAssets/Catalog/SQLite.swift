import Foundation
import SQLite3

/// A value bound to or read from SQLite.
enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    init(_ value: Double?) { self = value.map { .real($0) } ?? .null }
    init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    init(_ value: Int64?) { self = value.map { .integer($0) } ?? .null }
    init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    init(_ value: Date?) { self = value.map { .real($0.timeIntervalSince1970) } ?? .null }
}

/// One result row, by column name.
struct SQLRow {
    let values: [String: SQLValue]

    subscript(_ column: String) -> SQLValue { values[column] ?? .null }

    func string(_ column: String) -> String? {
        switch self[column] {
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .real(let d): return String(d)
        case .blob(let data): return String(data: data, encoding: .utf8)
        case .null: return nil
        }
    }

    func double(_ column: String) -> Double? {
        switch self[column] {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        case .text(let s): return Double(s)
        case .blob, .null: return nil
        }
    }

    func int64(_ column: String) -> Int64? {
        switch self[column] {
        case .integer(let i): return i
        case .real(let d): return Int64(d)
        case .text(let s): return Int64(s)
        case .blob, .null: return nil
        }
    }

    func int(_ column: String) -> Int? { int64(column).map { Int($0) } }
    func bool(_ column: String) -> Bool { (int64(column) ?? 0) != 0 }
    func date(_ column: String) -> Date? { double(column).map { Date(timeIntervalSince1970: $0) } }
}

/// A small wrapper over the system SQLite C API: one connection, statements
/// prepared per call, values bound by position. Callers serialise access.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    let path: String

    /// SQLite copies bound text and blobs when given this destructor.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
            if let db { sqlite3_close_v2(db) }
            throw AssetError.database("can't open \(path): \(message)")
        }
        handle = db
        // The app and the CLI can both have the catalogue open; wait for a
        // writer instead of failing straight away.
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    /// Runs one or more statements with no bindings.
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw AssetError.database(message)
        }
    }

    /// Runs one statement and discards any rows.
    func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        try withStatement(sql, bindings) { statement in
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return }
                if step != SQLITE_ROW { throw AssetError.database("\(errorMessage) in: \(sql)") }
            }
        }
    }

    /// Runs one statement and returns its rows.
    func query(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        try withStatement(sql, bindings) { statement in
            var rows: [SQLRow] = []
            let count = sqlite3_column_count(statement)
            let names = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw AssetError.database("\(errorMessage) in: \(sql)") }
                var values: [String: SQLValue] = [:]
                for index in 0..<count {
                    values[names[Int(index)]] = column(statement, index)
                }
                rows.append(SQLRow(values: values))
            }
            return rows
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs `body` in a transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
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

    private func withStatement<T>(_ sql: String, _ bindings: [SQLValue], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AssetError.database("\(errorMessage) in: \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let i): result = sqlite3_bind_int64(statement, index, i)
            case .real(let d): result = sqlite3_bind_double(statement, index, d)
            case .text(let s): result = sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else { throw AssetError.database("\(errorMessage) binding \(index) in: \(sql)") }
        }
        return try body(statement)
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }
}
