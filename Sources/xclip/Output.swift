import Foundation
import XClipCore

// MARK: - JSON 契约（agent 消费侧）

struct MediaDTO: Encodable {
    let type: String
    let localPath: String?
    let previewImageLocalPath: String?
    let width: Int?
    let height: Int?

    init(item: MediaItem, mediaRoot: URL) {
        type = item.type
        localPath = MediaCache.localFileIfPresent(in: mediaRoot, for: item.url)?.path
        let preview = Output.previewURL(for: item)
        previewImageLocalPath = (preview == item.url ? nil : preview).flatMap {
            MediaCache.localFileIfPresent(in: mediaRoot, for: $0)?.path
        }
        width = item.width
        height = item.height
    }
}

/// 完整贴文：只含本地可消费内容，不带上游作者/指标/链接噪音。
struct PostDTO: Encodable {
    let shortId: String
    let tags: [String]
    let summary: String
    let note: String
    let text: String
    let media: [MediaDTO]
    let fetchStatus: String

    init(post: Post, mediaRoot: URL) {
        shortId = post.shortID
        tags = post.tags
        summary = post.summary
        note = post.note
        text = post.text
        media = post.media.map { MediaDTO(item: $0, mediaRoot: mediaRoot) }
        fetchStatus = post.fetchStatus
    }
}

/// 列表索引项：编码 + 标签 + 提炼，agent 扫完就决定是否 show。
struct PostIndexDTO: Encodable {
    let shortId: String
    let tags: [String]
    let summary: String
}

struct PostListDTO: Encodable {
    let schemaVersion = 1
    let posts: [PostIndexDTO]
}

struct PostDetailDTO: Encodable {
    let schemaVersion = 1
    let post: PostDTO
    /// 当前标签池，录入/修改后直接可挑，省一次 xclip tags 调用
    let availableTags: [TagDTO]
}

struct TagDTO: Encodable {
    let slug: String
    let name: String
    let description: String?
    let count: Int
}

struct TagResultDTO: Encodable {
    let schemaVersion = 1
    let action: String
    let message: String
    let tag: TagDTO?
}

struct TagListDTO: Encodable {
    let schemaVersion = 1
    let tags: [TagDTO]
}

struct DeleteResultDTO: Encodable {
    let schemaVersion = 1
    let deleted: String
    let shortId: String
    let url: String
}

struct WarmResultDTO: Encodable {
    let schemaVersion = 1
    let total: Int
    let downloaded: Int
    let failed: Int
    let alreadyCached: Int
}

// MARK: - 输出

enum Output {
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// 视频/动图的静态预览图地址：Agent 没法直接读 mp4，看视频内容走它。
    static func previewURL(for item: MediaItem) -> String? {
        guard item.type != "photo" else { return nil }
        return item.previewImageURL
    }

    /// 本地化索引视图：编码 + 标签 + 提炼，不含作者/链接等上游噪音。
    /// summary 规范为英文单句不换行；为空标 [pending summary]，供补提炼。
    static func listLine(_ post: Post, index: Int) -> String {
        let header = "[\(post.shortID)] \(post.tags.isEmpty ? "[untagged]" : post.tags.joined(separator: ", "))"
        let body = post.summary.isEmpty ? "  [pending summary]" : "  \(post.summary)"
        return header + "\n" + body
    }

    /// 本地内容视图：编码/标签/提炼/备注/正文/本地媒体路径，不带上游信息。
    /// tagNames 为 slug → 中文名映射，标签回显为 slug(中文名)。
    static func detail(_ post: Post, mediaRoot: URL, tagNames: [String: String] = [:]) -> String {
        var lines: [String] = [
            "编码:   \(post.shortID)",
            "标签:   \(post.tags.isEmpty ? "（无）" : displayTags(post.tags, names: tagNames))"
        ]
        let summaryText = post.summary.isEmpty
            ? "（未填写，请用 1-2 句英文补充: xclip update \(post.shortID) --summary \"...\"）"
            : post.summary
        lines.append("提炼:   \(summaryText)")
        if !post.note.isEmpty && post.note != post.summary {
            lines.append("备注:   \(post.note)")
        }
        if post.fetchStatus != "ok" {
            lines.append("状态:   抓取失败，仅保存链接（xclip update \(post.shortID) --refetch 补抓）")
        }
        if !post.text.isEmpty {
            lines.append("")
            lines.append("正文:")
            lines.append(post.text)
        }
        if !post.media.isEmpty {
            lines.append("")
            lines.append("媒体文件:")
            for (index, item) in post.media.enumerated() {
                var head = "  \(index + 1). \(item.type)"
                if let width = item.width, let height = item.height {
                    head += " · \(width)×\(height)"
                }
                lines.append(head)
                let local = MediaCache.localFileIfPresent(in: mediaRoot, for: item.url)
                lines.append("     本地路径: \(local?.path ?? "（未缓存）")")
                if let preview = previewURL(for: item), preview != item.url {
                    let previewLocal = MediaCache.localFileIfPresent(in: mediaRoot, for: preview)
                    lines.append("     预览图:   \(previewLocal?.path ?? "（未缓存）")")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
