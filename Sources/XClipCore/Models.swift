import Foundation

public struct MediaItem: Equatable, Sendable, Codable {
    public var type: String          // "photo" | "video"
    public var url: String           // photo: 图片地址; video: 视频 mp4 地址（无 mp4 时退回缩略图）
    public var thumbnailURL: String? // video: 静态预览图地址; photo: nil
    public var width: Int?
    public var height: Int?

    public init(type: String, url: String, thumbnailURL: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.type = type
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.width = width
        self.height = height
    }

    /// 供界面显示的静态预览图地址：有 thumbnailURL 优先用它；否则若不是 mp4 视频流则用 url。
    public var previewImageURL: String? {
        if let thumbnailURL, !thumbnailURL.isEmpty { return thumbnailURL }
        let lowered = url.lowercased()
        if type == "video" && (lowered.contains(".mp4") || lowered.contains("video.twimg.com")) {
            return nil
        }
        return url.isEmpty ? nil : url
    }
}

public struct Metrics: Equatable, Sendable, Codable {
    public var likes: Int
    public var retweets: Int
    public var replies: Int
    public var views: Int
    public var bookmarks: Int

    public init(likes: Int = 0, retweets: Int = 0, replies: Int = 0, views: Int = 0, bookmarks: Int = 0) {
        self.likes = likes
        self.retweets = retweets
        self.replies = replies
        self.views = views
        self.bookmarks = bookmarks
    }
}

public struct Post: Equatable, Sendable, Identifiable {
    public let id: String            // 内部 UUID
    public let platform: String      // v1 恒为 "x"
    public let externalID: String    // tweet id，去重依据
    public let url: String           // 规范化展示 URL
    public let authorHandle: String
    public let authorName: String
    public let authorAvatar: String?
    public let text: String
    public let media: [MediaItem]
    public let metrics: Metrics
    public let summary: String       // 内容提炼描述（录入 Agent 落盘的高价值总结，用于内容索引）
    public let note: String          // 用户自己的话
    public let fetchStatus: String   // "ok" | "failed"
    public let postedAt: Date?
    public let savedAt: Date
    public let tags: [String]

    /// 8 位短编码（去除 UUID 连字符后的前 8 位小写字符），供索引展示与快速引用。
    public var shortID: String {
        let compact = id.replacing("-", with: "").lowercased()
        return String(compact.prefix(8))
    }

    /// 优先展示 summary，为空时退回 note，再退回 text。
    public var displaySummary: String {
        if !summary.isEmpty { return summary }
        if !note.isEmpty { return note }
        return text
    }

    public init(id: String, platform: String, externalID: String, url: String, authorHandle: String,
                authorName: String, authorAvatar: String?, text: String, media: [MediaItem],
                metrics: Metrics, summary: String = "", note: String = "", fetchStatus: String,
                postedAt: Date?, savedAt: Date, tags: [String]) {
        self.id = id
        self.platform = platform
        self.externalID = externalID
        self.url = url
        self.authorHandle = authorHandle
        self.authorName = authorName
        self.authorAvatar = authorAvatar
        self.text = text
        self.media = media
        self.metrics = metrics
        self.summary = summary
        self.note = note
        self.fetchStatus = fetchStatus
        self.postedAt = postedAt
        self.savedAt = savedAt
        self.tags = tags
    }
}

public struct PostDraft: Equatable, Sendable {
    public var platform: String
    public var externalID: String
    public var url: String
    public var authorHandle: String
    public var authorName: String
    public var authorAvatar: String?
    public var text: String
    public var media: [MediaItem]
    public var metrics: Metrics
    public var summary: String
    public var note: String
    public var fetchStatus: String
    public var postedAt: Date?
    public var tags: [String]
    /// 为 true 时清空该贴文的全部标签。`tags` 为空本身表示「不动标签」，
    /// 两者分工不同：重新录入补个备注不该把标签弄丢。
    public var clearTags: Bool

    public init(platform: String = "x", externalID: String, url: String, authorHandle: String,
                authorName: String = "", authorAvatar: String? = nil, text: String = "",
                media: [MediaItem] = [], metrics: Metrics = Metrics(), summary: String = "",
                note: String = "", fetchStatus: String = "ok", postedAt: Date? = nil,
                tags: [String] = [], clearTags: Bool = false) {
        self.platform = platform
        self.externalID = externalID
        self.url = url
        self.authorHandle = authorHandle
        self.authorName = authorName
        self.authorAvatar = authorAvatar
        self.text = text
        self.media = media
        self.metrics = metrics
        self.summary = summary
        self.note = note
        self.fetchStatus = fetchStatus
        self.postedAt = postedAt
        self.tags = tags
        self.clearTags = clearTags
    }
}

/// 局部编辑入参：nil 表示不动该字段。标签三种语义可叠加——`replaceTags` 整体替换 /
/// `addTags`、`removeTags` 增量增减 / `clearTags` 清空（优先级最高，先于增量生效）。
public struct PostPatch: Equatable, Sendable {
    public var summary: String?
    public var note: String?
    public var replaceTags: [String]?
    public var addTags: [String]
    public var removeTags: [String]
    public var clearTags: Bool

    public init(summary: String? = nil, note: String? = nil, replaceTags: [String]? = nil,
                addTags: [String] = [], removeTags: [String] = [], clearTags: Bool = false) {
        self.summary = summary
        self.note = note
        self.replaceTags = replaceTags
        self.addTags = addTags
        self.removeTags = removeTags
        self.clearTags = clearTags
    }
}

public enum PostSort: String, Equatable, Sendable, CaseIterable {
    case latest, bookmarks, likes
}

public struct ListFilter: Equatable, Sendable {
    public var tags: [String]
    public var query: String?
    public var sort: PostSort
    public var limit: Int

    public init(tags: [String] = [], query: String? = nil, sort: PostSort = .latest, limit: Int = 200) {
        self.tags = tags
        self.query = query
        self.sort = sort
        self.limit = limit
    }
}

public struct Tag: Equatable, Sendable, Identifiable {
    public var id: String { slug }
    public let slug: String          // 英文唯一标识（Agent 使用）
    public let name: String          // 中文唯一名称（App 界面给人展示）
    public let description: String?
    public let count: Int

    public init(slug: String, name: String, description: String?, count: Int) {
        self.slug = slug
        self.name = name
        self.description = description
        self.count = count
    }
}

public enum SummaryValidationError: Error, Equatable, CustomStringConvertible {
    case containsCJK
    case multiline
    case tooLong(Int)
    case tooManySentences(Int)

    public var description: String {
        switch self {
        case .containsCJK:
            return "提炼描述（summary）必须使用英文，不能包含中文字符"
        case .multiline:
            return "提炼描述（summary）限 1-2 句英文，不能换行"
        case .tooLong(let count):
            return "提炼描述（summary）过长（\(count) 字符，上限 \(SummaryValidator.maxCharacters) 字符），请精简为 1-2 句英文"
        case .tooManySentences(let count):
            return "提炼描述（summary）超过 \(SummaryValidator.maxSentences) 句（当前 \(count) 句），请精简为 1-2 句英文"
        }
    }
}

/// `summary` 提炼描述的写入校验：限 1-2 句英文。空串放行（表示暂未提炼），
/// 非空串校验通过后返回 trim 后的值。检索词、note、text 不受此限——只管 summary。
public enum SummaryValidator {
    /// 字符上限：2 句精炼英文写到 ~330 字符是常见情况，上限放宽到 400。
    public static let maxCharacters = 400
    /// 句数上限：只留 1-2 句高密度概括。
    public static let maxSentences = 2

    public static func validate(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.contains("\n") || trimmed.contains("\r") {
            throw SummaryValidationError.multiline
        }
        if trimmed.unicodeScalars.contains(where: isCJK) {
            throw SummaryValidationError.containsCJK
        }
        if trimmed.count > maxCharacters {
            throw SummaryValidationError.tooLong(trimmed.count)
        }
        let sentences = sentenceCount(trimmed)
        if sentences > maxSentences {
            throw SummaryValidationError.tooManySentences(sentences)
        }
        return trimmed
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,    // CJK 统一表意文字
             0x3400...0x4DBF,    // 表意文字扩展 A
             0x3040...0x30FF,    // 平假名、片假名
             0xFF61...0xFF9F,    // 半角片假名
             0x1100...0x11FF,    // 谚文字母
             0x3130...0x318F,    // 谚文兼容字母
             0xAC00...0xD7AF,    // 谚文音节
             0x3000...0x303F,    // CJK 标点
             0xFF01...0xFF60:    // 全角中日韩字符
            return true
        default:
            return false
        }
    }

    /// 句数估计：`.`/`!`/`?` 后跟空白或位于结尾算一个句子边界；连续标点只算一次。
    private static func sentenceCount(_ text: String) -> Int {
        var count = 0
        var pendingTerminator = false
        for character in text {
            if character == "." || character == "!" || character == "?" {
                pendingTerminator = true
            } else if character.isWhitespace {
                if pendingTerminator { count += 1; pendingTerminator = false }
            } else {
                pendingTerminator = false
            }
        }
        if pendingTerminator { count += 1 }
        return max(1, count)
    }
}
