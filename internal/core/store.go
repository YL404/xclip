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
	"unicode"
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
	if len(statements) == 0 {
		return s.Get(ctx, entry.ID)
	}
	statements = append(statements,
		sqlite.Statement{SQL: "UPDATE entries SET updated_at = ? WHERE id = ?", Args: []any{now, entry.ID}},
		sqlite.Statement{SQL: "DELETE FROM documents WHERE entry_id = ? AND kind = 'metadata'", Args: []any{entry.ID}},
		sqlite.Statement{SQL: "INSERT INTO documents(entry_id, kind, body) VALUES (?, 'metadata', ?)", Args: []any{entry.ID, strings.TrimSpace(entry.Title + "\n" + entry.Summary + "\n" + entry.Note)}},
	)
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

const queryChunkSize = 400

func placeholders(count int) string {
	if count <= 0 {
		return ""
	}
	return strings.Repeat("?,", count-1) + "?"
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
		entry := Entry{
			ID:        text(values[0]),
			Title:     text(values[1]),
			Summary:   text(values[2]),
			Note:      text(values[3]),
			Source:    text(values[4]),
			CreatedAt: time.Unix(created, 0).UTC(),
			UpdatedAt: time.Unix(updated, 0).UTC(),
			Tags:      []string{},
		}
		if includeAssets {
			entry.Assets = []Asset{}
		}
		entries = append(entries, entry)
	}
	if err := s.hydrateEntries(ctx, entries, includeAssets); err != nil {
		return nil, err
	}
	return entries, nil
}

func (s *Store) entriesByIDs(ctx context.Context, ids []string, includeAssets bool) ([]Entry, error) {
	if len(ids) == 0 {
		return []Entry{}, nil
	}
	byID := make(map[string]Entry, len(ids))
	for start := 0; start < len(ids); start += queryChunkSize {
		chunk := ids[start:min(start+queryChunkSize, len(ids))]
		args := make([]any, len(chunk))
		for i, id := range chunk {
			args[i] = id
		}
		loaded, err := s.entries(ctx, "WHERE e.id IN ("+placeholders(len(chunk))+")", args, includeAssets)
		if err != nil {
			return nil, err
		}
		for _, entry := range loaded {
			byID[entry.ID] = entry
		}
	}
	ordered := make([]Entry, 0, len(ids))
	for _, id := range ids {
		if entry, ok := byID[id]; ok {
			ordered = append(ordered, entry)
		}
	}
	return ordered, nil
}

func (s *Store) hydrateEntries(ctx context.Context, entries []Entry, includeAssets bool) error {
	if len(entries) == 0 {
		return nil
	}
	indexByID := make(map[string]int, len(entries))
	for i := range entries {
		indexByID[entries[i].ID] = i
	}
	for start := 0; start < len(entries); start += queryChunkSize {
		end := min(start+queryChunkSize, len(entries))
		args := make([]any, end-start)
		for i := start; i < end; i++ {
			args[i-start] = entries[i].ID
		}
		inClause := placeholders(len(args))
		tags, err := s.db.Query(ctx, `SELECT et.entry_id, t.slug
			FROM entry_tags et JOIN tags t ON t.id = et.tag_id
			WHERE et.entry_id IN (`+inClause+`)
			ORDER BY et.entry_id, t.slug`, args...)
		if err != nil {
			return err
		}
		for _, row := range tags.Values {
			if idx, ok := indexByID[text(row[0])]; ok {
				entries[idx].Tags = append(entries[idx].Tags, text(row[1]))
			}
		}
		if !includeAssets {
			continue
		}
		assets, err := s.db.Query(ctx, `SELECT a.entry_id, a.id, a.path, a.kind, a.mime, a.size, a.sha256,
			EXISTS(SELECT 1 FROM documents d WHERE d.asset_id = a.id AND d.kind IN ('text', 'code'))
			FROM assets a
			WHERE a.entry_id IN (`+inClause+`)
			ORDER BY a.entry_id, a.position`, args...)
		if err != nil {
			return err
		}
		for _, values := range assets.Values {
			idx, ok := indexByID[text(values[0])]
			if !ok {
				continue
			}
			size, _ := values[5].(int64)
			readable, _ := values[7].(int64)
			entries[idx].Assets = append(entries[idx].Assets, Asset{
				ID:        text(values[1]),
				Path:      text(values[2]),
				Kind:      text(values[3]),
				MIME:      text(values[4]),
				Size:      size,
				SHA256:    text(values[6]),
				LocalPath: blobPath(s.root, text(values[6])),
				Readable:  readable != 0,
			})
		}
	}
	return nil
}

func buildEntryFilter(options SearchOptions) (string, []any, error) {
	where, args := "WHERE 1 = 1", []any{}
	if options.Kind != "" {
		where += " AND EXISTS(SELECT 1 FROM assets a WHERE a.entry_id = e.id AND a.kind = ?)"
		args = append(args, options.Kind)
	}
	for _, raw := range options.Tags {
		slug, err := NormalizeSlug(raw)
		if err != nil {
			return "", nil, err
		}
		where += " AND EXISTS(SELECT 1 FROM entry_tags et JOIN tags t ON t.id = et.tag_id WHERE et.entry_id = e.id AND t.slug = ?)"
		args = append(args, slug)
	}
	return where, args, nil
}

func (s *Store) Search(ctx context.Context, options SearchOptions) ([]SearchResult, error) {
	limit := options.Limit
	if limit <= 0 {
		limit = 50
	}
	where, args, err := buildEntryFilter(options)
	if err != nil {
		return nil, err
	}
	tokens := strings.Fields(options.Query)
	if len(tokens) == 0 {
		sqlQuery := `SELECT e.id, e.title, e.summary, e.note, e.source, e.created_at, e.updated_at
			FROM entries e ` + where + ` ORDER BY e.created_at DESC, e.id DESC`
		if !options.AllResults {
			sqlQuery += " LIMIT ?"
			args = append(args, limit)
		}
		rows, err := s.db.Query(ctx, sqlQuery, args...)
		if err != nil {
			return nil, err
		}
		entries := make([]Entry, 0, len(rows.Values))
		for _, values := range rows.Values {
			created, _ := values[5].(int64)
			updated, _ := values[6].(int64)
			entries = append(entries, Entry{
				ID:        text(values[0]),
				Title:     text(values[1]),
				Summary:   text(values[2]),
				Note:      text(values[3]),
				Source:    text(values[4]),
				CreatedAt: time.Unix(created, 0).UTC(),
				UpdatedAt: time.Unix(updated, 0).UTC(),
				Tags:      []string{},
				Assets:    []Asset{},
			})
		}
		if err := s.hydrateEntries(ctx, entries, true); err != nil {
			return nil, err
		}
		results := make([]SearchResult, len(entries))
		for i, entry := range entries {
			results[i] = SearchResult{Entry: entry, Matches: []Match{}}
		}
		return results, nil
	}

	// 利用 FTS5 trigram 对满足条件的长词做倒排剪枝，短词或含非 ASCII 大小写折叠的词在 Go 中精确校验。
	docWhere := where
	docArgs := append([]any(nil), args...)
	for _, token := range tokens {
		if utf8.RuneCountInString(token) >= 3 && isFTSTrigramSafe(token) {
			docWhere += ` AND d.id IN (SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?)`
			docArgs = append(docArgs, ftsPhrase(token))
		}
	}
	rows, err := s.db.Query(ctx, `SELECT e.id, COALESCE(d.asset_id, ''), COALESCE(a.path, ''), d.kind, d.body
		FROM documents d
		JOIN entries e ON e.id = d.entry_id
		LEFT JOIN assets a ON a.id = d.asset_id `+docWhere+`
		ORDER BY e.created_at DESC, e.id DESC, d.id ASC`, docArgs...)
	if err != nil {
		return nil, err
	}

	lowerTokens := make([]string, len(tokens))
	for i, token := range tokens {
		lowerTokens[i] = strings.ToLower(token)
	}

	// 每份文档只报告首次命中位置及总命中次数，避免长代码文件刷屏。
	matchedOrder := make([]string, 0)
	matchesByEntry := make(map[string][]Match)
	for _, row := range rows.Values {
		entryID := text(row[0])
		if !options.AllResults && len(matchedOrder) >= limit {
			if _, seen := matchesByEntry[entryID]; !seen {
				break
			}
		}
		match, ok := matchDocument(text(row[1]), text(row[2]), text(row[3]), text(row[4]), lowerTokens)
		if !ok {
			continue
		}
		if _, seen := matchesByEntry[entryID]; !seen {
			matchedOrder = append(matchedOrder, entryID)
		}
		matchesByEntry[entryID] = append(matchesByEntry[entryID], match)
	}
	entries, err := s.entriesByIDs(ctx, matchedOrder, true)
	if err != nil {
		return nil, err
	}
	results := make([]SearchResult, 0, len(entries))
	for _, entry := range entries {
		results = append(results, SearchResult{Entry: entry, Matches: matchesByEntry[entry.ID]})
	}
	return results, nil
}

// isFTSTrigramSafe 判断词项是否可安全交由 SQLite trigram 索引过滤。
// SQLite 默认 trigram 仅对 ASCII 做大小写折叠，含非 ASCII 大小写变体的词留待 Go 精确匹配。
func isFTSTrigramSafe(token string) bool {
	for _, r := range token {
		if r > unicode.MaxASCII && unicode.ToLower(r) != unicode.ToUpper(r) {
			return false
		}
	}
	return true
}

func ftsPhrase(token string) string {
	return `"` + strings.ReplaceAll(strings.ToLower(token), `"`, `""`) + `"`
}

func matchDocument(assetID, path, kind, body string, lowerTokens []string) (Match, bool) {
	first := -1
	firstEnd := -1
	count := 0
	lowerBody := strings.ToLower(body)
	for _, lowerToken := range lowerTokens {
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
			return Match{}, false
		}
	}
	first, firstEnd = mapLowerSpan(body, first, firstEnd)
	line := 1 + strings.Count(body[:first], "\n")
	return Match{
		AssetID: assetID,
		Path:    path,
		Kind:    kind,
		Line:    line,
		Start:   first,
		End:     firstEnd,
		Count:   count,
		Snippet: snippet(body, first, firstEnd),
	}, true
}

// mapLowerSpan 将 strings.ToLower(body) 中的字节区间映射回 body 的合法 UTF-8 字符边界。
func mapLowerSpan(body string, start, end int) (int, int) {
	bodyStart, bodyEnd := -1, len(body)
	lowerPos := 0
	for i, r := range body {
		if bodyStart < 0 && lowerPos >= start {
			bodyStart = i
		}
		if lowerPos >= end {
			bodyEnd = i
			break
		}
		lowerPos += utf8.RuneLen(unicode.ToLower(r))
	}
	if bodyStart < 0 {
		bodyStart = len(body)
	}
	if bodyEnd < bodyStart {
		bodyEnd = bodyStart
	}
	return bodyStart, bodyEnd
}

func snippet(body string, start, end int) string {
	start = max(0, min(start, len(body)))
	end = max(start, min(end, len(body)))
	from := strings.LastIndex(body[:start], "\n") + 1
	if start-from > 120 {
		from = start - 120
		for from < start && !utf8.RuneStart(body[from]) {
			from++
		}
	}
	to := strings.Index(body[end:], "\n")
	if to < 0 {
		to = len(body)
	} else {
		to += end
	}
	if to-from > 320 {
		to = from + 320
		for to > from && to < len(body) && !utf8.RuneStart(body[to]) {
			to--
		}
	}
	return strings.TrimSpace(strings.ToValidUTF8(body[from:to], "\uFFFD"))
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

// Prune 删除没有附件引用的 blob，返回清理数量和释放的字节数。
func (s *Store) Prune(ctx context.Context) (int, int64, error) {
	rows, err := s.db.Query(ctx, `SELECT b.sha256, b.size FROM blobs b
		WHERE NOT EXISTS (SELECT 1 FROM assets a WHERE a.sha256 = b.sha256)`)
	if err != nil {
		return 0, 0, err
	}
	var removed int
	var freed int64
	for _, values := range rows.Values {
		digest := text(values[0])
		size, _ := values[1].(int64)
		// 条件删除防止并发录入刚建立引用；只有确实删掉记录才删文件。
		result, err := s.db.Execute(ctx, `DELETE FROM blobs WHERE sha256 = ?
			AND NOT EXISTS (SELECT 1 FROM assets WHERE assets.sha256 = blobs.sha256)`, digest)
		if err != nil {
			return removed, freed, err
		}
		if result.Changes == 0 {
			continue
		}
		if err := os.Remove(blobPath(s.root, digest)); err != nil && !os.IsNotExist(err) {
			return removed, freed, fmt.Errorf("删除附件 %s: %w", digest, err)
		}
		removed++
		freed += size
	}
	return removed, freed, nil
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
