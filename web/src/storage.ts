const PREFIX = "xclip:";

export function readSaved<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(PREFIX + key);
    if (raw === null) return fallback;
    return (JSON.parse(raw) as T | null) ?? fallback;
  } catch {
    return fallback;
  }
}

export function writeSaved(key: string, value: unknown): void {
  try {
    localStorage.setItem(PREFIX + key, JSON.stringify(value));
  } catch {
    // 隐私模式下仍可正常阅读。
  }
}

export type ThemeMode = "light" | "dark";

export function readInitialTheme(): ThemeMode {
  const saved = readSaved<string | null>("theme", null);
  if (saved === "light" || saved === "dark") return saved;
  return typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

export function applyTheme(theme: ThemeMode): void {
  document.documentElement.dataset.theme = theme;
  writeSaved("theme", theme);
}

export function readPlaybackProgress(): Record<string, number> {
  return readSaved<Record<string, number>>("progress", {});
}

export function writePlaybackProgress(progress: Record<string, number>): void {
  writeSaved("progress", progress);
}
