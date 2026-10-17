import Foundation
import XClipCore

struct CLIError: Error, CustomStringConvertible {
    var message: String
    var code: Int32

    init(_ message: String, code: Int32 = 1) {
        self.message = message
        self.code = code
    }

    var description: String { message }
}

enum Usage {
    static let text = """
    xclip — 本地 X 贴文库：正文 + 提炼描述 + 本地图片/视频

    用法:
      xclip add <链接> [选项]               录入：抓取快照并缓存媒体到本地
      xclip update <条目> [选项]            修改提炼/备注/标签（别名: edit）
      xclip list [选项] [关键词...]         内容索引：短编码 + 提炼描述（别名: search、index）
      xclip show <条目> [--json]            完整正文与本地媒体文件路径
      xclip tags [--json]                   受控标签池（slug + 中文名 + 计数 + 说明）
      xclip tag <create|set|rename|merge|delete>   标签词表维护（中英双向唯一）
      xclip warm [--json]                   预取全部媒体缓存
      xclip delete <条目> [--json]          删除（别名: rm）
      xclip help <命令>                     单条命令的详细帮助（同 <命令> --help）

    条目寻址:
      8 位短编码（如 e895bf71，可带 #）、完整 id、纯数字 tweet id、X 链接。

    通用选项:
      --db 路径    SQLite 位置，默认 ~/.xclip/xclip.db，也可用环境变量 XCLIP_DB
      --json       JSON 输出（schema_version=1），正文与提炼永不截断，媒体附 local_path

    Agent 录入工作流:
      1. xclip add <链接> -t <标签>          抓取 + 本地缓存图片/视频
      2. xclip show <短编码>                 读正文与本地媒体路径，看图/看视频
      3. xclip update <短编码> --summary "English summary" --add-tag <标签>

    Agent 检索参考工作流:
      1. xclip tags                          先看受控标签池
      2. xclip list --tag ui-design          或 xclip list 留白 — 扫 [短编码]+标签+提炼 索引
      3. xclip show <短编码>                 命中后读完整正文和本地图片/视频路径

    提炼规范:
      --summary 只收英文，1-2 句、不换行；建议 200–300 字符、硬性上限
      \(SummaryValidator.maxCharacters)，高密度概括可复用的
      设计/工程要点；不合规输入会被直接拦截报错（xclip help add 见示例）。

    说明:
      同一贴文重复 add 会被拦截并提示已有短编码，修改统一走 xclip update。
      list/show 只输出本地可消费内容（标签/提炼/正文/本地媒体路径），
      不含作者、指标、原帖链接等上游噪音；标签始终以英文 slug 呈现。
      打标时可直接内联新建标签：-t <新英文slug>:<新中文名>（add/update 均支持）。
      不传 --tag 不动已有标签，--clear-tags 才清空。
      全文搜索走 FTS5 trigram 分词，少于 3 个字符自动回退为子串匹配。
      图片（large 规格）与视频缓存到数据库同级 media/，库里只存远程地址。
    """
}

@main
struct CLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIError {
            fail(error.message, code: error.code)
        } catch ParseError.helpRequested {
            // --help 是查询不是错误，正常退出
            print(Usage.text)
        } catch let error as ParseError {
            fail(error.description, code: 64)
        } catch {
            fail(describe(error))
        }
    }

    static func run(_ arguments: [String]) async throws {
        let (arguments, leading) = try stripLeadingDatabaseOption(arguments)

        guard let command = arguments.first else {
            print(Usage.text)
            return
        }
        let rest = leading + Array(arguments.dropFirst())

        switch command {
        case "add":
            try await dispatch(AddCommand.help) { try await AddCommand.run(rest) }
        case "update", "edit":
            try await dispatch(UpdateCommand.help) { try await UpdateCommand.run(rest) }
        case "list", "search", "index":
            try await dispatch(ListCommand.help) { try await ListCommand.run(rest) }
        case "show":
            try await dispatch(ShowCommand.help) { try await ShowCommand.run(rest) }
        case "tags":
            try await dispatch(TagsCommand.help) { try await TagsCommand.run(rest) }
        case "tag":
            try await dispatch(TagCommand.help) { try await TagCommand.run(rest) }
        case "warm":
            try await dispatch(WarmCommand.help) { try await WarmCommand.run(rest) }
        case "delete", "rm":
            try await dispatch(DeleteCommand.help) { try await DeleteCommand.run(rest) }
        case "help":
            let (topic, _) = try stripLeadingDatabaseOption(rest)
            if let name = topic.first, let text = helpText(for: name) {
                print(text)
            } else {
                print(Usage.text)
            }
        case "-h", "--help":
            print(Usage.text)
        default:
            throw CLIError("未知命令: \(command)\n\n\(Usage.text)", code: 64)
        }
    }

    /// 子命令里 --help 由 ArgParser 抛 ParseError.helpRequested，
    /// 这里换回该命令的专属帮助文本打印，正常退出。
    private static func dispatch(_ help: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch ParseError.helpRequested {
            print(help)
        }
    }

    private static func helpText(for name: String) -> String? {
        switch name {
        case "add": return AddCommand.help
        case "update", "edit": return UpdateCommand.help
        case "list", "search", "index": return ListCommand.help
        case "show": return ShowCommand.help
        case "tags": return TagsCommand.help
        case "tag": return TagCommand.help
        case "warm": return WarmCommand.help
        case "delete", "rm": return DeleteCommand.help
        default: return nil
        }
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("xclip: \(message)\n".utf8))
        exit(code)
    }
}
