package core

import "testing"

func TestParseTag(t *testing.T) {
	slug, name, err := ParseTag(" Swift UI：SwiftUI 开发 ")
	if err != nil || slug != "swift-ui" || name != "SwiftUI 开发" {
		t.Fatalf("标签解析错误: %q %q %v", slug, name, err)
	}
	for _, value := range []string{"swiftui", "swiftui:", "swiftui:SwiftUI", "标签:中文"} {
		if _, _, err := ParseTag(value); value != "swiftui" && err == nil {
			t.Errorf("%q 应被拒绝", value)
		}
	}
}

func TestSummaryValidation(t *testing.T) {
	for _, valid := range []string{"", "One sentence.", "One sentence. Another sentence!"} {
		if _, err := ValidateSummary(valid); err != nil {
			t.Errorf("%q 应有效: %v", valid, err)
		}
	}
	for _, invalid := range []string{"中文总结", "two\nlines", "One. Two. Three."} {
		if _, err := ValidateSummary(invalid); err == nil {
			t.Errorf("%q 应被拒绝", invalid)
		}
	}
}
