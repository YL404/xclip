import SwiftUI
import XClipCore

/// 瀑布流顶部的筛选条：搜索框固定左侧，标签 pills 在中间横滚，右侧固定排序菜单和当前匹配篇数。
/// pill 上的计数是全库关联数，与当前筛选无关；右侧篇数才是筛选后的结果数。
struct FilterBar: View {
    let tags: [Tag]
    @Binding var selectedTag: String
    @Binding var query: String
    @Binding var feedSort: FeedSort
    var postCount: Int = 0

    @FocusState private var searchFocused: Bool
    @State private var didClearInitialFocus = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                searchField
                Divider().frame(height: 18)
                ScrollView(.horizontal) {
                    pills
                }
                .scrollIndicators(.hidden)
                // 横向 ScrollView 默认在交叉轴也贪婪吃高，会把整条筛选栏拉成半个窗口
                .fixedSize(horizontal: false, vertical: true)
                sortMenu
                Text("\(postCount) 篇")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
        }
        // 筛选栏永远单行高度贴顶，不随下方空态被拉伸
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // macOS 会自动把搜索框设为 first responder，启动时先清掉多余焦点环
            if !didClearInitialFocus {
                didClearInitialFocus = true
                DispatchQueue.main.async { searchFocused = false }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索提炼、正文、作者、备注", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { searchFocused = false }
            if !query.isEmpty {
                Button("清除搜索", systemImage: "xmark.circle.fill") { query = "" }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 210)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    searchFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        }
    }

    private var sortMenu: some View {
        // label 里只能放 Label：NSButtonCell 会剥掉其中的 padding/background，
        // 胶囊底和间距必须加在 Menu 本体上
        Menu {
            Picker("排序方式", selection: $feedSort) {
                ForEach(FeedSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(feedSort.title, systemImage: "arrow.up.arrow.down")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var pills: some View {
        HStack(spacing: 6) {
            FilterPill(title: "全部", count: nil, isSelected: selectedTag.isEmpty) {
                selectedTag = ""
            }
            ForEach(tags.filter { $0.count > 0 }) { tag in
                // 人看中文名；悬停给英文 slug + 说明，方便对照 CLI 参数
                FilterPill(title: tag.name, count: tag.count, isSelected: selectedTag == tag.slug) {
                    selectedTag = selectedTag == tag.slug ? "" : tag.slug
                }
                .help(tag.description.map { "\(tag.slug) · \($0)" } ?? tag.slug)
            }
        }
    }
}

/// 筛选 pill：macOS 26 上 `.buttonStyle(.bordered)` 配 `.tint(.clear)` 会把 label 文字也染成透明
/// （未选中 pill 只剩计数数字悬空），所以改用 `.plain` 按钮自绘胶囊。见 KNOWN-ISSUES.md。
private struct FilterPill: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(isSelected ? Font.caption.weight(.medium) : Font.caption)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                if let count {
                    Text("\(count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor : Color.primary.opacity(hovering ? 0.11 : 0.06),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .onHover { hovering = $0 }
    }
}
