import AppKit
import AVFoundation
import AVKit
import ObjectiveC
import SwiftUI
import XClipCore

struct PostDetailView: View {
    let post: Post
    let store: LibraryStore
    /// 居中浮层卡片模式下由宿主提供的关闭回调（替代 sheet 的 dismiss）。
    var onClose: () -> Void = {}
    /// 点开图片放大查看：把 (images, index) 交给宿主在最顶层渲染大图查看器。
    var onPreviewImage: (([MediaItem], Int) -> Void)? = nil
    /// 大图查看器打开时置 true：Esc 留给查看器，不再关详情。
    var suppressCloseShortcut = false

    @State private var editing = false
    @State private var editTags: Set<String> = []
    @State private var confirmingDelete = false
    @State private var refetchCopied = false
    @State private var actionError: String?
    @State private var showingError = false
    @State private var cliCopied = false
    /// 图片悬停放大提示：记录正在悬停的媒体 url
    @State private var hoveredMediaURL: String?

    /// 详情打开期间提炼/标签/备注/补抓结果变了要即时反映：总是读 store 里最新那条。
    private var currentPost: Post {
        store.posts.first { $0.id == post.id } ?? post
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if currentPost.fetchStatus != "ok" {
                    // 抓取走 Agent/CLI，人只查不改：给一条可复制发给 Agent 的命令
                    HStack(spacing: 8) {
                        Label("抓取失败，仅保存了链接", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button(refetchCopied ? "已复制" : "复制补抓命令") {
                            copyToPasteboard("xclip update #\(currentPost.shortID) --refetch")
                            refetchCopied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.2))
                                guard !Task.isCancelled else { return }
                                refetchCopied = false
                            }
                        }
                        .controlSize(.small)
                        .help("发给 Agent 重新抓取快照")
                    }
                }
                if !currentPost.summary.isEmpty {
                    summaryCard
                } else {
                    summaryPlaceholder
                }
                if !currentPost.text.isEmpty {
                    Text(currentPost.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
                if !currentPost.media.isEmpty {
                    mediaSection
                }
                if editing {
                    tagEditSection
                } else {
                    // 空 FlowLayout 也会占 VStack 间距，标签为空时整行跳过；
                    // v3 迁移把旧 note 回填进 summary，同一句不再上下重复显示
                    if !currentPost.tags.isEmpty { tagRow }
                    if !currentPost.note.isEmpty && currentPost.note != currentPost.summary { note }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 固定弹窗尺寸，避免贴文内容长短不同导致 sheet 大小剧烈跳动
        .frame(minWidth: 680, idealWidth: 780, minHeight: 480, idealHeight: 760)
        // 不用 .toolbar：sheet 里它不渲染（实测），按钮放内容区才可见
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    if editing {
                        Text("只调整标签关联，提炼与备注请交给 Agent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("取消") { editing = false }
                            .keyboardShortcut(closeShortcut)
                        Button("保存标签") { saveTags() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else if confirmingDelete {
                        // 浮层模式下系统 NSAlert 会和「点外部关闭」抢窗口事件，
                        // 删除确认收成底部栏内联二次确认
                        Text("删除后不可恢复")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("取消") { confirmingDelete = false }
                            .keyboardShortcut(closeShortcut)
                        Button("确认删除", role: .destructive) { Task { await deletePost() } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("删除", role: .destructive) { confirmingDelete = true }
                        Spacer(minLength: 0)
                        Button("关闭") { onClose() }
                            .keyboardShortcut(closeShortcut)
                        Button("调整标签") { beginEditing() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .background(.bar)
        }
        .alert("出错了", isPresented: $showingError) {
            Button("好") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - 只读部分

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            AuthorAvatar(post: currentPost, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.title3)
                    .bold()
                if !currentPost.authorHandle.isEmpty {
                    Text("@\(currentPost.authorHandle)")
                        .foregroundStyle(.secondary)
                }
                if let postedAt = currentPost.postedAt {
                    Text("\(postedAt.formatted(date: .long, time: .omitted))发布 · 保存于 \(currentPost.savedAt.formatted(date: .numeric, time: .omitted))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("保存于 \(currentPost.savedAt.formatted(date: .numeric, time: .omitted))")
                        .foregroundStyle(.secondary)
                }
                // 条目编码：点一下复制，直接发给 Agent 引用这条贴文
                ShortIDChip(post: currentPost)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            if let url = URL(string: currentPost.url) {
                Link(destination: url) {
                    Label("打开原帖", systemImage: "arrow.up.right")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// 名字为空退到 handle，两者都空（抓取失败）显示占位名。
    private var headerTitle: String {
        if !currentPost.authorName.isEmpty { return currentPost.authorName }
        return currentPost.authorHandle.isEmpty ? "未知作者" : "@\(currentPost.authorHandle)"
    }

    /// 内容提炼：Agent/用户写的高价值摘要，独立于原帖正文高亮展示。
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("内容提炼", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text(currentPost.summary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    /// 还没写提炼时的轻量占位：虚线卡提示这条未被索引化。
    /// 提炼只由 Agent 写——给一条可复制发给 Agent 的 CLI 命令。
    private var summaryPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("待提炼要点", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(cliCopied ? "已复制" : "复制 CLI 提炼命令") {
                copyToPasteboard("xclip update #\(currentPost.shortID) --summary \"\"")
                cliCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    cliCopied = false
                }
            }
            .font(.caption)
            .controlSize(.small)
            .help("发给 Agent 补写提炼，内容填进引号里")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.quaternary)
        }
    }

    /// FlowLayout 里 Button 不绘制（见 KNOWN-ISSUES），所以用 TagChip。
    /// 点标签回主列表按它筛选，和原型的行为一致。
    private var tagRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(currentPost.tags, id: \.self) { slug in
                TagChip(slug: slug, title: store.tagName(for: slug)) {
                    store.selectedTag = slug
                    onClose()
                }
            }
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("备注")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(currentPost.note)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    // MARK: - 调整标签

    /// 标签勾选区：只能点选词表里的已有标签，不提供新建入口——
    /// 词表由 Agent 通过 `xclip tag` 维护，人工随手建标签会打乱受控词表。
    private var tagEditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("标签")
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(allTagSlugs, id: \.self) { slug in
                    let selected = editTags.contains(slug)
                    TagChip(slug: slug, title: store.tagName(for: slug), selected: selected, showsRemoveMark: selected) {
                        if selected { editTags.remove(slug) } else { editTags.insert(slug) }
                    }
                }
            }

            Text("只能勾选词表中的标签；新建标签请交给 Agent 维护词表")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// 词表里的标签 + 当前贴文已有的（含已不在词表里的，保证能看见也能取消）。
    private var allTagSlugs: [String] {
        Set(store.tags.map(\.slug)).union(currentPost.tags).union(editTags).sorted()
    }

    private func beginEditing() {
        editTags = Set(currentPost.tags)
        editing = true
    }

    private func saveTags() {
        let tags = allTagSlugs.filter { editTags.contains($0) }
        Task {
            do {
                try await store.updateTags(postID: currentPost.id, tags: tags)
                editing = false
            } catch {
                presentError(error)
            }
        }
    }

    private func deletePost() async {
        do {
            try await store.delete(postID: currentPost.id)
            onClose()
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        actionError = describe(error)
        showingError = true
    }

    /// 大图查看器打开时 Esc 归查看器，详情的取消键先让位。
    private var closeShortcut: KeyboardShortcut? {
        suppressCloseShortcut ? nil : .cancelAction
    }

    // MARK: - 媒体

    /// 视频和图片分开排：视频逐个全宽给真播放器，图片维持单图全宽 / 多图网格。
    private var mediaSection: some View {
        let videos = currentPost.media.filter { $0.type == "video" }
        let images = currentPost.media.filter { $0.type != "video" }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(videos, id: \.url) { item in
                VideoBlock(item: item, shortID: currentPost.shortID, store: store)
            }
            if images.count == 1, let item = images.first {
                media(item, index: 0, in: images)
            } else if images.count > 1 {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(Array(images.enumerated()), id: \.element.url) { index, item in
                        gridMedia(item, index: index, in: images)
                    }
                }
            }
        }
    }

    /// 媒体右键菜单：本地有缓存的给「在 Finder 中显示」，远程地址可复制可打开。
    @ViewBuilder
    private func mediaContextMenu(_ item: MediaItem) -> some View {
        if let file = store.localFileURL(for: item.url) {
            Button("在 Finder 中显示缓存文件") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
            Button("用系统播放器打开") {
                NSWorkspace.shared.open(file)
            }
            Divider()
        }
        Button("复制媒体地址") {
            copyToPasteboard(item.url)
        }
        if let url = URL(string: item.url) {
            Button("打开远程地址") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 图片可点击放大：悬停出放大角标，点击交给宿主开全窗口查看器。
    private func imageInteraction(_ item: MediaItem, index: Int, in images: [MediaItem]) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { onPreviewImage?(images, index) }
            .onHover { hovering in hoveredMediaURL = hovering ? item.url : nil }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("放大查看图片")
    }

    /// 悬停时右下角的放大角标。
    private var zoomBadge: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
    }

    /// 单图：限制最大高度居中展示，横图方图竖图都完整显示在一屏内。
    @ViewBuilder
    private func media(_ item: MediaItem, index: Int, in images: [MediaItem]) -> some View {
        if let url = store.resolveMediaURL(item.url, variant: .medium) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    mediaFailure
                default:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: 520)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.04))
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if hoveredMediaURL == item.url { zoomBadge }
            }
            .overlay { imageInteraction(item, index: index, in: images) }
            .contextMenu { mediaContextMenu(item) }
        }
    }

    /// 网格里的单格：锁定 4:3 画幅，scaledToFill 裁掉溢出，混排横竖图行列也对齐。
    private func gridMedia(_ item: MediaItem, index: Int, in images: [MediaItem]) -> some View {
        Color.clear
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                if let url = store.resolveMediaURL(item.url, variant: .medium) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            mediaFailure
                        default:
                            Rectangle().fill(.quaternary)
                        }
                    }
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipped()
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if hoveredMediaURL == item.url { zoomBadge }
            }
            .overlay { imageInteraction(item, index: index, in: images) }
            .contextMenu { mediaContextMenu(item) }
    }

    /// 图片加载失败占位：灰底加图标。
    private var mediaFailure: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.tertiary)
            }
    }
}

/// 详情页视频块：AVPlayerView 真播放（本地缓存优先，远程流式兜底），
/// 底部给「在 Finder 中显示 / 用系统播放器打开」两个出口。
///
/// v1 旧库的视频条目只有静态封面：`url` 本身是张 .jpg、`thumbnailURL` 为空，
/// 即 `previewImageURL == url`。这种条目没有 mp4 可播，塞给 AVPlayer 只会得到
/// 空白播放器——降级渲染封面图，附「复制补抓命令」供发给 Agent。
private struct VideoBlock: View {
    let item: MediaItem
    let shortID: String
    let store: LibraryStore

    @State private var player: AVPlayer?
    @State private var refetchCopied = false

    /// 只有封面没有视频流的旧版条目。
    private var isLegacyCoverOnly: Bool {
        item.previewImageURL == item.url
    }

    /// 真实宽高比放宽到 0.35...2.4：配合 maxHeight 500，竖屏录屏也能整屏显示。
    private var aspect: CGFloat {
        guard let width = item.width, let height = item.height, width > 0, height > 0 else {
            return 16.0 / 9.0
        }
        return min(max(CGFloat(width) / CGFloat(height), 0.35), 2.4)
    }

    var body: some View {
        if isLegacyCoverOnly {
            legacyCover
        } else {
            playerSection
        }
    }

    private var playerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let player {
                    NativeVideoPlayer(player: player)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay { ProgressView() }
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: 500)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.04))
            .clipShape(.rect(cornerRadius: 8))

            HStack(spacing: 12) {
                if let file = store.localFileURL(for: item.url) {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    Button("用系统播放器打开") {
                        NSWorkspace.shared.open(file)
                    }
                } else {
                    Text("视频未缓存，正在播远程流")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .controlSize(.small)
        }
        .task(id: item.url) {
            // 初始保持暂停：点开详情不自动播，只在用户点播放器控制条时播放
            player = store.resolveVideoURL(for: item).map { url in
                let avPlayer = AVPlayer(url: url)
                avPlayer.pause()
                avPlayer.actionAtItemEnd = .pause
                return avPlayer
            }
        }
        .onDisappear {
            // 关掉详情页还在后台出声就不对了
            player?.pause()
            player = nil
        }
    }

    /// 旧版条目的静态封面 + 补抓入口。封面走图片管线，能命中本地图片缓存。
    private var legacyCover: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: store.resolveMediaURL(item.url, variant: .medium)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.tertiary)
                        }
                default:
                    Rectangle()
                        .fill(.quaternary)
                        .overlay { ProgressView() }
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxHeight: 500)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.04))
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 5))
                    .padding(6)
            }

            HStack(spacing: 10) {
                Text("旧版仅缓存了视频封面")
                    .foregroundStyle(.tertiary)
                Button(refetchCopied ? "已复制" : "复制补抓命令") {
                    copyToPasteboard("xclip update #\(shortID) --refetch")
                    refetchCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        refetchCopied = false
                    }
                }
                .help("发给 Agent 补抓 mp4 视频流")
            }
            .font(.caption)
            .controlSize(.small)
        }
    }
}

/// AppKit 原生播放器包装：直接实例化 `AVPlayerView`。
///
/// 不能用 SwiftUI 的 `VideoPlayer(player:)`：SwiftPM 构建 macOS 可执行文件时，
/// `VideoPlayer` 只引用 `_AVKit_SwiftUI` 的泛型符号，链接器不会把 AVKit.framework
/// 链进二进制；运行时 `_AVKit_SwiftUI` 初始化内部 NSViewRepresentable 包装类的
/// 元数据，父类是 AVKit 里的 ObjC 类 `AVPlayerView`，框架没加载，
/// `swift::getSuperclassMetadata` 直接 abort——点开视频贴必闪退。
/// 这里显式 `AVPlayerView()` 生成 `_OBJC_CLASS_$_AVPlayerView` 强符号引用，
/// 强制链接 AVKit.framework；Package.swift 另有 `.linkedFramework("AVKit")` 双保险。
/// 见 KNOWN-ISSUES.md 第 3 节。
private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NonScrubbingPlayerView {
        let view = NonScrubbingPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ nsView: NonScrubbingPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: NonScrubbingPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

/// 不吃滚轮的 AVPlayerView。
///
/// lldb 反汇编确认：`AVPlayerView` 内部有两个类实现 `scrollWheel:`——
/// `AVDesktopPlayerViewContentView`（内部走 `_gestureController` 触发视频时移）
/// 和底部控制条的进度滑块 `AVScrollSliderView`。基于坐标判断的 local event
/// monitor 堵不死它：NSWindow 对滚轮手势有目标视图相位锁定（scroll target
/// latching），快速滚动时部分 .changed / momentumPhase 事件绕过坐标判断
/// 直接落到内部子视图。
///
/// 根治：ObjC 运行时直接把这两个类的 `scrollWheel:` 换成「转发给外层
/// enclosingScrollView」、`swipeWithEvent:` 换成空实现，并把
/// `AVDesktopPlayerViewContentView` 的 `_gestureController` 置 nil——
/// NSWindow 原生维护滚动生命周期，事件语义上根本不存在时移入口。
/// 见 KNOWN-ISSUES.md 第 3 节。
private final class NonScrubbingPlayerView: AVPlayerView {
    private static let disableScrubbingOnce: Void = {
        let scrollSelector = #selector(NSResponder.scrollWheel(with:))
        let scrollBlock: @convention(block) (NSView, NSEvent) -> Void = { view, event in
            view.enclosingScrollView?.scrollWheel(with: event)
        }
        let scrollImp = imp_implementationWithBlock(scrollBlock)

        let swipeSelector = #selector(NSResponder.swipe(with:))
        let swipeBlock: @convention(block) (NSView, NSEvent) -> Void = { _, _ in }
        let swipeImp = imp_implementationWithBlock(swipeBlock)

        for className in ["AVDesktopPlayerViewContentView", "AVScrollSliderView"] {
            guard let cls = NSClassFromString(className) else { continue }
            if let method = class_getInstanceMethod(cls, scrollSelector) {
                method_setImplementation(method, scrollImp)
            }
            if let method = class_getInstanceMethod(cls, swipeSelector) {
                method_setImplementation(method, swipeImp)
            }
        }
    }()

    override init(frame frameRect: NSRect) {
        _ = Self.disableScrubbingOnce
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        _ = Self.disableScrubbingOnce
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        clearInternalGestureController()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearInternalGestureController()
    }

    /// AVKit 私有子视图懒挂载，layout/进 window 时都清一次手势控制器。
    private func clearInternalGestureController() {
        for subview in subviews {
            if String(cString: object_getClassName(subview)).contains("AVDesktopPlayerViewContentView") {
                subview.setValue(nil, forKey: "_gestureController")
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        enclosingScrollView?.scrollWheel(with: event)
    }
}
