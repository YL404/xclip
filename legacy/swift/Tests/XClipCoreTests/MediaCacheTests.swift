import Testing
import Foundation
@testable import XClipCore

struct MediaCacheTests {
    /// 每个测试一套独立的缓存根目录和源文件目录。
    private func scratch() throws -> (cacheRoot: URL, sourceDir: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("xclip-media-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = base.appendingPathComponent("cache", isDirectory: true)
        let sourceDir = base.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        return (cacheRoot, sourceDir)
    }

    private func writeSource(_ dir: URL, name: String = "photo.jpg", bytes: Data) throws -> URL {
        let file = dir.appendingPathComponent(name)
        try bytes.write(to: file)
        return file
    }

    @Test
    func resolvesVariantOnlyForTwimg() {
        let twimg = mediaURL("https://pbs.twimg.com/media/ABC.jpg?name=orig", variant: .large)
        #expect(twimg?.absoluteString == "https://pbs.twimg.com/media/ABC.jpg?name=large")

        // 已有其他查询参数时只替换 name，其余保留
        let withParams = mediaURL("https://pbs.twimg.com/media/ABC.jpg?foo=1&name=small", variant: .medium)
        #expect(withParams?.absoluteString == "https://pbs.twimg.com/media/ABC.jpg?foo=1&name=medium")

        // 头像/横幅尺寸已编码在路径里，追加 ?name 会被 CDN 404——原样返回
        #expect(mediaURL("https://pbs.twimg.com/profile_images/1955418282078638082/DcvXKbre_200x200.jpg",
                         variant: .large)?.absoluteString
            == "https://pbs.twimg.com/profile_images/1955418282078638082/DcvXKbre_200x200.jpg")
        #expect(mediaURL("https://pbs.twimg.com/profile_banners/1/1700000000/600x200", variant: .large)?
            .absoluteString == "https://pbs.twimg.com/profile_banners/1/1700000000/600x200")
        // 其余 pbs 路径（视频缩略图等）照旧改写 name
        #expect(mediaURL("https://pbs.twimg.com/amplify_video_thumb/123/img/abc.jpg",
                         variant: .large)?.absoluteString
            == "https://pbs.twimg.com/amplify_video_thumb/123/img/abc.jpg?name=large")

        // 非 twimg 域原样返回，本地文件地址也原样返回
        #expect(mediaURL("https://example.com/a.jpg?name=orig", variant: .large)?.absoluteString
            == "https://example.com/a.jpg?name=orig")
        #expect(mediaURL("file:///tmp/a.jpg", variant: .large)?.absoluteString == "file:///tmp/a.jpg")
        #expect(mediaURL("", variant: .large) == nil)
    }

    @Test
    func cachesDownloadedBytesAndReusesThem() async throws {
        let (cacheRoot, sourceDir) = try scratch()
        let source = try writeSource(sourceDir, bytes: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x11, 0x22, 0x33]))
        let cache = MediaCache(root: cacheRoot)

        // 首次：下载并落盘（file:// 地址走同一条下载路径）
        let local = try #require(await cache.cachedFile(for: source.absoluteString))
        #expect(local.pathExtension == "jpg")
        #expect(FileManager.default.contents(atPath: local.path) == Data([0xFF, 0xD8, 0xFF, 0xE0, 0x11, 0x22, 0x33]))

        // 源文件删掉后仍然命中——本地文件是派生缓存，不依赖上游
        try FileManager.default.removeItem(at: source)
        let again = try #require(await cache.cachedFile(for: source.absoluteString))
        #expect(again == local)
        #expect(cache.localFileIfPresent(for: source.absoluteString) == local)
    }

    @Test
    func fileNameIsContentAddressedAndStable() async throws {
        let (cacheRoot, sourceDir) = try scratch()
        let source = try writeSource(sourceDir, name: "stable.png", bytes: Data([1, 2, 3, 4]))
        let cache = MediaCache(root: cacheRoot)

        let first = try #require(await cache.cachedFile(for: source.absoluteString))
        let second = try #require(await cache.cachedFile(for: source.absoluteString))
        #expect(first == second)
        #expect(first.pathExtension == "png")

        // 同一地址换规格等于换键，不会误用旧文件
        #expect(first.lastPathComponent != MediaCache(root: cacheRoot).localFileIfPresent(for: "https://pbs.twimg.com/media/x.png?name=thumb")?.lastPathComponent)
    }

    @Test
    func warmSkipsCachedAndDeduplicates() async throws {
        let (cacheRoot, sourceDir) = try scratch()
        let first = try writeSource(sourceDir, name: "one.jpg", bytes: Data([1, 1, 1]))
        let second = try writeSource(sourceDir, name: "two.jpg", bytes: Data([2, 2, 2]))
        let cache = MediaCache(root: cacheRoot)

        // 同一地址传两次只算一次
        let result = await cache.warm([first.absoluteString, second.absoluteString, first.absoluteString])
        #expect(result.downloaded == 2)
        #expect(result.failed == 0)

        // 全部已有：什么都不做
        let again = await cache.warm([first.absoluteString, second.absoluteString])
        #expect(again.downloaded == 0)
        #expect(again.failed == 0)
    }

    @Test
    func cachesVideoFileWithMp4Extension() async throws {
        let (cacheRoot, sourceDir) = try scratch()
        let source = try writeSource(sourceDir, name: "clip.mp4",
                                     bytes: Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74]))
        let cache = MediaCache(root: cacheRoot)

        // 视频文件走同一条缓存路径，扩展名保留 mp4
        let local = try #require(await cache.cachedFile(for: source.absoluteString))
        #expect(local.pathExtension == "mp4")
        #expect(FileManager.default.contents(atPath: local.path)
            == Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74]))

        // 静态查询不用建 actor：同样的 root 直接查到文件
        #expect(MediaCache.localFileIfPresent(in: cacheRoot, for: source.absoluteString) == local)
        #expect(MediaCache.localFileIfPresent(in: cacheRoot, for: "https://example.com/x.png") == nil)
    }

    @Test
    func infersCacheExtensionFromURL() {
        let root = URL(fileURLWithPath: "/tmp/xclip-cache")

        // path 上的扩展名优先，原样保留
        #expect(MediaCache.fileURL(in: root, for: "https://video.twimg.com/v/clip.mp4")
            .pathExtension == "mp4")
        // pbs.twimg.com 无 path 扩展名时读 format 查询参数
        #expect(MediaCache.fileURL(in: root,
            for: "https://pbs.twimg.com/media/ABC?format=jpg&name=large").pathExtension == "jpg")
        // video.twimg.com 的无扩展名地址是视频流，按 mp4 处理
        #expect(MediaCache.fileURL(in: root,
            for: "https://video.twimg.com/ext_tw_video/1/pu/vid/x").pathExtension == "mp4")
        // 其余无扩展名地址退回 img
        #expect(MediaCache.fileURL(in: root, for: "https://example.com/noext")
            .pathExtension == "img")
    }

    @Test
    func collectibleURLsGathersMediaThumbnailsAndAvatar() {
        let post = Post(
            id: UUID().uuidString, platform: "x", externalID: "1",
            url: "https://x.com/a/status/1", authorHandle: "a", authorName: "A",
            authorAvatar: "https://pbs.twimg.com/profile_images/a.jpg",
            text: "x",
            media: [
                MediaItem(type: "photo", url: "https://pbs.twimg.com/media/p.jpg"),
                MediaItem(type: "video", url: "https://video.twimg.com/v.mp4",
                          thumbnailURL: "https://pbs.twimg.com/thumb/v.jpg"),
                // 重复地址只收一次；空 url 不收
                MediaItem(type: "photo", url: "https://pbs.twimg.com/media/p.jpg"),
                MediaItem(type: "video", url: "")
            ],
            metrics: Metrics(), fetchStatus: "ok", postedAt: nil, savedAt: Date(), tags: [])

        #expect(MediaCache.collectibleURLs(for: post) == [
            "https://pbs.twimg.com/media/p.jpg",
            "https://video.twimg.com/v.mp4",
            "https://pbs.twimg.com/thumb/v.jpg",
            "https://pbs.twimg.com/profile_images/a.jpg"
        ])

        // contentMediaURLs 只收附件媒体（url + 视频缩略图），不含头像
        #expect(MediaCache.contentMediaURLs(for: post) == [
            "https://pbs.twimg.com/media/p.jpg",
            "https://video.twimg.com/v.mp4",
            "https://pbs.twimg.com/thumb/v.jpg"
        ])

        // 无媒体无头像的贴文返回空
        let bare = Post(
            id: UUID().uuidString, platform: "x", externalID: "2",
            url: "https://x.com/b/status/2", authorHandle: "b", authorName: "",
            authorAvatar: nil, text: "y", media: [], metrics: Metrics(),
            fetchStatus: "ok", postedAt: nil, savedAt: Date(), tags: [])
        #expect(MediaCache.collectibleURLs(for: bare).isEmpty)
    }
}
