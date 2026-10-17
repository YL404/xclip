import Foundation

public enum TagStoreError: Error, Equatable, CustomStringConvertible {
    case tagNotFound(String)
    case unknownTagRequiresChineseName(String)
    case invalidSlug(String)
    case invalidChineseName(String)
    case slugAlreadyExists(slug: String, existingName: String)
    case nameAlreadyExists(name: String, existingSlug: String)

    public var description: String {
        switch self {
        case .tagNotFound(let slug):
            return "标签不存在: \(slug)（请运行 xclip tags 查看已有标签，或用 \(slug):中文名 新建）"
        case .unknownTagRequiresChineseName(let slug):
            return "标签 '\(slug)' 尚不存在；新建标签必须同时提供唯一中文名，格式为 --tag \(slug):中文名 或先运行 xclip tag create \(slug) <中文名>"
        case .invalidSlug(let raw):
            return "无效的英文标签: \(raw)（英文标签只能包含小写字母、数字和连字符）"
        case .invalidChineseName(let raw):
            return "无效的中文标签名: \(raw)（必须包含中文字符且不换行）"
        case .slugAlreadyExists(let slug, let existingName):
            return "英文标签 '\(slug)' 已存在（对应中文标签「\(existingName)」），不能重复绑定其他中文名"
        case .nameAlreadyExists(let name, let existingSlug):
            return "中文标签「\(name)」已被英文标签 '\(existingSlug)' 占用，中英文标签必须一一对应"
        }
    }
}

/// tags 行的最小投影，供唯一性检查。
private struct TagRow {
    let slug: String
    let name: String
    let description: String?
}

public struct TagStore {
    private let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    public func all() async throws -> [Tag] {
        let rows = try await db.query("""
            SELECT t.slug AS slug, t.name AS name, t.description AS description,
                   COUNT(pt.post_id) AS count
            FROM tags t
            LEFT JOIN post_tags pt ON pt.tag_id = t.id
            GROUP BY t.id
            ORDER BY t.slug
            """)
        return rows.map(Self.makeTag)
    }

    /// 新建标签：slug 与中文名双向唯一。
    /// slug 已存在时同名幂等（传入 description 会顺带更新），不同名抛 slugAlreadyExists。
    @discardableResult
    public func create(slug rawSlug: String, name rawName: String, description: String? = nil) async throws -> Tag {
        guard let slug = TagNormalizer.normalize(rawSlug) else {
            throw TagStoreError.invalidSlug(rawSlug)
        }
        guard let name = TagNormalizer.normalizeChineseName(rawName) else {
            throw TagStoreError.invalidChineseName(rawName)
        }
        let desc = Self.cleanedDescription(description)
        try await db.transaction { tx in
            if let existing = try Self.tagRow(on: tx, slug: slug) {
                guard existing.name == name else {
                    throw TagStoreError.slugAlreadyExists(slug: slug, existingName: existing.name)
                }
                if description != nil {
                    try tx.run("UPDATE tags SET description = ? WHERE slug = ?", [desc, .text(slug)])
                }
            } else {
                if let other = try Self.tagRow(on: tx, name: name) {
                    throw TagStoreError.nameAlreadyExists(name: name, existingSlug: other.slug)
                }
                try tx.run(
                    "INSERT INTO tags (slug, name, description, created_at) VALUES (?, ?, ?, ?)",
                    [.text(slug), .text(name), desc, .int(Int(Date.now.timeIntervalSince1970))]
                )
            }
        }
        return try await fetchTag(slug: slug)
    }

    /// 创建或更新标签说明，可选顺带改中文名。
    /// 标签不存在时必须给合法中文名才能建出来；说明 trim 后为空串时存 NULL。
    @discardableResult
    public func setDescription(slug rawSlug: String, name rawName: String? = nil, description: String?) async throws -> Tag {
        guard let slug = TagNormalizer.normalize(rawSlug) else {
            throw TagStoreError.invalidSlug(rawSlug)
        }
        let name = try Self.normalizedName(rawName)
        let desc = Self.cleanedDescription(description)
        try await db.transaction { tx in
            if let existing = try Self.tagRow(on: tx, slug: slug) {
                if let name, name != existing.name {
                    if let other = try Self.tagRow(on: tx, name: name) {
                        throw TagStoreError.nameAlreadyExists(name: name, existingSlug: other.slug)
                    }
                    try tx.run("UPDATE tags SET name = ?, description = ? WHERE slug = ?",
                               [.text(name), desc, .text(slug)])
                } else {
                    try tx.run("UPDATE tags SET description = ? WHERE slug = ?", [desc, .text(slug)])
                }
            } else {
                guard let name else { throw TagStoreError.unknownTagRequiresChineseName(slug) }
                if let other = try Self.tagRow(on: tx, name: name) {
                    throw TagStoreError.nameAlreadyExists(name: name, existingSlug: other.slug)
                }
                try tx.run(
                    "INSERT INTO tags (slug, name, description, created_at) VALUES (?, ?, ?, ?)",
                    [.text(slug), .text(name), desc, .int(Int(Date.now.timeIntervalSince1970))]
                )
            }
        }
        return try await fetchTag(slug: slug)
    }

    /// 重命名英文 slug，可选顺带更新中文名。历史关联跟着走，因为只改 tags 行。
    /// 目标 slug/中文名若被其他标签占用则报错。
    public func rename(from source: String, to target: String, chineseName: String? = nil) async throws {
        guard let from = TagNormalizer.normalize(source) else {
            throw TagStoreError.invalidSlug(source)
        }
        guard let to = TagNormalizer.normalize(target) else {
            throw TagStoreError.invalidSlug(target)
        }
        let name = try Self.normalizedName(chineseName)
        try await db.transaction { tx in
            guard let existing = try Self.tagRow(on: tx, slug: from) else {
                throw TagStoreError.tagNotFound(from)
            }
            if from != to, let taken = try Self.tagRow(on: tx, slug: to) {
                throw TagStoreError.slugAlreadyExists(slug: to, existingName: taken.name)
            }
            if let name, name != existing.name,
               let other = try Self.tagRow(on: tx, name: name) {
                throw TagStoreError.nameAlreadyExists(name: name, existingSlug: other.slug)
            }
            if from == to, name == nil || name == existing.name { return }
            try tx.run("UPDATE tags SET slug = ?, name = ? WHERE slug = ?",
                       [.text(to), .text(name ?? existing.name), .text(from)])
        }
    }

    /// 把 source 合并进 target：贴文关联取并集后删除 source。
    public func merge(source: String, into target: String) async throws {
        let from = TagNormalizer.normalize(source) ?? source
        let to = TagNormalizer.normalize(target) ?? target
        guard from != to else { return }
        let existing = try await existingSlugs([from, to])
        guard existing.contains(from) else { throw TagStoreError.tagNotFound(from) }
        guard existing.contains(to) else { throw TagStoreError.tagNotFound(to) }
        // 关联迁移和删除 source 必须一起成功：中间失败会把贴文标签留在半迁移状态。
        try await db.transaction { tx in
            try tx.run("""
                INSERT OR IGNORE INTO post_tags (post_id, tag_id)
                SELECT pt.post_id, (SELECT id FROM tags WHERE slug = ?)
                FROM post_tags pt JOIN tags t ON t.id = pt.tag_id
                WHERE t.slug = ?
                """, [.text(to), .text(from)])
            try tx.run("DELETE FROM tags WHERE slug = ?", [.text(from)])
        }
    }

    /// 删除标签：post_tags 里的关联靠外键级联一起清掉，贴文本身不受影响。
    public func delete(slug: String) async throws {
        let slug = TagNormalizer.normalize(slug) ?? slug
        guard try await existingSlugs([slug]).contains(slug) else {
            throw TagStoreError.tagNotFound(slug)
        }
        try await db.run("DELETE FROM tags WHERE slug = ?", [.text(slug)])
    }

    private func existingSlugs(_ slugs: [String]) async throws -> Set<String> {
        let placeholders = Array(repeating: "?", count: slugs.count).joined(separator: ",")
        let rows = try await db.query(
            "SELECT slug FROM tags WHERE slug IN (\(placeholders))",
            slugs.map { .text($0) }
        )
        return Set(rows.compactMap { $0["slug"]?.string })
    }

    /// 读回单个标签（含关联计数）；刚写完的标签必须存在。
    private func fetchTag(slug: String) async throws -> Tag {
        let rows = try await db.query("""
            SELECT t.slug AS slug, t.name AS name, t.description AS description,
                   COUNT(pt.post_id) AS count
            FROM tags t
            LEFT JOIN post_tags pt ON pt.tag_id = t.id
            WHERE t.slug = ?
            GROUP BY t.id
            """, [.text(slug)])
        guard let row = rows.first else {
            throw DatabaseError.stepFailed("标签写入后读回失败: \(slug)")
        }
        return Self.makeTag(row)
    }

    private static func tagRow(on tx: Transaction, slug: String) throws -> TagRow? {
        let rows = try tx.query("SELECT slug, name, description FROM tags WHERE slug = ?", [.text(slug)])
        return rows.first.map { TagRow(slug: $0["slug"]?.string ?? "",
                                       name: $0["name"]?.string ?? "",
                                       description: $0["description"]?.string) }
    }

    private static func tagRow(on tx: Transaction, name: String) throws -> TagRow? {
        let rows = try tx.query("SELECT slug, name, description FROM tags WHERE name = ?", [.text(name)])
        return rows.first.map { TagRow(slug: $0["slug"]?.string ?? "",
                                       name: $0["name"]?.string ?? "",
                                       description: $0["description"]?.string) }
    }

    private static func normalizedName(_ rawName: String?) throws -> String? {
        try rawName.map { raw in
            guard let name = TagNormalizer.normalizeChineseName(raw) else {
                throw TagStoreError.invalidChineseName(raw)
            }
            return name
        }
    }

    private static func cleanedDescription(_ description: String?) -> SQLValue {
        let clean = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? .null : .text(clean)
    }

    private static func makeTag(_ row: [String: SQLValue]) -> Tag {
        Tag(slug: row["slug"]?.string ?? "",
            name: row["name"]?.string ?? "",
            description: row["description"]?.string,
            count: row["count"]?.int ?? 0)
    }
}
