import CryptoKit
import Foundation

/// 图片规格。pbs.twimg.com 用 `name` 查询参数区分。
public enum MediaVariant: String, Sendable, CaseIterable {
    case thumb, small, medium, large
}

/// 按规格解析图片地址。只对 pbs.twimg.com 改写 `name` 参数，其他域原样返回。
/// 头像和横幅（/profile_images/、/profile_banners/）的尺寸已经编码在文件名里，
/// 追加 `?name=` 反而被 CDN 404——这两类路径原样返回。
public func mediaURL(_ remoteURL: String, variant: MediaVariant) -> URL? {
    guard let url = URL(string: remoteURL) else { return nil }
    guard url.host()?.contains("pbs.twimg.com") == true else { return url }
    if url.path.hasPrefix("/profile_images/") || url.path.hasPrefix("/profile_banners/") {
        return url
    }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "name" }
    items.append(URLQueryItem(name: "name", value: variant.rawValue))
    components.queryItems = items
    return components.url
}

/// 图片的本地缓存。
///
/// 库里只存远程地址，本地文件是**派生缓存**：删掉能重建，数据库不依赖它。
/// 文件名是地址（含规格）的内容寻址哈希，所以同一地址永远落到同一文件，
/// 也顺带去重。写入先落临时文件再 move，避免半张图被当成缓存。
public actor MediaCache {
    private let root: URL
    private let session: URLSession
    private let proxySession: URLSession?

    /// 建目录失败不抛错：缓存是优化不是正确性依赖，写盘时会自然失败并降级回远程。
    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // 专用 session，不用 .shared：它的 timeoutIntervalForResource 是 7 天，
        // 一个挂死的连接能把整个 warm 队列堵住。关掉 URLCache 避免和我们自己的缓存重复占盘。
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        // 资源超时 45s：代理通道卡死时给回退直连的重试留余量，
        // 保证最坏情况也远小于外层命令 120s 的强杀线。
        configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
        // 环境变量代理（终端常配 HTTPS_PROXY）：与直连同样的超时约束，
        // 代理进程没起或断流时 HTTPClient 会自动回退直连。
        self.proxySession = HTTPClient.environmentProxySession {
            $0.timeoutIntervalForRequest = 15
            $0.timeoutIntervalForResource = 45
            $0.urlCache = nil
        }
    }

    deinit {
        session.invalidateAndCancel()
        proxySession?.invalidateAndCancel()
    }

    /// 已缓存就直接给本地路径。同步、不碰网络，视图层每次显示都走它。
    public nonisolated func localFileIfPresent(for remoteURL: String) -> URL? {
        Self.localFileIfPresent(in: root, for: remoteURL)
    }

    /// 静态版同步查询：视图层渲染时不用为查文件专门建 actor 和 URLSession。
    public static func localFileIfPresent(in root: URL, for remoteURL: String) -> URL? {
        let file = fileURL(in: root, for: remoteURL)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// 单条贴文需要本地缓存的全部远程地址：每个媒体的 url、视频缩略图，外加作者头像。
    /// 去重保序，供录入后与 `warm` 批量补缓存。
    public static func collectibleURLs(for post: Post) -> [String] {
        var urls = contentMediaURLs(for: post)
        if let avatar = post.authorAvatar, !avatar.isEmpty, !urls.contains(avatar) {
            urls.append(avatar)
        }
        return urls
    }

    /// 只算贴文附件媒体（每个 media 的 url 和视频缩略图），不含作者头像。
    /// 供 CLI 把头像与正文媒体的缓存结果分开统计。去重保序。
    public static func contentMediaURLs(for post: Post) -> [String] {
        var seen = Set<String>()
        var urls: [String] = []
        for item in post.media {
            if !item.url.isEmpty, seen.insert(item.url).inserted {
                urls.append(item.url)
            }
            if let thumbnailURL = item.thumbnailURL, !thumbnailURL.isEmpty,
               seen.insert(thumbnailURL).inserted {
                urls.append(thumbnailURL)
            }
        }
        return urls
    }

    /// 没有就下载再返回。失败返回 nil，调用方继续用远程地址，保存动作不受阻塞。
    @discardableResult
    public func cachedFile(for remoteURL: String) async -> URL? {
        if let existing = localFileIfPresent(for: remoteURL) { return existing }
        guard let url = mediaURL(remoteURL, variant: .large) else { return nil }

        do {
            let (data, response) = try await HTTPClient.data(from: url, session: session, proxySession: proxySession)
            // URLSession 对非 2xx 不抛错，只返回 body。错误页是非空的，若不校验状态码
            // 会被内容寻址永久缓存——文件名只取决于 URL，没有任何自愈机会。
            // 只对 HTTP 响应校验：file:// 等非 HTTP 响应没有状态码，直接放行（测试走这条）。
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status), !data.isEmpty else { return nil }
            let destination = Self.fileURL(in: root, for: remoteURL)
            try writeAtomically(data, to: destination)
            return destination
        } catch {
            // 并发 warm 的另一进程可能已经把同一文件落盘，先查一遍再报失败
            if let existing = localFileIfPresent(for: remoteURL) { return existing }
            return nil
        }
    }

    /// 批量补缓存，已有的跳过。返回（新下载数, 失败数）。
    public func warm(_ remoteURLs: [String]) async -> (downloaded: Int, failed: Int) {
        let missing = Set(remoteURLs.filter { localFileIfPresent(for: $0) == nil })
        var downloaded = 0
        var failed = 0

        // 全部放进一个 task group，不人为分批：批与批之间串行会被最慢的一个拖住，
        // 而 URLSession 本身就有每主机连接数上限，限流交给它。
        await withTaskGroup(of: Bool.self) { group in
            for url in missing {
                group.addTask { await self.cachedFile(for: url) != nil }
            }
            for await succeeded in group {
                if succeeded { downloaded += 1 } else { failed += 1 }
            }
        }
        return (downloaded, failed)
    }

    // MARK: - Private

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = root.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        do {
            // replaceItemAt 底层是 rename(2) 原子覆盖：另一进程（App 与 CLI 同时 warm）
            // 抢先落盘同一内容寻址文件不会把 move 卡成 fileWriteFileExistsError。
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            // 另一进程抢先落盘同一内容寻址文件时直接视为成功
            if !FileManager.default.fileExists(atPath: destination.path) {
                throw error
            }
        }
    }

    static func fileURL(in root: URL, for remoteURL: String) -> URL {
        // 哈希的是解析后的地址：换规格等于换键，不会误用旧尺寸的文件
        let key = mediaURL(remoteURL, variant: .large)?.absoluteString ?? remoteURL
        let digest = Insecure.SHA1.hash(data: Data(key.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(hash.prefix(16)).\(fileExtension(for: remoteURL))")
    }

    /// 缓存文件的扩展名：URL path 有扩展名直接用它；pbs.twimg.com 常把格式放在
    /// `?format=` 查询参数里；video.twimg.com 的无扩展名地址是视频流按 mp4 处理。
    private static func fileExtension(for remoteURL: String) -> String {
        guard let url = URL(string: remoteURL) else { return "img" }
        if !url.pathExtension.isEmpty { return url.pathExtension }
        if let format = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "format" })?.value,
           !format.isEmpty {
            return format
        }
        if url.host()?.contains("video.twimg.com") == true { return "mp4" }
        return "img"
    }
}

