package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image/jpeg"
	"math"
	"os"
	"path/filepath"
	"strings"
)

type Preview struct {
	Poster   bool    `json:"poster"`
	Duration float64 `json:"duration"`
}

// 封面由系统 WebView 解码，Go 仅按已验证附件的内容哈希保存可重建缓存。
func (l *Library) previewPath(ctx context.Context, id string) (string, error) {
	path, name, err := l.serve(ctx, id)
	if err != nil {
		return "", err
	}
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi":
	default:
		return "", fmt.Errorf("此附件不支持视频封面")
	}
	return filepath.Join(l.root, "cache", "previews", filepath.Base(path)+"-v1"), nil
}

func (l *Library) Preview(ctx context.Context, id string) (Preview, error) {
	path, err := l.previewPath(ctx, id)
	if err != nil {
		return Preview{}, err
	}
	data, err := os.ReadFile(path + ".json")
	var preview Preview
	if err != nil || json.Unmarshal(data, &preview) != nil {
		return Preview{}, nil
	}
	if _, err := os.Stat(path + ".jpg"); err != nil {
		return Preview{}, nil
	}
	return preview, nil
}

func (l *Library) CachePreview(ctx context.Context, id, poster string, duration float64) error {
	path, err := l.previewPath(ctx, id)
	if err != nil {
		return err
	}
	if duration <= 0 || math.IsNaN(duration) || math.IsInf(duration, 0) {
		return fmt.Errorf("视频时长无效")
	}
	const prefix = "data:image/jpeg;base64,"
	if len(poster) > 2*1024*1024 || !strings.HasPrefix(poster, prefix) {
		return fmt.Errorf("封面必须为不超过 2 MB 的 JPEG 图片")
	}
	data, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(poster, prefix))
	if err != nil {
		return fmt.Errorf("封面编码无效")
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width > 1280 || config.Height > 1280 {
		return fmt.Errorf("封面尺寸或格式无效")
	}
	if _, err := jpeg.Decode(bytes.NewReader(data)); err != nil {
		return fmt.Errorf("封面图片不完整")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	metadata, err := json.Marshal(Preview{Poster: true, Duration: duration})
	if err != nil {
		return err
	}
	for _, file := range []struct {
		suffix string
		data   []byte
	}{{".jpg", data}, {".json", metadata}} {
		if err := writePreview(path+file.suffix, file.data); err != nil {
			return err
		}
	}
	return nil
}

func writePreview(path string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".preview-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(data)
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), path)
}
