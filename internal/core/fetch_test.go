package core

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestWebExtractionKeepsArticleAndImages(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/article":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(`<html><head><title>Focus article</title>
				<meta name="description" content="A practical guide to focus borders."></head>
				<body><script>alert(1)</script><nav>Home</nav><h1>Focus</h1>
				<p>Use <code>@FocusState</code> for a visible border.</p>
				<img src="/image.png" onerror="alert(2)"></body></html>`))
		case "/image.png":
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write([]byte("\x89PNG\r\n\x1a\n"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	store, err := Open(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	entry, err := store.ImportURL(context.Background(), server.URL+"/article", "", "", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if entry.Title != "Focus article" || entry.Source != server.URL+"/article" {
		t.Fatalf("网页元数据错误: %+v", entry)
	}
	if len(entry.Assets) != 2 {
		t.Fatalf("正文和图片都应保存: %+v", entry.Assets)
	}
	text, err := store.AssetText(context.Background(), entry.ID, "content.md")
	if err != nil || !strings.Contains(text, "@FocusState") {
		t.Fatalf("网页正文没有保存: %q %v", text, err)
	}
	if strings.Contains(text, "alert(1)") {
		t.Fatal("脚本内容不应进入正文")
	}
	results, err := store.Search(context.Background(), SearchOptions{Query: "visible border"})
	if err != nil || len(results) != 1 {
		t.Fatalf("网页正文不可检索: %+v %v", results, err)
	}
}

func TestFailedURLStillSavesSource(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "gone", http.StatusGone)
	}))
	defer server.Close()
	store, err := Open(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	entry, err := store.ImportURL(context.Background(), server.URL, "", "", "", nil)
	if err != nil {
		t.Fatal(err)
	}
	if entry.Source != server.URL || len(entry.Assets) != 1 {
		t.Fatalf("失败时仍应保留来源链接: %+v", entry)
	}
	text, err := store.AssetText(context.Background(), entry.ID, "source-url.txt")
	if err != nil || !strings.Contains(text, server.URL) {
		t.Fatalf("来源链接不可读取: %q %v", text, err)
	}
}
