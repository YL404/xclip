import SwiftUI

/// 流式布局：子视图从左到右排，排不下就换行。标签 chips 用。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    /// 缓存 sizeThatFits 的逐个子视图尺寸，placeSubviews 不再重测一遍。
    struct Cache {
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.sizes = sizes
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidthUsed: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > maxWidth {
                maxWidthUsed = max(maxWidthUsed, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        maxWidthUsed = max(maxWidthUsed, x - spacing)

        let height: CGFloat = subviews.isEmpty ? 0 : y + rowHeight
        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            return CGSize(width: maxWidthUsed, height: height)
        }
        return CGSize(width: proposedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let sizes = cache.sizes.count == subviews.count
            ? cache.sizes
            : subviews.map { $0.sizeThatFits(.unspecified) }
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for (subview, size) in zip(subviews, sizes) {
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
