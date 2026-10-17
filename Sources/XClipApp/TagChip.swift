import SwiftUI

/// 标签 chip：可点选，选中态实心。
///
/// 用 Text + onTapGesture 而不是 Button：自定义 `Layout` 容器里的 Button
/// 放置正常但不绘制（SwiftUI 平台限制，已实测确认），所以补
/// `.accessibilityAddTraits(.isButton)` 让 VoiceOver 仍读出按钮语义。
/// 同样的标签筛选在筛选条和详情页用的是真 Button，那些在系统容器里，不受影响。
struct TagChip: View {
    /// 机器身份（英文 slug）：回调、筛选和悬停提示都用它
    let slug: String
    /// 给人看的展示名（中文名）；nil 时显示 slug 本身
    var title: String? = nil
    var selected = false
    /// 编辑态下显示 ×，表示点它是移除
    var showsRemoveMark = false
    let action: () -> Void

    @State private var hovering = false

    private var displayTitle: String { title ?? slug }

    var body: some View {
        HStack(spacing: 3) {
            Text(displayTitle)
            if showsRemoveMark {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
        }
        .font(.caption)
        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.78))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.12 : 0.07), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        // 悬停露出英文 slug，方便对照 CLI 参数
        .help(slug)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(showsRemoveMark ? "移除标签 \(displayTitle)" : "标签 \(displayTitle)")
    }
}
