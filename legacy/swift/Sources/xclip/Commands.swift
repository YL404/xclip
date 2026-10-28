import Foundation
import XClipCore

private let databaseOption = Option("db", takesValue: true)

func openDatabase(_ parsed: Parsed) throws -> Database {
    try Database(path: Paths.databasePath(explicit: parsed.value("db")))
}

func mediaRoot(_ parsed: Parsed) -> URL {
    Paths.mediaRoot(explicit: parsed.value("db"))
}

/// 打标参数原样切片：每项是 "slug"（已有标签）或 "slug:中文名"（内联新建），
/// 不做归一化——中文名会被 normalize 滤掉，解析交给 core 的 parseTagInput。
func tagInputs(_ parsed: Parsed, option: String) -> [String] {
    parsed.all(option)
        .flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        .filter { !$0.isEmpty }
}

/// 过滤/移除参数只要英文 slug：剥掉 ":中文名"（半角/全角冒号）再归一化。
func tagSlug(_ raw: String) -> String {
    let head = raw.split(whereSeparator: { $0 == ":" || $0 == "：" }).first.map(String.init) ?? raw
    return TagNormalizer.normalize(head) ?? head
}

/// 列表过滤参数统一成 slug。
func filterTags(_ parsed: Parsed, option: String) -> [String] {
    tagInputs(parsed, option: option).map(tagSlug)
}

/// 标签池速览：`slug(中文名)` 列表，供录入后挑选既有标签。
func tagPoolLine(_ tags: [Tag]) -> String {
    "可选标签: " + tags.map { $0.name.isEmpty ? $0.slug : "\($0.slug)(\($0.name))" }.joined(separator: ", ")
}

/// slug → 中文名映射，供贴文标签回显 `slug(中文名)`。
func tagNames(_ pool: [Tag]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: pool.map { ($0.slug, $0.name) })
}

/// 标签回显：有中文名显示 slug(中文名)，否则只显示 slug。
/// 内联新建标签后能一眼确认中英文名都已生效，省一次 xclip tags | grep。
func displayTags(_ slugs: [String], names: [String: String]) -> String {
    slugs.map { slug in
        names[slug].flatMap { $0.isEmpty ? nil : "\(slug)(\($0))" } ?? slug
    }.joined(separator: ", ")
}

/// 按短编码 / 完整 id / tweet id / X 链接解析贴文，找不到抛带文案的 CLIError。
func resolvePost(_ store: PostStore, _ target: String) async throws -> Post {
    do {
        guard let post = try await store.resolve(target: target) else {
            throw CLIError("找不到贴文: \(target)")
        }
        return post
    } catch let error as CLIError {
        throw error
    } catch {
        throw CLIError(describe(error), code: 64)
    }
}

/// 贴文附件地址：每条媒体的 url + 预览图，去重保序。
/// 作者头像不在内——头像顺带缓存，但不计入给 Agent 看的媒体成败统计。
func postMediaURLs(_ post: Post) -> [String] {
    var urls: [String] = []
    for item in post.media {
        if !item.url.isEmpty, !urls.contains(item.url) { urls.append(item.url) }
        if let thumb = item.thumbnailURL, !thumb.isEmpty, !urls.contains(thumb) { urls.append(thumb) }
    }
    return urls
}

/// 缓存贴文附件；作者头像顺带下载，但返回的统计只含贴文附件。
func warmPostMedia(_ post: Post, in root: URL) async -> (downloaded: Int, failed: Int, total: Int) {
    let cache = MediaCache(root: root)
    let urls = postMediaURLs(post)
    let warm: (downloaded: Int, failed: Int) = urls.isEmpty ? (0, 0) : await cache.warm(urls)
    if let avatar = post.authorAvatar, !avatar.isEmpty {
        _ = await cache.cachedFile(for: avatar)
    }
    return (warm.downloaded, warm.failed, urls.count)
}

/// 「媒体: …」统计行：全部已在本地时显示「已就绪」，否则报新缓存/失败数。
func mediaStatLine(_ result: (downloaded: Int, failed: Int, total: Int)) -> String {
    result.downloaded == 0 && result.failed == 0
        ? "媒体: 已就绪（\(result.total) 项）"
        : "媒体: 新缓存 \(result.downloaded) 项，失败 \(result.failed) 项"
}

/// 正文随行输出：多行时次行起缩进 4 空格，与「正文: 」首行对齐。
func printPostText(_ post: Post) {
    guard !post.text.isEmpty else { return }
    var first = true
    for line in post.text.split(separator: "\n", omittingEmptySubsequences: false) {
        print(first ? "  正文: \(line)" : "    \(line)")
        first = false
    }
}

/// 逐项打印媒体本地路径（与 show 一致）：类型 · 尺寸，本地路径，视频附预览图路径。
func printLocalMedia(_ post: Post, in root: URL) {
    for (index, item) in post.media.enumerated() {
        var head = "    \(index + 1). \(item.type)"
        if let width = item.width, let height = item.height { head += " · \(width)×\(height)" }
        print(head)
        let local = MediaCache.localFileIfPresent(in: root, for: item.url)
        print("      本地路径: \(local?.path ?? "（未缓存）")")
        if let preview = Output.previewURL(for: item), preview != item.url {
            let previewLocal = MediaCache.localFileIfPresent(in: root, for: preview)
            print("      预览图:   \(previewLocal?.path ?? "（未缓存）")")
        }
    }
}

// MARK: - add

struct AddCommand {
    static let help = """
    xclip add — 录入一条 X 贴文：抓取快照，图片/视频缓存到本地

    用法:
      xclip add <链接> [选项]

    选项:
      -s, --summary <文本>   内容提炼描述（硬性规范：英文，1-2 句、不换行；
                           建议 200–300 字符、硬性上限 \(SummaryValidator.maxCharacters)，
                           高密度概括可复用要点；不合规会被直接拦截报错）
      -n, --note <文本>      个人备注
      -t, --tag <标签>       归档标签，可多次传参或逗号分隔；
                           传 <新英文slug>:<新中文名> 直接新建并打标
                           （中文名须含中文字符；英文专名附中文类别词，
                           如 spatial-ui:空间交互、app-store:"App Store 设计"）
          --clear-tags       清空该贴文的全部标签
          --no-fetch         只存链接，不抓取快照
          --json             输出 PostDetailDTO（此时媒体已缓存，含 local_path）
          --db <路径>        SQLite 位置，默认 ~/.xclip/xclip.db

    行为:
      fxtwitter 抓快照 → 写入 SQLite → 图片/视频/头像缓存到 media/ 目录。
      重复录入防护：同一贴文已在库中会被直接拦截并提示已有编码，
      修改统一走 xclip update <编码>。
      抓取失败也保存链接（fetch_status=failed），之后可 --refetch 补抓。

    示例:
      xclip add https://x.com/user/status/123 -t ui-design
      xclip add <链接> -s "Grid system primer: 12-col baseline layout for dense dashboards." -t typography,grid
      xclip add <链接> --no-fetch -n "回头再抓"
    """

    static let options = [
        databaseOption,
        Option("summary", short: "s", takesValue: true),
        Option("note", short: "n", takesValue: true),
        Option("tag", short: "t", takesValue: true),
        Option("clear-tags"),
        Option("no-fetch"),
        Option("json")
    ]

    static func run(_ arguments: [String]) async throws {
        let parsed = try parse(arguments, options: options)
        guard let url = parsed.positionals.first, parsed.positionals.count == 1 else {
            throw CLIError("需要且仅接受一个链接\n用法: xclip add <链接> [选项]，详见 xclip help add", code: 64)
        }
        // 提炼校验先行：不合规的 summary 在发起任何网络请求前就报错
        if let summary = parsed.value("summary"), !summary.isEmpty {
            _ = try SummaryValidator.validate(summary)
        }

        let ref: PostRef
        do {
            ref = try XURL.canonicalPostURL(url)
        } catch {
            throw CLIError("无法解析链接: \(url)（\(describe(error))）", code: 64)
        }

        let db = try openDatabase(parsed)
        let store = PostStore(db)
        // 重复录入防护：同一贴文已在库中就直接拦截，不抓、不写
        if let existing = try await store.post(externalID: ref.id) {
            throw CLIError("该贴文已在库中（编码: \(existing.shortID)），不再重复录入；如需修改请运行 xclip update \(existing.shortID)", code: 1)
        }

        var draft = PostDraft(
            externalID: ref.id,
            url: ref.url,
            authorHandle: ref.screenName,
            summary: parsed.value("summary") ?? "",
            note: parsed.value("note") ?? "",
            fetchStatus: "failed"
        )

        let headline: String
        if parsed.has("no-fetch") {
            headline = "已保存链接（未抓取）"
        } else {
            do {
                let fetched = try await Fetcher().fetch(ref: ref)
                draft.url = fetched.url
                draft.authorHandle = fetched.authorHandle
                draft.authorName = fetched.authorName
                draft.authorAvatar = fetched.authorAvatar
                draft.text = fetched.text
                draft.media = fetched.media
                draft.metrics = fetched.metrics
                draft.postedAt = fetched.postedAt
                draft.fetchStatus = "ok"
                headline = "已保存并抓取内容"
            } catch {
                headline = "已保存链接（抓取失败: \(describe(error))）"
            }
        }

        draft.tags = tagInputs(parsed, option: "tag")
        // 不传 --tag 时不动已有标签；要清空必须显式 --clear-tags。
        draft.clearTags = parsed.has("clear-tags")

        let post = try await store.insert(draft)

        // 录入阶段就把贴文附件落到本地（头像顺带缓存但不计入统计），
        // 快照在保存那一刻就是完整的
        let root = mediaRoot(parsed)
        let mediaResult = await warmPostMedia(post, in: root)

        let pool = try await TagStore(db).all()
        if parsed.has("json") {
            let dtos = pool.map { TagDTO(slug: $0.slug, name: $0.name, description: $0.description, count: $0.count) }
            print(try Output.json(PostDetailDTO(post: PostDTO(post: post, mediaRoot: root), availableTags: dtos)))
            return
        }

        print(headline)
        print("  编码: \(post.shortID)  (id: \(post.id))")
        if !post.tags.isEmpty {
            print("  标签: \(displayTags(post.tags, names: tagNames(pool)))")
        }
        if !post.summary.isEmpty {
            print("  提炼: \(post.summary)")
        }
        printPostText(post)
        if mediaResult.total > 0 {
            print("  \(mediaStatLine(mediaResult))")
            printLocalMedia(post, in: root)
        }
        // 录入时就让 Agent 直接看到标签池：打标优先复用，不满足再内联新建
        if !pool.isEmpty {
            print("  \(tagPoolLine(pool))（不满足可用 -t <新英文slug>:<新中文名> 新建，中文名须含中文字符）")
        }
        if post.summary.isEmpty {
            print("  提示: 阅读正文与本地媒体后，运行 xclip update \(post.shortID) --summary \"English takeaway...\" --tag <标签> 完成归档")
        }
    }
}

// MARK: - update

struct UpdateCommand {
    static let help = """
    xclip update — 修改已录入贴文的提炼、备注、标签（别名: edit）

    用法:
      xclip update <条目> <修改选项...>

    条目寻址:
      8 位短编码（e895bf71，可带 #）、完整 id、纯数字 tweet id、X 链接。

    修改选项（至少一项，或与 --refetch 组合）:
      -s, --summary <文本>   设置内容提炼描述（英文，1-2 句、不换行；
                           建议 200–300 字符、硬性上限 \(SummaryValidator.maxCharacters)）
          --clear-summary    清空内容提炼描述
      -n, --note <文本>      设置个人备注
          --clear-note       清空个人备注
      -t, --tag <标签>       整体替换标签（逗号分隔或多次传参；
                           <新英文slug>:<新中文名> 直接新建，中文名须含中文字符）
          --add-tag <标签>   追加标签（逗号分隔或多次传参；
                           <新英文slug>:<新中文名> 直接新建，中文名须含中文字符）
          --remove-tag <标签> 移除指定标签（按英文 slug，逗号分隔或多次传参）
          --clear-tags       清空全部标签
          --refetch          重新抓取快照并补齐媒体缓存，提炼/备注/标签保留
          --json             输出 PostDetailDTO
          --db <路径>        SQLite 位置

    说明:
      --tag 是整体替换，与 --add-tag/--remove-tag/--clear-tags 互斥。
      元数据修改不动快照与 saved_at；要刷新正文/媒体/指标用 --refetch。

    示例:
      xclip update e895bf71 -s "Liquid Glass adaptation notes: layered materials + edge tints." -t ui-design
      xclip update e895bf71 --add-tag typography --remove-tag draft
      xclip update e895bf71 --clear-note
      xclip edit e895bf71 --refetch          # 原快照抓取失败时补抓
    """

    static let options = [
        databaseOption,
        Option("summary", short: "s", takesValue: true),
        Option("clear-summary"),
        Option("note", short: "n", takesValue: true),
        Option("clear-note"),
        Option("tag", short: "t", takesValue: true),
        Option("add-tag", takesValue: true),
        Option("remove-tag", takesValue: true),
        Option("clear-tags"),
        Option("refetch"),
        Option("json")
    ]

    static func run(_ arguments: [String]) async throws {
        let parsed = try parse(arguments, options: options)
        guard let target = parsed.positionals.first, parsed.positionals.count == 1 else {
            throw CLIError("需要且仅接受一个目标\n用法: xclip update <条目> <修改选项...>，详见 xclip help update", code: 64)
        }
        if parsed.has("summary") && parsed.has("clear-summary") {
            throw CLIError("--summary 与 --clear-summary 互斥", code: 64)
        }
        // 提炼校验先行：不合规的 summary 直接拦截
        if let summary = parsed.value("summary"), !summary.isEmpty {
            _ = try SummaryValidator.validate(summary)
        }
        if parsed.has("note") && parsed.has("clear-note") {
            throw CLIError("--note 与 --clear-note 互斥", code: 64)
        }
        if parsed.has("tag") && (parsed.has("add-tag") || parsed.has("remove-tag") || parsed.has("clear-tags")) {
            throw CLIError("--tag 是整体替换，不能与 --add-tag/--remove-tag/--clear-tags 同时使用", code: 64)
        }

        let modifies = ["summary", "clear-summary", "note", "clear-note",
                        "tag", "add-tag", "remove-tag", "clear-tags"].contains { parsed.has($0) }
        guard modifies || parsed.has("refetch") else {
            throw CLIError("没有要修改的内容\n用法: xclip update <条目> [-s 提炼] [-n 备注] [-t/--add-tag/--remove-tag 标签] [--refetch]，详见 xclip help update", code: 64)
        }

        let db = try openDatabase(parsed)
        let store = PostStore(db)
        var post = try await resolvePost(store, target)
        let root = mediaRoot(parsed)

        var refetchReport: String? = nil
        if parsed.has("refetch") {
            do {
                let ref = try XURL.canonicalPostURL(post.url)
                let fetched = try await Fetcher().fetch(ref: ref)
                // 快照刷新但元数据原样带回：refetch 绝不能弄丢用户写的提炼/备注
                let draft = PostDraft(
                    externalID: ref.id,
                    url: fetched.url,
                    authorHandle: fetched.authorHandle,
                    authorName: fetched.authorName,
                    authorAvatar: fetched.authorAvatar,
                    text: fetched.text,
                    media: fetched.media,
                    metrics: fetched.metrics,
                    summary: post.summary,
                    note: post.note,
                    fetchStatus: "ok",
                    postedAt: fetched.postedAt
                )
                post = try await store.upsert(draft)
                let mediaResult = await warmPostMedia(post, in: root)
                if mediaResult.total == 0 {
                    refetchReport = "已重新抓取快照"
                } else {
                    refetchReport = "已重新抓取快照；\(mediaStatLine(mediaResult))"
                }
            } catch {
                refetchReport = "重新抓取失败: \(describe(error))（已保留旧快照）"
            }
        }

        if modifies {
            let patch = PostPatch(
                summary: parsed.has("clear-summary") ? "" : parsed.value("summary"),
                note: parsed.has("clear-note") ? "" : parsed.value("note"),
                replaceTags: parsed.has("tag") ? tagInputs(parsed, option: "tag") : nil,
                addTags: tagInputs(parsed, option: "add-tag"),
                removeTags: tagInputs(parsed, option: "remove-tag").map(tagSlug),
                clearTags: parsed.has("clear-tags")
            )
            post = try await store.patch(postID: post.id, patch)
        }

        if parsed.has("json") {
            let pool = try await TagStore(db).all()
            let dtos = pool.map { TagDTO(slug: $0.slug, name: $0.name, description: $0.description, count: $0.count) }
            print(try Output.json(PostDetailDTO(post: PostDTO(post: post, mediaRoot: root), availableTags: dtos)))
            return
        }

        let pool = try await TagStore(db).all()
        print("已更新: \(post.shortID)")
        if let refetchReport {
            print("  \(refetchReport)")
        }
        print("  提炼: \(post.summary.isEmpty ? "（未填写）" : post.summary)")
        if !post.note.isEmpty {
            print("  备注: \(post.note)")
        }
        print("  标签: \(post.tags.isEmpty ? "（无）" : displayTags(post.tags, names: tagNames(pool)))")
        // --refetch 后直接给出正文、本地媒体路径与标签池，省一次 show/tags 往返
        if parsed.has("refetch") {
            printPostText(post)
            if !post.media.isEmpty {
                print("  媒体文件:")
                printLocalMedia(post, in: root)
            }
            if !pool.isEmpty {
                print("  \(tagPoolLine(pool))（不满足可用 --add-tag <新英文slug>:<新中文名> 新建，中文名须含中文字符）")
            }
        }
    }
}

// MARK: - list / search / index

struct ListCommand {
    static let help = """
    xclip list — 内容索引：按标签/关键词检索，输出 [短编码] + 提炼描述（别名: search、index）

    用法:
      xclip list [选项] [关键词...]
      xclip search 网格系统              # 位置参数自动拼成搜索词，与 --query 等价

    选项:
      -t, --tag <标签>       按标签过滤，多个为 AND；可多次传参或逗号分隔
      -q, --query <词>       全文搜索（正文、作者、备注、提炼）
          --sort <方式>      latest（默认，按保存时间）| bookmarks | likes
      -n, --limit <数量>     条数上限，默认 200
          --json             输出 PostListDTO（每项只含 short_id、tags、summary）
          --db <路径>        SQLite 位置

    输出:
      本地化纯净索引，只含本地可消费内容——第一行 [e895bf71] 标签列表，
      第二行完整英文提炼描述（不截断）；未打标显示 [untagged]，
      无提炼显示 [pending summary]。命中后用 xclip show <编码> 看正文与本地媒体。

    示例:
      xclip list --tag ui-design
      xclip list -t product-design --sort bookmarks -n 10
      xclip search 网格系统
      xclip index 留白 --json
    """

    static let options = [
        databaseOption,
        Option("tag", short: "t", takesValue: true),
        Option("query", short: "q", takesValue: true),
        Option("sort", short: "s", takesValue: true),
        Option("limit", short: "n", takesValue: true),
        Option("json")
    ]

    static func run(_ arguments: [String]) async throws {
        let parsed = try parse(arguments, options: options)

        let limit: Int
        if let raw = parsed.value("limit") {
            guard let value = Int(raw), value >= 1 else {
                throw CLIError("--limit 需要正整数: \(raw)", code: 64)
            }
            limit = value
        } else {
            limit = 200
        }

        let sortRaw = parsed.value("sort") ?? "latest"
        guard let sort = PostSort(rawValue: sortRaw) else {
            throw CLIError("--sort 仅支持 latest、bookmarks、likes: \(sortRaw)", code: 64)
        }

        // 位置参数拼成搜索词：`xclip search 网格系统` 即查
        var query = parsed.value("query")
        if query == nil, !parsed.positionals.isEmpty {
            query = parsed.positionals.joined(separator: " ")
        }

        let filter = ListFilter(tags: filterTags(parsed, option: "tag"), query: query, sort: sort, limit: limit)
        let posts = try await PostStore(try openDatabase(parsed)).list(filter)

        if parsed.has("json") {
            print(try Output.json(PostListDTO(posts: posts.map {
                PostIndexDTO(shortId: $0.shortID, tags: $0.tags, summary: $0.summary)
            })))
            return
        }
        for (index, post) in posts.enumerated() {
            print(Output.listLine(post, index: index + 1))
        }
        if posts.isEmpty {
            print("（没有匹配的贴文）")
        } else if posts.count >= limit {
            print("共 \(posts.count) 条（已达上限，可用 -n <数量> 查看更多） · 查看完整正文与本地媒体: xclip show <编码>")
        } else {
            print("共 \(posts.count) 条 · 查看完整正文与本地媒体: xclip show <编码>")
        }
    }
}

// MARK: - show

struct ShowCommand {
    static let help = """
    xclip show — 查看完整正文与本地媒体文件路径

    用法:
      xclip show <条目> [--json] [--db 路径]

    条目寻址:
      8 位短编码（e895bf71，可带 #）、完整 id、纯数字 tweet id、X 链接。

    输出:
      只含本地可消费内容：编码、标签、内容提炼、备注、完整正文，
      以及每项媒体的类型、尺寸、本地路径（未缓存会注明）与视频预览图路径。
      不含作者、指标、原帖链接等上游噪音；抓取成功的贴文若媒体缺缓存，
      输出前自动静默补齐——local_path 拿来就能读图。

    示例:
      xclip show e895bf71
      xclip show '#e895bf71' --json
      xclip show https://x.com/user/status/123
    """

    static let options = [
        databaseOption,
        Option("json")
    ]

    static func run(_ arguments: [String]) async throws {
        let parsed = try parse(arguments, options: options)
        guard let target = parsed.positionals.first, parsed.positionals.count == 1 else {
            throw CLIError("需要且仅接受一个目标\n用法: xclip show <条目> [--json]，详见 xclip help show", code: 64)
        }
        let db = try openDatabase(parsed)
        let store = PostStore(db)
        let post = try await resolvePost(store, target)
        let root = mediaRoot(parsed)

        // 抓取成功的贴文补齐缺失的媒体缓存，保证输出的 local_path 可读
        if post.fetchStatus == "ok" {
            let missing = MediaCache.collectibleURLs(for: post)
                .filter { MediaCache.localFileIfPresent(in: root, for: $0) == nil }
            if !missing.isEmpty {
                _ = await MediaCache(root: root).warm(missing)
            }
        }

        let pool = try await TagStore(db).all()
        if parsed.has("json") {
            let dtos = pool.map { TagDTO(slug: $0.slug, name: $0.name, description: $0.description, count: $0.count) }
            print(try Output.json(PostDetailDTO(post: PostDTO(post: post, mediaRoot: root), availableTags: dtos)))
        } else {
            print(Output.detail(post, mediaRoot: root, tagNames: tagNames(pool)))
        }
    }
}

// MARK: - tags

struct TagsCommand {
    static let help = """
    xclip tags — 列出受控标签池

    用法:
      xclip tags [--json] [--db 路径]

    输出:
      每行 slug (引用数) 说明；--json 输出 TagListDTO。
      检索前先看它：优先复用已有标签归档，保持词表收敛。

    词表维护（set/rename/merge/delete）见 xclip help tag。
    """

    static let options = [
        databaseOption,
        Option("json")
    ]

    static func run(_ arguments: [String]) async throws {
        let parsed = try parse(arguments, options: options)
        let tags = try await TagStore(try openDatabase(parsed)).all()

        if parsed.has("json") {
            let dtos = tags.map { TagDTO(slug: $0.slug, name: $0.name, description: $0.description, count: $0.count) }
            print(try Output.json(TagListDTO(tags: dtos)))
            return
        }
        if tags.isEmpty {
            print("（没有标签）")
            return
        }
        for tag in tags {
            var line = tag.slug
            if !tag.name.isEmpty { line += "  \(tag.name)" }
            line += " (\(tag.count))"
            if let description = tag.description, !description.isEmpty {
                line += "  \(description)"
            }
            print(line)
        }
    }
}

// MARK: - tag create / set / rename / merge / delete

struct TagCommand {
    static let help = """
    xclip tag — 维护标签词表（中英文标签双向唯一）

    用法:
      xclip tag create <英文slug> <中文名> [--desc 说明]   新建标签
      xclip tag set <slug> [中文名] [说明]                  修改已有标签的中文名/说明
      xclip tag set <slug> [--name 中文名] [--desc 说明]    同上，显式选项写法
      xclip tag rename <旧slug> <新slug> [--name 新中文名]  重命名，历史关联跟着改
      xclip tag merge <源slug> <目标slug>                  合并：关联取并集后删除源标签
      xclip tag delete <slug>                              删除标签及其全部关联

    通用: 各子命令均支持 --json 与 --db。

    标签是「英文 slug + 中文名」对，slug 归一化为小写连字符
    （Product Design → product-design），中英文都唯一。
    description 是词表的纪律工具：一行说明写清这个标签收什么。

    打标时也可以内联新建：xclip add/update 的 -t/--tag/--add-tag 直接传
    <新英文slug>:<新中文名>（如 -t spatial-ui:空间交互），自动建标签并挂上。
    中文名须含中文字符——英文专名附中文类别词（如 app-store:"App Store 设计"），
    不能传纯英文。

    示例:
      xclip tag create spatial-ui 空间交互 --desc "空间计算与三维界面"
      xclip tag set spatial-ui 空间界面 --desc "空间 UI 相关"
      xclip tag rename ui-design ui --name 界面设计
      xclip tag merge ux ux-design
      xclip tag delete draft
    """

    private static let jsonOption = Option("json")
    private static let nameOption = Option("name", takesValue: true)
    private static let descOption = Option("desc", short: "d", takesValue: true)

    /// 统一的结果出口：非 JSON 打一句话，JSON 打结构化结果。
    private static func emit(action: String, message: String, tag: TagDTO?, json: Bool) throws {
        if json {
            print(try Output.json(TagResultDTO(action: action, message: message, tag: tag)))
        } else {
            print(message)
        }
    }

    private static func dto(_ tag: Tag) -> TagDTO {
        TagDTO(slug: tag.slug, name: tag.name, description: tag.description, count: tag.count)
    }

    static func run(_ arguments: [String]) async throws {
        let (rest, database) = try stripLeadingDatabaseOption(arguments)
        guard let subcommand = rest.first else {
            throw CLIError("用法: xclip tag <create|set|rename|merge|delete> ...，详见 xclip help tag", code: 64)
        }
        if subcommand == "-h" || subcommand == "--help" {
            throw ParseError.helpRequested
        }
        let subArguments = database + Array(rest.dropFirst())

        switch subcommand {
        case "create":
            let parsed = try parse(subArguments, options: [databaseOption, descOption, jsonOption])
            guard parsed.positionals.count == 2 else {
                throw CLIError("用法: xclip tag create <英文slug> <中文名> [--desc 说明]", code: 64)
            }
            let tag = try await TagStore(try openDatabase(parsed)).create(
                slug: parsed.positionals[0], name: parsed.positionals[1],
                description: parsed.value("desc"))
            try emit(action: "created", message: "已创建标签: \(tag.slug)（\(tag.name)）",
                     tag: dto(tag), json: parsed.has("json"))

        case "set":
            let parsed = try parse(subArguments, options: [databaseOption, nameOption, descOption, jsonOption])
            guard let slug = parsed.positionals.first else {
                throw CLIError("用法: xclip tag set <slug> [中文名] [说明] [--name] [--desc]", code: 64)
            }
            let store = TagStore(try openDatabase(parsed))
            let name = parsed.value("name")
                ?? (parsed.positionals.count > 1 ? parsed.positionals[1] : nil)
            // 未显式给说明时保留原说明，避免「只改中文名」顺手把说明清掉
            var description = parsed.value("desc")
            if description == nil, parsed.positionals.count > 2 {
                description = parsed.positionals.dropFirst(2).joined(separator: " ")
            }
            if description == nil {
                let normalized = TagNormalizer.normalize(slug) ?? slug
                description = try await store.all().first(where: { $0.slug == normalized })?.description
            }
            let tag = try await store.setDescription(slug: slug, name: name, description: description)
            try emit(action: "set", message: "已保存标签: \(tag.slug)（\(tag.name)）\(tag.description.map { "  \($0)" } ?? "")",
                     tag: dto(tag), json: parsed.has("json"))

        case "rename":
            let parsed = try parse(subArguments, options: [databaseOption, nameOption, jsonOption])
            guard parsed.positionals.count == 2 else {
                throw CLIError("用法: xclip tag rename <旧slug> <新slug> [--name 新中文名]", code: 64)
            }
            let (from, to) = (parsed.positionals[0], parsed.positionals[1])
            try await TagStore(try openDatabase(parsed)).rename(from: from, to: to, chineseName: parsed.value("name"))
            try emit(action: "renamed", message: "已重命名: \(from) → \(to)", tag: nil, json: parsed.has("json"))

        case "merge":
            let parsed = try parse(subArguments, options: [databaseOption, jsonOption])
            guard parsed.positionals.count == 2 else {
                throw CLIError("用法: xclip tag merge <源slug> <目标slug>", code: 64)
            }
            let (from, to) = (parsed.positionals[0], parsed.positionals[1])
            try await TagStore(try openDatabase(parsed)).merge(source: from, into: to)
            try emit(action: "merged", message: "已合并: \(from) → \(to)", tag: nil, json: parsed.has("json"))

        case "delete":
            let parsed = try parse(subArguments, options: [databaseOption, jsonOption])
            guard let rawSlug = parsed.positionals.first, parsed.positionals.count == 1 else {
                throw CLIError("用法: xclip tag delete <slug>", code: 64)
            }
            let slug = TagNormalizer.normalize(rawSlug) ?? rawSlug
            try await TagStore(try openDatabase(parsed)).delete(slug: slug)
            try emit(action: "deleted", message: "已删除标签: \(slug)", tag: nil, json: parsed.has("json"))

        default:
            throw CLIError("未知子命令: tag \(subcommand)\n详见 xclip help tag", code: 64)
        }
    }
}

// MARK: - warm

struct WarmCommand {
    static let help = """
    xclip warm — 预取全库媒体到本地缓存

    用法:
      xclip warm [--json] [--db 路径]

    幂等：已缓存的跳过。媒体缓存与数据库同级（默认 ~/.xclip/media/）。
    """

    static let options = [
        databaseOption,
        Option("json")
    ]

    static func run(_ arguments: [String]) async throws {
        let parsed = try parse(arguments, options: options)
        let store = PostStore(try openDatabase(parsed))
        let urls = try await store.allMediaURLs()
        let cache = MediaCache(root: mediaRoot(parsed))
        let result = await cache.warm(urls)
        // 去重后再算「已有」：库里同一地址可能出现多次，直接用 urls.count 会偏大
        let unique = Set(urls).count
        let alreadyCached = unique - result.downloaded - result.failed
        if parsed.has("json") {
            print(try Output.json(WarmResultDTO(
                total: unique, downloaded: result.downloaded,
                failed: result.failed, alreadyCached: alreadyCached)))
            return
        }
        print("共 \(unique) 个媒体地址（去重后）：新缓存 \(result.downloaded) 个，失败 \(result.failed) 个，已有 \(alreadyCached) 个")
    }
}

// MARK: - delete / rm

struct DeleteCommand {
    static let help = """
    xclip delete — 删除一条贴文（别名: rm）

    用法:
      xclip delete <条目> [--json] [--db 路径]

    条目寻址:
      8 位短编码（e895bf71，可带 #）、完整 id、纯数字 tweet id、X 链接。

    只删数据库记录与标签关联；media/ 里的已缓存文件保留（内容寻址，可复用）。
    """

    static let options = [
        databaseOption,
        Option("json")
    ]

    static func run(_ arguments: [String]) async throws {
        let parsed = try parse(arguments, options: options)
        guard let target = parsed.positionals.first, parsed.positionals.count == 1 else {
            throw CLIError("需要且仅接受一个目标\n用法: xclip delete <条目> [--json]，详见 xclip help delete", code: 64)
        }
        let store = PostStore(try openDatabase(parsed))
        let post = try await resolvePost(store, target)
        try await store.delete(id: post.id)
        if parsed.has("json") {
            print(try Output.json(DeleteResultDTO(deleted: post.id, shortId: post.shortID, url: post.url)))
        } else {
            print("已删除: \(post.shortID)  \(post.url)")
        }
    }
}
