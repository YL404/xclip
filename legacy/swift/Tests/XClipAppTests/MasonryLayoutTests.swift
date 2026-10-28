import Testing
import CoreGraphics
@testable import XClipApp

struct MasonryLayoutTests {
    @Test
    func columnCountFollowsAvailableWidth() {
        // 1180 宽、最小列宽 264、间距 14 → 4 列
        let wide = MasonryLayout.columns(totalWidth: 1180, minimum: 264, spacing: 14)
        #expect(wide.count == 4)
        #expect(abs(wide.width - (1180 - 14 * 3) / 4) < 0.001)

        // 700 宽 → 2 列
        let medium = MasonryLayout.columns(totalWidth: 700, minimum: 264, spacing: 14)
        #expect(medium.count == 2)
        #expect(abs(medium.width - (700 - 14) / 2) < 0.001)

        // 刚好放一列 / 放不下也至少一列
        #expect(MasonryLayout.columns(totalWidth: 278, minimum: 264, spacing: 14).count == 1)
        #expect(MasonryLayout.columns(totalWidth: 100, minimum: 264, spacing: 14).count == 1)
        #expect(MasonryLayout.columns(totalWidth: 100, minimum: 264, spacing: 14).width == 100)
    }

    @Test
    func distributionFillsShortestColumnFirst() {
        let placements = MasonryLayout.distribute(
            columnCount: 3,
            itemHeights: [100, 50, 80, 40],
            spacing: 10
        )

        // 前三张各占一列；第四张进最矮的第 1 列（已有 50+10=60）
        #expect(placements.map(\.column) == [0, 1, 2, 1])
        #expect(placements.map(\.y) == [0, 0, 0, 60])
    }

    @Test
    func distributionHandlesSingleColumnAndEmptyInput() {
        let single = MasonryLayout.distribute(columnCount: 1, itemHeights: [30, 40], spacing: 8)
        #expect(single.map(\.column) == [0, 0])
        #expect(single.map(\.y) == [0, 38])

        #expect(MasonryLayout.distribute(columnCount: 3, itemHeights: [], spacing: 8).isEmpty)
    }

    @Test
    func contentHeightIsTallestColumnNotLastItem() {
        // 三张卡 100/200/50 分两列：前两张各占一列，第三张进较矮的第 0 列（y=110）。
        // 最后一个条目底部只有 160，但第 1 列的内容已经到 200——容器必须按 200 算，
        // 否则高列的内容会被裁掉。（列高累积里的尾随间距不算内容。）
        let itemHeights: [CGFloat] = [100, 200, 50]
        let placements = MasonryLayout.distribute(columnCount: 2, itemHeights: itemHeights, spacing: 10)
        #expect(placements.map(\.column) == [0, 1, 0])
        #expect(placements.map(\.y) == [0, 0, 110])
        #expect(MasonryLayout.contentHeight(placements: placements, itemHeights: itemHeights) == 200)
    }
}
