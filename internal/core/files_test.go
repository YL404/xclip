package core

import (
	"os"
	"path/filepath"
	"testing"
)

func TestKindForTreatsShaderSourceAsCode(t *testing.T) {
	if kind := kindFor("Helpers/AlphaThreshold.metal", "text/plain; charset=utf-8"); kind != "code" {
		t.Fatalf("Metal 着色器应按代码录入，得到 %s", kind)
	}
}

func TestCollectFilesSkipsMacMetadata(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		".DS_Store": "junk",
		"._Icon\r":  "junk",
		"Sky.swift": "// sky",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	files, _, _, err := collectFiles([]string{dir})
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].relative != "Sky.swift" {
		t.Fatalf("应只收录普通文件，得到 %+v", files)
	}
}
