package service

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/YL404/xclip/internal/core"
)

func TestMediaHandlerServesOwnedVideoRange(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "demo.mp4")
	if err := os.WriteFile(source, []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := core.Open(context.Background(), filepath.Join(root, "library"))
	if err != nil {
		t.Fatal(err)
	}
	entry, err := store.Import(context.Background(), core.Import{Paths: []string{source}})
	if err != nil {
		t.Fatal(err)
	}
	store.Close()
	if err := os.Remove(source); err != nil {
		t.Fatal(err)
	}
	library := NewLibrary(filepath.Join(root, "library"))
	request := httptest.NewRequest("GET", "xclip-media://localhost/"+entry.Assets[0].ID, nil)
	request.Header.Set("Range", "bytes=2-5")
	response := httptest.NewRecorder()
	MediaHandler(library).ServeHTTP(response, request)
	if response.Code != 206 || response.Body.String() != "2345" {
		t.Fatalf("自有视频 Range 请求失败: %d %q", response.Code, response.Body.String())
	}
	for _, target := range []string{"../../xclip.db", "../secret", "unknown"} {
		response := httptest.NewRecorder()
		MediaHandler(library).ServeHTTP(response, httptest.NewRequest("GET", "xclip-media://localhost/"+target, nil))
		if response.Code != 404 {
			t.Errorf("非附件 ID %q 不应返回内容: %d", target, response.Code)
		}
	}
	library.Close()
}
