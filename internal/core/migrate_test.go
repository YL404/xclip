package core

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/sqlite"
)

func TestMigrateV1PreservesMetadataAndMedia(t *testing.T) {
	root := t.TempDir()
	legacyPath := filepath.Join(root, "xclip.db")
	mediaRoot := filepath.Join(root, "media")
	if err := os.MkdirAll(mediaRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	legacy, err := sqlite.Open(context.Background(), legacyPath, sqlite.OpenOptions{})
	if err != nil {
		t.Fatal(err)
	}
	body := " \t正文\n\n"
	statements := []sqlite.Statement{
		{SQL: `CREATE TABLE posts (id TEXT PRIMARY KEY, platform TEXT NOT NULL, external_id TEXT NOT NULL,
			url TEXT NOT NULL, author_handle TEXT NOT NULL, author_name TEXT NOT NULL DEFAULT '', author_avatar TEXT,
			text TEXT NOT NULL DEFAULT '', media TEXT NOT NULL DEFAULT '[]', metrics TEXT NOT NULL DEFAULT '{}',
			note TEXT NOT NULL DEFAULT '', fetch_status TEXT NOT NULL DEFAULT 'ok', posted_at INTEGER, saved_at INTEGER NOT NULL,
			summary TEXT NOT NULL DEFAULT '', UNIQUE(platform, external_id))`},
		{SQL: `CREATE TABLE tags (id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE, name TEXT NOT NULL UNIQUE, description TEXT)`},
		{SQL: `CREATE TABLE post_tags (post_id TEXT NOT NULL, tag_id INTEGER NOT NULL, PRIMARY KEY(post_id, tag_id))`},
		{SQL: `INSERT INTO tags(id, slug, name, description) VALUES (1, 'ui-design', '界面设计', '界面参考')`},
		{SQL: `INSERT INTO tags(id, slug, name, description) VALUES (2, 'unused', '未使用', '保留标签池')`},
		{SQL: `INSERT INTO posts(id, platform, external_id, url, author_handle, author_name, text, media, summary, note, saved_at)
			VALUES ('2EF4DE2C-D521-4977-81F4-A7F98085FB41', 'x', '123', 'https://x.com/a/status/123', 'a', 'Alice', ?,
			'[{"type":"photo","url":"https://pbs.twimg.com/media/demo.jpg?name=large"}]', 'A short summary.', '备注', 1700000000)`, Args: []any{body}},
		{SQL: `INSERT INTO posts(id, platform, external_id, url, author_handle, saved_at)
			VALUES ('empty', 'x', '124', 'https://x.com/a/status/124', 'a', 1700000001)`},
		{SQL: `INSERT INTO post_tags(post_id, tag_id) VALUES ('2EF4DE2C-D521-4977-81F4-A7F98085FB41', 1)`},
		{SQL: `PRAGMA user_version = 4`},
	}
	if _, err := legacy.Transaction(context.Background(), statements); err != nil {
		t.Fatal(err)
	}
	legacy.Close()

	remote := "https://pbs.twimg.com/media/demo.jpg?name=large"
	cacheName := legacySHA1(remote)[:16] + ".jpg"
	if err := os.WriteFile(filepath.Join(mediaRoot, cacheName), []byte("jpeg-bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := Open(context.Background(), filepath.Join(root, "library"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	store.now = func() time.Time { return time.Unix(1800000000, 0) }
	report, err := store.MigrateV1(context.Background(), legacyPath, mediaRoot)
	if err != nil {
		t.Fatal(err)
	}
	if report.Entries != 2 || report.Assets != 3 || report.MissingMedia != 0 {
		t.Fatalf("迁移统计错误: %+v", report)
	}
	entry, err := store.Get(context.Background(), "2EF4DE2C-D521-4977-81F4-A7F98085FB41")
	if err != nil {
		t.Fatal(err)
	}
	if entry.ShortID() != "2ef4de2c" || entry.Summary != "A short summary." || entry.Note != "备注" {
		t.Fatalf("旧字段没有保留: %+v", entry)
	}
	if len(entry.Tags) != 1 || entry.Tags[0] != "ui-design" {
		t.Fatalf("旧标签没有保留: %+v", entry.Tags)
	}
	if len(entry.Assets) != 2 {
		t.Fatalf("正文和媒体应各有一个附件: %+v", entry.Assets)
	}
	if got, err := store.AssetText(context.Background(), entry.ID, "content.md"); err != nil || got != body {
		t.Fatalf("正文没有原样迁移: %q %v", got, err)
	}
	if got, err := store.AssetText(context.Background(), "empty", "content.md"); err != nil || got != "" {
		t.Fatalf("空正文被改写: %q %v", got, err)
	}
	tags, err := store.Tags(context.Background())
	if err != nil || len(tags) != 2 {
		t.Fatalf("标签池没有完整迁移: %+v %v", tags, err)
	}
	if tags[0].Slug != "ui-design" || tags[0].Name != "界面设计" || tags[0].Description != "界面参考" || tags[0].Count != 1 ||
		tags[1].Slug != "unused" || tags[1].Name != "未使用" || tags[1].Description != "保留标签池" || tags[1].Count != 0 {
		t.Fatalf("标签说明或未关联标签没有保留: %+v", tags)
	}
	if _, err := store.MigrateV1(context.Background(), legacyPath, mediaRoot); err == nil {
		t.Fatal("非空库不应重复迁移")
	}
}
