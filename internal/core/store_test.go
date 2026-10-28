package core

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAppSearchIncludesEntriesBeyondCLIDefaultLimit(t *testing.T) {
	ctx := context.Background()
	store, err := Open(ctx, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	for range 55 {
		if _, err := store.Import(ctx, Import{Title: "焦点示例", TextName: "FocusState.swift", Text: "// 输入框焦点\n@FocusState var input = false\n.focused($input)"}); err != nil {
			t.Fatal(err)
		}
	}
	for _, test := range []struct {
		options SearchOptions
		count   int
	}{
		{SearchOptions{}, 50},
		{SearchOptions{AllResults: true}, 55},
		{SearchOptions{Query: "焦点 FocusState", AllResults: true}, 55},
		{SearchOptions{Query: ".focused($input)", Limit: 2}, 2},
		{SearchOptions{Limit: 500}, 55},
	} {
		results, err := store.Search(ctx, test.options)
		if err != nil || len(results) != test.count {
			t.Fatalf("检索 %+v: %d 条，预期 %d，错误 %v", test.options, len(results), test.count, err)
		}
		if len(results) > 0 && results[0].Assets[0].Kind != "code" {
			t.Fatal("有代码文件名的文本输入应按代码录入")
		}
	}
}

func TestDataVersionSeesOtherConnections(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	app, err := Open(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	before, err := app.DataVersion(ctx)
	if err != nil {
		t.Fatal(err)
	}
	other, err := Open(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if _, err := other.Import(ctx, Import{Title: "外部录入", Text: "从 CLI 写入"}); err != nil {
		t.Fatal(err)
	}
	after, err := app.DataVersion(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if after == before {
		t.Fatalf("其他连接提交后 data_version 未变化: %d", after)
	}
	if _, err := app.Import(ctx, Import{Title: "应用内录入", Text: "应用自己写入"}); err != nil {
		t.Fatal(err)
	}
	if own, err := app.DataVersion(ctx); err != nil || own != after {
		t.Fatalf("本连接提交不应改变 data_version: %d -> %d, %v", after, own, err)
	}
}

func TestUTF8BoundaryAndExistingMissingTextIndex(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "说明.md")
	content := strings.Repeat("a", 511) + "焦点 FocusState mixed_identifier\n完整中文说明"
	if err := os.WriteFile(source, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	libraryRoot := filepath.Join(root, "library")
	store, err := Open(ctx, libraryRoot)
	if err != nil {
		t.Fatal(err)
	}
	entry, err := store.Import(ctx, Import{Paths: []string{source}})
	if err != nil {
		t.Fatal(err)
	}
	if !entry.Assets[0].Readable {
		t.Fatal("512 字节处截断中文字符不能使完整文档变为不可读")
	}
	if _, err := store.db.Execute(ctx, "DELETE FROM documents WHERE asset_id = ?", entry.Assets[0].ID); err != nil {
		t.Fatal(err)
	}
	store.Close()
	if err := os.Remove(source); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		store, err = Open(ctx, libraryRoot)
		if err != nil {
			t.Fatal(err)
		}
		results, err := store.Search(ctx, SearchOptions{Query: "焦点 FocusState mixed_identifier"})
		if err != nil || len(results) != 1 || !results[0].Assets[0].Readable {
			t.Fatalf("应从库内原件恢复中文与代码索引: %+v %v", results, err)
		}
		body, err := store.AssetText(ctx, entry.ID, "说明.md")
		if err != nil || body != content {
			t.Fatalf("恢复索引不能截断或重复正文: %v", err)
		}
		store.Close()
	}
}

func importFixture(t *testing.T) (*Store, Entry, string) {
	t.Helper()
	root := t.TempDir()
	source := filepath.Join(root, "SwiftUI FocusState")
	if err := os.MkdirAll(source, 0o700); err != nil {
		t.Fatal(err)
	}
	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(source, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("README.md", "# SwiftUI FocusState\n用 @FocusState 跟踪输入框焦点，聚焦时显示边框。")
	write("TheFocusState.swift", "struct TheFocusState: View {\n@FocusState var istyping\n}")
	write("demo.mp4", "0123456789")
	store, err := Open(context.Background(), filepath.Join(root, "library"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	entry, err := store.Import(context.Background(), Import{Paths: []string{source}, Tags: []string{"swiftui:SwiftUI 开发"}})
	if err != nil {
		t.Fatal(err)
	}
	return store, entry, source
}

func TestDirectoryImportIsSelfContained(t *testing.T) {
	store, entry, source := importFixture(t)
	if len(entry.Assets) != 3 {
		t.Fatalf("应保留三个附件，实际为 %+v", entry.Assets)
	}
	if entry.Title != "SwiftUI FocusState" || entry.Tags[0] != "swiftui" {
		t.Fatalf("条目元数据错误: %+v", entry)
	}
	if err := os.RemoveAll(source); err != nil {
		t.Fatal(err)
	}
	body, err := store.AssetText(context.Background(), entry.ShortID(), "TheFocusState.swift")
	if err != nil || !strings.Contains(body, "@FocusState") {
		t.Fatalf("源目录删除后无法读取代码: %q %v", body, err)
	}
	for _, asset := range entry.Assets {
		path, _, err := store.AssetPath(context.Background(), asset.ID)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(path); err != nil {
			t.Errorf("附件没有保存在内容库中: %v", err)
		}
	}
}

func TestSearchReturnsAssetAndLocation(t *testing.T) {
	store, entry, _ := importFixture(t)
	for _, test := range []struct{ query, path string }{
		{"焦点", "README.md"},
		{"FocusState", "README.md"},
		{"istyping", "TheFocusState.swift"},
		{"不存在的词", ""},
	} {
		results, err := store.Search(context.Background(), SearchOptions{Query: test.query})
		if err != nil {
			t.Fatal(err)
		}
		if test.path == "" {
			if len(results) != 0 {
				t.Fatalf("查询 %q 不应命中", test.query)
			}
			continue
		}
		if len(results) == 0 || results[0].ID != entry.ID {
			t.Fatalf("查询 %q 未命中: %+v", test.query, results)
		}
		found := false
		for _, match := range results[0].Matches {
			if match.Path == test.path && match.Line > 0 {
				found = true
			}
		}
		if !found {
			t.Fatalf("查询 %q 没有定位到 %s: %+v", test.query, test.path, results[0].Matches)
		}
	}
}

func TestPatchDoesNotTouchOriginalAssets(t *testing.T) {
	store, entry, _ := importFixture(t)
	summary := "SwiftUI focus styling with FocusState and a rounded border."
	patched, err := store.Patch(context.Background(), entry.ShortID(), Patch{
		Summary: &summary, AssetTexts: map[string]string{"demo.mp4": "点击输入框时边框亮起。"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if patched.Summary != summary || patched.UpdatedAt.Before(entry.UpdatedAt) {
		t.Fatalf("更新失败: %+v", patched)
	}
	results, err := store.Search(context.Background(), SearchOptions{Query: "边框亮起"})
	if err != nil || len(results) != 1 {
		t.Fatalf("媒体说明没有入索引: %+v %v", results, err)
	}
	body, err := store.AssetText(context.Background(), entry.ID, "TheFocusState.swift")
	if err != nil || !strings.Contains(body, "@FocusState") {
		t.Fatal("更新媒体说明影响了代码")
	}
}

func TestFailedImportLeavesNoEntry(t *testing.T) {
	root := t.TempDir()
	store, err := Open(context.Background(), filepath.Join(root, "library"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, err = store.Import(context.Background(), Import{Paths: []string{filepath.Join(root, "missing")}})
	if err == nil {
		t.Fatal("缺失目录不应录入成功")
	}
	entries, err := store.Search(context.Background(), SearchOptions{})
	if err != nil || len(entries) != 0 {
		t.Fatalf("失败录入留下条目: %+v %v", entries, err)
	}
}

func TestImportRejectsUnknownTagsBeforeWriting(t *testing.T) {
	root := t.TempDir()
	store, err := Open(context.Background(), filepath.Join(root, "library"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	text := "body"
	_, err = store.Import(context.Background(), Import{Text: text, Tags: []string{"missing"}})
	if err == nil {
		t.Fatal("未知标签不应被静默忽略")
	}
	entries, _ := store.Search(context.Background(), SearchOptions{})
	if len(entries) != 0 {
		t.Fatal("失败录入留下了条目")
	}
}

func TestDuplicateContentSharesBlobButNotAsset(t *testing.T) {
	store, first, source := importFixture(t)
	second, err := store.Import(context.Background(), Import{Paths: []string{source}})
	if err != nil {
		t.Fatal(err)
	}
	if first.Assets[0].ID == second.Assets[0].ID || first.Assets[0].SHA256 != second.Assets[0].SHA256 {
		t.Fatal("内容去重不应合并附件身份")
	}
}

func TestPruneRemovesOnlyUnreferencedBlobs(t *testing.T) {
	ctx := context.Background()
	store, err := Open(ctx, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	kept, err := store.Import(ctx, Import{Title: "保留", TextName: "kept.swift", Text: "// kept"})
	if err != nil {
		t.Fatal(err)
	}
	dropped, err := store.Import(ctx, Import{Title: "删除", TextName: "dropped.swift", Text: "// dropped"})
	if err != nil {
		t.Fatal(err)
	}
	orphan := dropped.Assets[0].LocalPath
	if err := store.Delete(ctx, dropped.ID); err != nil {
		t.Fatal(err)
	}
	removed, freed, err := store.Prune(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if removed != 1 || freed <= 0 {
		t.Fatalf("清理 %d 个、%d 字节，预期 1 个且释放字节", removed, freed)
	}
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatalf("无引用附件未删除: %v", err)
	}
	if _, err := os.Stat(kept.Assets[0].LocalPath); err != nil {
		t.Fatalf("在用附件被删除: %v", err)
	}
	if again, _, err := store.Prune(ctx); err != nil || again != 0 {
		t.Fatalf("重复清理: %d 个, 错误 %v", again, err)
	}
}
