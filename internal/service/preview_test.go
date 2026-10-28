package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"image"
	"image/jpeg"
	"math"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestPreviewUsesOwnedVideoAndValidatesCache(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	source := filepath.Join(root, "demo.mp4")
	original := []byte("owned video bytes")
	if err := os.WriteFile(source, original, 0o600); err != nil {
		t.Fatal(err)
	}
	library := NewLibrary(filepath.Join(root, "library"))
	defer library.Close()
	entry, err := library.Import(ctx, []string{source})
	if err != nil {
		t.Fatal(err)
	}
	asset := entry.Assets[0]
	if err := os.Remove(source); err != nil {
		t.Fatal(err)
	}
	preview, err := library.Preview(ctx, asset.ID)
	if err != nil || preview.Poster {
		t.Fatalf("未生成缓存: %+v %v", preview, err)
	}
	var buffer bytes.Buffer
	if err := jpeg.Encode(&buffer, image.NewRGBA(image.Rect(0, 0, 32, 18)), nil); err != nil {
		t.Fatal(err)
	}
	poster := "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(buffer.Bytes())
	for _, input := range []struct {
		id, poster string
		duration   float64
	}{
		{"../../outside", poster, 14}, {asset.ID, "data:image/svg+xml;base64,PHN2Zz4=", 14},
		{asset.ID, "data:image/jpeg;base64,invalid", 14}, {asset.ID, poster, math.NaN()},
		{asset.ID, poster, math.Inf(1)}, {asset.ID, poster, -1},
	} {
		if err := library.CachePreview(ctx, input.id, input.poster, input.duration); err == nil {
			t.Errorf("无效封面应被拒绝: %+v", input)
		}
	}
	if err := library.CachePreview(ctx, asset.ID, poster, 14); err != nil {
		t.Fatal(err)
	}
	preview, err = library.Preview(ctx, asset.ID)
	if err != nil || !preview.Poster || preview.Duration != 14 {
		t.Fatalf("缓存元数据: %+v %v", preview, err)
	}
	response := httptest.NewRecorder()
	MediaHandler(library).ServeHTTP(response, httptest.NewRequest("GET", "xclip-media://localhost/"+asset.ID+"?preview=1", nil))
	if response.Code != 200 || response.Header().Get("Content-Type") != "image/jpeg" || !bytes.Equal(response.Body.Bytes(), buffer.Bytes()) {
		t.Fatalf("封面资源读取失败: %d", response.Code)
	}
	owned, err := os.ReadFile(asset.LocalPath)
	if err != nil || !bytes.Equal(owned, original) {
		t.Fatalf("生成封面不能修改原件: %v", err)
	}
	response = httptest.NewRecorder()
	MediaHandler(library).ServeHTTP(response, httptest.NewRequest("GET", "xclip-media://localhost/unknown?preview=1", nil))
	if response.Code != 404 {
		t.Fatalf("未知附件不应暴露缓存: %d", response.Code)
	}
}
