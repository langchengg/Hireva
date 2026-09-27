import Foundation
import SQLite3

struct SQLPracticeResult: Codable {
    var query: String
    var dataset = "synthetic-orders-v1"
    var schema = PracticeSQLService.schema
    var columns: [String]
    var rows: [[String?]]
    var elapsedMS: Int
    var truncated: Bool
    var error: String?
    var executed: Bool
}

/// Dedicated ephemeral SQLite connection. Never accepts an application database
/// path or initialization SQL from the model/user. Authorization remains installed
/// during prepare and step, including automatic statement re-preparation.
enum PracticeSQLService {
    static let schema = "customers(id INTEGER, name TEXT); orders(id INTEGER, customer_id INTEGER, amount REAL). Customers 1=Ada, 2=Lin, 3=Sam; orders (1,1,10), (2,1,10), (3,2,NULL). SQLite dialect."
    private final class Budget {
        var callbacks = 0
        let started = Date()
        func exceeded() -> Bool { callbacks += 1; return callbacks > 2000 || Date().timeIntervalSince(started) > 2 || Task.isCancelled }
    }
    static func run(_ query: String) -> SQLPracticeResult {
        let start = Date()
        var result = SQLPracticeResult(query: query, columns: [], rows: [], elapsedMS: 0, truncated: false, error: nil, executed: false)
        defer { /* elapsed computed before return below */ }
        do {
            guard !query.contains("\0"), query.utf8.count <= 16000 else { throw MaterialError.invalid("Query exceeds limit or contains a NUL byte.") }
            var handle: OpaquePointer?
            guard sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                  let db = handle else { if let handle { sqlite3_close(handle) }; throw MaterialError.invalid("Could not open isolated practice database.") }
            defer { sqlite3_close(db) }
            // Trusted initialization phase, before the untrusted query authorizer.
            guard sqlite3_exec(db, "CREATE TABLE customers(id INTEGER, name TEXT); CREATE TABLE orders(id INTEGER, customer_id INTEGER, amount REAL); INSERT INTO customers VALUES(1,'Ada'),(2,'Lin'),(3,'Sam'); INSERT INTO orders VALUES(1,1,10),(2,1,10),(3,2,NULL); PRAGMA query_only=ON;", nil, nil, nil) == SQLITE_OK else { throw MaterialError.invalid("Synthetic dataset initialization failed.") }
            // Extension loading is disabled by SQLite by default, never enabled here,
            // and load_extension is also denied by the function authorizer.
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 100_000)
            sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 16000)
            sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 64)
            sqlite3_limit(db, SQLITE_LIMIT_EXPR_DEPTH, 32)
            sqlite3_limit(db, SQLITE_LIMIT_COMPOUND_SELECT, 8)
            sqlite3_limit(db, SQLITE_LIMIT_VDBE_OP, 50_000)
            sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
            sqlite3_limit(db, SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 256)
            sqlite3_set_authorizer(db, { _, action, first, second, _, _ in
                switch action {
                case SQLITE_SELECT, SQLITE_RECURSIVE: return SQLITE_OK
                case SQLITE_READ:
                    let table = first.map { String(cString: $0).lowercased() } ?? ""
                    return ["customers", "orders"].contains(table) ? SQLITE_OK : SQLITE_DENY
                case SQLITE_FUNCTION:
                    let function = second.map { String(cString: $0).lowercased() } ?? ""
                    let allowed: Set<String> = ["count", "sum", "total", "avg", "min", "max", "coalesce", "ifnull", "nullif", "round", "abs", "lower", "upper", "length", "substr", "substring", "trim", "typeof", "like", "row_number", "rank", "dense_rank", "lag", "lead", "first_value", "last_value", "ntile"]
                    return allowed.contains(function) ? SQLITE_OK : SQLITE_DENY
                default: return SQLITE_DENY // PRAGMA, ATTACH, DDL/DML, transactions, extensions.
                }
            }, nil)
            let budget = Budget()
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                return Unmanaged<Budget>.fromOpaque(context).takeUnretainedValue().exceeded() ? 1 : 0
            }, Unmanaged.passUnretained(budget).toOpaque())
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            var statement: OpaquePointer?
            var trailing = ""
            let prepared = query.withCString { sql -> Int32 in
                var tail: UnsafePointer<CChar>?
                let code = sqlite3_prepare_v2(db, sql, -1, &statement, &tail)
                trailing = tail.map { String(cString: $0) } ?? ""
                return code
            }
            defer { sqlite3_finalize(statement) }
            guard prepared == SQLITE_OK, let statement else { throw MaterialError.invalid(String(cString: sqlite3_errmsg(db))) }
            var extra: OpaquePointer?
            let extraCode = sqlite3_prepare_v2(db, trailing, -1, &extra, nil)
            defer { sqlite3_finalize(extra) }
            guard extraCode == SQLITE_OK, extra == nil, sqlite3_stmt_readonly(statement) != 0 else { throw MaterialError.invalid("Only one read-only query is allowed.") }
            result.columns = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
            var outputBytes = 0
            result.executed = true
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw MaterialError.invalid(String(cString: sqlite3_errmsg(db))) }
                if result.rows.count >= 200 { result.truncated = true; break }
                let row: [String?] = (0..<sqlite3_column_count(statement)).map { column in
                    guard sqlite3_column_type(statement, column) != SQLITE_NULL, let text = sqlite3_column_text(statement, column) else { return nil }
                    let count = Int(sqlite3_column_bytes(statement, column))
                    return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
                }
                outputBytes += row.compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
                if outputBytes > 64000 { result.truncated = true; break }
                result.rows.append(row)
            }
        } catch { result.error = error.localizedDescription }
        result.elapsedMS = Int(Date().timeIntervalSince(start) * 1000)
        return result
    }
}
