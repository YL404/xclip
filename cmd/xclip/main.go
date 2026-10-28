package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/YL404/xclip/internal/core"
)

const usage = `xclip — 人和 agent 共用的本地内容库

用法:
  xclip add <文件或目录>... [--title 标题] [-s 提炼] [-n 备注] [-t 标签] [--json]
  xclip add --text-file <路径或 -> [--name 附件名] [--title 标题]
  xclip search [关键词...] [-t 标签] [--kind 类型] [--limit 数量] [--json]
  xclip show <条目> [--asset 相对路径] [--json]
  xclip update <条目> [--title 标题] [-s 提炼] [-n 备注] [-t 标签]
              [--clear-summary] [--clear-note] [--clear-tags] [--describe 路径=说明]
  xclip tags [--json]
  xclip delete <条目> [--json]
  xclip migrate --from <旧xclip.db> [--media <旧media目录>] [--to <新内容库>] [--json]

链接、文件、目录、文本都可以成为一条内容；目录默认整体作为一条。

标签使用英文 slug，或 slug:中文名称 内联创建；多个 -t 为 AND 筛选。
--home 指定内容库目录，默认 ~/.xclip；也可用 XCLIP_HOME。v2 数据库为 library.db。
JSON 使用 schema_version=2；正文、提炼和路径不截断。`

type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ",") }
func (s *stringList) Set(value string) error {
	for _, item := range strings.Split(value, ",") {
		if item = strings.TrimSpace(item); item != "" {
			*s = append(*s, item)
		}
	}
	return nil
}

// rawList 不按逗号拆分，用于说明等自由文本。
type rawList []string

func (s *rawList) String() string { return strings.Join(*s, ", ") }
func (s *rawList) Set(value string) error {
	*s = append(*s, value)
	return nil
}

type options struct {
	home         string
	json         bool
	title        string
	summary      string
	note         string
	name         string
	text         string
	asset        string
	kind         string
	limit        int
	tags         stringList
	describe     rawList
	clearSummary bool
	clearNote    bool
	clearTags    bool
}

func newFlags(name string, o *options) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&o.home, "home", "", "内容库目录")
	fs.BoolVar(&o.json, "json", false, "JSON 输出")
	return fs
}

func metadataFlags(fs *flag.FlagSet, o *options) {
	fs.StringVar(&o.title, "title", "", "标题")
	fs.StringVar(&o.summary, "summary", "", "英文提炼")
	fs.StringVar(&o.summary, "s", "", "英文提炼")
	fs.StringVar(&o.note, "note", "", "备注")
	fs.StringVar(&o.note, "n", "", "备注")
	fs.Var(&o.tags, "tag", "标签")
	fs.Var(&o.tags, "t", "标签")
}

func patchFlags(fs *flag.FlagSet, o *options) {
	fs.StringVar(&o.title, "title", "", "标题")
	fs.StringVar(&o.summary, "summary", "", "英文提炼")
	fs.StringVar(&o.summary, "s", "", "英文提炼")
	fs.StringVar(&o.note, "note", "", "备注")
	fs.StringVar(&o.note, "n", "", "备注")
	fs.BoolVar(&o.clearSummary, "clear-summary", false, "清空提炼")
	fs.BoolVar(&o.clearNote, "clear-note", false, "清空备注")
	fs.BoolVar(&o.clearTags, "clear-tags", false, "清空标签")
	fs.Var(&o.tags, "tag", "标签")
	fs.Var(&o.tags, "t", "标签")
	fs.Var(&o.describe, "describe", "附件路径=说明")
}

func run(ctx context.Context, args []string, stdout io.Writer) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprintln(stdout, usage)
		return nil
	}
	var o options
	if args[0] == "--home" {
		if len(args) < 3 {
			return errors.New("--home 后需要内容库目录和命令")
		}
		o.home, args = args[1], args[2:]
	}
	command := args[0]
	if command == "migrate" {
		return runMigrate(ctx, args[1:], stdout, &o)
	}
	fs := newFlags(command, &o)
	switch command {
	case "add":
		metadataFlags(fs, &o)
		fs.StringVar(&o.text, "text-file", "", "正文文件，- 为标准输入")
		fs.StringVar(&o.name, "name", "", "正文附件相对路径")
	case "search", "list", "index":
		fs.Var(&o.tags, "tag", "标签")
		fs.Var(&o.tags, "t", "标签")
		fs.StringVar(&o.kind, "kind", "", "附件类型")
		fs.IntVar(&o.limit, "limit", 50, "结果数量")
		fs.IntVar(&o.limit, "n", 50, "结果数量")
	case "show":
		fs.StringVar(&o.asset, "asset", "", "附件相对路径")
	case "update", "edit":
		patchFlags(fs, &o)
	case "tags":
	case "delete", "rm":
	default:
		return fmt.Errorf("未知命令 %s\n%s", args[0], usage)
	}
	positional, flags, err := parseIntermixed(fs, args[1:])
	if err == nil {
		err = fs.Parse(append(flags, positional...))
	}
	if err != nil {
		return fmt.Errorf("%w\n使用 xclip help 查看用法", err)
	}
	root, err := core.LibraryRoot(o.home)
	if err != nil {
		return err
	}
	store, err := core.Open(ctx, root)
	if err != nil {
		return err
	}
	defer store.Close()

	switch command {
	case "add":
		if fs.NArg() == 0 && o.text == "" {
			return errors.New("请提供链接、文件、目录或 --text-file")
		}
		var entry core.Entry
		if len(fs.Args()) == 1 && o.text == "" && looksLikeURL(fs.Arg(0)) {
			entry, err = store.ImportURL(ctx, fs.Arg(0), o.title, o.summary, o.note, o.tags)
		} else {
			for _, arg := range fs.Args() {
				if looksLikeURL(arg) {
					return errors.New("链接需要单独录入；文件与链接不要混在同一次 add 中")
				}
			}
			input := core.Import{Title: o.title, Summary: o.summary, Note: o.note, Paths: fs.Args(), Tags: o.tags, TextName: o.name}
			if o.text != "" {
				var data []byte
				if o.text == "-" {
					data, err = io.ReadAll(os.Stdin)
				} else {
					data, err = os.ReadFile(o.text)
				}
				if err != nil {
					return err
				}
				input.Text = string(data)
			}
			entry, err = store.Import(ctx, input)
		}
		if err != nil {
			return err
		}
		return printEntry(stdout, o.json, "entry", entry, store)
	case "search", "list", "index":
		results, err := store.Search(ctx, core.SearchOptions{Query: strings.Join(fs.Args(), " "), Tags: o.tags, Kind: o.kind, Limit: o.limit})
		if err != nil {
			return err
		}
		if o.json {
			return printJSON(stdout, map[string]any{"schema_version": 2, "results": results})
		}
		for _, result := range results {
			fmt.Fprintf(stdout, "[%s] %s\n  %s\n", result.Entry.ShortID(), result.Entry.Title, result.Entry.Summary)
			fmt.Fprintf(stdout, "  标签: %s\n", strings.Join(result.Entry.Tags, ", "))
			for _, match := range result.Matches {
				fmt.Fprintf(stdout, "  命中: %s:%d (%s)\n", match.Path, match.Line, match.Kind)
			}
		}
		return nil
	case "show":
		if fs.NArg() != 1 {
			return errors.New("show 需要一个条目编码")
		}
		entry, err := store.Get(ctx, fs.Arg(0))
		if err != nil {
			return err
		}
		if o.asset != "" {
			body, err := store.AssetText(ctx, entry.ID, o.asset)
			if err != nil {
				return err
			}
			if o.json {
				return printJSON(stdout, map[string]any{"schema_version": 2, "entry_id": entry.ID, "path": o.asset, "text": body})
			}
			fmt.Fprintln(stdout, body)
			return nil
		}
		return printEntry(stdout, o.json, "entry", entry, store)
	case "update", "edit":
		if fs.NArg() != 1 {
			return errors.New("update 需要一个条目编码")
		}
		patch := core.Patch{AssetTexts: map[string]string{}}
		if o.clearSummary {
			empty := ""
			patch.Summary = &empty
		} else if o.summary != "" {
			patch.Summary = &o.summary
		}
		if o.clearNote {
			empty := ""
			patch.Note = &empty
		} else if o.note != "" {
			patch.Note = &o.note
		}
		if o.clearTags {
			empty := []string{}
			patch.Tags = &empty
		} else if len(o.tags) > 0 {
			tags := []string(o.tags)
			patch.Tags = &tags
		}
		if o.title != "" {
			patch.Title = &o.title
		}
		for _, item := range o.describe {
			path, description, ok := strings.Cut(item, "=")
			if !ok || path == "" {
				return errors.New("--describe 格式应为 附件路径=说明")
			}
			patch.AssetTexts[path] = description
		}
		entry, err := store.Patch(ctx, fs.Arg(0), patch)
		if err != nil {
			return err
		}
		return printEntry(stdout, o.json, "entry", entry, store)
	case "tags":
		if fs.NArg() != 0 {
			return errors.New("tags 不接受位置参数")
		}
		tags, err := store.Tags(ctx)
		if err != nil {
			return err
		}
		if o.json {
			return printJSON(stdout, map[string]any{"schema_version": 2, "tags": tags})
		}
		for _, tag := range tags {
			fmt.Fprintf(stdout, "%s(%s) · %d 条\n", tag.Slug, tag.Name, tag.Count)
		}
		return nil
	case "delete", "rm":
		if fs.NArg() != 1 {
			return errors.New("delete 需要一个条目编码")
		}
		entry, err := store.Get(ctx, fs.Arg(0))
		if err != nil {
			return err
		}
		if err := store.Delete(ctx, entry.ID); err != nil {
			return err
		}
		if o.json {
			return printJSON(stdout, map[string]any{"schema_version": 2, "deleted": entry.ID, "short_id": entry.ShortID()})
		}
		fmt.Fprintf(stdout, "已删除: %s\n", entry.ShortID())
		return nil
	}
	return nil
}

func looksLikeURL(value string) bool {
	value = strings.ToLower(strings.TrimSpace(value))
	if strings.HasPrefix(value, "http://") || strings.HasPrefix(value, "https://") {
		return true
	}
	for _, host := range []string{"x.com/", "www.x.com/", "twitter.com/", "www.twitter.com/", "mobile.x.com/", "mobile.twitter.com/"} {
		if strings.HasPrefix(value, host) {
			return true
		}
	}
	return false
}

func runMigrate(ctx context.Context, args []string, stdout io.Writer, o *options) error {
	fs := flag.NewFlagSet("migrate", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&o.text, "from", "", "旧 xclip.db 路径")
	fs.StringVar(&o.name, "media", "", "旧 media 目录，默认与数据库同级")
	fs.StringVar(&o.home, "to", "", "新内容库目录")
	fs.BoolVar(&o.json, "json", false, "JSON 输出")
	positional, flags, err := parseIntermixed(fs, args)
	if err == nil {
		err = fs.Parse(append(flags, positional...))
	}
	if err != nil {
		return err
	}
	if o.text == "" {
		return errors.New("migrate 需要 --from <旧xclip.db>")
	}
	root, err := core.LibraryRoot(o.home)
	if err != nil {
		return err
	}
	store, err := core.Open(ctx, root)
	if err != nil {
		return err
	}
	defer store.Close()
	media := o.name
	if media == "" {
		media = filepath.Join(filepath.Dir(o.text), "media")
	}
	report, err := store.MigrateV1(ctx, o.text, media)
	if err != nil {
		return err
	}
	if o.json {
		return printJSON(stdout, map[string]any{"schema_version": 2, "migration": report})
	}
	fmt.Fprintf(stdout, "已迁移 %d 条内容、%d 个附件；未缓存媒体 %d 个\n", report.Entries, report.Assets, report.MissingMedia)
	return nil
}

func parseIntermixed(fs *flag.FlagSet, args []string) ([]string, []string, error) {
	var positional, flags []string
	for index := 0; index < len(args); index++ {
		arg := args[index]
		if arg == "--" {
			positional = append(positional, args[index+1:]...)
			break
		}
		if arg == "-" || !strings.HasPrefix(arg, "-") {
			positional = append(positional, arg)
			continue
		}
		name := strings.TrimLeft(arg, "-")
		if before, _, ok := strings.Cut(name, "="); ok {
			name = before
		}
		item := fs.Lookup(name)
		if item == nil {
			return nil, nil, fmt.Errorf("未知选项: %s", arg)
		}
		flags = append(flags, arg)
		if !strings.Contains(arg, "=") {
			boolean, ok := item.Value.(interface{ IsBoolFlag() bool })
			if !ok || !boolean.IsBoolFlag() {
				index++
				if index >= len(args) {
					return nil, nil, fmt.Errorf("选项 %s 缺少值", arg)
				}
				flags = append(flags, args[index])
			}
		}
	}
	return positional, flags, nil
}

func printEntry(w io.Writer, asJSON bool, key string, entry core.Entry, store *core.Store) error {
	if asJSON {
		tags, err := store.Tags(context.Background())
		if err != nil {
			return err
		}
		return printJSON(w, map[string]any{"schema_version": 2, key: entry, "short_id": entry.ShortID(), "available_tags": tags})
	}
	fmt.Fprintf(w, "[%s] %s\n提炼: %s\n备注: %s\n标签: %s\n", entry.ShortID(), entry.Title, entry.Summary, entry.Note, strings.Join(entry.Tags, ", "))
	for _, asset := range entry.Assets {
		fmt.Fprintf(w, "附件: %s (%s)\n  本地路径: %s\n", asset.Path, asset.Kind, asset.LocalPath)
	}
	return nil
}

func printJSON(w io.Writer, value any) error {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "xclip:", err)
		os.Exit(1)
	}
}
