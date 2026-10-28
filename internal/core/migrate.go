package core

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"mime"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/egoist/mygo/plugins/sqlite"
)

// MigrationReport 记录迁入内容、已复制附件和旧库未缓存的媒体数量。
type MigrationReport struct {
	Entries      int      `json:"entries"`
	Assets       int      `json:"assets"`
	MissingMedia int      `json:"missing_media"`
	Source       string   `json:"source"`
	Skipped      []string `json:"skipped,omitempty"`
}

type legacyPost struct {
	ID           string
	Platform     string
	ExternalID   string
	URL          string
	AuthorHandle string
	AuthorName   string
	Text         string
	MediaJSON    string
	Summary      string
	Note         string
	PostedAt     *int64
	SavedAt      int64
	Tags         []string
}

type legacyMedia struct {
	Type         string `json:"type"`
	URL          string `json:"url"`
	ThumbnailURL string `json:"thumbnail_url"`
	Width        int    `json:"width"`
	Height       int    `json:"height"`
}

// MigrateV1 opens the legacy database read-only. A missing database is an error:
// silently creating an empty one would make the migration look successful.
func (s *Store) MigrateV1(ctx context.Context, legacyPath, mediaRoot string) (MigrationReport, error) {
	report := MigrationReport{Source: legacyPath}
	info, err := os.Stat(legacyPath)
	if err != nil {
		return report, fmt.Errorf("读取旧数据库: %w", err)
	}
	if !info.Mode().IsRegular() {
		return report, fmt.Errorf("旧数据库不是普通文件: %s", legacyPath)
	}
	rows, err := s.db.Query(ctx, "SELECT COUNT(*) FROM entries")
	if err != nil {
		return report, err
	}
	if existing, _ := rowInt(rows, 0); existing > 0 {
		return report, fmt.Errorf("当前内容库已有 %d 条内容；请使用一个空的新库迁移，避免重复导入", existing)
	}
	legacy, err := sqlite.Open(ctx, legacyPath, sqlite.OpenOptions{ReadOnly: true, BusyTimeout: 15_000_000_000})
	if err != nil {
		return report, fmt.Errorf("打开旧数据库: %w", err)
	}
	defer legacy.Close()
	posts, err := legacy.Query(ctx, `SELECT id, platform, external_id, url, author_handle, author_name, text,
		media, summary, note, posted_at, saved_at FROM posts ORDER BY saved_at`)
	if err != nil {
		return report, fmt.Errorf("读取旧贴文: %w", err)
	}
	tagRows, err := legacy.Query(ctx, `SELECT pt.post_id, t.slug, t.name FROM post_tags pt JOIN tags t ON t.id = pt.tag_id ORDER BY t.slug`)
	if err != nil {
		return report, fmt.Errorf("读取旧标签: %w", err)
	}
	vocabulary, err := legacy.Query(ctx, "SELECT slug, name, COALESCE(description, '') FROM tags ORDER BY slug")
	if err != nil {
		return report, fmt.Errorf("读取旧标签池: %w", err)
	}
	var statements []sqlite.Statement
	for _, row := range vocabulary.Values {
		statements = append(statements, sqlite.Statement{SQL: "INSERT INTO tags(slug, name, description) VALUES (?, ?, ?)",
			Args: []any{legacyText(row[0]), legacyText(row[1]), legacyText(row[2])}})
	}
	if len(statements) > 0 {
		if _, err := s.db.Transaction(ctx, statements); err != nil {
			return report, fmt.Errorf("迁移旧标签池: %w", err)
		}
	}
	tagsByPost := map[string][]string{}
	for _, row := range tagRows.Values {
		postID := legacyText(row[0])
		// Migrated libraries may not contain the old vocabulary, so carry the
		// bilingual pair and let tagStatements create it.
		tagsByPost[postID] = append(tagsByPost[postID], legacyText(row[1])+":"+legacyText(row[2]))
	}
	for _, values := range posts.Values {
		post := legacyPost{
			ID: legacyText(values[0]), Platform: legacyText(values[1]), ExternalID: legacyText(values[2]),
			URL: legacyText(values[3]), AuthorHandle: legacyText(values[4]), AuthorName: legacyText(values[5]),
			Text: legacyText(values[6]), MediaJSON: legacyText(values[7]), Summary: legacyText(values[8]),
			Note: legacyText(values[9]), SavedAt: legacyInt(values[11]), Tags: tagsByPost[legacyText(values[0])],
		}
		if values[10] != nil {
			value := legacyInt(values[10])
			post.PostedAt = &value
		}
		if err := s.migratePost(ctx, post, mediaRoot, &report); err != nil {
			return report, err
		}
		report.Entries++
	}
	return report, nil
}

func (s *Store) migratePost(ctx context.Context, post legacyPost, mediaRoot string, report *MigrationReport) error {
	id := post.ID
	if id == "" {
		var err error
		id, err = NewID()
		if err != nil {
			return err
		}
	}
	title := strings.TrimSpace(post.AuthorName)
	if title == "" {
		title = post.AuthorHandle
	}
	if title == "" {
		title = "X 内容"
	}
	title += " · X"
	stage, err := stageLibrary(s.root)
	if err != nil {
		return err
	}
	defer cleanupStage(stage)
	var assets []stagedMigrationAsset
	textDocument := post.Text
	textPath := filepath.Join(stage.path, "source.md")
	if err := os.WriteFile(textPath, []byte(textDocument), 0o600); err != nil {
		return err
	}
	textAsset, err := stageMigrationAsset(stage, textPath, "content.md", "text", "text/plain")
	if err != nil {
		return err
	}
	assets = append(assets, textAsset)
	var media []legacyMedia
	if post.MediaJSON != "" {
		_ = json.Unmarshal([]byte(post.MediaJSON), &media)
	}
	for index, item := range media {
		if item.URL == "" {
			report.MissingMedia++
			continue
		}
		remotePath := legacyMediaPath(mediaRoot, item.URL)
		if remotePath == "" {
			report.MissingMedia++
			continue
		}
		name := fmt.Sprintf("%s-%d%s", item.Type, index+1, filepath.Ext(remotePath))
		asset, err := stageMigrationAsset(stage, remotePath, name, "", "")
		if err != nil {
			report.MissingMedia++
			continue
		}
		assets = append(assets, asset)
	}
	for _, asset := range assets {
		if err := commitBlob(s.root, asset.stagedPath, asset.sha256); err != nil {
			return err
		}
	}
	now := s.now().Unix()
	created := post.SavedAt
	if created == 0 {
		created = now
	}
	statements := []sqlite.Statement{{SQL: `INSERT INTO entries
		(id, title, summary, note, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		Args: []any{id, title, post.Summary, post.Note, post.URL, created, now}}}
	for position, asset := range assets {
		statements = append(statements,
			sqlite.Statement{SQL: `INSERT INTO blobs(sha256, size) VALUES (?, ?) ON CONFLICT(sha256) DO NOTHING`, Args: []any{asset.sha256, asset.size}},
			sqlite.Statement{SQL: `INSERT INTO assets(id, entry_id, path, kind, mime, size, sha256, position)
				VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, Args: []any{asset.id, id, asset.relative, asset.kind, asset.mime, asset.size, asset.sha256, position}},
		)
		if asset.kind == "text" {
			statements = append(statements, sqlite.Statement{SQL: `INSERT INTO documents(entry_id, asset_id, kind, body) VALUES (?, ?, 'text', ?)`, Args: []any{id, asset.id, textDocument}})
		}
	}
	metadata := strings.TrimSpace(title + "\n" + post.Summary + "\n" + post.Note + "\n" + post.URL + "\n" + post.AuthorHandle)
	statements = append(statements,
		sqlite.Statement{SQL: `INSERT INTO documents(entry_id, kind, body) VALUES (?, 'metadata', ?)`, Args: []any{id, metadata}},
	)
	statements = append(statements, tagStatements(id, post.Tags)...)
	if _, err := s.db.Transaction(ctx, statements); err != nil {
		return err
	}
	report.Assets += len(assets)
	return nil
}

type stagedMigrationAsset struct {
	id, relative, kind, mime, sha256, stagedPath string
	size                                         int64
}

func stageMigrationAsset(stage *stageDir, source, relative, kind, mimeType string) (stagedMigrationAsset, error) {
	assetID, err := NewID()
	if err != nil {
		return stagedMigrationAsset{}, err
	}
	target := stage.assetPath(assetID)
	digest, err := copyFile(source, target)
	if err != nil {
		return stagedMigrationAsset{}, err
	}
	if mimeType == "" {
		mimeType = guessMIME(relative)
	}
	if kind == "" {
		kind = kindFor(relative, mimeType)
	}
	info, err := os.Stat(source)
	if err != nil {
		return stagedMigrationAsset{}, err
	}
	return stagedMigrationAsset{
		id: assetID, relative: relative, kind: kind, mime: mimeType,
		sha256: fmt.Sprintf("%x", digest), stagedPath: target, size: info.Size(),
	}, nil
}

func legacyMediaPath(root, remoteURL string) string {
	// The legacy cache key is the SHA-1 of the resolved URL (photos use the
	// `name=large` variant), with a short filename prefix. Check the candidate
	// keys rather than duplicating the whole cache writer here.
	entries, err := os.ReadDir(root)
	if err != nil {
		return ""
	}
	names := map[string]bool{}
	for _, entry := range entries {
		if !entry.IsDir() {
			names[entry.Name()] = true
		}
	}
	for _, candidate := range legacyURLCandidates(remoteURL) {
		digest := legacySHA1(candidate)
		prefix := digest[:16]
		for name := range names {
			if strings.HasPrefix(name, prefix) {
				return filepath.Join(root, name)
			}
		}
	}
	return ""
}

func legacyURLCandidates(remoteURL string) []string {
	candidates := []string{remoteURL}
	parsed, err := url.Parse(remoteURL)
	if err != nil || !strings.Contains(parsed.Host, "pbs.twimg.com") ||
		strings.HasPrefix(parsed.Path, "/profile_images/") ||
		strings.HasPrefix(parsed.Path, "/profile_banners/") {
		return candidates
	}
	query := parsed.Query()
	query.Del("name")
	query.Set("name", "large")
	parsed.RawQuery = query.Encode()
	candidates = append([]string{parsed.String()}, candidates...)
	return candidates
}

func legacySHA1(value string) string {
	sum := sha1.Sum([]byte(value))
	return hex.EncodeToString(sum[:])
}

func guessMIME(name string) string {
	if mimeType := mime.TypeByExtension(strings.ToLower(filepath.Ext(name))); mimeType != "" {
		return mimeType
	}
	return "application/octet-stream"
}

func legacyText(value any) string {
	switch value := value.(type) {
	case string:
		return value
	case []byte:
		return string(value)
	case nil:
		return ""
	default:
		return fmt.Sprint(value)
	}
}

func legacyInt(value any) int64 {
	switch value := value.(type) {
	case int64:
		return value
	case int:
		return int64(value)
	case float64:
		return int64(value)
	case string:
		parsed, _ := strconv.ParseInt(value, 10, 64)
		return parsed
	default:
		return 0
	}
}
