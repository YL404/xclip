package core

import (
	"fmt"
	"io"
	"io/fs"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

const maxTextBytes = 4 << 20

type sourceFile struct {
	path     string
	relative string
}

func collectFiles(inputs []string) ([]sourceFile, string, string, error) {
	var files []sourceFile
	var title, source string
	for _, input := range inputs {
		absolute, err := filepath.Abs(input)
		if err != nil {
			return nil, "", "", err
		}
		info, err := os.Stat(absolute)
		if err != nil {
			return nil, "", "", fmt.Errorf("无法读取 %s: %w", input, err)
		}
		if source != "" {
			source += "\n"
		}
		source += absolute
		if title == "" {
			title = info.Name()
		}
		if !info.IsDir() {
			if !info.Mode().IsRegular() {
				return nil, "", "", fmt.Errorf("只能录入普通文件或目录: %s", input)
			}
			files = append(files, sourceFile{path: absolute, relative: info.Name()})
			continue
		}
		root := filepath.Clean(absolute) + string(os.PathSeparator)
		err = filepath.WalkDir(absolute, func(filePath string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			// macOS 会在目录里留下 .DS_Store 和 AppleDouble 文件，不属于内容。
			if name := entry.Name(); name == ".DS_Store" || strings.HasPrefix(name, "._") {
				return nil
			}
			if entry.Type()&os.ModeSymlink != 0 {
				if entry.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if entry.IsDir() {
				return nil
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if !info.Mode().IsRegular() {
				return nil
			}
			files = append(files, sourceFile{path: filePath, relative: filepath.ToSlash(strings.TrimPrefix(filePath, root))})
			return nil
		})
		if err != nil {
			return nil, "", "", fmt.Errorf("无法遍历 %s: %w", input, err)
		}
	}
	if len(files) == 0 {
		return nil, "", "", fmt.Errorf("目录中没有可录入的普通文件")
	}
	if len(inputs) > 1 {
		title = "收录内容"
	}
	return files, title, source, nil
}

func readAssetFile(filePath, name string) (kind, mimeType string, size int64, text, textKind string, readable bool, err error) {
	file, err := os.Open(filePath)
	if err != nil {
		return "", "", 0, "", "", false, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", "", 0, "", "", false, err
	}
	size = info.Size()
	prefix := make([]byte, 512)
	n, readErr := io.ReadFull(file, prefix)
	if readErr != nil && readErr != io.EOF && readErr != io.ErrUnexpectedEOF {
		return "", "", 0, "", "", false, readErr
	}
	prefix = prefix[:n]
	mimeType = mime.TypeByExtension(strings.ToLower(filepath.Ext(name)))
	if mimeType == "" {
		mimeType = http.DetectContentType(prefix)
	}
	kind = kindFor(name, mimeType)
	if kind == "text" || kind == "code" {
		if size <= maxTextBytes {
			data, err := os.ReadFile(filePath)
			if err != nil {
				return "", "", 0, "", "", false, err
			}
			if utf8.Valid(data) {
				text = string(data)
				textKind = kind
				readable = true
			}
		}
	}
	return kind, mimeType, size, text, textKind, readable, nil
}

func kindFor(name, mimeType string) string {
	ext := strings.ToLower(path.Ext(name))
	if codeExtensions[ext] {
		return "code"
	}
	if strings.HasPrefix(mimeType, "image/") {
		return "image"
	}
	if strings.HasPrefix(mimeType, "video/") {
		return "video"
	}
	if strings.HasPrefix(mimeType, "audio/") {
		return "audio"
	}
	if strings.HasPrefix(mimeType, "text/") || ext == ".pdf" || ext == ".json" || ext == ".xml" || ext == ".yaml" || ext == ".yml" {
		return "text"
	}
	return "file"
}

var codeExtensions = map[string]bool{
	".c": true, ".cc": true, ".cpp": true, ".css": true, ".go": true,
	".h": true, ".html": true, ".java": true, ".js": true, ".jsx": true,
	".kt": true, ".m": true, ".metal": true, ".mm": true, ".php": true, ".py": true,
	".rb": true, ".rs": true, ".sh": true, ".sql": true, ".swift": true,
	".ts": true, ".tsx": true, ".vue": true, ".zig": true,
}

func cleanRelative(name string) (string, error) {
	name = path.Clean(filepath.ToSlash(name))
	if name == "." || name == "" || name == ".." || strings.HasPrefix(name, "../") || path.IsAbs(name) {
		return "", fmt.Errorf("无效的附件相对路径: %s", name)
	}
	return name, nil
}
