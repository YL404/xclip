package core

import (
	"context"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/egoist/mygo/plugins/sqlite"
)

type Store struct {
	db   *sqlite.DB
	root string
	now  func() time.Time
}

func Open(ctx context.Context, root string) (*Store, error) {
	if err := ensureLibrary(root); err != nil {
		return nil, err
	}
	db, err := sqlite.Open(ctx, DatabasePath(root), sqlite.OpenOptions{BusyTimeout: 15 * time.Second})
	if err != nil {
		return nil, fmt.Errorf("打开内容库: %w", err)
	}
	store := &Store{db: db, root: root, now: time.Now}
	if err := store.migrate(ctx); err != nil {
		db.Close()
		return nil, err
	}
	if err := store.indexMissingText(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return store, nil
}

// DataVersion 返回当前连接看到的数据版本，其他连接提交后才会变化。
func (s *Store) DataVersion(ctx context.Context) (int64, error) {
	rows, err := s.db.Query(ctx, `PRAGMA data_version`)
	if err != nil {
		return 0, err
	}
	if len(rows.Values) != 1 || len(rows.Values[0]) != 1 {
		return 0, fmt.Errorf("读取 data_version 失败")
	}
	version, _ := rows.Values[0][0].(int64)
	return version, nil
}

// 修复旧版文件头检查漏掉的 UTF-8 文档，只读取内容库中的原件。
func (s *Store) indexMissingText(ctx context.Context) error {
	rows, err := s.db.Query(ctx, `SELECT a.id, a.entry_id, a.kind, a.sha256 FROM assets a
		WHERE a.kind IN ('text', 'code') AND a.size <= ? AND NOT EXISTS
		(SELECT 1 FROM documents d WHERE d.asset_id = a.id AND d.kind IN ('text', 'code'))`, maxTextBytes)
	if err != nil {
		return err
	}
	var statements []sqlite.Statement
	for _, row := range rows.Values {
		data, err := os.ReadFile(blobPath(s.root, text(row[3])))
		if err != nil || !utf8.Valid(data) {
			continue
		}
		statements = append(statements, sqlite.Statement{SQL: `INSERT INTO documents(entry_id, asset_id, kind, body)
			SELECT ?, ?, ?, ? WHERE NOT EXISTS
			(SELECT 1 FROM documents WHERE asset_id = ? AND kind IN ('text', 'code'))`,
			Args: []any{text(row[1]), text(row[0]), text(row[2]), string(data), text(row[0])}})
	}
	if len(statements) == 0 {
		return nil
	}
	_, err = s.db.Transaction(ctx, statements)
	return err
}

func (s *Store) Close() error { return s.db.Close() }
func (s *Store) Root() string { return s.root }

func (s *Store) migrate(ctx context.Context) error {
	rows, err := s.db.Query(ctx, "PRAGMA user_version")
	if err != nil {
		return err
	}
	version, err := rowInt(rows, 0)
	if err != nil {
		return err
	}
	if version > 1 {
		return fmt.Errorf("不支持的内容库版本 %d", version)
	}
	if version == 1 {
		rows, err := s.db.Query(ctx, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'entries'")
		if err != nil {
			return err
		}
		if len(rows.Values) != 1 {
			return fmt.Errorf("旧版数据库请通过显式迁移导入，不能直接改写")
		}
		_, err = s.db.Execute(ctx, "PRAGMA journal_mode = WAL")
		return err
	}
	for _, statement := range []string{
		"PRAGMA journal_mode = WAL",
		"PRAGMA foreign_keys = ON",
	} {
		if _, err := s.db.Execute(ctx, statement); err != nil {
			return err
		}
	}
	statements := []sqlite.Statement{
		{SQL: `CREATE TABLE entries (
			id TEXT PRIMARY KEY, title TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '',
			note TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '',
			created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
		)`},
		{SQL: `CREATE TABLE blobs (sha256 TEXT PRIMARY KEY, size INTEGER NOT NULL)`},
		{SQL: `CREATE TABLE assets (
			id TEXT PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
			path TEXT NOT NULL, kind TEXT NOT NULL, mime TEXT NOT NULL DEFAULT '',
			size INTEGER NOT NULL, sha256 TEXT NOT NULL REFERENCES blobs(sha256), position INTEGER NOT NULL,
			UNIQUE(entry_id, path)
		)`},
		{SQL: `CREATE TABLE documents (
			id INTEGER PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
			asset_id TEXT REFERENCES assets(id) ON DELETE CASCADE,
			kind TEXT NOT NULL, body TEXT NOT NULL
		)`},
		{SQL: `CREATE INDEX documents_asset ON documents(asset_id)`},
		{SQL: `CREATE TABLE tags (
			id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE, name TEXT NOT NULL UNIQUE,
			description TEXT NOT NULL DEFAULT ''
		)`},
		{SQL: `CREATE TABLE entry_tags (
			entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
			tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
			PRIMARY KEY(entry_id, tag_id)
		)`},
		{SQL: `CREATE VIRTUAL TABLE documents_fts USING fts5(body, content='documents', content_rowid='id', tokenize='trigram')`},
		{SQL: `CREATE TRIGGER documents_ai AFTER INSERT ON documents BEGIN
			INSERT INTO documents_fts(rowid, body) VALUES (new.id, new.body); END`},
		{SQL: `CREATE TRIGGER documents_ad AFTER DELETE ON documents BEGIN
			INSERT INTO documents_fts(documents_fts, rowid, body) VALUES ('delete', old.id, old.body); END`},
		{SQL: `CREATE TRIGGER documents_au AFTER UPDATE OF body ON documents BEGIN
			INSERT INTO documents_fts(documents_fts, rowid, body) VALUES ('delete', old.id, old.body);
			INSERT INTO documents_fts(rowid, body) VALUES (new.id, new.body); END`},
		{SQL: `PRAGMA user_version = 1`},
	}
	_, err = s.db.Transaction(ctx, statements)
	return err
}

func (s *Store) Import(ctx context.Context, input Import) (Entry, error) {
	var err error
	input.Summary, err = ValidateSummary(input.Summary)
	if err != nil {
		return Entry{}, err
	}
	var files []sourceFile
	if len(input.Paths) > 0 {
		var defaultTitle string
		files, defaultTitle, input.Source, err = collectFiles(input.Paths)
		if err != nil {
			return Entry{}, err
		}
		if input.Title == "" {
			input.Title = defaultTitle
		}
	}
	return s.importFiles(ctx, input, files)
}

func (s *Store) importFiles(ctx context.Context, input Import, files []sourceFile) (Entry, error) {
	var err error
	if input.Title == "" {
		input.Title = "未命名内容"
	}
	if input.Text != "" {
		if input.TextName == "" {
			input.TextName = "content.md"
		}
		input.TextName, err = cleanRelative(input.TextName)
		if err != nil {
			return Entry{}, err
		}
	}
	id, err := NewID()
	if err != nil {
		return Entry{}, err
	}
	stage, err := stageLibrary(s.root)
	if err != nil {
		return Entry{}, err
	}
	defer cleanupStage(stage)
	type stagedAsset struct {
		asset      Asset
		stagedPath string
	}
	var staged []stagedAsset
	addFile := func(sourcePath, relative string) error {
		relative, err = cleanRelative(relative)
		if err != nil {
			return err
		}
		for _, existing := range staged {
			if existing.asset.Path == relative {
				return fmt.Errorf("附件相对路径重复: %s", relative)
			}
		}
		assetID, err := NewID()
		if err != nil {
			return err
		}
		stagedPath := stage.assetPath(assetID)
		digest, err := copyFile(sourcePath, stagedPath)
		if err != nil {
			return err
		}
		kind, mimeType, size, extractedText, textKind, readable, err := readAssetFile(stagedPath, relative)
		if err != nil {
			return err
		}
		staged = append(staged, stagedAsset{asset: Asset{
			ID: assetID, Path: relative, Kind: kind, MIME: mimeType, Size: size,
			SHA256: hex.EncodeToString(digest[:]), Text: extractedText, TextKind: textKind, Readable: readable,
		}, stagedPath: stagedPath})
		return nil
	}
	for _, file := range files {
		if err := addFile(file.path, file.relative); err != nil {
			return Entry{}, fmt.Errorf("录入 %s: %w", file.path, err)
		}
	}
	if input.Text != "" {
		temp := filepath.Join(stage.path, "text-input")
		err := os.WriteFile(temp, []byte(input.Text), 0o600)
		if err != nil {
			return Entry{}, err
		}
		if err := addFile(temp, input.TextName); err != nil {
			return Entry{}, err
		}
	}
	if len(staged) == 0 {
		return Entry{}, fmt.Errorf("没有可录入的内容")
	}
	if len(input.Tags) > 0 {
		if err := s.validateTags(ctx, input.Tags); err != nil {
			return Entry{}, err
		}
	}
	for _, item := range staged {
		if err := commitBlob(s.root, item.stagedPath, item.asset.SHA256); err != nil {
			return Entry{}, err
		}
	}
	now := s.now().Unix()
	statements := []sqlite.Statement{{SQL: `INSERT INTO entries
		(id, title, summary, note, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		Args: []any{id, input.Title, input.Summary, input.Note, input.Source, now, now}}}
	for position, item := range staged {
		asset := item.asset
		statements = append(statements,
			sqlite.Statement{SQL: `INSERT INTO blobs(sha256, size) VALUES (?, ?) ON CONFLICT(sha256) DO NOTHING`, Args: []any{asset.SHA256, asset.Size}},
			sqlite.Statement{SQL: `INSERT INTO assets
				(id, entry_id, path, kind, mime, size, sha256, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
				Args: []any{asset.ID, id, asset.Path, asset.Kind, asset.MIME, asset.Size, asset.SHA256, position}},
		)
		if asset.Readable {
			statements = append(statements, sqlite.Statement{SQL: `INSERT INTO documents(entry_id, asset_id, kind, body) VALUES (?, ?, ?, ?)`, Args: []any{id, asset.ID, asset.TextKind, asset.Text}})
		}
	}
	statements = append(statements, sqlite.Statement{SQL: `INSERT INTO documents(entry_id, kind, body) VALUES (?, 'metadata', ?)`, Args: []any{id, strings.TrimSpace(input.Title + "\n" + input.Summary + "\n" + input.Note)}})
	statements = append(statements, tagStatements(id, input.Tags)...)
	if _, err := s.db.Transaction(ctx, statements); err != nil {
		return Entry{}, fmt.Errorf("写入内容库: %w", err)
	}
	return s.Get(ctx, id)
}

func (s *Store) Get(ctx context.Context, target string) (Entry, error) {
	id, err := s.resolve(ctx, target)
	if err != nil {
		return Entry{}, err
	}
	entries, err := s.entries(ctx, "WHERE e.id = ?", []any{id}, true)
	if err != nil || len(entries) == 0 {
		return Entry{}, fmt.Errorf("找不到内容: %s", target)
	}
	return entries[0], nil
}

func (s *Store) resolve(ctx context.Context, target string) (string, error) {
	target = strings.TrimPrefix(strings.TrimSpace(target), "#")
	if target == "" {
		return "", fmt.Errorf("条目编码不能为空")
	}
	rows, err := s.db.Query(ctx, "SELECT id FROM entries WHERE id = ?", target)
	if err != nil {
		return "", err
	}
	if len(rows.Values) == 1 {
		return rows.Values[0][0].(string), nil
	}
	prefix := strings.ReplaceAll(strings.ToLower(target), "-", "")
	if len(prefix) < 4 {
		return "", fmt.Errorf("找不到内容: %s", target)
	}
	rows, err = s.db.Query(ctx, "SELECT id FROM entries WHERE LOWER(REPLACE(id, '-', '')) LIKE ? LIMIT 2", prefix+"%")
	if err != nil {
		return "", err
	}
	if len(rows.Values) != 1 {
		if len(rows.Values) > 1 {
			return "", fmt.Errorf("编码前缀 %s 匹配多条内容，请使用更长前缀", prefix)
		}
		return "", fmt.Errorf("找不到内容: %s", target)
	}
	return rows.Values[0][0].(string), nil
}

func (s *Store) Patch(ctx context.Context, target string, patch Patch) (Entry, error) {
	entry, err := s.Get(ctx, target)
	if err != nil {
		return Entry{}, err
	}
	if patch.Summary != nil {
		value, err := ValidateSummary(*patch.Summary)
		if err != nil {
			return Entry{}, err
		}
		patch.Summary = &value
	}
	if patch.Tags != nil {
		if err := s.validateTags(ctx, *patch.Tags); err != nil {
			return Entry{}, err
		}
	}
	now := s.now().Unix()
	var statements []sqlite.Statement
	if patch.Title != nil {
		if strings.TrimSpace(*patch.Title) == "" {
			return Entry{}, fmt.Errorf("标题不能为空")
		}
		statements = append(statements, sqlite.Statement{SQL: "UPDATE entries SET title = ? WHERE id = ?", Args: []any{strings.TrimSpace(*patch.Title), entry.ID}})
		entry.Title = strings.TrimSpace(*patch.Title)
	}
	if patch.Summary != nil {
		statements = append(statements, sqlite.Statement{SQL: "UPDATE entries SET summary = ? WHERE id = ?", Args: []any{*patch.Summary, entry.ID}})
		entry.Summary = *patch.Summary
	}
	if patch.Note != nil {
		statements = append(statements, sqlite.Statement{SQL: "UPDATE entries SET note = ? WHERE id = ?", Args: []any{*patch.Note, entry.ID}})
		entry.Note = *patch.Note
	}
	if patch.Tags != nil {
		statements = append(statements, sqlite.Statement{SQL: "DELETE FROM entry_tags WHERE entry_id = ?", Args: []any{entry.ID}})
		statements = append(statements, tagStatements(entry.ID, *patch.Tags)...)
	}
	for assetPath, text := range patch.AssetTexts {
		var assetID *string
		for _, asset := range entry.Assets {
			if asset.Path == assetPath {
				assetID = &asset.ID
				break
			}
		}
		if assetID == nil {
			return Entry{}, fmt.Errorf("找不到附件: %s", assetPath)
		}
		statements = append(statements,
			sqlite.Statement{SQL: "DELETE FROM documents WHERE asset_id = ? AND kind IN ('description', 'transcript')", Args: []any{*assetID}},
			sqlite.Statement{SQL: "INSERT INTO documents(entry_id, asset_id, kind, body) VALUES (?, ?, 'description', ?)", Args: []any{entry.ID, *assetID, text}},
		)
	}
	statements = append(statements,
		sqlite.Statement{SQL: "UPDATE entries SET updated_at = ? WHERE id = ?", Args: []any{now, entry.ID}},
		sqlite.Statement{SQL: "DELETE FROM documents WHERE entry_id = ? AND kind = 'metadata'", Args: []any{entry.ID}},
		sqlite.Statement{SQL: "INSERT INTO documents(entry_id, kind, body) VALUES (?, 'metadata', ?)", Args: []any{entry.ID, strings.TrimSpace(entry.Title + "\n" + entry.Summary + "\n" + entry.Note)}},
	)
	if len(statements) == 2 && patch.Tags == nil {
		return s.Get(ctx, entry.ID)
	}
	if _, err := s.db.Transaction(ctx, statements); err != nil {
		return Entry{}, err
	}
	return s.Get(ctx, entry.ID)
}

func (s *Store) validateTags(ctx context.Context, rawTags []string) error {
	for _, raw := range rawTags {
		slug, name, err := ParseTag(raw)
		if err != nil {
			return err
		}
		rows, err := s.db.Query(ctx, "SELECT name FROM tags WHERE slug = ?", slug)
		if err != nil {
			return err
		}
		if len(rows.Values) == 0 && name == "" {
			return fmt.Errorf("标签 %s 不存在，请使用 %s:中文名称 创建", slug, slug)
		}
		if len(rows.Values) == 1 && name != "" && text(rows.Values[0][0]) != name {
			return fmt.Errorf("标签 %s 已使用中文名称 %s", slug, text(rows.Values[0][0]))
		}
		if name != "" {
			rows, err = s.db.Query(ctx, "SELECT slug FROM tags WHERE name = ? AND slug <> ?", name, slug)
			if err != nil {
				return err
			}
			if len(rows.Values) != 0 {
				return fmt.Errorf("中文名称 %s 已被标签 %s 使用", name, text(rows.Values[0][0]))
			}
		}
	}
	return nil
}

func tagStatements(entryID string, rawTags []string) []sqlite.Statement {
	var statements []sqlite.Statement
	for _, raw := range rawTags {
		slug, name, _ := ParseTag(raw)
		if name != "" {
			statements = append(statements, sqlite.Statement{SQL: "INSERT INTO tags(slug, name) VALUES (?, ?) ON CONFLICT(slug) DO NOTHING", Args: []any{slug, name}})
		}
		statements = append(statements, sqlite.Statement{SQL: `INSERT INTO entry_tags(entry_id, tag_id)
			SELECT ?, id FROM tags WHERE slug = ?`, Args: []any{entryID, slug}})
	}
	return statements
}

func (s *Store) entries(ctx context.Context, where string, args []any, includeAssets bool) ([]Entry, error) {
	rows, err := s.db.Query(ctx, `SELECT e.id, e.title, e.summary, e.note, e.source, e.created_at, e.updated_at
		FROM entries e `+where+` ORDER BY e.created_at DESC, e.id DESC`, args...)
	if err != nil {
		return nil, err
	}
	entries := make([]Entry, 0, len(rows.Values))
	for _, values := range rows.Values {
		created, _ := values[5].(int64)
		updated, _ := values[6].(int64)
		entries = append(entries, Entry{ID: text(values[0]), Title: text(values[1]), Summary: text(values[2]), Note: text(values[3]), Source: text(values[4]), CreatedAt: time.Unix(created, 0).UTC(), UpdatedAt: time.Unix(updated, 0).UTC(), Tags: []string{}})
	}
	for i := range entries {
		tags, err := s.db.Query(ctx, `SELECT t.slug FROM entry_tags et JOIN tags t ON t.id = et.tag_id WHERE et.entry_id = ? ORDER BY t.slug`, entries[i].ID)
		if err != nil {
			return nil, err
		}
		for _, row := range tags.Values {
			entries[i].Tags = append(entries[i].Tags, text(row[0]))
		}
		if includeAssets {
			assets, err := s.db.Query(ctx, `SELECT a.id, a.path, a.kind, a.mime, a.size, a.sha256,
				EXISTS(SELECT 1 FROM documents d WHERE d.asset_id = a.id AND d.kind IN ('text', 'code'))
				FROM assets a WHERE a.entry_id = ? ORDER BY a.position`, entries[i].ID)
			if err != nil {
				return nil, err
			}
			entries[i].Assets = make([]Asset, 0, len(assets.Values))
			for _, values := range assets.Values {
				size, _ := values[4].(int64)
				readable, _ := values[6].(int64)
				entries[i].Assets = append(entries[i].Assets, Asset{ID: text(values[0]), Path: text(values[1]), Kind: text(values[2]), MIME: text(values[3]), Size: size, SHA256: text(values[5]), LocalPath: blobPath(s.root, text(values[5])), Readable: readable != 0})
			}
		}
	}
	return entries, nil
}

func (s *Store) Search(ctx context.Context, options SearchOptions) ([]SearchResult, error) {
	limit := options.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	where, args := "WHERE 1 = 1", []any{}
	if options.Kind != "" {
		where += " AND EXISTS(SELECT 1 FROM assets a WHERE a.entry_id = e.id AND a.kind = ?)"
		args = append(args, options.Kind)
	}
	for _, raw := range options.Tags {
		slug, err := NormalizeSlug(raw)
		if err != nil {
			return nil, err
		}
		where += " AND EXISTS(SELECT 1 FROM entry_tags et JOIN tags t ON t.id = et.tag_id WHERE et.entry_id = e.id AND t.slug = ?)"
		args = append(args, slug)
	}
	entries, err := s.entries(ctx, where, args, true)
	if err != nil {
		return nil, err
	}
	tokens := strings.Fields(options.Query)
	results := make([]SearchResult, 0)
	for _, entry := range entries {
		matches, err := s.matches(ctx, entry, tokens)
		if err != nil {
			return nil, err
		}
		if len(tokens) > 0 && len(matches) == 0 {
			continue
		}
		results = append(results, SearchResult{Entry: entry, Matches: matches})
		if !options.AllResults && len(results) >= limit {
			break
		}
	}
	return results, nil
}

func (s *Store) matches(ctx context.Context, entry Entry, tokens []string) ([]Match, error) {
	if len(tokens) == 0 {
		return []Match{}, nil
	}
	rows, err := s.db.Query(ctx, `SELECT d.id, COALESCE(d.asset_id, ''), COALESCE(a.path, ''), d.kind, d.body
		FROM documents d LEFT JOIN assets a ON a.id = d.asset_id WHERE d.entry_id = ?`, entry.ID)
	if err != nil {
		return nil, err
	}
	var ftsIDs []int64
	for _, token := range tokens {
		if utf8.RuneCountInString(token) >= 3 {
			rows, err := s.db.Query(ctx, `SELECT d.id FROM documents d JOIN documents_fts f ON f.rowid = d.id
				WHERE d.entry_id = ? AND documents_fts MATCH ?`, entry.ID, `"`+strings.ReplaceAll(strings.ToLower(token), `"`, "")+`"`)
			if err != nil {
				return nil, err
			}
			ids := make([]int64, 0, len(rows.Values))
			for _, row := range rows.Values {
				id, _ := row[0].(int64)
				ids = append(ids, id)
			}
			ftsIDs = append(ftsIDs, ids...)
		}
	}
	longMatches := map[int64]bool{}
	for _, id := range ftsIDs {
		longMatches[id] = true
	}
	// A match is reported once per document: the first location plus the number
	// of occurrences. Returning every occurrence makes a code file swamp the
	// result and gives an agent no better choice about which file to read.
	var matches []Match
	for _, row := range rows.Values {
		id, _ := row[0].(int64)
		body := text(row[4])
		if len(tokens) > 0 && !longMatches[id] && !hasShortToken(tokens) {
			continue
		}
		first := -1
		firstEnd := -1
		count := 0
		lowerBody := strings.ToLower(body)
		ok := true
		for _, token := range tokens {
			lowerToken := strings.ToLower(token)
			offset := 0
			found := false
			for offset < len(lowerBody) {
				index := strings.Index(lowerBody[offset:], lowerToken)
				if index < 0 {
					break
				}
				start := offset + index
				end := start + len(lowerToken)
				if start < first || first < 0 {
					first, firstEnd = start, end
				}
				count++
				found = true
				offset = end
			}
			if !found {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		line := 1 + strings.Count(body[:first], "\n")
		matches = append(matches, Match{
			AssetID: text(row[1]), Path: text(row[2]), Kind: text(row[3]), Line: line,
			Start: first, End: firstEnd, Count: count, Snippet: snippet(body, first, firstEnd),
		})
	}
	return matches, nil
}

func hasShortToken(tokens []string) bool {
	for _, token := range tokens {
		if utf8.RuneCountInString(token) < 3 {
			return true
		}
	}
	return false
}

func snippet(body string, start, end int) string {
	from := strings.LastIndex(body[:start], "\n") + 1
	if start-from > 120 {
		from = start - 120
	}
	to := strings.Index(body[end:], "\n")
	if to < 0 {
		to = len(body)
	} else {
		to += end
	}
	if to-from > 320 {
		to = from + 320
	}
	return strings.TrimSpace(body[from:to])
}

func (s *Store) AssetText(ctx context.Context, target, assetPath string) (string, error) {
	entry, err := s.Get(ctx, target)
	if err != nil {
		return "", err
	}
	for _, asset := range entry.Assets {
		if asset.Path == assetPath {
			rows, err := s.db.Query(ctx, `SELECT body FROM documents WHERE asset_id = ? AND kind IN ('text', 'code', 'description', 'transcript') ORDER BY id`, asset.ID)
			if err != nil {
				return "", err
			}
			var parts []string
			for _, row := range rows.Values {
				parts = append(parts, text(row[0]))
			}
			return strings.Join(parts, "\n"), nil
		}
	}
	return "", fmt.Errorf("找不到附件: %s", assetPath)
}

func (s *Store) AssetPath(ctx context.Context, assetID string) (string, string, error) {
	rows, err := s.db.Query(ctx, "SELECT sha256, path FROM assets WHERE id = ?", assetID)
	if err != nil {
		return "", "", err
	}
	if len(rows.Values) != 1 {
		return "", "", fmt.Errorf("附件不存在")
	}
	digest := text(rows.Values[0][0])
	return blobPath(s.root, digest), text(rows.Values[0][1]), nil
}

func (s *Store) Tags(ctx context.Context) ([]Tag, error) {
	rows, err := s.db.Query(ctx, `SELECT t.slug, t.name, t.description, COUNT(et.entry_id)
		FROM tags t LEFT JOIN entry_tags et ON et.tag_id = t.id GROUP BY t.id ORDER BY t.slug`)
	if err != nil {
		return nil, err
	}
	tags := make([]Tag, 0, len(rows.Values))
	for _, values := range rows.Values {
		count, _ := values[3].(int64)
		tags = append(tags, Tag{Slug: text(values[0]), Name: text(values[1]), Description: text(values[2]), Count: int(count)})
	}
	return tags, nil
}

func (s *Store) Delete(ctx context.Context, target string) error {
	entry, err := s.Get(ctx, target)
	if err != nil {
		return err
	}
	_, err = s.db.Execute(ctx, "DELETE FROM entries WHERE id = ?", entry.ID)
	return err
}

func text(value any) string {
	switch value := value.(type) {
	case string:
		return value
	case []byte:
		return string(value)
	default:
		return fmt.Sprint(value)
	}
}

func rowInt(rows sqlite.Rows, column int) (int64, error) {
	if len(rows.Values) != 1 || len(rows.Values[0]) <= column {
		return 0, sql.ErrNoRows
	}
	value, ok := rows.Values[0][column].(int64)
	if !ok {
		return 0, fmt.Errorf("SQLite 返回了非整数值")
	}
	return value, nil
}
