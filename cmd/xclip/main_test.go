package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCLIFullLocalWorkflow(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "note")
	if err := os.Mkdir(source, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "README.md"), []byte("# FocusState\n输入框焦点高亮"), 0o600); err != nil {
		t.Fatal(err)
	}
	library := filepath.Join(root, "library")
	var output bytes.Buffer
	err := run(context.Background(), []string{"add", "--home", library, source, "-t", "swiftui:SwiftUI 开发", "-s", "Focus handling in SwiftUI.", "--json"}, &output)
	if err != nil {
		t.Fatal(err)
	}
	if output.Len() == 0 {
		t.Fatal("add 没有输出")
	}
	var added struct {
		Entry struct {
			ID     string `json:"id"`
			Assets []struct {
				Path      string `json:"path"`
				LocalPath string `json:"local_path"`
			} `json:"assets"`
		} `json:"entry"`
	}
	if err := json.Unmarshal(output.Bytes(), &added); err != nil {
		t.Fatalf("JSON 输出无效: %v\n%s", err, output.String())
	}
	if len(added.Entry.Assets) != 1 || added.Entry.Assets[0].Path != "README.md" {
		t.Fatalf("附件错误: %+v", added)
	}
	if _, err := os.Stat(added.Entry.Assets[0].LocalPath); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err := run(context.Background(), []string{"search", "--home", library, "焦点", "--json"}, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "README.md") {
		t.Fatalf("检索没有返回附件定位: %s", output.String())
	}
	output.Reset()
	if err := run(context.Background(), []string{"show", "--home", library, added.Entry.ID[:8], "--asset", "README.md", "--json"}, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "输入框焦点高亮") {
		t.Fatalf("完整正文未返回: %s", output.String())
	}
	output.Reset()
	if err := run(context.Background(), []string{"update", "--home", library, added.Entry.ID[:8], "--describe", "README.md=焦点说明, 含逗号", "--json"}, &output); err != nil {
		t.Fatalf("说明含逗号时报错: %v", err)
	}
	output.Reset()
	if err := run(context.Background(), []string{"search", "--home", library, "含逗号", "--json"}, &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "README.md") {
		t.Fatalf("说明未写入: %s", output.String())
	}
}

func TestParseIntermixedPreservesValues(t *testing.T) {
	var o options
	fs := newFlags("add", &o)
	metadataFlags(fs, &o)
	positionals, flags, err := parseIntermixed(fs, []string{"a directory", "-t", "swiftui:SwiftUI 开发", "-s", "A summary.", "--json"})
	if err != nil {
		t.Fatal(err)
	}
	if len(positionals) != 1 || positionals[0] != "a directory" || len(flags) != 5 {
		t.Fatalf("参数重排错误: positional=%q flags=%q", positionals, flags)
	}
	if err := fs.Parse(append(flags, positionals...)); err != nil {
		t.Fatal(err)
	}
	if len(o.tags) != 1 || o.summary != "A summary." || fs.Arg(0) != "a directory" {
		t.Fatalf("参数值错误: %+v, args=%q", o, fs.Args())
	}
}
