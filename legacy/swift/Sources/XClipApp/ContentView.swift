import AppKit
import SwiftUI
import XClipCore

struct ContentView: View {
    @State private var store = LibraryStore()
    @State private var selectedPost: Post?
    @State private var showingTagManager = false
    /// 大图查看器：详情页点图片后在窗口最顶层铺满渲染
    @State private var lightbox: LightboxState?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 全库为空且无筛选时，筛选条只剩「全部」和「0 篇」，没有作用，直接隐藏；
                // 有激活筛选时保留，让用户能看到并清掉筛选条件
                if !store.posts.isEmpty || store.hasActiveFilter {
                    FilterBar(
                        tags: store.tags,
                        selectedTag: $store.selectedTag,
                        query: $store.query,
                        feedSort: $store.feedSort,
                        postCount: store.sortedPosts.count
                    )
                }
                content
            }
            // 浮层打开时禁掉底层列表的命中测试：鼠标掠过遮罩不该触发
            // 卡片 hover 放大或底层 ScrollView 滚动
            .allowsHitTesting(selectedPost == nil && !showingTagManager)

            // 居中模态浮层卡片：.sheet 底层是 beginSheet 系统模态，点击卡片以外的
            // 区域根本到不了 App——换成遮罩 + 卡片，点遮罩即关。
            if let post = selectedPost {
                modalCard(onDismiss: { selectedPost = nil }) {
                    PostDetailView(
                        post: post,
                        store: store,
                        onClose: { selectedPost = nil },
                        onPreviewImage: { images, index in
                            lightbox = LightboxState(images: images, index: index)
                        },
                        suppressCloseShortcut: lightbox != nil
                    )
                }
            }
            if showingTagManager {
                modalCard(onDismiss: { showingTagManager = false }) {
                    TagManagementSheet(store: store, onClose: { showingTagManager = false })
                }
            }
            // 大图查看器永远在最顶层：铺满整个窗口，不受详情卡片尺寸限制
            if let lightbox {
                ImageLightboxView(
                    images: lightbox.images,
                    index: lightboxIndexBinding,
                    store: store,
                    onClose: { self.lightbox = nil }
                )
            }
        }
        .frame(minWidth: 900, minHeight: 660)
        .task(id: store.filterKey) { await store.load() }
        .onAppear {
            // macOS 会把旧版 1000×680 窗口尺寸缓存进偏好，启动时若偏小就撑到新默认尺寸
            if let window = NSApp.windows.first,
               window.frame.width < 1180 || window.frame.height < 820 {
                window.setContentSize(NSSize(width: 1240, height: 860))
                window.center()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("视图", selection: $store.feedView) {
                    Label("卡片", systemImage: "square.grid.2x2").tag(FeedView.cards)
                    Label("列表", systemImage: "list.bullet").tag(FeedView.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 78)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("刷新 (⌘R)")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showingTagManager = true
                } label: {
                    Label("标签词表", systemImage: "tag")
                }
                .help("标签词表")
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
            }
        }
    }

    /// 大图查看器的打开状态：图片列表 + 当前索引。
    private struct LightboxState {
        var images: [MediaItem]
        var index: Int
    }

    private var lightboxIndexBinding: Binding<Int> {
        Binding(
            get: { lightbox?.index ?? 0 },
            set: { lightbox?.index = $0 }
        )
    }

    /// 居中浮层卡片容器：全窗口半透明遮罩点按即关；
    /// 卡片底层吃掉落在卡片空白处的点击，防止穿透到遮罩误关。
    /// 尺寸跟随窗口：宽 680...820，高 520...800，窗口大卡片就大。
    @ViewBuilder
    private func modalCard<Content: View>(
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Color.black.opacity(0.28)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)
        GeometryReader { proxy in
            content()
                .frame(width: min(max(proxy.size.width - 80, 680), 820))
                .frame(maxHeight: min(max(proxy.size.height - 48, 520), 800))
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.windowBackgroundColor))
                        .onTapGesture {}
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        // 筛选查不到结果时 posts 本身也是空的，要先看 hasActiveFilter 再决定空态文案，
        // 否则筛选无结果会误显示「还没有贴文」。
        if store.posts.isEmpty {
            if store.hasActiveFilter {
                ContentUnavailableView {
                    Label("没有匹配的贴文", systemImage: "magnifyingglass")
                } description: {
                    Text("换个关键词，或清掉标签筛选")
                } actions: {
                    Button("清除筛选") {
                        store.selectedTag = ""
                        store.query = ""
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyLibraryGuide
            }
        } else {
            feed
        }
    }

    /// 全库为空时的首次引导：录入只走 Agent/CLI，本界面仅供查阅、筛选、
    /// 调整标签关联与删除。
    private var emptyLibraryGuide: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("还没有收录贴文")
                    .font(.title3.weight(.semibold))
                Text("在 Agent 中调用 xclip 录入链接：自动抓取快照、缓存媒体，并完成英文要点提炼与打标。本界面仅供查阅、筛选、调整标签与删除。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            commandCard
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 常用 CLI 命令速查卡：等宽字体、可框选复制。
    private var commandCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            commandLine("xclip add <url> -t ui-design -s \"1-2 English sentences...\"")
            commandLine("xclip list --tag ui-design")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
    }

    private func commandLine(_ command: String) -> some View {
        HStack(spacing: 6) {
            Text("$").foregroundStyle(.tertiary)
            Text(command).foregroundStyle(.secondary)
        }
        .font(.callout.monospaced())
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var feed: some View {
        ScrollView {
            if store.feedView == .cards {
                MasonryLayout(minimumColumnWidth: 264, spacing: 14) {
                    ForEach(store.displayedPosts) { post in
                        FeedCardView(
                            post: post,
                            store: store,
                            onSelect: { select(post) }
                        )
                    }
                }
                .padding(16)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(store.displayedPosts) { post in
                        FeedRowView(
                            post: post,
                            store: store,
                            onSelect: { select(post) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if store.hasMore {
                Button("显示更多（还有 \(store.remainingCount) 篇）") {
                    store.showMore()
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.feedView == .cards ? Color.primary.opacity(0.025) : Color.clear)
    }

    // MARK: - 选中与筛选

    private func select(_ post: Post) {
        selectedPost = post
    }

}
