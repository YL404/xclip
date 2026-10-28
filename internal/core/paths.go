package core

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

func DefaultLibraryRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".xclip"), nil
}

func LibraryRoot(explicit string) (string, error) {
	if explicit == "" {
		explicit = os.Getenv("XCLIP_HOME")
	}
	if explicit == "" {
		return DefaultLibraryRoot()
	}
	if strings.HasPrefix(explicit, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		explicit = filepath.Join(home, explicit[2:])
	}
	return filepath.Abs(explicit)
}

func DatabasePath(root string) string { return filepath.Join(root, "library.db") }

var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

func NormalizeSlug(raw string) (string, error) {
	for _, r := range raw {
		if r > 127 && (unicode.IsLetter(r) || unicode.IsNumber(r)) {
			return "", fmt.Errorf("标签 slug 必须使用 ASCII 字母和数字")
		}
	}
	slug := nonSlug.ReplaceAllString(strings.ToLower(strings.TrimSpace(raw)), "-")
	slug = strings.Trim(slug, "-")
	if slug == "" {
		return "", fmt.Errorf("标签 slug 不能为空")
	}
	return slug, nil
}

func NormalizeTagName(raw string) (string, error) {
	name := strings.TrimSpace(raw)
	if name == "" || strings.ContainsAny(name, "\r\n") {
		return "", fmt.Errorf("标签中文名称无效")
	}
	for _, r := range name {
		if r >= 0x3400 && r <= 0x9fff {
			return name, nil
		}
	}
	return "", fmt.Errorf("标签名称必须包含中文字符")
}

func ParseTag(raw string) (slug, name string, err error) {
	separator := strings.IndexAny(raw, ":：")
	if separator < 0 {
		slug, err = NormalizeSlug(raw)
		return slug, "", err
	}
	slug, err = NormalizeSlug(raw[:separator])
	if err != nil {
		return "", "", err
	}
	_, separatorSize := utf8.DecodeRuneInString(raw[separator:])
	name, err = NormalizeTagName(raw[separator+separatorSize:])
	return slug, name, err
}

func ShortID(id string) string {
	id = strings.ReplaceAll(strings.ToLower(id), "-", "")
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

func NewID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	id[6] = id[6]&0x0f | 0x40
	id[8] = id[8]&0x3f | 0x80
	return fmt.Sprintf("%s-%s-%s-%s-%s", hex.EncodeToString(id[0:4]), hex.EncodeToString(id[4:6]), hex.EncodeToString(id[6:8]), hex.EncodeToString(id[8:10]), hex.EncodeToString(id[10:16])), nil
}

func ValidateSummary(raw string) (string, error) {
	summary := strings.TrimSpace(raw)
	if len(summary) > 400 || strings.ContainsAny(summary, "\r\n") {
		return "", fmt.Errorf("提炼必须为不超过 400 字符的单行英文")
	}
	for _, r := range summary {
		if r >= 0x2e80 && r <= 0x9fff || r >= 0xac00 && r <= 0xd7af {
			return "", fmt.Errorf("提炼必须使用英文")
		}
	}
	count := 0
	pending := false
	for _, r := range summary {
		switch {
		case r == '.' || r == '!' || r == '?':
			pending = true
		case r == ' ' || r == '\t':
			if pending {
				count++
				pending = false
			}
		default:
			pending = false
		}
	}
	if pending {
		count++
	}
	if summary != "" && count > 2 {
		return "", fmt.Errorf("提炼不能超过两句")
	}
	return summary, nil
}
