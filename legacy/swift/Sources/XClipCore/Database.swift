import Foundation
import SQLite3

public enum DatabaseError: Error, Equatable, CustomStringConvertible {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let message): return "打开数据库失败: \(message)"
        case .execFailed(let message): return "执行 SQL 失败: \(message)"
        case .prepareFailed(let message): return "准备语句失败: \(message)"
        case .stepFailed(let message): return "执行语句失败: \(message)"
        }
    }
}

/// SQLite 连接。actor 隔离保证同一时刻只有一个任务在使用连接；
/// 打开时使用 FULLMUTEX，配合 WAL 模式，CLI 与 App 两个进程可同时读写同一文件。
public actor Database {
    private let handle: OpaquePointer
    public let path: URL

    public init(path: URL) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var raw: OpaquePointer?
        if sqlite3_open_v2(path.path, &raw,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let raw { sqlite3_close(raw) }
            throw DatabaseError.openFailed(message)
        }
        guard let handle = raw else { throw DatabaseError.openFailed("unknown error") }
        self.handle = handle

        // busy_timeout 必须先于 journal_mode 设好：默认是 0，多个 CLI 并行打开时
        // 连切 WAL 这一步都会 0ms 直接 SQLITE_BUSY。直接调 C API，不用等 PRAGMA 生效。
        sqlite3_busy_timeout(handle, 15_000)

        do {
            try sqlExec(handle, "PRAGMA journal_mode = WAL")
            try sqlExec(handle, "PRAGMA foreign_keys = ON")
            try sqlMigrate(handle)
        } catch {
            // 初始化失败时实例不会反初始化，必须手动关闭连接。
            sqlite3_close(handle)
            throw error
        }
    }

    isolated deinit {
        sqlite3_close(handle)
    }

    // MARK: - actor 隔离的写入读取入口

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[String: SQLValue]] {
        try sqlQuery(handle, sql, params)
    }

    func run(_ sql: String, _ params: [SQLValue] = []) throws {
        try sqlRun(handle, sql, params)
    }

    /// 把多步写入包进 `BEGIN IMMEDIATE ... COMMIT`，出错整体回滚。
    /// 闭包拿到的 `Transaction` 同步持有 actor：期间的语句不与其他任务交错，
    /// 因此 `run`/`query` 直接同步调用、不需要 await。
    func transaction<T>(_ body: sending (Transaction) throws -> T) throws -> T {
        try sqlExec(handle, "BEGIN IMMEDIATE")
        do {
            let result = try body(Transaction(handle: handle))
            try sqlExec(handle, "COMMIT")
            return result
        } catch {
            try? sqlExec(handle, "ROLLBACK")
            throw error
        }
    }
}

/// `Database.transaction` 的闭包参数：事务内的同步执行入口。
/// 只在闭包生命周期内有效——事务随闭包返回而提交，句柄不能再拿出去用。
struct Transaction {
    fileprivate let handle: OpaquePointer

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[String: SQLValue]] {
        try sqlQuery(handle, sql, params)
    }

    func run(_ sql: String, _ params: [SQLValue] = []) throws {
        try sqlRun(handle, sql, params)
    }
}

// MARK: - 连接级 SQL 原语
//
// 这些函数在 actor 隔离之外执行：句柄由 Database 的 actor 隔离或 init 期间的
// 独占所有权保证同一时刻只有一个调用方，不会并发访问。

private func sqlMigrate(_ handle: OpaquePointer) throws {
    let version = try sqlQuery(handle, "PRAGMA user_version", []).first?["user_version"]?.int ?? 0
    if version < 1 {
        try sqlExec(handle, Schema.v1)
        try sqlExec(handle, "PRAGMA user_version = 1")
    }
    if version < 2 {
        try sqlExec(handle, Schema.v2)
        try sqlExec(handle, "PRAGMA user_version = 2")
    }
    if version < 3 {
        try sqlExec(handle, Schema.v3)
        try sqlExec(handle, "PRAGMA user_version = 3")
    }
    if version < 4 {
        try sqlExec(handle, Schema.v4)
        try sqlExec(handle, "PRAGMA user_version = 4")
    }
}

/// SQLITE_BUSY/SQLITE_LOCKED：busy_timeout 覆盖大部分等待，这里再兜住超时后
/// 仍撞上锁竞争的场景（多 CLI 并行写、迁移语句抢锁），50ms 退避最多重试 5 次。
private func isLockCode(_ code: Int32) -> Bool {
    code == SQLITE_BUSY || code == SQLITE_LOCKED
}

private let lockRetryCount = 5
private let lockRetryDelayMicroseconds: useconds_t = 50_000

private func sqlExec(_ handle: OpaquePointer, _ sql: String) throws {
    var retries = 0
    while true {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        if code == SQLITE_OK { return }
        guard isLockCode(code), retries < lockRetryCount else {
            throw DatabaseError.execFailed(lastErrorMessage(handle))
        }
        retries += 1
        // 脚本在事务中间被锁打断时会留下开着的事务，重放前先回滚干净；
        // COMMIT/ROLLBACK 本身是事务动词，原样重试即可。
        let verb = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !verb.hasPrefix("COMMIT"), !verb.hasPrefix("ROLLBACK") {
            _ = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        }
        usleep(lockRetryDelayMicroseconds)
    }
}

private func sqlQuery(_ handle: OpaquePointer, _ sql: String, _ params: [SQLValue]) throws -> [[String: SQLValue]] {
    var statement: OpaquePointer?
    var prepareRetries = 0
    while true {
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        if code == SQLITE_OK, statement != nil { break }
        guard isLockCode(code), prepareRetries < lockRetryCount else {
            throw DatabaseError.prepareFailed(lastErrorMessage(handle))
        }
        prepareRetries += 1
        usleep(lockRetryDelayMicroseconds)
    }
    guard let statement else {
        throw DatabaseError.prepareFailed(lastErrorMessage(handle))
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in params.enumerated() {
        bind(statement, Int32(index + 1), value)
    }

    var rows: [[String: SQLValue]] = []
    var retries = 0
    while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW {
            let columns = sqlite3_column_count(statement)
            var row: [String: SQLValue] = [:]
            row.reserveCapacity(Int(columns))
            for column in 0..<columns {
                let name = String(cString: sqlite3_column_name(statement, column))
                row[name] = readColumn(statement, column)
            }
            rows.append(row)
        } else if code == SQLITE_DONE {
            break
        } else if isLockCode(code), retries < lockRetryCount {
            retries += 1
            // reset 后整条查询从头执行，已收集的半截行必须丢弃避免重复
            sqlite3_reset(statement)
            rows.removeAll()
            usleep(lockRetryDelayMicroseconds)
        } else {
            throw DatabaseError.stepFailed(lastErrorMessage(handle))
        }
    }
    return rows
}

private func sqlRun(_ handle: OpaquePointer, _ sql: String, _ params: [SQLValue]) throws {
    var statement: OpaquePointer?
    var prepareRetries = 0
    while true {
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        if code == SQLITE_OK, statement != nil { break }
        guard isLockCode(code), prepareRetries < lockRetryCount else {
            throw DatabaseError.prepareFailed(lastErrorMessage(handle))
        }
        prepareRetries += 1
        usleep(lockRetryDelayMicroseconds)
    }
    guard let statement else {
        throw DatabaseError.prepareFailed(lastErrorMessage(handle))
    }
    defer { sqlite3_finalize(statement) }
    for (index, value) in params.enumerated() {
        bind(statement, Int32(index + 1), value)
    }
    var retries = 0
    while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE || code == SQLITE_ROW { return }
        // BUSY 后 sqlite3_step 可自动重置再跑；reset 显式兜底，绑定参数不受影响
        guard isLockCode(code), retries < lockRetryCount else {
            throw DatabaseError.stepFailed(lastErrorMessage(handle))
        }
        retries += 1
        sqlite3_reset(statement)
        usleep(lockRetryDelayMicroseconds)
    }
}

private func lastErrorMessage(_ handle: OpaquePointer) -> String {
    String(cString: sqlite3_errmsg(handle))
}

private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: SQLValue) {
    // SQLITE_TRANSIENT 让 SQLite 拷贝字符串，避免悬垂指针。
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    switch value {
    case .text(let text):
        sqlite3_bind_text(statement, index, text, -1, transient)
    case .int(let number):
        sqlite3_bind_int64(statement, index, Int64(number))
    case .null:
        sqlite3_bind_null(statement, index)
    }
}

private func readColumn(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_INTEGER:
        return .int(Int(sqlite3_column_int64(statement, index)))
    case SQLITE_FLOAT:
        return .int(Int(sqlite3_column_double(statement, index)))
    case SQLITE_NULL:
        return .null
    default:
        return .text(String(cString: sqlite3_column_text(statement, index)))
    }
}
