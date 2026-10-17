import Foundation

public enum PostStoreError: Error, Equatable, CustomStringConvertible {
    case duplicatePost(shortID: String, externalID: String)

    public var description: String {
        switch self {
        case .duplicatePost(let shortID, _):
            return "该贴文已在库中（编码: \(shortID)），不再重复录入；如需修改请使用 update \(shortID)"
        }
    }
}

public struct PostStore {
    private let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    private static let columns = """
        p.id, p.platform, p.external_id, p.url, p.author_handle, p.author_name, p.author_avatar,
        p.text, p.media, p.metrics, p.summary, p.note, p.fetch_status, p.posted_at, p.saved_at
        """

    // MARK: - 写入

    /// 只录入新贴文：`(platform, externalID)` 已存在时直接抛错，不覆盖库内记录。
    /// 查重与写入之间存在极小的并发窗口，冲突时仍回落到 upsert 的合并语义，不会写坏数据。
    @discardableResult
    public func insert(_ draft: PostDraft) async throws -> Post {
        if let existing = try await post(platform: draft.platform, externalID: draft.externalID) {
            throw PostStoreError.duplicatePost(shortID: existing.shortID, externalID: existing.externalID)
        }
        return try await upsert(draft)
    }

    /// 按 `(platform, external_id)` 去重，供 `--refetch` 重抓快照与内部测试使用。
    /// 常规录入请走 `insert`，重复录入会被拒绝。重复录入同一链接时：
    /// - 抓取失败的重复录入不覆盖已有快照，只更新 summary 和 note；
    /// - 新 summary/note 为空时保留已写的旧值；
    /// - `tags` 为空表示不动标签，要清空必须显式传 `clearTags`。
    @discardableResult
    public func upsert(_ draft: PostDraft) async throws -> Post {
        let summary = try SummaryValidator.validate(draft.summary)
        // 先解析并建好标签再写贴文：非法写法或缺中文名的未知标签在贴文落库前就失败，
        // 不会让 `insert` 留下写了贴文但没打上标的半成品。`slug:中文名` 在这里建新标签。
        if !draft.tags.isEmpty {
            try await db.transaction { tx in
                for raw in draft.tags {
                    _ = try Self.ensureTag(on: tx, input: TagNormalizer.parseTagInput(raw))
                }
            }
        }
        let now = Int(Date.now.timeIntervalSince1970)
        let mediaJSON = encodeJSON(draft.media) ?? "[]"
        let metricsJSON = encodeJSON(draft.metrics) ?? "{}"

        // 单条语句完成插入或更新，因此是原子的：两个进程同时首录同一条帖子时，
        // 后到者阻塞到前者提交后再走 DO UPDATE，不会撞 UNIQUE 约束。
        // 两条业务规则直接写进 SQL，见方法注释。
        try await db.run("""
            INSERT INTO posts
                (id, platform, external_id, url, author_handle, author_name, author_avatar,
                 text, media, metrics, summary, note, fetch_status, posted_at, saved_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (platform, external_id) DO UPDATE SET
                url           = CASE WHEN posts.fetch_status = 'ok' AND excluded.fetch_status <> 'ok'
                                     THEN posts.url ELSE excluded.url END,
                author_handle = CASE WHEN posts.fetch_status = 'ok' AND excluded.fetch_status <> 'ok'
                                     THEN posts.author_handle ELSE excluded.author_handle END,
                author_name   = CASE WHEN posts.fetch_status = 'ok' AND excluded.fetch_status <> 'ok'
                                     THEN posts.author_name ELSE excluded.author_name END,
                author_avatar = CASE WHEN posts.fetch_status = 'ok' AND excluded.fetch_status <> 'ok'
                                     THEN posts.author_avatar ELSE excluded.author_avatar END,
                text          = CASE WHEN posts.fetch_status = 'ok' AND excluded.fetch_status <> 'ok'
                                     THEN posts.text ELSE excluded.text END,
                media         = CASE WHEN posts.fetch_status = 'ok' AND excluded.fetch_status <> 'ok'
                                     THEN posts.media ELSE excluded.media END,
                metrics       = CASE WHEN posts.fetch_status = 'ok' AND excluded.fetch_status <> 'ok'
                                     THEN posts.metrics ELSE excluded.metrics END,
                fetch_status  = CASE WHEN posts.fetch_status = 'ok' AND excluded.fetch_status <> 'ok'
                                     THEN posts.fetch_status ELSE excluded.fetch_status END,
                posted_at     = CASE WHEN posts.fetch_status = 'ok' AND excluded.fetch_status <> 'ok'
                                     THEN posts.posted_at ELSE excluded.posted_at END,
                saved_at      = excluded.saved_at,
                summary       = CASE WHEN excluded.summary = '' THEN posts.summary ELSE excluded.summary END,
                note          = CASE WHEN excluded.note = '' THEN posts.note ELSE excluded.note END
            """,
            [.text(UUID().uuidString), .text(draft.platform), .text(draft.externalID), .text(draft.url),
             .text(draft.authorHandle), .text(draft.authorName), optionalText(draft.authorAvatar),
             .text(draft.text), .text(mediaJSON), .text(metricsJSON), .text(summary),
             .text(draft.note), .text(draft.fetchStatus), optionalTimestamp(draft.postedAt), .int(now)])

        guard var saved = try await post(platform: draft.platform, externalID: draft.externalID) else {
            throw DatabaseError.stepFailed("写入后读回贴文失败")
        }

        if !draft.tags.isEmpty || draft.clearTags {
            try await db.transaction { tx in
                try Self.replaceTags(on: tx, postID: saved.id, tags: draft.tags)
            }
            guard let updated = try await post(platform: draft.platform, externalID: draft.externalID) else {
                throw DatabaseError.stepFailed("写入标签后读回贴文失败")
            }
            saved = updated
        }
        return saved
    }

    public func delete(id: String) async throws {
        try await db.run("DELETE FROM posts WHERE id = ?", [.text(id)])
    }

    /// 只改标签和备注，不动快照、不动 saved_at——编辑不该把贴文顶到列表最上面。
    public func updateTagsAndNote(postID: String, tags: [String], note: String) async throws {
        try await db.transaction { tx in
            try tx.run("UPDATE posts SET note = ? WHERE id = ?", [.text(note), .text(postID)])
            try Self.replaceTags(on: tx, postID: postID, tags: tags)
        }
    }

    /// 只改贴文与标签的关联，不动 summary、note 和 saved_at。
    /// 每个元素是已存在的 slug 或内联新建格式 "slug:中文名"。
    public func updateTags(postID: String, tags: [String]) async throws {
        try await db.transaction { tx in
            try Self.replaceTags(on: tx, postID: postID, tags: tags)
        }
    }

    /// 编辑标签、提炼和备注，不动快照、不动 saved_at。
    public func update(postID: String, tags: [String], summary: String, note: String) async throws {
        let summary = try SummaryValidator.validate(summary)
        try await db.transaction { tx in
            try tx.run("UPDATE posts SET summary = ?, note = ? WHERE id = ?",
                       [.text(summary), .text(note), .text(postID)])
            try Self.replaceTags(on: tx, postID: postID, tags: tags)
        }
    }

    /// 局部编辑：只改 `patch` 里给出的字段。标签是否变动看 `PostPatch` 的标签字段
    /// 是否至少给了一种语义（清空/替换/增/减），没给就保持原标签不动。
    @discardableResult
    public func patch(postID: String, _ patch: PostPatch) async throws -> Post {
        guard let existing = try await post(id: postID) else {
            throw DatabaseError.stepFailed("贴文不存在: \(postID)")
        }
        var summary = existing.summary
        if let patched = patch.summary {
            summary = try SummaryValidator.validate(patched)
        }
        let note = patch.note ?? existing.note

        let touchesTags = patch.clearTags || patch.replaceTags != nil
            || !patch.addTags.isEmpty || !patch.removeTags.isEmpty
        try await db.transaction { tx in
            try tx.run("UPDATE posts SET summary = ?, note = ? WHERE id = ?",
                       [.text(summary), .text(note), .text(postID)])
            if touchesTags {
                // removeTags 只按 slug 移除；replaceTags/addTags 保留原始串交给
                // replaceTags——"slug:中文名" 的内联建标语义要原样传下去。
                // 这里先 parse 一遍只为拿 slug 做去重和移除比对。
                let removed = Set(try patch.removeTags.map { try TagNormalizer.parseTagInput($0).slug })
                var seen = Set<String>()
                var tags: [String] = []
                let base = patch.clearTags ? [] : (patch.replaceTags ?? existing.tags)
                for raw in base + patch.addTags {
                    let input = try TagNormalizer.parseTagInput(raw)
                    guard !removed.contains(input.slug), seen.insert(input.slug).inserted else { continue }
                    tags.append(raw)
                }
                try Self.replaceTags(on: tx, postID: postID, tags: tags)
            }
        }
        guard let updated = try await post(id: postID) else {
            throw DatabaseError.stepFailed("贴文更新后读回失败: \(postID)")
        }
        return updated
    }

    // MARK: - 读取

    /// `tags` 为 AND 语义：只返回同时带有全部指定标签的贴文。
    public func list(_ filter: ListFilter) async throws -> [Post] {
        var conditions: [String] = []
        var params: [SQLValue] = []

        if let query = filter.query?.trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty {
            // trigram 对少于 3 个字符的词恒不命中（"AI"、"网格" 等），
            // 长词走 FTS，短词逐个走 LIKE 子串匹配兜底，条件之间都是 AND。
            var ftsTokens: [String] = []
            for token in query.split(whereSeparator: { $0 == " " || $0.isNewline }) {
                if token.count >= 3 {
                    ftsTokens.append(String(token))
                } else {
                    conditions.append("""
                        (LOWER(p.text) LIKE ? ESCAPE '\\' OR LOWER(p.author_handle) LIKE ? ESCAPE '\\' \
                        OR LOWER(p.author_name) LIKE ? ESCAPE '\\' OR LOWER(p.summary) LIKE ? ESCAPE '\\' \
                        OR LOWER(p.note) LIKE ? ESCAPE '\\')
                        """)
                    let pattern = likePattern(String(token))
                    params.append(contentsOf: [.text(pattern), .text(pattern), .text(pattern),
                                               .text(pattern), .text(pattern)])
                }
            }
            if !ftsTokens.isEmpty {
                conditions.append("p.rowid IN (SELECT rowid FROM posts_fts WHERE posts_fts MATCH ?)")
                params.append(.text(matchQuery(ftsTokens)))
            }
        }
        for tag in filter.tags {
            let slug = TagNormalizer.normalize(tag) ?? tag
            conditions.append("""
                EXISTS (SELECT 1 FROM post_tags pt JOIN tags t ON t.id = pt.tag_id
                        WHERE pt.post_id = p.id AND t.slug = ?)
                """)
            params.append(.text(slug))
        }

        var sql = "SELECT \(Self.columns) FROM posts p"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        switch filter.sort {
        case .latest:
            sql += " ORDER BY p.saved_at DESC, p.id DESC LIMIT ?"
        case .bookmarks:
            sql += " ORDER BY COALESCE(CAST(json_extract(p.metrics, '$.bookmarks') AS INTEGER), 0) DESC, p.saved_at DESC, p.id DESC LIMIT ?"
        case .likes:
            sql += " ORDER BY COALESCE(CAST(json_extract(p.metrics, '$.likes') AS INTEGER), 0) DESC, p.saved_at DESC, p.id DESC LIMIT ?"
        }
        params.append(.int(max(1, filter.limit)))

        return try await hydrate(try await db.query(sql, params))
    }

    public func post(id: String) async throws -> Post? {
        let rows = try await db.query("SELECT \(Self.columns) FROM posts p WHERE p.id = ?", [.text(id)])
        return try await hydrate(rows).first
    }

    public func post(externalID: String) async throws -> Post? {
        try await post(platform: "x", externalID: externalID)
    }

    private func post(platform: String, externalID: String) async throws -> Post? {
        let rows = try await db.query(
            "SELECT \(Self.columns) FROM posts p WHERE p.platform = ? AND p.external_id = ?",
            [.text(platform), .text(externalID)]
        )
        return try await hydrate(rows).first
    }

    /// 接受内部 id、8 位短编码或更长前缀（`#a1b2c3d4`、带连字符形态都行）、
    /// 纯数字的帖子 id，或原始链接。
    public func resolve(target: String) async throws -> Post? {
        var trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("x.com") || trimmed.contains("twitter.com") {
            let ref = try XURL.canonicalPostURL(trimmed)
            return try await post(externalID: ref.id)
        }
        // `#` 是短编码/条目的引用写法，先剥掉再走后面的匹配；带 # 的数字串
        // 不当 externalID 查——UUID 前 8 位恰好全是数字的情况存在（约 2.3%）。
        // 不带 # 的纯数字先查 externalID，未命中继续往下走 id/短编码匹配。
        let hadHash = trimmed.hasPrefix("#")
        if hadHash { trimmed.removeFirst() }
        if !hadHash, !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }),
           let byExternal = try await post(externalID: trimmed) {
            return byExternal
        }
        if let exact = try await post(id: trimmed) {
            return exact
        }
        // 短编码/前缀匹配：去掉所有连字符转小写，对照 id 的紧凑形态。
        // 历史 id 不全是 UUID（如 "demo-b"），字符校验放宽到字母数字；
        // 短于 4 位的输入歧义风险太大，不当短编码查。
        let prefix = trimmed.replacing("-", with: "").lowercased()
        guard prefix.count >= 4, prefix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let rows = try await db.query("""
            SELECT \(Self.columns) FROM posts p
            WHERE LOWER(REPLACE(p.id, '-', '')) LIKE ?
            ORDER BY p.saved_at DESC LIMIT 2
            """, [.text("\(prefix)%")])
        return try await hydrate(rows).first
    }

    /// 全库的媒体地址和作者头像，供 `xclip warm` 预取缓存。
    public func allMediaURLs() async throws -> [String] {
        let rows = try await db.query("SELECT media, author_avatar FROM posts")
        var urls: [String] = []
        for row in rows {
            if let avatar = row["author_avatar"]?.string, !avatar.isEmpty {
                urls.append(avatar)
            }
            guard let json = row["media"]?.string else { continue }
            let items: [MediaItem]? = decodeJSON(json)
            for item in items ?? [] {
                if !item.url.isEmpty { urls.append(item.url) }
                if let thumbnail = item.thumbnailURL, !thumbnail.isEmpty {
                    urls.append(thumbnail)
                }
            }
        }
        return urls
    }

    // MARK: - Private

    /// 只能在 `db.transaction` 里调用：多步删除+插入必须在同一事务里原子完成。
    /// 每个元素是已存在的 slug 或内联新建格式 "slug:中文名"。
    private static func replaceTags(on tx: Transaction, postID: String, tags: [String]) throws {
        try tx.run("DELETE FROM post_tags WHERE post_id = ?", [.text(postID)])
        var seen = Set<String>()
        for raw in tags {
            let input = try TagNormalizer.parseTagInput(raw)
            guard seen.insert(input.slug).inserted else { continue }
            let tagID = try ensureTag(on: tx, input: input)
            try tx.run(
                "INSERT OR IGNORE INTO post_tags (post_id, tag_id) VALUES (?, ?)",
                [.text(postID), .int(tagID)]
            )
        }
    }

    /// 取标签 id：纯 slug 必须已存在，否则抛 unknownTagRequiresChineseName——
    /// 绝不静默插入无中文名的标签。`slug:中文名` 形式命中同名标签则复用；
    /// slug 已存在但中文名不同、或中文名已被别的 slug 占用，都报错（双向唯一）。
    private static func ensureTag(on tx: Transaction, input: TagInput) throws -> Int {
        let bySlug = try tx.query("SELECT id, name FROM tags WHERE slug = ?", [.text(input.slug)])
        if let row = bySlug.first {
            if let name = input.chineseName {
                let existing = row["name"]?.string ?? ""
                guard existing == name else {
                    throw TagStoreError.slugAlreadyExists(slug: input.slug, existingName: existing)
                }
            }
            guard let id = row["id"]?.int else {
                throw DatabaseError.stepFailed("标签行缺少 id: \(input.slug)")
            }
            return id
        }
        guard let name = input.chineseName else {
            throw TagStoreError.unknownTagRequiresChineseName(input.slug)
        }
        if let other = try tx.query("SELECT slug FROM tags WHERE name = ?", [.text(name)]).first {
            throw TagStoreError.nameAlreadyExists(name: name, existingSlug: other["slug"]?.string ?? "")
        }
        try tx.run(
            "INSERT INTO tags (slug, name, description, created_at) VALUES (?, ?, NULL, ?)",
            [.text(input.slug), .text(name), .int(Int(Date.now.timeIntervalSince1970))]
        )
        let rows = try tx.query("SELECT id FROM tags WHERE slug = ?", [.text(input.slug)])
        guard let id = rows.first?["id"]?.int else {
            throw DatabaseError.stepFailed("标签写入后读回失败: \(input.slug)")
        }
        return id
    }

    private func hydrate(_ rows: [[String: SQLValue]]) async throws -> [Post] {
        guard !rows.isEmpty else { return [] }

        let ids = rows.compactMap { $0["id"]?.string }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let tagRows = try await db.query("""
            SELECT pt.post_id AS post_id, t.slug AS slug
            FROM post_tags pt JOIN tags t ON t.id = pt.tag_id
            WHERE pt.post_id IN (\(placeholders))
            ORDER BY t.slug
            """, ids.map { .text($0) })
        var tagsByPost: [String: [String]] = [:]
        for row in tagRows {
            guard let postID = row["post_id"]?.string, let slug = row["slug"]?.string else { continue }
            tagsByPost[postID, default: []].append(slug)
        }

        return rows.map { row in
            let id = row["id"]?.string ?? ""
            return Post(
                id: id,
                platform: row["platform"]?.string ?? "",
                externalID: row["external_id"]?.string ?? "",
                url: row["url"]?.string ?? "",
                authorHandle: row["author_handle"]?.string ?? "",
                authorName: row["author_name"]?.string ?? "",
                authorAvatar: row["author_avatar"]?.string,
                text: row["text"]?.string ?? "",
                media: decodeJSON(row["media"]?.string ?? "[]") ?? [],
                metrics: decodeJSON(row["metrics"]?.string ?? "{}") ?? Metrics(),
                summary: row["summary"]?.string ?? "",
                note: row["note"]?.string ?? "",
                fetchStatus: row["fetch_status"]?.string ?? "ok",
                postedAt: row["posted_at"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                savedAt: Date(timeIntervalSince1970: TimeInterval(row["saved_at"]?.int ?? 0)),
                tags: tagsByPost[id] ?? []
            )
        }
    }

    /// FTS5 的 MATCH 语法：每个词单独加引号，词间为 AND，避免用户输入里的特殊字符引发语法错误。
    private func matchQuery(_ tokens: [String]) -> String {
        tokens.map { token in
            let cleaned = token.replacing("\"", with: "")
            return "\"\(cleaned.lowercased())\""
        }.joined(separator: " ")
    }

    /// 短词 LIKE 匹配用的 pattern：`\`、`%`、`_` 是 LIKE 元字符，按 ESCAPE '\' 转义后
    /// 当成字面量，两侧再补通配做成子串匹配。
    private func likePattern(_ token: String) -> String {
        var pattern = "%"
        for character in token.lowercased() {
            if character == "\\" || character == "%" || character == "_" {
                pattern.append("\\")
            }
            pattern.append(character)
        }
        return pattern + "%"
    }

    private func optionalText(_ value: String?) -> SQLValue {
        value.map { .text($0) } ?? .null
    }

    private func optionalTimestamp(_ date: Date?) -> SQLValue {
        date.map { .int(Int($0.timeIntervalSince1970)) } ?? .null
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJSON<T: Decodable>(_ string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
