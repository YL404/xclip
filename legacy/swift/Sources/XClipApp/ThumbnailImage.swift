import AppKit
import ImageIO
import SwiftUI
import XClipCore

/// 远端 URL → 已落盘本地文件 的命中表。只记命中、不记 miss：
/// 后台 warm 可能稍后才把文件落下来，miss 每轮还是得查一次盘。
/// LibraryStore 的解析接口和 AuthorAvatar 共用，避免每次渲染都
/// 在主线程跑 SHA256 + stat。
final class LocalFileURLCache: @unchecked Sendable {
    static let shared = LocalFileURLCache()

    private let lock = NSLock()
    private var hits: [String: URL] = [:]

    private init() {}

    func localFile(for remoteURL: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = hits[remoteURL] { return hit }
        guard let url = MediaCache.localFileIfPresent(in: Paths.mediaRoot(), for: remoteURL) else {
            return nil
        }
        hits[remoteURL] = url
        return url
    }
}

/// 降采样缩略图的进程内共享缓存。NSCache 命中时视图 body 能同步出图，
/// 零异步闪烁、零重解码；未命中时在后台线程做 ImageIO 降采样再写回。
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.countLimit = 400 }

    func cached(url: URL, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixelSize))
    }

    /// 后台解码 + 写缓存。整段放在 detached 任务里：调用方任务被取消
    /// 也不影响写入，下一个求值者仍能吃上缓存。
    func load(url: URL, maxPixelSize: Int) async -> NSImage? {
        if let hit = cached(url: url, maxPixelSize: maxPixelSize) { return hit }
        return await Task.detached(priority: .utility) {
            if let hit = self.cached(url: url, maxPixelSize: maxPixelSize) { return hit }
            guard let image = await Self.decode(url: url, maxPixelSize: maxPixelSize) else { return nil }
            self.cache.setObject(image, forKey: self.key(url, maxPixelSize))
            return image
        }.value
    }

    private func key(_ url: URL, _ maxPixelSize: Int) -> NSString {
        "\(url.absoluteString)|\(maxPixelSize)" as NSString
    }

    /// 本地文件直接流式降采样；远端地址先取回 Data 再降采样
    /// （真正的落盘缓存由 MediaCache.warm 负责，这里不重复写盘）。
    private static func decode(url: URL, maxPixelSize: Int) async -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        let source: CGImageSource?
        if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let source,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// 降采样缩略图：缓存命中同步出图，未命中后台解码后刷新。
/// 只用于卡片/列表行/头像等缩略场景——详情页和大图查看器仍看原图。
/// 未出图时渲染为透明，底层可用 .background 铺占位（灰底或首字母头像）。
struct ThumbnailImage: View {
    let url: URL?
    let maxPixelSize: Int

    @State private var decoded: NSImage?

    var body: some View {
        let image = url.flatMap { ThumbnailCache.shared.cached(url: $0, maxPixelSize: maxPixelSize) } ?? decoded
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard let url else { return }
            // body 已同步命中缓存：再赋值 decoded 只会白触发一次刷新
            guard ThumbnailCache.shared.cached(url: url, maxPixelSize: maxPixelSize) == nil else { return }
            decoded = await ThumbnailCache.shared.load(url: url, maxPixelSize: maxPixelSize)
        }
    }
}
