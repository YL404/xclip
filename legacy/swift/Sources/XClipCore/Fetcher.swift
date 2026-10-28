import Foundation

public enum FetchError: Error, Equatable {
    case missingScreenName
    case httpStatus(Int)
    case apiError(String)
    case malformedResponse
}

public struct FetchedPost: Equatable, Sendable {
    public var externalID: String
    public var url: String
    public var authorHandle: String
    public var authorName: String
    public var authorAvatar: String?
    public var text: String
    public var media: [MediaItem]
    public var metrics: Metrics
    public var postedAt: Date?

    public init(externalID: String, url: String, authorHandle: String, authorName: String,
                authorAvatar: String?, text: String, media: [MediaItem], metrics: Metrics,
                postedAt: Date?) {
        self.externalID = externalID
        self.url = url
        self.authorHandle = authorHandle
        self.authorName = authorName
        self.authorAvatar = authorAvatar
        self.text = text
        self.media = media
        self.metrics = metrics
        self.postedAt = postedAt
    }
}

/// 通过 fxtwitter 的免费无鉴权接口抓取贴文快照。
public struct Fetcher: Sendable {
    private let session: URLSession
    private let proxySession: URLSession?

    /// 显式注入的 session 原样使用（测试的 MockURLProtocol 不被代理配置干扰）；
    /// 默认构造时从环境变量解析代理，抓不到就用纯直连，瞬时错误照样重试。
    public init(session: URLSession = .shared) {
        self.session = session
        self.proxySession = session === URLSession.shared ? HTTPClient.environmentProxySession() : nil
    }

    public func fetch(ref: PostRef) async throws -> FetchedPost {
        // `/i/status/<id>` 形式拿不到用户名，fxtwitter 无法按路径抓取。
        guard !ref.screenName.isEmpty else { throw FetchError.missingScreenName }

        guard let url = URL(string: "https://api.fxtwitter.com/\(ref.screenName)/status/\(ref.id)") else {
            throw FetchError.malformedResponse
        }
        let (data, response) = try await HTTPClient.data(from: url, session: session, proxySession: proxySession)
        guard let http = response as? HTTPURLResponse else { throw FetchError.malformedResponse }
        guard http.statusCode == 200 else { throw FetchError.httpStatus(http.statusCode) }

        let decoded: FXResponse
        do {
            decoded = try JSONDecoder().decode(FXResponse.self, from: data)
        } catch {
            throw FetchError.malformedResponse
        }
        guard decoded.code == 200, let tweet = decoded.tweet else {
            throw FetchError.apiError(decoded.message ?? "接口未返回贴文")
        }

        return FetchedPost(
            externalID: tweet.id,
            // 用接口返回的作者名重建 URL，覆盖 `/i/status/` 这种不带用户名的输入。
            url: "https://x.com/\(tweet.author.screenName.lowercased())/status/\(tweet.id)",
            authorHandle: tweet.author.screenName,
            authorName: tweet.author.name,
            authorAvatar: tweet.author.avatarURL,
            text: tweet.text ?? "",
            media: (tweet.media?.all ?? []).compactMap { item in
                guard item.type == "photo" || item.type == "video" || item.type == "gif" else { return nil }
                // gif 归一成 video，让帖子带视频徽标。video/gif 的 url 是 mp4 流地址，
                // 静态预览图在 thumbnail_url——两个都留：界面预览走缩略图，播放和本地留存走 mp4。
                if item.type == "photo" {
                    return MediaItem(type: "photo", url: item.url, width: item.width, height: item.height)
                }
                return MediaItem(
                    type: "video",
                    url: item.url.isEmpty ? (item.thumbnailURL ?? "") : item.url,
                    thumbnailURL: item.thumbnailURL,
                    width: item.width,
                    height: item.height
                )
            },
            metrics: Metrics(
                likes: tweet.likes ?? 0,
                retweets: tweet.retweets ?? 0,
                replies: tweet.replies ?? 0,
                views: tweet.views ?? 0,
                bookmarks: tweet.bookmarks ?? 0
            ),
            postedAt: tweet.createdTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

// MARK: - fxtwitter 响应模型

private struct FXResponse: Decodable {
    var code: Int?
    var message: String?
    var tweet: FXTweet?
}

private struct FXTweet: Decodable {
    var id: String
    var text: String?
    var author: FXAuthor
    var media: FXMedia?
    var createdTimestamp: Int?
    var likes: Int?
    var retweets: Int?
    var replies: Int?
    var views: Int?
    var bookmarks: Int?

    enum CodingKeys: String, CodingKey {
        case id, text, author, media, likes, retweets, replies, views, bookmarks
        case createdTimestamp = "created_timestamp"
    }
}

private struct FXAuthor: Decodable {
    var screenName: String
    var name: String
    var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case screenName = "screen_name", name
        case avatarURL = "avatar_url"
    }
}

private struct FXMedia: Decodable {
    var all: [FXMediaItem]?
}

private struct FXMediaItem: Decodable {
    var type: String
    var url: String
    var thumbnailURL: String?
    var width: Int?
    var height: Int?

    enum CodingKeys: String, CodingKey {
        case type, url, width, height
        case thumbnailURL = "thumbnail_url"
    }
}
