import Foundation
import XClipCore

extension Post {
    /// Preview 与开发用的自包含样例，不依赖网络或数据库。
    static let preview = Post(
        id: "preview",
        platform: "x",
        externalID: "1900000000000000001",
        url: "https://x.com/mika_sole/status/1900000000000000001",
        authorHandle: "mika_sole",
        authorName: "Mika Sole",
        authorAvatar: nil,
        text: "Nothing beats a good product demo. The whole team shipped this in a week.",
        media: [],
        metrics: Metrics(likes: 981, retweets: 39, replies: 15, views: 40286, bookmarks: 919),
        summary: "一周做完产品 demo 的团队复盘：演示驱动开发缩小了决策范围",
        note: "",
        fetchStatus: "ok",
        postedAt: Date(timeIntervalSince1970: 1790234033),
        savedAt: Date.now,
        tags: ["product-design", "ui-design"]
    )
}
