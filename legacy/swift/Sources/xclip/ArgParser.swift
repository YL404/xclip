import Foundation

/// 命令行参数解析。零第三方依赖：`swift build` 不需要网络。
struct Option {
    var long: String
    var short: String?
    var takesValue: Bool

    init(_ long: String, short: String? = nil, takesValue: Bool = false) {
        self.long = long
        self.short = short
        self.takesValue = takesValue
    }
}

struct Parsed {
    var values: [String: [String]] = [:]
    var positionals: [String] = []

    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
    func has(_ name: String) -> Bool { values[name] != nil }
}

enum ParseError: Error, CustomStringConvertible {
    case helpRequested
    case unknownFlag(String)
    case missingValue(String)
    case unexpectedValue(String)

    var description: String {
        switch self {
        case .helpRequested: return ""
        case .unknownFlag(let flag): return "未知选项: \(flag)"
        case .missingValue(let flag): return "选项缺少参数: \(flag)"
        case .unexpectedValue(let flag): return "选项不接受参数: \(flag)"
        }
    }
}

/// 解析规则：`--long value`、`--long=value`、`-s value`、`-svalue`；
/// 布尔选项不取值；可重复选项累积为数组；`--` 之后全部按位置参数处理。
func parse(_ arguments: [String], options: [Option]) throws -> Parsed {
    var parsed = Parsed()
    var index = arguments.startIndex

    func record(_ name: String, _ value: String) {
        parsed.values[name, default: []].append(value)
    }

    while index < arguments.endIndex {
        let argument = arguments[index]
        index += 1

        if argument == "--" {
            parsed.positionals.append(contentsOf: arguments[index...])
            break
        }
        if argument == "-h" || argument == "--help" {
            throw ParseError.helpRequested
        }

        if argument.hasPrefix("--") {
            let body = String(argument.dropFirst(2))
            let (name, inlineValue) = body.splitFirst("=")
            guard let option = options.first(where: { $0.long == name }) else {
                throw ParseError.unknownFlag("--\(name)")
            }
            if option.takesValue {
                if let inlineValue {
                    record(name, inlineValue)
                } else if index < arguments.endIndex {
                    record(name, arguments[index])
                    index += 1
                } else {
                    throw ParseError.missingValue("--\(name)")
                }
            } else if inlineValue != nil {
                throw ParseError.unexpectedValue("--\(name)")
            } else {
                record(name, "")
            }
        } else if argument.hasPrefix("-"), argument.count > 1 {
            let body = String(argument.dropFirst(1))
            let name = String(body.prefix(1))
            guard let option = options.first(where: { $0.short == name }) else {
                throw ParseError.unknownFlag("-\(name)")
            }
            let attached = String(body.dropFirst(1))
            if option.takesValue {
                if !attached.isEmpty {
                    record(option.long, attached)
                } else if index < arguments.endIndex {
                    record(option.long, arguments[index])
                    index += 1
                } else {
                    throw ParseError.missingValue("-\(name)")
                }
            } else if !attached.isEmpty {
                throw ParseError.unexpectedValue(argument)
            } else {
                record(option.long, "")
            }
        } else {
            parsed.positionals.append(argument)
        }
    }
    return parsed
}

extension String {
    /// 按第一个分隔符切成两段，不存在分隔符时第二段为 nil。
    func splitFirst(_ separator: Character) -> (String, String?) {
        guard let index = firstIndex(of: separator) else { return (self, nil) }
        return (String(self[..<index]), String(self[self.index(after: index)...]))
    }
}

/// 剥离开头的 `--db 路径` / `--db=路径`，返回剩余参数和取出的数据库参数。
/// 供顶层命令和 `tag` 子命令复用：两种写法都支持。
func stripLeadingDatabaseOption(_ arguments: [String]) throws -> (rest: [String], database: [String]) {
    var rest = arguments
    var database: [String] = []

    while rest.first == "--db" {
        guard rest.count >= 2 else { throw ParseError.missingValue("--db") }
        database.append(contentsOf: [rest[0], rest[1]])
        rest.removeFirst(2)
    }
    while rest.first?.hasPrefix("--db=") == true {
        database.append(rest.removeFirst())
    }
    return (rest, database)
}
