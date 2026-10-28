import createDOMPurify from "dompurify";
import { marked } from "marked";
import type { Asset } from "./mygo";

export type AssetKind = "text" | "code" | "image" | "video" | "audio" | "file";

export function renderMarkdown(text: string, assets: Asset[] = [], basePath = ""): string {
  const forbiddenTags = ["script", "style", "form", "input", "button", "textarea", "select", "dialog", "iframe", "object", "embed", "base", "meta", "link", "svg", "math"];
  const parsed = marked.parse(text, { async: false, gfm: true }) as string;
  // 每个浏览器窗口使用自己的 DOMPurify 实例，兼容测试中的独立 DOM。
  const purifier = createDOMPurify(window as unknown as Parameters<typeof createDOMPurify>[0]);
  const sanitized = purifier.sanitize(parsed, {
    USE_PROFILES: { html: true },
    ALLOW_DATA_ATTR: false,
    FORBID_TAGS: forbiddenTags,
    FORBID_ATTR: ["style", "srcset", "autoplay"],
  });
  // 部分测试 DOM 的遍历器并不完整，仍保留相同的脚本与事件属性禁用规则。
  const clean = sanitized.replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, "")
    .replace(/\son\w+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, "")
    .replace(/\s(href|src)\s*=\s*(["'])\s*javascript:[^"']*\2/gi, "");
  const template = document.createElement("template");
  template.innerHTML = clean;
  template.content.querySelectorAll(forbiddenTags.join(",")).forEach((node) => node.replaceWith(document.createTextNode(node.textContent ?? "")));
  template.content.querySelectorAll("*").forEach((node) => {
    for (const attribute of [...node.attributes]) {
      if (/^(data-|on)/i.test(attribute.name) || ["style", "ping", "autofocus"].includes(attribute.name)) node.removeAttribute(attribute.name);
    }
  });
  template.content.querySelectorAll<HTMLElement>("img, video, audio, source").forEach((node) => {
    const asset = resolveAsset(node.getAttribute("src") ?? node.querySelector("source")?.getAttribute("src") ?? "", basePath, assets);
    node.removeAttribute("srcset");
    if (!asset || !["image", "video", "audio"].includes(asset.kind)) {
      node.replaceWith(document.createTextNode("（此媒体未收录到内容库）"));
      return;
    }
    node.setAttribute("src", mediaURL(asset));
    if (node.tagName === "VIDEO" || node.tagName === "AUDIO") {
      node.setAttribute("controls", "");
      node.setAttribute("preload", "metadata");
      node.setAttribute("data-media", asset.id);
      node.removeAttribute("autoplay");
      node.removeAttribute("loop");
    }
    node.removeAttribute("poster");
  });
  template.content.querySelectorAll<HTMLAnchorElement>("a").forEach((anchor) => {
    const href = anchor.getAttribute("href") ?? "";
    const asset = resolveAsset(href, basePath, assets);
    if (asset) {
      anchor.setAttribute("href", "#");
      anchor.setAttribute("data-asset", asset.id);
    } else if (/^https?:\/\//i.test(href)) {
      anchor.target = "_blank";
      anchor.rel = "noopener noreferrer";
    } else if (!href.startsWith("#")) anchor.removeAttribute("href");
  });
  return template.innerHTML;
}

export function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
}

export function shortID(id: string): string { return id.replaceAll("-", "").toLowerCase().slice(0, 8); }

export function mediaURL(asset: Pick<Asset, "id">, preview = false): string {
  const base = navigator.platform.startsWith("Win") ? "http://xclip-media.localhost/" : "xclip-media://localhost/";
  return base + encodeURIComponent(asset.id) + (preview ? "?preview=1" : "");
}

export function documentAsset(assets: Asset[]): Asset | undefined {
  return assets.find((asset) => /(^|\/)readme\.md$/i.test(asset.path)) ?? assets.find((asset) => asset.kind === "text" && asset.readable);
}

export function primaryAsset(assets: Asset[]): Asset | undefined {
  return assets.find((asset) => asset.kind === "video") ?? assets.find((asset) => asset.kind === "image") ?? documentAsset(assets) ?? assets.find((asset) => asset.kind === "code") ?? assets[0];
}

export function resolveAsset(raw: string, basePath: string, assets: Asset[]): Asset | undefined {
  if (!raw || /^[a-z][a-z\d+.-]*:/i.test(raw) || raw.startsWith("/") || raw.startsWith("#")) return;
  let path: string;
  try { path = decodeURIComponent(raw.split(/[?#]/)[0]); } catch { return; }
  const parts = basePath.split("/").slice(0, -1);
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") { if (!parts.length) return; parts.pop(); }
    else parts.push(part);
  }
  return assets.find((asset) => asset.path === parts.join("/"));
}

export function contentExcerpt(text: string): string {
  const paragraphs = text.replace(/```[\s\S]*?```/g, "").replace(/<[^>]*>/g, "").split(/\n\s*\n/)
    .map((part) => part.trim()).filter((part) => !/^(#|[-*]|\d+\.|来源|作者|环境|标签|文件结构|\|)/.test(part));
  return (paragraphs.find((part) => part.length >= 20) ?? paragraphs[0] ?? "").replace(/!?(?:\[([^\]]*)\])\([^)]*\)/g, "$1").replace(/[*`_]/g, "").replace(/\s+/g, " ").slice(0, 220);
}

export function highlight(text: string, query = ""): string {
  const tokens = query.trim().split(/\s+/).filter(Boolean).map((token) => token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  if (!tokens.length) return escapeHTML(text);
  const pattern = new RegExp(tokens.join("|"), "gi");
  let html = "", last = 0;
  for (const match of text.matchAll(pattern)) {
    html += escapeHTML(text.slice(last, match.index)) + `<mark>${escapeHTML(match[0])}</mark>`;
    last = match.index! + match[0].length;
  }
  return html + escapeHTML(text.slice(last));
}

export function highlightCode(text: string, query = ""): string {
  const pattern = /\/\/[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:import|from|export|function|const|let|return|if|else|new|as|type|struct|var|some|true|false|nil|private|public|func|guard|for|in|class|static|throws|try|await|async)\b|@\w+|\b\d+(?:\.\d+)?\b/g;
  let html = "", last = 0;
  for (const match of text.matchAll(pattern)) {
    html += highlight(text.slice(last, match.index), query);
    const value = match[0];
    const kind = value.startsWith("//") ? "comment" : /^["']/.test(value) ? "string" : /^\d/.test(value) ? "number" : "keyword";
    html += `<span class="tok-${kind}">${highlight(value, query)}</span>`;
    last = match.index! + value.length;
  }
  return html + highlight(text.slice(last), query);
}

export function formatDuration(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
}

export function kindLabel(kind: AssetKind | string): string {
  return ({ text: "文档", code: "代码", image: "图片", video: "视频", audio: "音频", file: "文件" } as Record<string, string>)[kind] ?? kind;
}

export function excerpt(text: string, start: number, end: number): string {
  const safeStart = Math.max(0, Math.min(start, text.length));
  const safeEnd = Math.max(safeStart, Math.min(end, text.length));
  const from = Math.max(0, text.lastIndexOf("\n", safeStart - 1) + 1, safeStart - 100);
  const lineEnd = text.indexOf("\n", safeEnd);
  const to = Math.min(text.length, lineEnd < 0 ? safeEnd + 180 : lineEnd, safeEnd + 180);
  return text.slice(from, to).trim();
}

export function debounce<T extends unknown[]>(fn: (...args: T) => void, wait: number): (...args: T) => void {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), wait);
  };
}
