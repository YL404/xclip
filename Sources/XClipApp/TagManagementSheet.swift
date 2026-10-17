import SwiftUI
import XClipCore

/// 标签词表（只读）：列出每个标签的中文名、英文 slug、说明和贴文数。
/// 词表由 Agent 通过 `xclip tag` CLI 维护，人工侧只查不改；
/// 点击某一行直接按该标签筛选主列表并关闭面板。
struct TagManagementSheet: View {
    let store: LibraryStore
    /// 居中浮层卡片模式下由宿主提供的关闭回调（替代 sheet 的 dismiss）。
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)
            columnHeader
            Divider()
            tagList
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .safeAreaInset(edge: .bottom) { footer }
    }

    // MARK: - 头部与列头

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("标签词表")
                .font(.title3)
                .bold()
            Text("受控词表由 Agent 通过 xclip tag 命令维护，这里只读。点击一行可按该标签筛选列表。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("名称")
                .frame(width: 140, alignment: .leading)
            Text("slug")
                .frame(width: 150, alignment: .leading)
            Text("说明")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("贴文数")
                .frame(minWidth: 44, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.bottom, 6)
    }

    // MARK: - 列表

    private var tagList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.tags) { tag in
                    row(tag)
                    if tag.id != store.tags.last?.id {
                        Divider()
                    }
                }
                if store.tags.isEmpty {
                    Text("词表还是空的。Agent 录入贴文或运行 xclip tag set 后，标签会出现在这里。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 整行可点：点击 = 按该标签筛选主列表。slug 列等宽可选中复制。
    private func row(_ tag: Tag) -> some View {
        HStack(spacing: 10) {
            Text(tag.name)
                .font(.callout)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            Text(tag.slug)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: 150, alignment: .leading)
            Text(tag.description ?? "—")
                .font(.callout)
                .foregroundStyle(tag.description == nil ? .quaternary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(tag.count)")
                .font(.callout)
                .foregroundStyle(tag.count == 0 ? .tertiary : .secondary)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onTapGesture {
            store.selectedTag = tag.slug
            onClose()
        }
        .accessibilityAddTraits(.isButton)
        .help("点击按「\(tag.name)」筛选")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text("新建、重命名、合并和删除标签请交给 Agent 运行 xclip tag")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("完成") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}
