import AppKit
import SwiftUI
import XClipCore

/// 写剪贴板。右键菜单、短编码 chip、详情页复制按钮共用。
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// 条目短编码 chip：`#e895bf71`，点击复制，方便直接发给 Agent 引用这条贴文。
/// 卡片、列表行、详情页共用同一个，保证样式和交互一致。
struct ShortIDChip: View {
    let post: Post

    @State private var copied = false
    @State private var hovering = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Text(copied ? "已复制" : "#\(post.shortID)")
            .font(.caption.monospaced())
            .foregroundStyle(copied ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(hovering ? 0.11 : 0.05), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                copyToPasteboard("#\(post.shortID)")
                copied = true
                resetTask?.cancel()
                resetTask = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    copied = false
                }
            }
            .onHover { hovering = $0 }
            .help("条目编码 · 点击复制")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("复制条目编码 \(post.shortID)")
    }
}

/// 卡片与列表行共用的右键菜单内容。
/// 删除经 `confirmDelete` 交给宿主视图弹确认框，菜单本体不直接删。
@ViewBuilder
func postContextMenuItems(post: Post, store: LibraryStore, confirmDelete: @escaping () -> Void) -> some View {
    Button("复制条目编码") {
        copyToPasteboard("#\(post.shortID)")
    }
    Button("复制提炼与正文") {
        copyToPasteboard([post.summary, post.text].filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
    .disabled(post.summary.isEmpty && post.text.isEmpty)
    Button("复制原帖链接") {
        copyToPasteboard(post.url)
    }
    Button("打开原帖") {
        if let url = URL(string: post.url) {
            NSWorkspace.shared.open(url)
        }
    }
    Divider()
    Button("删除贴文", role: .destructive, action: confirmDelete)
}

/// 瀑布流卡片：图为主，下方作者 + 指标 + 标签。
struct FeedCardView: View {
    let post: Post
    let store: LibraryStore
    let onSelect: () -> Void

    @State private var hovering = false
    @State private var confirmingDelete = false

    private var displayName: String {
        if !post.authorName.isEmpty { return post.authorName }
        if !post.authorHandle.isEmpty { return "@\(post.authorHandle)" }
        return "未知作者"
    }

    var body: some View {
        // 整卡不用 Button：macOS 外层 Button 会抢走内部 TagChip 的点击。
        // 改成整卡 onTapGesture——子视图手势优先，点标签筛选、点其它区域进详情。
        VStack(alignment: .leading, spacing: 0) {
            media
            if !post.media.isEmpty || post.fetchStatus != "ok" {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
            }
            if !post.displaySummary.isEmpty {
                // 不开 textSelection：macOS 上点按可选文字会吞掉整卡的点击，
                // 文本选择留给详情页。
                HStack(alignment: .top, spacing: 5) {
                    // 提炼描述优先于备注、备注优先于原文展示；✦ 标一下，和原文区分开。
                    if !post.summary.isEmpty {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 2)
                    }
                    Text(post.displaySummary)
                        .font(.callout)
                        .lineLimit(4)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            if !post.tags.isEmpty {
                tagLabels
                    .padding(.horizontal, 12)
                    .padding(.bottom, 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color(.controlBackgroundColor)
                if post.media.isEmpty && post.fetchStatus == "ok" {
                    Color.primary.opacity(0.038)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                // 悬停只动描边：阴影半径动画和缩放会随滚动沿途卡片连续触发，
                // 离屏高斯重绘和重采样直接拖垮 WindowServer。
                .strokeBorder(Color.primary.opacity(hovering ? 0.22 : 0.09), lineWidth: hovering ? 1 : 0.5)
        }
        .contentShape(.rect(cornerRadius: 10))
        // 整卡读成一句，而不是容器标签和子元素各读一遍。
        // 必须放在 onTapGesture/isButton 之前：combine 会建新的无障碍元素，
        // 丢掉它内部声明的 traits 和 press action。
        .accessibilityElement(children: .combine)
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onSelect)
        .onHover { hovering = $0 }
        .contextMenu {
            postContextMenuItems(post: post, store: store, confirmDelete: { confirmingDelete = true })
        }
        .confirmationDialog("删除这条贴文？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await store.delete(postID: post.id)
                    } catch {
                        store.errorMessage = describe(error)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不可恢复，快照、备注和标签关联都会没了。")
        }
    }

    // MARK: - 媒体区

    @ViewBuilder
    private var media: some View {
        if post.fetchStatus != "ok" {
            failedMedia
        } else if post.media.count == 1, let item = post.media.first {
            mediaSlot(url: store.resolvePreviewURL(for: item, variant: .medium), aspect: clampedAspect(of: item), isVideo: item.type == "video", maxPixelSize: 640)
        } else if post.media.count > 1 {
            // 非懒加载的固定两行网格：ScrollView 里嵌 LazyVGrid 会在滚动时
            // 反复做视口命中计算并销毁重建子视图，连带触发图片重解码。
            let items = Array(post.media.prefix(4))
            VStack(spacing: 2) {
                gridRow(Array(items.prefix(2)))
                if items.count > 2 {
                    gridRow(Array(items.dropFirst(2)))
                }
            }
        }
    }

    /// 一行两格；末行只有一格时补一个透明格，保住方格尺寸和左对齐。
    private func gridRow(_ items: [MediaItem]) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.url) { item in
                mediaSlot(url: store.resolvePreviewURL(for: item, variant: .small), aspect: 1, isVideo: item.type == "video", maxPixelSize: 360)
            }
            if items.count == 1 {
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
    }

    /// 单个媒体格：Color.clear 先把布局尺寸锁死，ThumbnailImage 只负责在 overlay 里填充，
    /// 未裁剪的图片尺寸不会透传给 MasonryLayout。占位底色铺在缩略图下面，解码前显示。
    private func mediaSlot(url: URL?, aspect: CGFloat, isVideo: Bool, maxPixelSize: Int) -> some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                ThumbnailImage(url: url, maxPixelSize: maxPixelSize)
                    .scaledToFill()
                    .background(placeholder)
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if isVideo { videoBadge }
            }
    }

    /// 视频缩略图角标：半透明深色胶囊 + 播放符号。
    private var videoBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(7)
    }

    private var failedMedia: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary.opacity(0.3))
                .frame(height: 92)
            VStack(spacing: 5) {
                Label("未抓到内容，仅保存链接", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(post.url)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.5))
    }

    private func clampedAspect(of item: MediaItem) -> CGFloat {
        guard let width = item.width, let height = item.height, width > 0, height > 0 else {
            return 4.0 / 3.0
        }
        return min(max(CGFloat(width) / CGFloat(height), 0.72), 1.9)
    }

    // MARK: - 作者行与编码

    /// 卡片聚焦「媒体 + 提炼 + 标签 + 编码」：作者只留一行弱化名，
    /// 点赞/收藏等上游指标不进卡片，需要时看详情页。
    private var footer: some View {
        HStack(spacing: 8) {
            AuthorAvatar(post: post, size: 20)
            Text(displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            ShortIDChip(post: post)
        }
    }

    private var tagLabels: some View {
        FlowLayout(spacing: 5) {
            ForEach(post.tags, id: \.self) { slug in
                TagChip(slug: slug, title: store.tagName(for: slug), selected: store.selectedTag == slug) {
                    store.toggleTag(slug)
                }
            }
        }
    }
}
