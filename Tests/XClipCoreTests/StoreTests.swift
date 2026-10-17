import Testing
import Foundation
import SQLite3
@testable import XClipCore

struct PostStoreTests {
    @Test
    func upsertDeduplicatesAndPreservesNote() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)

        let draft = PostDraft(
            externalID: "1900000000000000001",
            url: "https://x.com/mika_sole/status/1900000000000000001",
            authorHandle: "mika_sole",
            authorName: "Mika Sole",
            text: "hello world",
            media: [MediaItem(type: "photo", url: "https://pbs.twimg.com/media/a.jpg", width: 4000, height: 3000)],
            metrics: Metrics(likes: 981, bookmarks: 919),
            tags: ["Product Design"]
        )
        let first = try await store.upsert(draft)
        #expect(first.tags == ["product-design"])
        #expect(first.media.count == 1)
        #expect(first.metrics.bookmarks == 919)

        var refreshed = draft
        refreshed.text = "hello there"
        refreshed.tags = ["ui-design"]
        let second = try await store.upsert(refreshed)
        #expect(second.id == first.id)
        #expect(second.text == "hello there")
        #expect(second.tags == ["ui-design"])

        var noted = draft
        noted.note = "设计参考：留白与网格"
        let third = try await store.upsert(noted)
        #expect(third.note == "设计参考：留白与网格")

        // 新 note 为空时不覆盖用户原来写的 note
        let fourth = try await store.upsert(refreshed)
        #expect(fourth.note == "设计参考：留白与网格")
    }

    @Test
    func filtersByTagAndFullText() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "swift concurrency tips", tags: ["software-development"]))
        try await store.upsert(PostDraft(
            externalID: "2", url: "https://x.com/b/status/2", authorHandle: "b",
            text: "typography poster", tags: ["typography", "ui-design"]))
        try await store.upsert(PostDraft(
            externalID: "3", url: "https://x.com/c/status/3", authorHandle: "c",
            text: "another swift note", tags: ["software-development", "essay"]))

        #expect(try await store.list(ListFilter(tags: ["software-development"])).count == 2)
        #expect(try await store.list(ListFilter(tags: ["software-development", "essay"])).map(\.externalID) == ["3"])
        #expect(try await store.list(ListFilter(query: "swift")).count == 2)
        #expect(try await store.list(ListFilter(query: "typography")).map(\.externalID) == ["2"])
    }

    @Test
    func resolveAcceptsIDAndURL() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let post = try await store.upsert(PostDraft(
            externalID: "1900000000000000001",
            url: "https://x.com/mika_sole/status/1900000000000000001",
            authorHandle: "mika_sole", text: "hello"))

        #expect(try await store.resolve(target: post.id)?.id == post.id)
        #expect(try await store.resolve(target: "1900000000000000001")?.id == post.id)
        #expect(try await store.resolve(target: "https://twitter.com/mika_sole/status/1900000000000000001?s=20")?.id == post.id)
        #expect(try await store.resolve(target: "missing") == nil)
    }

    @Test
    func failedRefetchKeepsExistingSnapshot() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let good = try await store.upsert(PostDraft(
            externalID: "42", url: "https://x.com/a/status/42", authorHandle: "a",
            authorName: "Alice", text: "original text",
            media: [MediaItem(type: "photo", url: "https://example.com/a.jpg", width: 4000, height: 3000)],
            metrics: Metrics(likes: 5), fetchStatus: "ok"))

        var failed = PostDraft(
            externalID: "42", url: "https://x.com/i/status/42", authorHandle: "",
            text: "", fetchStatus: "failed")
        failed.tags = ["essay"]
        let after = try await store.upsert(failed)

        #expect(after.id == good.id)
        #expect(after.text == "original text")
        #expect(after.url == "https://x.com/a/status/42")
        #expect(after.fetchStatus == "ok")
        #expect(after.media.count == 1)
        #expect(after.tags == ["essay"])
    }

    @Test
    func searchesAuthorName() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "mika_sole",
            authorName: "Mika Sole", text: "hello"))

        #expect(try await store.list(ListFilter(query: "Sole")).count == 1)
        #expect(try await store.list(ListFilter(query: "mika_sole")).count == 1)
    }

    @Test
    func searchesChineseSubstring() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            authorName: "设计师", text: "今天聊聊产品设计里的网格系统，AI 排版留 100% 余量",
            tags: ["product-design"]))
        try await store.upsert(PostDraft(
            externalID: "2", url: "https://x.com/b/status/2", authorHandle: "b",
            text: "聊聊 k_f 参数", tags: ["ui-design"]))
        try await store.upsert(PostDraft(
            externalID: "3", url: "https://x.com/c/status/3", authorHandle: "c",
            text: "聊聊 kbf 参数与 1000 宽度", tags: ["ui-design"]))

        // trigram 分词：中英文都按子串匹配，不是整段相等
        #expect(try await store.list(ListFilter(query: "网格系统")).map(\.externalID) == ["1"])
        #expect(try await store.list(ListFilter(query: "设计师")).map(\.externalID) == ["1"])
        #expect(try await store.list(ListFilter(query: "product")).isEmpty)

        // 少于 3 个字符的词 trigram 恒不命中，改走 LIKE 子串匹配兜底
        #expect(try await store.list(ListFilter(query: "网格")).map(\.externalID) == ["1"])
        #expect(try await store.list(ListFilter(query: "ai")).map(\.externalID) == ["1"])
        // LIKE 的元字符 % _ 按字面量转义，不当通配符
        #expect(try await store.list(ListFilter(query: "0%")).map(\.externalID) == ["1"])
        #expect(try await store.list(ListFilter(query: "k_")).map(\.externalID) == ["2"])
    }

    @Test
    func sortsByBookmarksAndLikes() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", metrics: Metrics(likes: 10, bookmarks: 300)))
        try await store.upsert(PostDraft(
            externalID: "2", url: "https://x.com/b/status/2", authorHandle: "b",
            text: "y", metrics: Metrics(likes: 900, bookmarks: 50)))
        try await store.upsert(PostDraft(
            externalID: "3", url: "https://x.com/c/status/3", authorHandle: "c",
            text: "z", metrics: Metrics(likes: 500, bookmarks: 100)))

        // 排序在 SQL 层完成，指标高者优先，指标相同再回落到 saved_at
        #expect(try await store.list(ListFilter(sort: .bookmarks)).map(\.externalID) == ["1", "3", "2"])
        #expect(try await store.list(ListFilter(sort: .likes)).map(\.externalID) == ["2", "3", "1"])
    }

    @Test
    func upsertKeepsTagsWhenNoneProvided() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let draft = PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", tags: ["product-design", "ui-design"])
        try await store.upsert(draft)

        // 重新录入只补备注、不传标签：已有标签必须保留
        var noted = draft
        noted.note = "补一句备注"
        let after = try await store.upsert(noted)
        #expect(after.tags == ["product-design", "ui-design"])
        #expect(after.note == "补一句备注")

        // 要清空必须显式声明，且不传新标签
        var cleared = draft
        cleared.tags = []
        cleared.clearTags = true
        let empty = try await store.upsert(cleared)
        #expect(empty.tags.isEmpty)
    }

    @Test
    func updatesTagsAndNoteWithoutTouchingSnapshot() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let post = try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            authorName: "Alice", text: "original text", metrics: Metrics(likes: 42),
            fetchStatus: "ok", tags: ["product-design"]))
        let originalSavedAt = post.savedAt

        try await store.updateTagsAndNote(postID: post.id, tags: ["ui-design", "essay"], note: "改过的备注")

        let updated = try #require(try await store.post(id: post.id))
        #expect(updated.tags == ["essay", "ui-design"])
        #expect(updated.note == "改过的备注")
        // 编辑不动快照，也不该把贴文顶到列表最上面
        #expect(updated.text == "original text")
        #expect(updated.metrics.likes == 42)
        #expect(updated.savedAt == originalSavedAt)
    }

    @Test
    func allMediaURLsIncludesAuthorAvatar() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            authorAvatar: "https://pbs.twimg.com/profile_images/a.jpg",
            text: "x",
            media: [
                MediaItem(type: "photo", url: "https://pbs.twimg.com/media/p.jpg"),
                MediaItem(type: "video", url: "https://video.twimg.com/v.mp4",
                          thumbnailURL: "https://pbs.twimg.com/thumb/v.jpg")
            ]))
        // 无头像、无媒体的贴文不贡献地址
        try await store.upsert(PostDraft(
            externalID: "2", url: "https://x.com/b/status/2", authorHandle: "b", text: "y"))

        // 视频的流地址和缩略图都要收进待缓存清单
        #expect(try await Set(store.allMediaURLs()) == [
            "https://pbs.twimg.com/profile_images/a.jpg",
            "https://pbs.twimg.com/media/p.jpg",
            "https://video.twimg.com/v.mp4",
            "https://pbs.twimg.com/thumb/v.jpg"
        ])
    }

    @Test
    func deleteRemovesPost() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let post = try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", tags: ["essay"]))

        try await store.delete(id: post.id)
        #expect(try await store.post(id: post.id) == nil)
        #expect(try await store.list(ListFilter(tags: ["essay"])).isEmpty)
    }

    @Test
    func storesAndSearchesSummary() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let post = try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "hello", summary: "Notes on AI grid systems and whitespace ratios.",
            note: "私人备注"))
        #expect(post.summary == "Notes on AI grid systems and whitespace ratios.")
        #expect(post.displaySummary == post.summary)

        // summary 进 trigram FTS，长词按子串命中；短词走 LIKE 兜底同样覆盖 summary
        #expect(try await store.list(ListFilter(query: "whitespace ratios")).map(\.externalID) == ["1"])
        #expect(try await store.list(ListFilter(query: "ai")).map(\.externalID) == ["1"])
        // note 不受英文限制，仍然可搜中文
        #expect(try await store.list(ListFilter(query: "私人")).map(\.externalID) == ["1"])

        // displaySummary 回退顺序：summary > note > text
        let noted = try await store.upsert(PostDraft(
            externalID: "2", url: "https://x.com/b/status/2", authorHandle: "b",
            text: "原文", note: "只有备注"))
        #expect(noted.displaySummary == "只有备注")
        let plain = try await store.upsert(PostDraft(
            externalID: "3", url: "https://x.com/c/status/3", authorHandle: "c", text: "只有原文"))
        #expect(plain.displaySummary == "只有原文")

        // 重复录入：空 summary 不覆盖已有值，非空才更新
        var refreshed = PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a", text: "refreshed")
        var again = try await store.upsert(refreshed)
        #expect(again.summary == "Notes on AI grid systems and whitespace ratios.")
        refreshed.summary = "Rewritten distillation."
        again = try await store.upsert(refreshed)
        #expect(again.summary == "Rewritten distillation.")
    }

    @Test
    func updateEditsSummaryNoteAndTags() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let post = try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", metrics: Metrics(likes: 7), tags: ["essay"]))
        let savedAt = post.savedAt

        try await store.update(postID: post.id, tags: ["Typography"],
                               summary: "Updated English summary.", note: "备注")

        let updated = try #require(try await store.post(id: post.id))
        #expect(updated.summary == "Updated English summary.")
        #expect(updated.note == "备注")
        #expect(updated.tags == ["typography"])
        // 编辑不动快照，也不该把贴文顶到列表最上面
        #expect(updated.metrics.likes == 7)
        #expect(updated.savedAt == savedAt)

        // update 同样校验 summary：中文直接拒绝，原值不动
        await #expect(throws: SummaryValidationError.containsCJK) {
            try await store.update(postID: post.id, tags: ["typography"], summary: "中文", note: "")
        }
        #expect(try await store.post(id: post.id)?.summary == "Updated English summary.")
    }

    @Test
    func patchUpdatesSelectedFields() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let post = try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", note: "原备注", tags: ["ui-design"]))

        // 只给 summary：note 和标签不动
        var patched = try await store.patch(postID: post.id,
            PostPatch(summary: "Patched English summary."))
        #expect(patched.summary == "Patched English summary.")
        #expect(patched.note == "原备注")
        #expect(patched.tags == ["ui-design"])

        // patch 写非法 summary 会被拦下，已有字段不受影响
        await #expect(throws: SummaryValidationError.containsCJK) {
            try await store.patch(postID: post.id, PostPatch(summary: "中文提炼"))
        }
        #expect(try await store.post(id: post.id)?.summary == "Patched English summary.")

        // 增量增减标签：addTags 支持内联建标，removeTags 按 slug 归一化比对
        patched = try await store.patch(postID: post.id,
            PostPatch(addTags: ["ai-tools:AI 工具"], removeTags: ["UI Design"]))
        #expect(patched.tags == ["ai-tools"])
        #expect(try await TagStore(db).all().first { $0.slug == "ai-tools" }?.name == "AI 工具")

        // 打标时只给不存在、也不带中文名的 slug，直接拒绝而不是静默建标
        await #expect(throws: TagStoreError.unknownTagRequiresChineseName("ghost-tag")) {
            try await store.patch(postID: post.id, PostPatch(addTags: ["ghost-tag"]))
        }

        // replaceTags 整体替换，归一化后去重
        patched = try await store.patch(postID: post.id,
            PostPatch(replaceTags: ["essay", "Essay", "product-design"]))
        #expect(patched.tags == ["essay", "product-design"])

        // clearTags 优先于 replaceTags 作基准，addTags 仍然生效
        patched = try await store.patch(postID: post.id,
            PostPatch(replaceTags: ["essay"], addTags: ["typography"], clearTags: true))
        #expect(patched.tags == ["typography"])

        // 什么都不给的空 patch：字段原样保留
        patched = try await store.patch(postID: post.id, PostPatch())
        #expect(patched.summary == "Patched English summary.")
        #expect(patched.note == "原备注")
        #expect(patched.tags == ["typography"])

        await #expect(throws: DatabaseError.stepFailed("贴文不存在: missing")) {
            try await store.patch(postID: "missing", PostPatch())
        }
    }

    @Test
    func resolveAcceptsShortID() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let post = try await store.upsert(PostDraft(
            externalID: "9", url: "https://x.com/a/status/9", authorHandle: "a", text: "x"))

        // 短编码是去连字符 UUID 的前 8 位小写
        #expect(post.shortID == String(post.id.replacing("-", with: "").lowercased().prefix(8)))
        #expect(post.shortID.count == 8)

        #expect(try await store.resolve(target: post.shortID)?.id == post.id)
        #expect(try await store.resolve(target: "#\(post.shortID)")?.id == post.id)
        #expect(try await store.resolve(target: post.shortID.uppercased())?.id == post.id)
        // 带连字符的更长前缀形态也能命中
        #expect(try await store.resolve(target: String(post.id.prefix(13)))?.id == post.id)
        // 完整 UUID 走精确匹配（含 # 前缀形态）
        #expect(try await store.resolve(target: post.id)?.id == post.id)
        #expect(try await store.resolve(target: "#\(post.id)")?.id == post.id)

        // 历史库里存在非 UUID 的 id（如 "demo-b"，短编码 "demob" 含非十六进制字母）
        try await db.run("""
            INSERT INTO posts (id, platform, external_id, url, author_handle, text, saved_at)
            VALUES ('demo-b', 'x', 'demo-b-ext', 'https://x.com/a/status/demo-b', 'a', 'demo', 1)
            """)
        #expect(try await store.resolve(target: "demo-b")?.id == "demo-b")
        #expect(try await store.resolve(target: "demob")?.id == "demo-b")
        #expect(try await store.resolve(target: "#demo-b")?.id == "demo-b")
        #expect(try await store.resolve(target: "#demob")?.id == "demo-b")

        // 太短的前缀不当短编码查；库里不存在的合法前缀返回 nil
        #expect(try await store.resolve(target: String(post.shortID.prefix(3))) == nil)
        #expect(try await store.resolve(target: "deadbeef") == nil)
    }

    @Test
    func resolveRejectsAmbiguousPrefix() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        // 两条贴文共享 4 位前缀：歧义必须报错，不能按 saved_at 静默挑最新一条
        try await db.run("""
            INSERT INTO posts (id, platform, external_id, url, author_handle, text, saved_at)
            VALUES ('ab12aaaa-1111-2222-3333-444444444444', 'x', 'e1', 'https://x.com/a/status/1', 'a', 'old', 1)
            """)
        try await db.run("""
            INSERT INTO posts (id, platform, external_id, url, author_handle, text, saved_at)
            VALUES ('ab12bbbb-5555-6666-7777-888888888888', 'x', 'e2', 'https://x.com/a/status/2', 'a', 'new', 2)
            """)

        do {
            // 不抛错的话旧实现会返回 saved_at 最新的那条，断言在此兜底
            #expect(try await store.resolve(target: "ab12") == nil)
            Issue.record("歧义前缀应抛 ambiguousPrefix")
        } catch let error as PostStoreError {
            guard case .ambiguousPrefix(_, let candidates) = error else {
                Issue.record("错误类型不对: \(error)")
                return
            }
            #expect(Set(candidates) == ["ab12aaaa", "ab12bbbb"])
        }
        // 更长前缀无歧义，仍正常命中
        #expect(try await store.resolve(target: "ab12a")?.id == "ab12aaaa-1111-2222-3333-444444444444")
    }

    @Test
    func resolveNumericShortID() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        // UUID 前 8 位可能恰好全是数字（约 2.3% 概率）——不能被误当 externalID 吞掉
        try await db.run("""
            INSERT INTO posts (id, platform, external_id, url, author_handle, text, saved_at)
            VALUES ('87290253-FF8F-4BBE-BA19-971664F784F2', 'x', '999888777666555',
                    'https://x.com/a/status/999888777666555', 'a', 'x', 1)
            """)

        // 不带 #：externalID 未命中时继续走短编码匹配
        #expect(try await store.resolve(target: "87290253")?.id == "87290253-FF8F-4BBE-BA19-971664F784F2")
        // 带 #：跳过 externalID 直接走短编码
        #expect(try await store.resolve(target: "#87290253")?.id == "87290253-FF8F-4BBE-BA19-971664F784F2")
        // 真正的数字 tweet id 仍走 externalID 命中
        #expect(try await store.resolve(target: "999888777666555")?.id == "87290253-FF8F-4BBE-BA19-971664F784F2")
    }

    @Test
    func migratesV2DatabaseBackfillingSummary() async throws {
        let url = temporaryDatabaseURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 手工建一个停在 v2 的库，塞一条只写了 note 的旧数据
        var raw: OpaquePointer?
        try #require(sqlite3_open(url.path, &raw) == SQLITE_OK)
        let handle = try #require(raw)
        defer { sqlite3_close(handle) }
        let statements = [
            Schema.v1,
            Schema.v2,
            "PRAGMA user_version = 2",
            """
            INSERT INTO posts (id, platform, external_id, url, author_handle, text, note, saved_at)
            VALUES ('p1', 'x', '1', 'https://x.com/a/status/1', 'a', '正文', '旧备注提炼', 1)
            """
        ]
        for statement in statements {
            try #require(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
        }

        // 打开即一路迁到最新版：旧 note 回填进 summary（note 保留原文），FTS 重建后两列都可搜
        let db = try Database(path: url)
        let store = PostStore(db)
        let migrated = try #require(try await store.post(externalID: "1"))
        #expect(migrated.summary == "旧备注提炼")
        #expect(migrated.note == "旧备注提炼")
        #expect(try await store.list(ListFilter(query: "备注提炼")).map(\.externalID) == ["1"])

        // 迁移后的库正常工作：新贴的 summary 进索引（新写入走英文校验）
        let fresh = try await store.upsert(PostDraft(
            externalID: "2", url: "https://x.com/b/status/2", authorHandle: "b",
            text: "x", summary: "New distillation in English."))
        #expect(fresh.summary == "New distillation in English.")
        #expect(try await store.list(ListFilter(query: "distillation")).map(\.externalID) == ["2"])

        // tags 表迁到 v4 后种子标签带上了中文名，slug/name 一一对应
        let tags = try await TagStore(db).all()
        #expect(tags.first { $0.slug == "product-design" }?.name == "产品设计")
        #expect(Set(tags.map(\.name)).count == tags.count)
    }

    @Test
    func validatesSummary() throws {
        // 空串放行：表示暂未提炼；合规的 1-2 句英文 trim 后返回
        #expect(try SummaryValidator.validate("") == "")
        #expect(try SummaryValidator.validate("   ") == "")
        #expect(try SummaryValidator.validate("  One sentence summary.  ") == "One sentence summary.")
        #expect(try SummaryValidator.validate("First sentence. Second one.")
            == "First sentence. Second one.")

        // 中文、日文假名、CJK 标点都算 CJK 字符
        #expect(throws: SummaryValidationError.containsCJK) {
            try SummaryValidator.validate("含中文的 summary")
        }
        #expect(throws: SummaryValidationError.containsCJK) {
            try SummaryValidator.validate("カタカナだけ")
        }
        #expect(throws: SummaryValidationError.containsCJK) {
            try SummaryValidator.validate("English with CJK period。")
        }
        // 换行、超长、超过 2 句分别拦下
        #expect(throws: SummaryValidationError.multiline) {
            try SummaryValidator.validate("first line.\nsecond line.")
        }
        // 上限放宽到 400：330 字符的 2 句英文放行，401 字符拒绝
        let long330 = String(repeating: "a", count: 160) + ". " + String(repeating: "b", count: 168)
        #expect(long330.count == 330)
        #expect(try SummaryValidator.validate(long330) == long330)
        #expect(throws: SummaryValidationError.tooLong(401)) {
            try SummaryValidator.validate(String(repeating: "a", count: 401))
        }
        #expect(throws: SummaryValidationError.tooManySentences(3)) {
            try SummaryValidator.validate("One. Two. Three.")
        }
    }

    @Test
    func insertRejectsDuplicatePost() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let draft = PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "original", summary: "First take.")
        let first = try await store.insert(draft)
        #expect(first.summary == "First take.")

        // 同一 externalID 再次录入：抛错且不覆盖原记录
        var duplicate = draft
        duplicate.text = "changed"
        duplicate.summary = "Second take."
        duplicate.note = "added note"
        await #expect(throws: PostStoreError.duplicatePost(shortID: first.shortID, externalID: "1")) {
            try await store.insert(duplicate)
        }
        let kept = try #require(try await store.post(externalID: "1"))
        #expect(kept.id == first.id)
        #expect(kept.text == "original")
        #expect(kept.summary == "First take.")
        #expect(kept.note == "")

        // 录入路径也校验 summary：非法值连首次写入都进不来（insert 与 upsert 同一道关）
        var bad = PostDraft(externalID: "2", url: "https://x.com/b/status/2",
                            authorHandle: "b", text: "x")
        bad.summary = "中文提炼"
        await #expect(throws: SummaryValidationError.containsCJK) {
            try await store.insert(bad)
        }
        await #expect(throws: SummaryValidationError.containsCJK) {
            try await store.upsert(bad)
        }
        #expect(try await store.post(externalID: "2") == nil)
    }

    @Test
    func inlineCreatesTagWhileTagging() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)

        // "slug:中文名" 内联建标并关联；种子标签照常直接关联
        let post = try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", tags: ["spatial-ui:空间交互", "essay"]))
        #expect(post.tags == ["essay", "spatial-ui"])
        #expect(try await TagStore(db).all().first { $0.slug == "spatial-ui" }?.name == "空间交互")

        // 同一组合再打幂等复用，全角冒号也认
        let again = try await store.upsert(PostDraft(
            externalID: "2", url: "https://x.com/b/status/2", authorHandle: "b",
            text: "y", tags: ["spatial-ui：空间交互"]))
        #expect(again.tags == ["spatial-ui"])

        // slug 已存在但配了不同中文名 → slugAlreadyExists
        await #expect(throws: TagStoreError.slugAlreadyExists(slug: "spatial-ui", existingName: "空间交互")) {
            try await store.upsert(PostDraft(
                externalID: "3", url: "https://x.com/c/status/3", authorHandle: "c",
                text: "z", tags: ["spatial-ui:别的名"]))
        }
        // 中文名已被别的 slug 占用 → nameAlreadyExists
        await #expect(throws: TagStoreError.nameAlreadyExists(name: "空间交互", existingSlug: "spatial-ui")) {
            try await store.upsert(PostDraft(
                externalID: "4", url: "https://x.com/d/status/4", authorHandle: "d",
                text: "w", tags: ["other-tag:空间交互"]))
        }
    }

    @Test
    func unknownTagRequiresChineseName() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)

        // 不存在的 slug 且没给中文名：拒绝录入，贴文都不落库
        await #expect(throws: TagStoreError.unknownTagRequiresChineseName("no-such-tag")) {
            try await store.insert(PostDraft(
                externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
                text: "x", tags: ["no-such-tag"]))
        }
        #expect(try await store.post(externalID: "1") == nil)

        // 中文/全角字符进不了英文 slug；冒号后半段必须是真中文名
        await #expect(throws: TagStoreError.invalidSlug("中文标签")) {
            try await store.upsert(PostDraft(
                externalID: "2", url: "https://x.com/b/status/2", authorHandle: "b",
                text: "y", tags: ["中文标签"]))
        }
        await #expect(throws: TagStoreError.invalidChineseName("x-tag:english only")) {
            try await store.upsert(PostDraft(
                externalID: "3", url: "https://x.com/c/status/3", authorHandle: "c",
                text: "z", tags: ["x-tag:english only"]))
        }
    }

    @Test
    func updateTagsOnlyTouchesAssociations() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let post = try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", summary: "Keep this.", note: "备注", tags: ["essay"]))

        try await store.updateTags(postID: post.id, tags: ["typography", "custom-x:自定义"])
        let after = try #require(try await store.post(id: post.id))
        #expect(after.tags == ["custom-x", "typography"])
        // 只动关联：summary、note、saved_at 一概不变
        #expect(after.summary == "Keep this.")
        #expect(after.note == "备注")
        #expect(after.savedAt == post.savedAt)

        await #expect(throws: TagStoreError.unknownTagRequiresChineseName("ghost")) {
            try await store.updateTags(postID: post.id, tags: ["ghost"])
        }
    }

    @Test
    func concurrentWritersAcrossConnections() async throws {
        let dbURL = temporaryDatabaseURL()
        // 先由一条连接跑完迁移，再放并发写入——隔离出纯写锁竞争
        _ = try Database(path: dbURL)

        // 6 个并发任务各自开独立连接写库（对应多个 xclip 子进程并行写同一文件），
        // busy_timeout + 退避重试兜住锁竞争，不允许抛 database is locked
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let db = try Database(path: dbURL)
                    let store = PostStore(db)
                    if index % 2 == 0 {
                        try await store.insert(PostDraft(
                            externalID: "c-\(index)",
                            url: "https://x.com/a/status/\(index)",
                            authorHandle: "a", text: "concurrent \(index)",
                            tags: ["essay"]))
                    } else {
                        let post = try await store.insert(PostDraft(
                            externalID: "c-\(index)",
                            url: "https://x.com/a/status/\(index)",
                            authorHandle: "a", text: "x"))
                        try await store.patch(postID: post.id, PostPatch(note: "note \(index)"))
                    }
                }
            }
            try await group.waitForAll()
        }

        let db = try Database(path: dbURL)
        let rows = try await db.query("SELECT COUNT(*) AS c FROM posts")
        #expect(rows.first?["c"]?.int == 6)
        let patched = try await db.query("SELECT COUNT(*) AS c FROM posts WHERE note LIKE 'note %'")
        #expect(patched.first?["c"]?.int == 3)
    }
}

struct TagStoreTests {
    @Test
    func seedsCanonicalTags() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let tags = try await TagStore(db).all()
        let expected: [(String, String)] = [
            ("product-design", "产品设计"), ("ui-design", "界面设计"),
            ("ux-design", "交互设计"), ("design-system", "设计系统"),
            ("typography", "字体排印"), ("color", "色彩体系"),
            ("motion", "动效转场"), ("app-development", "客户端开发"),
            ("software-development", "软件工程"), ("web-development", "前端开发"),
            ("dev-tools", "开发工具"), ("ai", "人工智能"), ("essay", "深度长文")
        ]
        // 13 个种子标签各自带唯一英文 slug 和唯一中文名，一一对应
        #expect(tags.count == expected.count)
        for (slug, name) in expected {
            #expect(tags.first { $0.slug == slug }?.name == name)
        }
        #expect(Set(tags.map(\.slug)).count == tags.count)
        #expect(Set(tags.map(\.name)).count == tags.count)
    }

    @Test
    func renameAndMerge() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let tagStore = TagStore(db)
        try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", tags: ["ui-design"]))
        try await store.upsert(PostDraft(
            externalID: "2", url: "https://x.com/b/status/2", authorHandle: "b",
            text: "y", tags: ["ui-design", "product-design"]))

        try await tagStore.rename(from: "ui-design", to: "interface-design")
        #expect(try await store.post(externalID: "1")?.tags == ["interface-design"])
        // 重命名只改 slug，中文名跟着标签走
        #expect(try await tagStore.all().first { $0.slug == "interface-design" }?.name == "界面设计")

        // 目标 slug 已被占用 → slugAlreadyExists；同 slug 可顺带改中文名
        await #expect(throws: TagStoreError.slugAlreadyExists(slug: "essay", existingName: "深度长文")) {
            try await tagStore.rename(from: "interface-design", to: "essay")
        }
        try await tagStore.rename(from: "interface-design", to: "interface-design", chineseName: "界面重构")
        #expect(try await tagStore.all().first { $0.slug == "interface-design" }?.name == "界面重构")

        try await tagStore.merge(source: "product-design", into: "interface-design")
        #expect(try await store.post(externalID: "2")?.tags == ["interface-design"])

        let slugs = try await tagStore.all().map(\.slug)
        #expect(!slugs.contains("product-design"))
        #expect(slugs.contains("interface-design"))
    }

    @Test
    func createEnforcesBidirectionalUniqueness() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let tagStore = TagStore(db)

        let created = try await tagStore.create(slug: "My Tag", name: "我的标签")
        #expect(created.slug == "my-tag")
        #expect(created.name == "我的标签")

        // 同 slug 同名幂等，传入 description 会顺带更新
        let again = try await tagStore.create(slug: "my-tag", name: "我的标签", description: "新说明")
        #expect(again.description == "新说明")

        // slug 重复配不同中文名 / 中文名重复配不同 slug 都拒绝
        await #expect(throws: TagStoreError.slugAlreadyExists(slug: "my-tag", existingName: "我的标签")) {
            try await tagStore.create(slug: "my-tag", name: "换个名")
        }
        await #expect(throws: TagStoreError.nameAlreadyExists(name: "我的标签", existingSlug: "my-tag")) {
            try await tagStore.create(slug: "other-slug", name: "我的标签")
        }

        // 非法输入各自报错
        await #expect(throws: TagStoreError.invalidSlug("中文")) {
            try await tagStore.create(slug: "中文", name: "名")
        }
        await #expect(throws: TagStoreError.invalidChineseName("ascii only")) {
            try await tagStore.create(slug: "ok-tag", name: "ascii only")
        }
    }

    @Test
    func errorsOnMissingTag() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        await #expect(throws: TagStoreError.tagNotFound("nope")) {
            try await TagStore(db).rename(from: "nope", to: "other")
        }
    }

    @Test
    func setDescriptionCreatesAndUpdates() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let tagStore = TagStore(db)

        // 标签不存在时必须带中文名才建得出来，否则报 unknownTagRequiresChineseName
        await #expect(throws: TagStoreError.unknownTagRequiresChineseName("my-tag")) {
            try await tagStore.setDescription(slug: "my-tag", description: "x")
        }

        // 带中文名建标：slug 与 name 归一化，说明 trim 后落库
        let created = try await tagStore.setDescription(
            slug: "My Tag", name: " 我的标签 ", description: "  说明文字  ")
        #expect(created.slug == "my-tag")
        #expect(created.name == "我的标签")
        #expect(created.description == "说明文字")
        #expect(created.count == 0)

        // 已存在时只改说明
        let updated = try await tagStore.setDescription(slug: "my-tag", description: "新说明")
        #expect(updated.description == "新说明")
        #expect(updated.name == "我的标签")

        // 传 name 顺带改名；撞了别人占用的中文名抛 nameAlreadyExists
        let renamed = try await tagStore.setDescription(slug: "my-tag", name: "我的新标签", description: "d")
        #expect(renamed.name == "我的新标签")
        await #expect(throws: TagStoreError.nameAlreadyExists(name: "界面设计", existingSlug: "ui-design")) {
            try await tagStore.setDescription(slug: "my-tag", name: "界面设计", description: nil)
        }

        // 空白说明存 NULL；传 nil 也是清掉
        #expect(try await tagStore.setDescription(slug: "my-tag", description: "   ").description == nil)
        #expect(try await tagStore.setDescription(slug: "my-tag", description: nil).description == nil)

        // 挂上贴文后返回关联计数
        try await PostStore(db).upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", tags: ["my-tag"]))
        #expect(try await tagStore.setDescription(slug: "my-tag", description: "d").count == 1)

        // 归一化后为空的 slug（纯标点）抛 invalidSlug
        await #expect(throws: TagStoreError.invalidSlug("!!!")) {
            try await tagStore.setDescription(slug: "!!!", description: "x")
        }
    }

    @Test
    func deleteRemovesTagAndAssociations() async throws {
        let db = try Database(path: temporaryDatabaseURL())
        let store = PostStore(db)
        let tagStore = TagStore(db)
        let post = try await store.upsert(PostDraft(
            externalID: "1", url: "https://x.com/a/status/1", authorHandle: "a",
            text: "x", tags: ["essay", "ui-design"]))

        // 入参先归一化；删除后 post_tags 关联被外键级联清掉，贴文本身还在
        try await tagStore.delete(slug: "Essay")
        #expect(try await store.post(id: post.id)?.tags == ["ui-design"])
        #expect(try await tagStore.all().map(\.slug).contains("essay") == false)
        #expect(try await store.post(id: post.id) != nil)

        await #expect(throws: TagStoreError.tagNotFound("essay")) {
            try await tagStore.delete(slug: "essay")
        }
    }
}

/// 回放录好的 fxtwitter 响应，不打真实网络。
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct FetcherTests {
    private func stubbedFetcher(_ json: String) -> Fetcher {
        StubURLProtocol.responseBody = Data(json.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return Fetcher(session: URLSession(configuration: configuration))
    }

    @Test
    func videoAndGifKeepStreamAndThumbnail() async throws {
        let fetcher = stubbedFetcher("""
            {
              "code": 200,
              "tweet": {
                "id": "123",
                "text": "media test",
                "author": {"screen_name": "alice", "name": "Alice"},
                "media": {"all": [
                  {"type": "photo", "url": "https://pbs.twimg.com/media/p.jpg",
                   "width": 1200, "height": 800},
                  {"type": "video",
                   "url": "https://video.twimg.com/ext_tw_video/1/pu/vid/1280x720/v.mp4",
                   "thumbnail_url": "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/v.jpg",
                   "width": 1280, "height": 720},
                  {"type": "gif",
                   "url": "https://video.twimg.com/tweet_video/g.mp4",
                   "thumbnail_url": "https://pbs.twimg.com/tweet_video_thumb/g.jpg"},
                  {"type": "video", "url": "https://video.twimg.com/clip/no-thumb.mp4"},
                  {"type": "video", "url": "",
                   "thumbnail_url": "https://pbs.twimg.com/thumb/fallback.jpg"},
                  {"type": "audio", "url": "https://example.com/a.mp3"}
                ]},
                "created_timestamp": 1700000000,
                "likes": 10, "retweets": 2, "replies": 1, "views": 100, "bookmarks": 3
              }
            }
            """)

        let post = try await fetcher.fetch(ref: PostRef(
            screenName: "alice", id: "123", url: "https://x.com/alice/status/123"))

        // video/gif 归一成 video：url 保留 mp4 流地址供播放与本地留存，
        // thumbnailURL 保留静态预览图供界面显示；没有 mp4 时退回缩略图。audio 整条丢弃。
        #expect(post.media == [
            MediaItem(type: "photo", url: "https://pbs.twimg.com/media/p.jpg",
                      width: 1200, height: 800),
            MediaItem(type: "video",
                      url: "https://video.twimg.com/ext_tw_video/1/pu/vid/1280x720/v.mp4",
                      thumbnailURL: "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/v.jpg",
                      width: 1280, height: 720),
            MediaItem(type: "video",
                      url: "https://video.twimg.com/tweet_video/g.mp4",
                      thumbnailURL: "https://pbs.twimg.com/tweet_video_thumb/g.jpg"),
            MediaItem(type: "video", url: "https://video.twimg.com/clip/no-thumb.mp4"),
            MediaItem(type: "video", url: "https://pbs.twimg.com/thumb/fallback.jpg",
                      thumbnailURL: "https://pbs.twimg.com/thumb/fallback.jpg")
        ])

        // 界面预览图：有缩略图用缩略图；只有 mp4 流时没有可显示的静态图
        #expect(post.media[0].previewImageURL == "https://pbs.twimg.com/media/p.jpg")
        #expect(post.media[1].previewImageURL == "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/v.jpg")
        #expect(post.media[2].previewImageURL == "https://pbs.twimg.com/tweet_video_thumb/g.jpg")
        #expect(post.media[3].previewImageURL == nil)

        #expect(post.postedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(post.metrics.views == 100)
    }
}
