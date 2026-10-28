import SwiftUI

/// 瀑布流布局：列宽相等，每张卡片放进当前最矮的那一列，高度自然错落。
/// 列数由可用宽度和最小列宽决定，窗口缩放时自动增减。
///
/// 注意：瀑布流需要预先知道所有子视图的高度，所以不是懒布局——
/// 调用方必须分批投喂（见 `LibraryStore.displayedPosts`），不要一次灌进几百张卡片。
struct MasonryLayout: Layout {
    var minimumColumnWidth: CGFloat = 264
    var spacing: CGFloat = 14

    /// sizeThatFits 测量结果，供紧随其后的 placeSubviews 复用，
    /// 避免一轮布局把全部卡片量两遍。尺寸有变化时 sizeThatFits 会重算刷新。
    struct Cache {
        var width: CGFloat = .nan
        var count = -1
        var columnWidth: CGFloat = 0
        var sizes: [CGSize] = []
        var placements: [(column: Int, y: CGFloat)] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? .zero
        guard width > 0 else {
            cache = Cache()
            return CGSize(width: width, height: 0)
        }

        let columns = Self.columns(totalWidth: width, minimum: minimumColumnWidth, spacing: spacing)
        let sizes = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columns.width, height: nil))
        }
        let placements = Self.distribute(columnCount: columns.count, itemHeights: sizes.map(\.height), spacing: spacing)
        let height = Self.contentHeight(placements: placements, itemHeights: sizes.map(\.height))
        cache = Cache(width: width, count: subviews.count, columnWidth: columns.width, sizes: sizes, placements: placements)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard !subviews.isEmpty else { return }

        // 宽度与子视图个数没变就复用 sizeThatFits 的测量，只对不上的罕见情况重测
        let columnWidth: CGFloat
        let sizes: [CGSize]
        let placements: [(column: Int, y: CGFloat)]
        if cache.width == bounds.width, cache.count == subviews.count {
            columnWidth = cache.columnWidth
            sizes = cache.sizes
            placements = cache.placements
        } else {
            let columns = Self.columns(totalWidth: bounds.width, minimum: minimumColumnWidth, spacing: spacing)
            columnWidth = columns.width
            sizes = subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: columns.width, height: nil))
            }
            placements = Self.distribute(
                columnCount: columns.count,
                itemHeights: sizes.map(\.height),
                spacing: spacing
            )
        }

        for (index, subview) in subviews.enumerated() {
            let placement = placements[index]
            let x = bounds.minX + CGFloat(placement.column) * (columnWidth + spacing)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY + placement.y),
                anchor: .topLeading,
                // 传列宽而不是子视图自己算出的宽度：万一子视图要求更宽（比如 fixedSize），
                // x 仍按列宽排布，两张卡不会重叠
                proposal: ProposedViewSize(width: columnWidth, height: sizes[index].height)
            )
        }
    }

    // MARK: - 纯计算部分（抽出来是为了能单测）

    /// 给定总宽，算出放得下几列以及每列多宽。
    static func columns(totalWidth: CGFloat, minimum: CGFloat, spacing: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((totalWidth + spacing) / (minimum + spacing)))
        let width = (totalWidth - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (count, width)
    }

    /// 按「放进当前最矮的列」逐个分配，返回每个条目的落点（列索引 + 列内 y）。
    static func distribute(columnCount: Int, itemHeights: [CGFloat], spacing: CGFloat) -> [(column: Int, y: CGFloat)] {
        var heights = [CGFloat](repeating: 0, count: max(1, columnCount))
        var placements: [(column: Int, y: CGFloat)] = []
        placements.reserveCapacity(itemHeights.count)

        for height in itemHeights {
            let column = shortest(heights)
            placements.append((column, heights[column]))
            heights[column] += height + spacing
        }
        return placements
    }

    /// 内容总高 = 最高的那一列的底部。注意不是最后一个条目的底部——
    /// 最后一个条目可能落在矮列里，那样容器会算矮，内容被裁掉。
    static func contentHeight(placements: [(column: Int, y: CGFloat)], itemHeights: [CGFloat]) -> CGFloat {
        zip(placements, itemHeights).map { $0.y + $1 }.max() ?? 0
    }

    private static func shortest(_ heights: [CGFloat]) -> Int {
        heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
    }
}
