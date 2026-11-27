import assert from "node:assert/strict";
import { test } from "node:test";
import { Window } from "happy-dom";
import type { Asset } from "../src/mygo";

const win = new Window();
Object.assign(globalThis, {
  window: win,
  document: win.document,
  DOMParser: win.DOMParser,
  Node: win.Node,
  Element: win.Element,
  HTMLElement: win.HTMLElement,
});
Object.defineProperty(globalThis, "navigator", { value: win.navigator, configurable: true });

const { renderMarkdown, formatBytes, excerpt, resolveAsset, primaryAsset, highlight } = await import(
  "../src/view"
);

test("Markdown removes active content", () => {
  const html = renderMarkdown(
    `# Title\n<script>alert(1)<\/script>\n<img src="x" onerror="alert(1)">\n[link](javascript:alert(1))`,
  );
  assert.doesNotMatch(html, /<script|onerror|href="javascript:/i);
  assert.match(html, /Title/);
});

test("Markdown keeps ordinary article formatting", () => {
  const html = renderMarkdown("# 核心模式\n\n- **@FocusState** 绑定输入框\n\n```swift\n.focused($istyping)\n```");
  assert.match(html, /<strong>@FocusState<\/strong>/);
  assert.match(html, /<code class="language-swift">/);
});

test("formatting preserves full source and formats bytes", () => {
  assert.equal(formatBytes(2048), "2.0 KB");
  const source = "first line\n@FocusState var istyping\nlast line";
  const start = source.indexOf("@FocusState");
  assert.equal(excerpt(source, start, start + 10), "@FocusState var istyping");
});

const assets: Asset[] = [
  { id: "readme", path: "notes/README.md", kind: "text", mime: "text/markdown", size: 1, sha256: "1", local_path: "/1", readable: true },
  { id: "video", path: "media/demo.mp4", kind: "video", mime: "video/mp4", size: 2, sha256: "2", local_path: "/2", readable: false },
  { id: "code", path: "source/FocusState.swift", kind: "code", mime: "text/plain", size: 3, sha256: "3", local_path: "/3", readable: true },
  { id: "image", path: "media/焦点 图.png", kind: "image", mime: "image/png", size: 4, sha256: "4", local_path: "/4", readable: false },
];

test("Markdown resolves owned media and file links without trusting archived URLs", () => {
  const html = renderMarkdown(
    '<video src="../media/demo.mp4" autoplay loop></video>\n\n![焦点](../media/%E7%84%A6%E7%82%B9%20%E5%9B%BE.png)\n\n[代码](../source/FocusState.swift)\n\n<img src="https://example.com/tracker" srcset="https://example.com/2x 2x">\n\n[危险页面](file:///etc/passwd)\n\n<button data-reveal="other" data-copy-entry="fake">按钮</button>',
    assets,
    "notes/README.md",
  );
  assert.match(html, /src="xclip-media:\/\/localhost\/video"/);
  assert.match(html, /src="xclip-media:\/\/localhost\/image"/);
  assert.match(html, /data-asset="code"/);
  assert.doesNotMatch(html, /autoplay|\sloop|srcset|example\.com|file:\/\//);
  assert.doesNotMatch(html, /data-reveal|data-copy-entry/);
  assert.equal(resolveAsset("../../media/demo.mp4", "notes/README.md", assets), undefined);
  assert.equal(primaryAsset(assets)?.id, "video");
});

test("highlighting CJK and code identifiers preserves literal markup safely", () => {
  const html = highlight('<img onerror="alert(1)"> 焦点 .focused($value)', "焦点 .focused($value)");
  assert.match(html, /<mark>焦点<\/mark>/);
  assert.match(html, /<mark>\.focused\(\$value\)<\/mark>/);
  assert.doesNotMatch(html, /<img/);
});
