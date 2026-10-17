import Foundation

enum Schema {
    /// v1 结构。`user_version` 到 1 后不再执行，新增字段走后续版本的增量迁移。
    static let v1 = """
        CREATE TABLE IF NOT EXISTS posts (
            id            TEXT PRIMARY KEY NOT NULL,
            platform      TEXT NOT NULL,
            external_id   TEXT NOT NULL,
            url           TEXT NOT NULL,
            author_handle TEXT NOT NULL,
            author_name   TEXT NOT NULL DEFAULT '',
            author_avatar TEXT,
            text          TEXT NOT NULL DEFAULT '',
            media         TEXT NOT NULL DEFAULT '[]',
            metrics       TEXT NOT NULL DEFAULT '{}',
            note          TEXT NOT NULL DEFAULT '',
            fetch_status  TEXT NOT NULL DEFAULT 'ok',
            posted_at     INTEGER,
            saved_at      INTEGER NOT NULL,
            UNIQUE (platform, external_id)
        );
        CREATE INDEX IF NOT EXISTS posts_saved_at_idx ON posts (saved_at DESC);

        CREATE VIRTUAL TABLE IF NOT EXISTS posts_fts USING fts5(
            text,
            author_handle,
            author_name,
            note,
            content = 'posts',
            content_rowid = 'rowid'
        );
        CREATE TRIGGER IF NOT EXISTS posts_fts_ai AFTER INSERT ON posts BEGIN
            INSERT INTO posts_fts(rowid, text, author_handle, author_name, note)
            VALUES (new.rowid, new.text, new.author_handle, new.author_name, new.note);
        END;
        CREATE TRIGGER IF NOT EXISTS posts_fts_ad AFTER DELETE ON posts BEGIN
            INSERT INTO posts_fts(posts_fts, rowid, text, author_handle, author_name, note)
            VALUES ('delete', old.rowid, old.text, old.author_handle, old.author_name, old.note);
        END;
        CREATE TRIGGER IF NOT EXISTS posts_fts_au AFTER UPDATE OF text, author_handle, author_name, note ON posts BEGIN
            INSERT INTO posts_fts(posts_fts, rowid, text, author_handle, author_name, note)
            VALUES ('delete', old.rowid, old.text, old.author_handle, old.author_name, old.note);
            INSERT INTO posts_fts(rowid, text, author_handle, author_name, note)
            VALUES (new.rowid, new.text, new.author_handle, new.author_name, new.note);
        END;

        CREATE TABLE IF NOT EXISTS tags (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            slug        TEXT NOT NULL UNIQUE,
            name        TEXT NOT NULL UNIQUE,
            description TEXT,
            created_at  INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS post_tags (
            post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
            tag_id  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (post_id, tag_id)
        );
        CREATE INDEX IF NOT EXISTS post_tags_tag_idx ON post_tags (tag_id);

        INSERT OR IGNORE INTO tags (slug, name, description, created_at) VALUES
            ('product-design',      '产品设计',   '产品定位与功能决策',       strftime('%s','now')),
            ('ui-design',           '界面设计',   '界面视觉与组件样式',       strftime('%s','now')),
            ('ux-design',           '交互设计',   '交互流程与信息架构',       strftime('%s','now')),
            ('design-system',       '设计系统',   '设计系统、token 与组件库', strftime('%s','now')),
            ('typography',          '字体排印',   '字体排印',                 strftime('%s','now')),
            ('color',               '色彩体系',   '色彩',                     strftime('%s','now')),
            ('motion',              '动效转场',   '动效与转场',               strftime('%s','now')),
            ('app-development',     '客户端开发', '客户端 App 开发实践',      strftime('%s','now')),
            ('software-development','软件工程',   '通用软件工程实践',         strftime('%s','now')),
            ('web-development',     '前端开发',   '前端与 Web 技术',          strftime('%s','now')),
            ('dev-tools',           '开发工具',   '开发工具与工作流',         strftime('%s','now')),
            ('ai',                  '人工智能',   'AI 应用与模型能力',        strftime('%s','now')),
            ('essay',               '深度长文',   '观点长文与思考',           strftime('%s','now'));
        """

    /// v2：FTS5 换 trigram 分词器。
    /// 默认 unicode61 分词器把连续 CJK 当成一个 token，中文子串搜索完全失效
    /// （只有输入与原文逐字相同的整段才命中）。trigram 支持中英文子串匹配，
    /// 代价是少于 3 个字符的查询无结果，这一点写进 README 和搜索框提示。
    /// 换分词器必须重建索引，所以走迁移而不是改 v1。
    static let v2 = """
        DROP TRIGGER IF EXISTS posts_fts_ai;
        DROP TRIGGER IF EXISTS posts_fts_ad;
        DROP TRIGGER IF EXISTS posts_fts_au;
        DROP TABLE IF EXISTS posts_fts;
        CREATE VIRTUAL TABLE posts_fts USING fts5(
            text,
            author_handle,
            author_name,
            note,
            content = 'posts',
            content_rowid = 'rowid',
            tokenize = 'trigram'
        );
        CREATE TRIGGER posts_fts_ai AFTER INSERT ON posts BEGIN
            INSERT INTO posts_fts(rowid, text, author_handle, author_name, note)
            VALUES (new.rowid, new.text, new.author_handle, new.author_name, new.note);
        END;
        CREATE TRIGGER posts_fts_ad AFTER DELETE ON posts BEGIN
            INSERT INTO posts_fts(posts_fts, rowid, text, author_handle, author_name, note)
            VALUES ('delete', old.rowid, old.text, old.author_handle, old.author_name, old.note);
        END;
        CREATE TRIGGER posts_fts_au AFTER UPDATE OF text, author_handle, author_name, note ON posts BEGIN
            INSERT INTO posts_fts(posts_fts, rowid, text, author_handle, author_name, note)
            VALUES ('delete', old.rowid, old.text, old.author_handle, old.author_name, old.note);
            INSERT INTO posts_fts(rowid, text, author_handle, author_name, note)
            VALUES (new.rowid, new.text, new.author_handle, new.author_name, new.note);
        END;
        INSERT INTO posts_fts(posts_fts) VALUES ('rebuild');
        """

    /// v3：新增 `summary` 内容提炼列，FTS 索引带上它。
    /// 旧数据里非空的 note 回填到 summary：v1/v2 时代 note 同时承担「个人备注」和
    /// 「内容提炼」两个角色，升级后提炼优先放 summary，note 保留原文不动。
    /// 虚拟表加列等于重建（外部内容表按列名回读 posts），触发器同步换列清单。
    static let v3 = """
        ALTER TABLE posts ADD COLUMN summary TEXT NOT NULL DEFAULT '';
        UPDATE posts SET summary = note WHERE summary = '' AND note <> '';
        DROP TRIGGER IF EXISTS posts_fts_ai;
        DROP TRIGGER IF EXISTS posts_fts_ad;
        DROP TRIGGER IF EXISTS posts_fts_au;
        DROP TABLE IF EXISTS posts_fts;
        CREATE VIRTUAL TABLE posts_fts USING fts5(
            text,
            author_handle,
            author_name,
            summary,
            note,
            content = 'posts',
            content_rowid = 'rowid',
            tokenize = 'trigram'
        );
        CREATE TRIGGER posts_fts_ai AFTER INSERT ON posts BEGIN
            INSERT INTO posts_fts(rowid, text, author_handle, author_name, summary, note)
            VALUES (new.rowid, new.text, new.author_handle, new.author_name, new.summary, new.note);
        END;
        CREATE TRIGGER posts_fts_ad AFTER DELETE ON posts BEGIN
            INSERT INTO posts_fts(posts_fts, rowid, text, author_handle, author_name, summary, note)
            VALUES ('delete', old.rowid, old.text, old.author_handle, old.author_name, old.summary, old.note);
        END;
        CREATE TRIGGER posts_fts_au AFTER UPDATE OF text, author_handle, author_name, summary, note ON posts BEGIN
            INSERT INTO posts_fts(posts_fts, rowid, text, author_handle, author_name, summary, note)
            VALUES ('delete', old.rowid, old.text, old.author_handle, old.author_name, old.summary, old.note);
            INSERT INTO posts_fts(rowid, text, author_handle, author_name, summary, note)
            VALUES (new.rowid, new.text, new.author_handle, new.author_name, new.summary, new.note);
        END;
        INSERT INTO posts_fts(posts_fts) VALUES ('rebuild');
        """

    /// v4：tags 表加中文名 `name`，slug 与 name 双向唯一。
    /// 重建表而不是 ADD COLUMN——ALTER 补不了 UNIQUE/NOT NULL 约束。
    /// 旧库里无中文名的自建标签兜底用「标签-<slug>」占位；种子标签给标准中文名。
    /// DROP TABLE 会触发 post_tags 的外键引用检查，迁移期间先关 foreign_keys。
    /// 整段 DDL 包在事务里：中途被锁打断可整体回滚重跑，不留半成品 tags_new；
    /// `DROP TABLE IF EXISTS` 兜底清理上一轮失败迁移的残留。tag_id 原样搬运，
    /// post_tags 关联不动。
    static let v4 = """
        PRAGMA foreign_keys = OFF;
        BEGIN IMMEDIATE;
        DROP TABLE IF EXISTS tags_new;
        CREATE TABLE tags_new (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            slug        TEXT NOT NULL UNIQUE,
            name        TEXT NOT NULL UNIQUE,
            description TEXT,
            created_at  INTEGER NOT NULL
        );
        INSERT INTO tags_new (id, slug, name, description, created_at)
            SELECT id, slug,
                CASE slug
                    WHEN 'product-design'       THEN '产品设计'
                    WHEN 'ui-design'            THEN '界面设计'
                    WHEN 'ux-design'            THEN '交互设计'
                    WHEN 'design-system'        THEN '设计系统'
                    WHEN 'typography'           THEN '字体排印'
                    WHEN 'color'                THEN '色彩体系'
                    WHEN 'motion'               THEN '动效转场'
                    WHEN 'app-development'      THEN '客户端开发'
                    WHEN 'software-development' THEN '软件工程'
                    WHEN 'web-development'      THEN '前端开发'
                    WHEN 'dev-tools'            THEN '开发工具'
                    WHEN 'ai'                   THEN '人工智能'
                    WHEN 'essay'                THEN '深度长文'
                    ELSE '标签-' || slug
                END,
                description, created_at
            FROM tags;
        DROP TABLE tags;
        ALTER TABLE tags_new RENAME TO tags;
        COMMIT;
        PRAGMA foreign_keys = ON;
        """
}
