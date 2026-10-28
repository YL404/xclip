import Testing
import Foundation
@testable import XClipCore

struct TagNormalizerTests {
    @Test
    func normalizesCommonShapes() {
        #expect(TagNormalizer.normalize("Product Design") == "product-design")
        #expect(TagNormalizer.normalize("  ui/ux  ") == "ui-ux")
        #expect(TagNormalizer.normalize("dev_tools") == "dev-tools")
        #expect(TagNormalizer.normalize("A - B") == "a-b")
        #expect(TagNormalizer.normalize("--a--b--") == "a-b")
        #expect(TagNormalizer.normalize("C++") == "c")
    }

    @Test
    func rejectsEmptyResults() {
        #expect(TagNormalizer.normalize("") == nil)
        #expect(TagNormalizer.normalize("   ") == nil)
        #expect(TagNormalizer.normalize("+++") == nil)
    }

    @Test
    func rejectsNonASCIILetters() {
        // 中文/全角字符不是合法英文 slug——slug 只收 ASCII 字母数字和连字符
        #expect(TagNormalizer.normalize("产品设计") == nil)
        #expect(TagNormalizer.normalize("ai 工具") == nil)
        #expect(TagNormalizer.normalize("ｆｕｌｌ") == nil)
    }

    @Test
    func normalizesChineseNames() {
        #expect(TagNormalizer.normalizeChineseName(" 空间交互 ") == "空间交互")
        #expect(TagNormalizer.normalizeChineseName("AI 应用") == "AI 应用")
        #expect(TagNormalizer.normalizeChineseName("english only") == nil)
        #expect(TagNormalizer.normalizeChineseName("两行\n名字") == nil)
        #expect(TagNormalizer.normalizeChineseName("   ") == nil)
    }

    @Test
    func parsesTagInput() throws {
        let plain = try TagNormalizer.parseTagInput("UI Design")
        #expect(plain == TagInput(slug: "ui-design"))
        let inline = try TagNormalizer.parseTagInput("Spatial UI:空间交互")
        #expect(inline == TagInput(slug: "spatial-ui", chineseName: "空间交互"))
        let fullwidth = try TagNormalizer.parseTagInput("x-tag：新标签")
        #expect(fullwidth == TagInput(slug: "x-tag", chineseName: "新标签"))

        #expect(throws: TagStoreError.invalidSlug(":名称")) {
            try TagNormalizer.parseTagInput(":名称")
        }
        #expect(throws: TagStoreError.invalidSlug("产品设计")) {
            try TagNormalizer.parseTagInput("产品设计")
        }
        #expect(throws: TagStoreError.invalidChineseName("a:english only")) {
            try TagNormalizer.parseTagInput("a:english only")
        }
    }
}

struct XURLTests {
    @Test
    func canonicalizesVariants() throws {
        let reference = try XURL.canonicalPostURL("https://x.com/mika_sole/status/1900000000000000001?s=20&t=abc")
        #expect(reference.id == "1900000000000000001")
        #expect(reference.screenName == "mika_sole")
        #expect(reference.url == "https://x.com/mika_sole/status/1900000000000000001")

        let twitter = try XURL.canonicalPostURL("twitter.com/SomeUser/status/123/photo/1")
        #expect(twitter.url == "https://x.com/someuser/status/123")

        let noScheme = try XURL.canonicalPostURL("www.x.com/a/status/999")
        #expect(noScheme.url == "https://x.com/a/status/999")

        let iForm = try XURL.canonicalPostURL("https://x.com/i/status/555")
        #expect(iForm.screenName == "")
        #expect(iForm.url == "https://x.com/i/status/555")
    }

    @Test
    func rejectsUnsupportedLinks() {
        #expect(throws: XURLError.notAnXURL) {
            _ = try XURL.canonicalPostURL("https://example.com/a/status/123")
        }
        #expect(throws: XURLError.notAnXURL) {
            _ = try XURL.canonicalPostURL("https://x.com/mika_sole")
        }
        #expect(throws: XURLError.missingStatusID) {
            _ = try XURL.canonicalPostURL("https://x.com/mika_sole/status/abc")
        }
    }
}
