import type { SearchResult } from "./mygo";

export type AssetKind = "text" | "code" | "image" | "video" | "audio" | "file";

const DAY_MS = 86_400_000;

function startOfDay(date: Date): number {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
}

export function dayDistance(value: string): number {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return Infinity;
  return Math.round((startOfDay(new Date()) - startOfDay(date)) / DAY_MS);
}

export function relativeDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const days = dayDistance(value);
  if (days <= 0) return "今天";
  if (days === 1) return "昨天";
  if (days < 7) return `${days} 天前`;
  if (date.getFullYear() === new Date().getFullYear()) {
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }
  return `${date.getFullYear()}年${date.getMonth() + 1}月`;
}

export function timeLabel(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });
}

export function shortDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  if (date.getFullYear() === new Date().getFullYear()) {
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }
  return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
}

export function dateGroup(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "更早";
  const days = dayDistance(value);
  if (days <= 0) return "今天";
  if (days === 1) return "昨天";
  if (days < 7) return "近 7 天";
  const now = new Date();
  if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth()) {
    return "本月";
  }
  if (date.getFullYear() === now.getFullYear()) {
    return `${date.getMonth() + 1}月`;
  }
  return `${date.getFullYear()}年${date.getMonth() + 1}月`;
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
  const labels: Record<string, string> = {
    text: "文档",
    code: "代码",
    image: "图片",
    video: "视频",
    audio: "音频",
    file: "文件",
  };
  return labels[kind] ?? kind;
}

export function pathParts(path: string): { name: string; dir: string } {
  const index = path.lastIndexOf("/");
  if (index < 0) return { name: path, dir: "" };
  return { name: path.slice(index + 1), dir: path.slice(0, index) };
}

export function sourceLabel(source: string): string {
  if (!source) return "本地收录";
  try {
    const host = new URL(source).hostname.replace(/^www\./, "");
    return /(^|\.)x\.com$|(^|\.)twitter\.com$/.test(host) ? "来自 X" : host;
  } catch {
    return "本地收录";
  }
}

export function uniqueContentBytes(entries: SearchResult[]): number {
  const seen = new Set<string>();
  let bytes = 0;
  for (const entry of entries) {
    for (const asset of entry.assets) {
      if (!seen.has(asset.sha256)) {
        seen.add(asset.sha256);
        bytes += asset.size;
      }
    }
  }
  return bytes;
}
