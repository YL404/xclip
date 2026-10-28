package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const maxFetchBytes = 20 << 20

type fetchedRemote struct {
	Title  string
	Text   string
	Source string
	Assets []remoteAsset
}

type remoteAsset struct {
	Name        string
	URL         string
	ContentType string
}

type fetcher struct {
	client *http.Client
}

func newFetcher() *fetcher {
	return &fetcher{client: &http.Client{Timeout: 45 * time.Second}}
}

// ImportURL saves the canonical URL even when the remote source cannot be read.
// That distinction matters for an agent workflow: a temporary network failure
// must not lose the user's intent to archive a page.
func (s *Store) ImportURL(ctx context.Context, rawURL, title, summary, note string, tags []string) (Entry, error) {
	canonical, err := canonicalURL(rawURL)
	if err != nil {
		return Entry{}, err
	}
	if summary != "" {
		summary, err = ValidateSummary(summary)
		if err != nil {
			return Entry{}, err
		}
	}
	remote, fetchErr := newFetcher().fetch(ctx, canonical)
	if remote == nil {
		remote = &fetchedRemote{Source: canonical, Title: title}
	}
	if title == "" {
		title = remote.Title
	}
	if title == "" {
		title = canonical
	}
	if remote.Text != "" {
		return s.importFetched(ctx, remote, title, summary, note, tags)
	}
	// Text-only fallback: keep the URL itself searchable and readable.
	return s.Import(ctx, Import{
		Title: title, Summary: summary, Note: note, Source: canonical,
		Text: canonical + "\n" + describeFetchFailure(fetchErr), TextName: "source-url.txt", Tags: tags,
	})
}

func describeFetchFailure(err error) string {
	if err == nil {
		return "页面没有返回可提取的正文。"
	}
	return "抓取失败，已保留来源链接：" + err.Error()
}

func (s *Store) importFetched(ctx context.Context, remote *fetchedRemote, title, summary, note string, tags []string) (Entry, error) {
	var files []sourceFile
	cleanup := func() {}
	defer func() { cleanup() }()
	tempDir, err := os.MkdirTemp("", "xclip-fetch-")
	if err != nil {
		return Entry{}, err
	}
	cleanup = func() { _ = os.RemoveAll(tempDir) }
	if remote.Text != "" {
		textPath := filepath.Join(tempDir, "content.md")
		if err := os.WriteFile(textPath, []byte(remote.Text), 0o600); err != nil {
			return Entry{}, err
		}
		files = append(files, sourceFile{path: textPath, relative: "content.md"})
	}
	for index, asset := range remote.Assets {
		name := asset.Name
		if name == "" {
			name = fmt.Sprintf("media-%d", index+1)
		}
		name = filepath.Base(name)
		if ext := extensionFor(asset.ContentType, asset.URL); ext != "" && filepath.Ext(name) == "" {
			name += ext
		}
		target := filepath.Join(tempDir, name)
		if err := newFetcher().download(ctx, asset.URL, target); err != nil {
			// A media failure does not lose the text snapshot.
			continue
		}
		files = append(files, sourceFile{path: target, relative: name})
	}
	if len(files) == 0 {
		return Entry{}, errors.New("抓取结果中没有可保存的正文")
	}
	input := Import{Title: title, Summary: summary, Note: note, Source: remote.Source, Tags: tags}
	// Import's title default would use the first file's name; the URL page's title
	// is more useful. The temporary files remain only for the duration of Import.
	for _, file := range files {
		input.Paths = append(input.Paths, file.path)
	}
	input.Title = title
	return s.importFiles(ctx, input, files)
}

func canonicalURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", errors.New("链接不能为空")
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" {
		return "", fmt.Errorf("无效链接: %s", raw)
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", fmt.Errorf("只支持 http/https 链接")
	}
	parsed.Fragment = ""
	parsed.Host = strings.ToLower(parsed.Host)
	parsed.Scheme = strings.ToLower(parsed.Scheme)
	return parsed.String(), nil
}

func (f *fetcher) fetch(ctx context.Context, source string) (*fetchedRemote, error) {
	if ref, ok := xPostRef(source); ok {
		return f.fetchX(ctx, ref)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", "xclip/0.2 (+local content library)")
	request.Header.Set("Accept", "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.2")
	response, err := f.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	contentType := response.Header.Get("Content-Type")
	body, err := io.ReadAll(io.LimitReader(response.Body, maxFetchBytes))
	if err != nil {
		return nil, err
	}
	text, title, assets := extractWeb(string(body), contentType, source)
	return &fetchedRemote{Title: title, Text: text, Source: source, Assets: assets}, nil
}

func (f *fetcher) download(ctx context.Context, source, destination string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return err
	}
	response, err := f.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("HTTP %d", response.StatusCode)
	}
	file, err := os.Create(destination)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(file, io.LimitReader(response.Body, maxFetchBytes))
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

type xRef struct {
	ID     string
	Handle string
	URL    string
}

func xPostRef(source string) (xRef, bool) {
	parsed, err := url.Parse(source)
	if err != nil {
		return xRef{}, false
	}
	host := strings.TrimPrefix(strings.ToLower(parsed.Host), "www.")
	if host != "x.com" && host != "twitter.com" && host != "mobile.x.com" && host != "mobile.twitter.com" {
		return xRef{}, false
	}
	parts := strings.Split(strings.Trim(parsed.Path, "/"), "/")
	if len(parts) < 3 || parts[1] != "status" {
		return xRef{}, false
	}
	id := parts[2]
	if id == "" {
		return xRef{}, false
	}
	for _, r := range id {
		if r < '0' || r > '9' {
			return xRef{}, false
		}
	}
	return xRef{ID: id, Handle: parts[0], URL: "https://x.com/" + parts[0] + "/status/" + id}, true
}

type fxResponse struct {
	Code    int      `json:"code"`
	Message string   `json:"message"`
	Tweet   *fxTweet `json:"tweet"`
}

type fxTweet struct {
	ID     string `json:"id"`
	Text   string `json:"text"`
	Author struct {
		ScreenName string `json:"screen_name"`
		Name       string `json:"name"`
		AvatarURL  string `json:"avatar_url"`
	} `json:"author"`
	Media *struct {
		All []struct {
			Type         string `json:"type"`
			URL          string `json:"url"`
			ThumbnailURL string `json:"thumbnail_url"`
		} `json:"all"`
	} `json:"media"`
}

func (f *fetcher) fetchX(ctx context.Context, ref xRef) (*fetchedRemote, error) {
	if ref.Handle == "i" {
		return nil, errors.New("该 X 链接不带用户名，无法抓取；可以稍后手动补充正文")
	}
	endpoint := "https://api.fxtwitter.com/" + url.PathEscape(ref.Handle) + "/status/" + ref.ID
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	response, err := f.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fxtwitter HTTP %d", response.StatusCode)
	}
	var payload fxResponse
	if err := json.NewDecoder(io.LimitReader(response.Body, maxFetchBytes)).Decode(&payload); err != nil {
		return nil, err
	}
	if payload.Code != 200 || payload.Tweet == nil {
		return nil, fmt.Errorf("fxtwitter: %s", payload.Message)
	}
	tweet := payload.Tweet
	result := &fetchedRemote{
		Title:  tweet.Author.Name + " · X",
		Text:   tweet.Text,
		Source: "https://x.com/" + strings.ToLower(tweet.Author.ScreenName) + "/status/" + tweet.ID,
	}
	if tweet.Media != nil {
		for index, item := range tweet.Media.All {
			if item.Type != "photo" && item.Type != "video" && item.Type != "gif" {
				continue
			}
			source := item.URL
			if item.Type == "video" && source == "" {
				source = item.ThumbnailURL
			}
			if source == "" {
				continue
			}
			name := fmt.Sprintf("%s-%d", item.Type, index+1)
			result.Assets = append(result.Assets, remoteAsset{Name: name, URL: source})
		}
	}
	return result, nil
}

var (
	titlePattern = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
	scriptStyle  = regexp.MustCompile(`(?is)<(?:script|style|noscript|svg|template)[^>]*>.*?</(?:script|style|noscript|svg|template)>`)
	tagPattern   = regexp.MustCompile(`(?is)<[^>]+>`)
	spacePattern = regexp.MustCompile(`[ \t\f\v]+`)
	imagePattern = regexp.MustCompile(`(?is)<img\b[^>]*\bsrc=["']([^"']+)["'][^>]*>`)
	metaTitle    = regexp.MustCompile(`(?is)<meta[^>]+(?:property|name)=["']og:title["'][^>]+content=["']([^"']+)["']`)
	metaDesc     = regexp.MustCompile(`(?is)<meta[^>]+(?:property|name)=["'](?:og:description|description)["'][^>]+content=["']([^"']+)["']`)
)

func extractWeb(body, contentType, source string) (text, title string, assets []remoteAsset) {
	if strings.Contains(contentType, "text/plain") || (!strings.Contains(contentType, "html") && !strings.Contains(body, "<html")) {
		return body, filepath.Base(source), nil
	}
	if match := metaTitle.FindStringSubmatch(body); len(match) > 1 {
		title = html.UnescapeString(strings.TrimSpace(match[1]))
	}
	if title == "" {
		if match := titlePattern.FindStringSubmatch(body); len(match) > 1 {
			title = html.UnescapeString(strings.TrimSpace(match[1]))
		}
	}
	body = scriptStyle.ReplaceAllString(body, " ")
	for _, match := range imagePattern.FindAllStringSubmatch(body, 20) {
		ref, err := url.Parse(strings.TrimSpace(match[1]))
		if err != nil {
			continue
		}
		base, err := url.Parse(source)
		if err != nil {
			continue
		}
		absolute := base.ResolveReference(ref)
		if absolute.Scheme != "http" && absolute.Scheme != "https" {
			continue
		}
		assets = append(assets, remoteAsset{Name: fmt.Sprintf("image-%d", len(assets)+1), URL: absolute.String()})
	}
	if match := metaDesc.FindStringSubmatch(body); len(match) > 1 {
		text = html.UnescapeString(strings.TrimSpace(match[1])) + "\n\n"
	}
	body = tagPattern.ReplaceAllString(body, "\n")
	body = html.UnescapeString(body)
	lines := strings.Split(body, "\n")
	var clean []string
	for _, line := range lines {
		line = strings.TrimSpace(spacePattern.ReplaceAllString(line, " "))
		if line != "" {
			clean = append(clean, line)
		}
	}
	text += strings.Join(clean, "\n")
	return text, title, assets
}

func extensionFor(contentType, source string) string {
	parsed, err := url.Parse(source)
	if err == nil && filepath.Ext(parsed.Path) != "" {
		return filepath.Ext(parsed.Path)
	}
	if contentType != "" {
		if ext, err := mime.ExtensionsByType(contentType); err == nil && len(ext) > 0 {
			return ext[0]
		}
	}
	return ""
}
