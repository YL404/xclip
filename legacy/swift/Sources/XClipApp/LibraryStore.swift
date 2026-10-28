import AppKit
import Darwin
import Foundation
import XClipCore

/// 主页面两种视图：瀑布流卡片 / 紧凑列表。
enum FeedView: String, CaseIterable, Identifiable {
    case cards, list
    var id: String { rawValue }
}

/// 排序方式。
enum FeedSort: String, CaseIterable, Identifiable {
    case latest, bookmarks, likes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return "最新"
        case .bookmarks: return "收藏最多"
        case .likes: return "喜欢最多"
        }
    }
}

/// App 侧唯一的状态所有者：持有数据库连接，暴露贴文与标签，
/// 所有写操作都在这里收口，写完自动刷新。
@MainActor
@Observable
final class LibraryStore {
    /// 瀑布流是即时布局，一次渲染太多卡片会掉帧，所以分批显示。
    private let pageSize = 60

    private(set) var posts: [Post] = []
    private(set) var tags: [Tag] = [] {
        didSet {
            // slug → 中文名的查表：每个 TagChip 渲染都查，不能再 O(n) 线性扫
            tagNameMap = Dictionary(tags.map { ($0.slug, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
    }

    var selectedTag = ""      // 空串 = 全部
    var query = ""
    var feedView = FeedView.cards
    var feedSort = FeedSort.latest
    private(set) var shownCount: Int
    var errorMessage: String?

    private var database: Database?
    /// 数据库文件路径，open() 时记下；`Database.path` 是 actor 隔离属性，同步读会报错。
    private var databaseURL: URL?
    private let mediaCache: MediaCache
    /// 上一次补缓存的任务。搜索时每敲一个字符都会 reload，不取消的话旧任务会跑完，
    /// 而两个并发的 warm 都看到「缺失」就会重复下载同一地址。
    private var warmTask: Task<Void, Never>?
    private var opened = false

    // MARK: 外部写入监听
    // CLI / 其他 Agent 直接写同一个 SQLite 文件，开着的 App 要跟着刷新。
    // WAL 模式下写先进 xclip.db-wal，主库文件要等 checkpoint 才动，两个文件都要盯；
    // 目录也要盯，-wal/-shm 的创建和删除只在目录层面产生事件。
    private var fileWatchers: [DispatchSourceFileSystemObject] = []
    private var activationObserver: NSObjectProtocol?
    /// 数据库文件的 (mtime, size) 签名，上一次刷新时的快照，用来区分真变更和重复事件。
    private var lastDatabaseSignature = ""
    private var externalSyncScheduled = false

    init() {
        mediaCache = MediaCache(root: Paths.mediaRoot())
        shownCount = pageSize
    }

    isolated deinit {
        warmTask?.cancel()
        fileWatchers.forEach { $0.cancel() }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// 筛选条件变了就重新查。调用方用 `.task(id:)` 驱动，自动取消上一个任务。
    var filterKey: String { "\(selectedTag)|\(query)|\(feedSort.rawValue)" }

    /// 顶栏是否有生效中的筛选，用来决定显示「清除筛选」之类的出口。
    var hasActiveFilter: Bool {
        !selectedTag.isEmpty || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 显示用地址：有本地缓存就用本地文件，否则退回远程（带上规格参数）。
    /// 命中走 LocalFileURLCache：缓存过的文件不再重复 SHA256 + stat。
    func resolveMediaURL(_ remoteURL: String, variant: MediaVariant) -> URL? {
        if let local = LocalFileURLCache.shared.localFile(for: remoteURL) { return local }
        return mediaURL(remoteURL, variant: variant)
    }

    /// 卡片/列表缩略图：视频给缩略帧（thumbnailURL），图片给原图。
    func resolvePreviewURL(for item: MediaItem, variant: MediaVariant) -> URL? {
        guard let remote = item.previewImageURL else { return nil }
        return resolveMediaURL(remote, variant: variant)
    }

    /// 详情页视频播放地址：本地缓存的 mp4 优先，否则交给 AVPlayer 流式播远程。
    func resolveVideoURL(for item: MediaItem) -> URL? {
        if let local = LocalFileURLCache.shared.localFile(for: item.url) { return local }
        return URL(string: item.url)
    }

    /// 「在 Finder 中显示」用：只在缓存文件真的存在时返回本地文件 URL。
    func localFileURL(for remoteURL: String) -> URL? {
        LocalFileURLCache.shared.localFile(for: remoteURL)
    }

    func toggleTag(_ slug: String) {
        selectedTag = selectedTag == slug ? "" : slug
    }

    /// slug → 显示名映射，随 tags 更新（每个 TagChip 都查，必须 O(1)）
    private var tagNameMap: [String: String] = [:]

    /// 给人看的标签名：词表里的中文名，找不到（游离 slug）回退显示 slug 本身。
    func tagName(for slug: String) -> String {
        tagNameMap[slug] ?? slug
    }

    /// 排序后的结果，两种视图共用。数据库已按 feedSort 排好序，这里直接透传，
    /// 避免视图每次访问都在内存里重排一遍。
    var sortedPosts: [Post] { posts }

    var displayedPosts: [Post] {
        Array(sortedPosts.prefix(shownCount))
    }

    var hasMore: Bool {
        shownCount < posts.count
    }

    var remainingCount: Int {
        max(0, posts.count - shownCount)
    }

    func showMore() {
        shownCount = min(posts.count, shownCount + pageSize)
    }

    func open() async {
        do {
            let dbURL = Paths.databasePath(explicit: nil)
            let database = try Database(path: dbURL)
            self.database = database
            self.databaseURL = dbURL
            // 标签计数来自全库关联查询，与当前筛选无关
            tags = try await TagStore(database).all()
        } catch {
            errorMessage = describe(error)
        }
        await reload()
        startExternalSync()
    }

    /// 首屏加载的唯一入口：第一次负责开库，之后只做筛选重载。
    /// 合并成一个 `.task(id:)` 驱动，避免「开库」和「按筛选条件加载」两个 task
    /// 顺序不定、首屏查两次。
    func load() async {
        guard !opened else {
            await reload()
            return
        }
        opened = true
        await open()
    }

    func reload() async {
        guard let database else { return }
        do {
            let loaded = try await PostStore(database).list(
                ListFilter(
                    tags: selectedTag.isEmpty ? [] : [selectedTag],
                    query: query.isEmpty ? nil : query,
                    sort: PostSort(rawValue: feedSort.rawValue) ?? .latest,
                    limit: 2000
                )
            )
            // 查询期间筛选条件可能又变了，旧结果后到就丢弃
            guard !Task.isCancelled else { return }
            posts = loaded
            shownCount = pageSize
            errorMessage = nil
            // 同步数据库签名：自己的写入也会触发文件事件，先盖章避免紧接着一次多余刷新。
            // 若外部写恰好落在这条之后，签名不同，仍会被下次检查抓到。
            lastDatabaseSignature = databaseSignature()
            // 列表里出现的媒体（视频流、视频缩略图、图片、头像），缺缓存的顺手补上；
            // 历史数据靠这个自愈
            let urls = loaded.flatMap { MediaCache.collectibleURLs(for: $0) }
            guard !urls.isEmpty else { return }
            warmTask?.cancel()
            warmTask = Task { _ = await mediaCache.warm(urls) }
        } catch {
            // 取消导致的错误不弹给用户
            guard !Task.isCancelled else { return }
            errorMessage = describe(error)
        }
    }

    /// 手动刷新（⌘R）：不看签名，无条件重载列表和标签池。
    func refresh() async {
        await reload()
        await refreshTags()
    }

    // MARK: - 外部变更监听

    private func startExternalSync() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleExternalSync()
            }
        }
        watchDatabaseFiles()
    }

    /// 监听数据库文件。`open(O_EVTONLY)` 失败说明文件还没被创建（如 -wal），
    /// 跳过即可——目录监听会在它被建出来时触发，随后重建监听补上。
    private func watchDatabaseFiles() {
        fileWatchers.forEach { $0.cancel() }
        fileWatchers = []
        guard let dbURL = databaseURL else { return }
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let targets = [dbURL, walURL, dbURL.deletingLastPathComponent()]
        for url in targets {
            let fd = Darwin.open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.scheduleExternalSync()
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            fileWatchers.append(source)
        }
    }

    /// 一次外部写入会触发一长串 vnode 事件，合并成一次签名检查。
    private func scheduleExternalSync() {
        guard !externalSyncScheduled else { return }
        externalSyncScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            externalSyncScheduled = false
            await syncIfExternallyModified()
        }
    }

    /// 文件签名 = mtime + 大小。只看 mtime 不够，同秒内的两次写可能撞时间戳；
    /// -wal 不存在时记 -1，和 0 字节文件区分开。
    private func databaseSignature() -> String {
        guard let dbURL = databaseURL else { return "" }
        return [dbURL, URL(fileURLWithPath: dbURL.path + "-wal")]
            .map { url in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attrs?[.size] as? Int) ?? -1
                return "\(mtime):\(size)"
            }
            .joined(separator: "|")
    }

    /// 外部进程改了数据库就重载；签名没变说明只是重复事件或自己的写。
    private func syncIfExternallyModified() async {
        let signature = databaseSignature()
        guard !signature.isEmpty, signature != lastDatabaseSignature else { return }
        lastDatabaseSignature = signature
        // -wal 可能刚被创建或 checkpoint 掉，重建监听保证后续写入仍能抓到。
        watchDatabaseFiles()
        await reload()
        await refreshTags()
    }

    /// 只调整贴文绑定的标签：不动提炼、备注和快照。词表本身由 CLI 维护，
    /// App 侧只允许在已有标签之间勾选。
    func updateTags(postID: String, tags: [String]) async throws {
        guard let database else { throw DatabaseError.openFailed("数据库尚未打开") }
        try await PostStore(database).updateTags(postID: postID, tags: tags)
        await reload()
        await refreshTags()
    }

    func delete(postID: String) async throws {
        guard let database else { throw DatabaseError.openFailed("数据库尚未打开") }
        try await PostStore(database).delete(id: postID)
        await reload()
        await refreshTags()
    }

    /// 标签计数来自全库关联查询，改标签或删贴文后都要重查。
    private func refreshTags() async {
        guard let database,
              let refreshed = try? await TagStore(database).all() else { return }
        tags = refreshed
    }
}
