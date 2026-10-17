import Foundation
import SQLite3

/// 传给 SQL 语句的绑定值。仅 core 内部使用，不作为库的公开接口。
enum SQLValue: Equatable {
    case text(String)
    case int(Int)
    case null

    var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}
