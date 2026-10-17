import SwiftUI
import XClipCore

/// 紧凑列表行：左侧缩略图，中间作者 + 一行预览，右侧标签（最多 2 个）。
struct FeedRowView: View {
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

    /// 提炼 > 备注 > 原文（displaySummary 已含这条回退链）；都没有才数媒体个数。
    private var preview: String {
        if !post.displaySummary.isEmpty { return post.displaySummary }
        if !post.media.isEmpty { return "\(post.media.count) 个媒体文件" }
        return "（无内容）"
    }

    private var visibleTags: [String] {
        Array(post.tags.prefix(2))
    }

    var body: some View {
        // 整行不用 Button：macOS 外层 Button 会抢走内部 ShortIDChip 的点按复制，
        // 和卡片一样用 onTapGesture——子视图手势优先。见 KNOWN-ISSUES.md。
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    // 作者只作弱化辅助，突出媒体、提炼、标签和编码；
                    // 上游指标不进列表，需要时看详情页
                    Text(displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(post.savedAt.formatted(date: .numeric, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    ShortIDChip(post: post)
                    if post.fetchStatus != "ok" {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("抓取失败")
                    }
                }
                HStack(spacing: 3) {
                    // 提炼描述优先于原文展示；✦ 标一下，和原文区分开。
                    if !post.summary.isEmpty {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if !visibleTags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(visibleTags, id: \.self) { slug in
                        Text(store.tagName(for: slug))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .help(slug)
                    }
                    if post.tags.count > visibleTags.count {
                        Text("+\(post.tags.count - visibleTags.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(.rect(cornerRadius: 7))
        .contentShape(.rect(cornerRadius: 7))
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onSelect)
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

    @ViewBuilder
    private var thumbnail: some View {
        if post.fetchStatus != "ok" {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .foregroundStyle(.quaternary)
                .overlay {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
        } else if post.media.count == 1, let item = post.media.first {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ThumbnailImage(url: store.resolvePreviewURL(for: item, variant: .small), maxPixelSize: 120)
                        .scaledToFill()
                        .background { Rectangle().fill(.quaternary.opacity(0.5)) }
                }
                .clipped()
                .clipShape(.rect(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    if item.type == "video" { videoBadge }
                }
        } else if post.media.count > 1 {
            // 和卡片一样不用 LazyVGrid：滚动中的懒网格会反复销毁重建。
            let items = Array(post.media.prefix(4))
            VStack(spacing: 1) {
                gridRow(Array(items.prefix(2)))
                if items.count > 2 {
                    gridRow(Array(items.dropFirst(2)))
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomTrailing) {
                // 格子太小，逐格贴角标会糊成一片；只在整块缩略图上标一次「含视频」。
                if items.contains(where: { $0.type == "video" }) { videoBadge }
            }
        } else {
            AuthorAvatar(post: post, size: 42)
        }
    }

    private func gridRow(_ items: [MediaItem]) -> some View {
        HStack(spacing: 1) {
            ForEach(items, id: \.url) { item in
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ThumbnailImage(url: store.resolvePreviewURL(for: item, variant: .small), maxPixelSize: 120)
                            .scaledToFill()
                            .background { Rectangle().fill(.quaternary.opacity(0.5)) }
                    }
                    .clipped()
            }
            if items.count == 1 {
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
    }

    /// 视频缩略图角标：半透明深色胶囊 + 播放符号，42pt 缩略图用的紧凑版。
    private var videoBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(.white)
            .padding(3.5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(2)
    }
}
