export type IconName =
  | "grid"
  | "list"
  | "search"
  | "clock"
  | "folder"
  | "close"
  | "check"
  | "play"
  | "video"
  | "image"
  | "doc"
  | "code"
  | "right"
  | "left"
  | "copy"
  | "expand"
  | "compare"
  | "sun"
  | "moon"
  | "menu"
  | "info"
  | "plus"
  | "chevron"
  | "refresh";

export function assetIconName(kind: string): IconName {
  if (kind === "code") return "code";
  if (kind === "image") return "image";
  if (kind === "video" || kind === "audio") return "video";
  return "doc";
}

export function Icon({ name, className }: { name: IconName; className?: string }) {
  return (
    <svg aria-hidden="true" class={className}>
      <use href={`#i-${name}`} />
    </svg>
  );
}

export function IconSprite() {
  return (
    <svg
      aria-hidden="true"
      style={{ position: "absolute", width: 0, height: 0, overflow: "hidden" }}
    >
      <defs>
        <symbol id="i-grid" viewBox="0 0 24 24">
          <rect x="4" y="4" width="6" height="6" rx="1" />
          <rect x="14" y="4" width="6" height="6" rx="1" />
          <rect x="4" y="14" width="6" height="6" rx="1" />
          <rect x="14" y="14" width="6" height="6" rx="1" />
        </symbol>
        <symbol id="i-list" viewBox="0 0 24 24">
          <path d="M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01" />
        </symbol>
        <symbol id="i-search" viewBox="0 0 24 24">
          <circle cx="10.5" cy="10.5" r="6.5" />
          <path d="m16 16 4.5 4.5" />
        </symbol>
        <symbol id="i-clock" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="8" />
          <path d="M12 7v5l3 2" />
        </symbol>
        <symbol id="i-folder" viewBox="0 0 24 24">
          <path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v10H3Z" />
        </symbol>
        <symbol id="i-close" viewBox="0 0 24 24">
          <path d="m6 6 12 12M6 18 18 6" />
        </symbol>
        <symbol id="i-check" viewBox="0 0 24 24">
          <path d="m5 12 4 4L19 6" />
        </symbol>
        <symbol id="i-play" viewBox="0 0 24 24">
          <path d="m7 4 13 8-13 8Z" />
        </symbol>
        <symbol id="i-video" viewBox="0 0 24 24">
          <rect x="3" y="5" width="13" height="14" rx="2" />
          <path d="m16 10 5-3v10l-5-3" />
        </symbol>
        <symbol id="i-image" viewBox="0 0 24 24">
          <rect x="3" y="3" width="18" height="18" rx="2" />
          <circle cx="8" cy="8" r="1.5" />
          <path d="m4 17 5-5 4 4 3-3 5 5" />
        </symbol>
        <symbol id="i-doc" viewBox="0 0 24 24">
          <path d="M14 3H5v18h14V8Zm0 0v5h5M8 12h8M8 16h6" />
        </symbol>
        <symbol id="i-code" viewBox="0 0 24 24">
          <path d="m8 6-6 6 6 6M16 6l6 6-6 6M14 4l-4 16" />
        </symbol>
        <symbol id="i-right" viewBox="0 0 24 24">
          <path d="m9 5 7 7-7 7" />
        </symbol>
        <symbol id="i-left" viewBox="0 0 24 24">
          <path d="m15 5-7 7 7 7" />
        </symbol>
        <symbol id="i-copy" viewBox="0 0 24 24">
          <rect x="8" y="8" width="12" height="13" rx="2" />
          <path d="M16 8V3H3v13h5" />
        </symbol>
        <symbol id="i-expand" viewBox="0 0 24 24">
          <path d="M8 3H3v5M16 3h5v5M21 16v5h-5M3 16v5h5" />
        </symbol>
        <symbol id="i-compare" viewBox="0 0 24 24">
          <rect x="3" y="4" width="18" height="16" rx="2" />
          <path d="M12 4v16M6 8h3M15 8h3M15 12h3" />
        </symbol>
        <symbol id="i-sun" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M5 19l1.5-1.5M17.5 6.5 19 5" />
        </symbol>
        <symbol id="i-moon" viewBox="0 0 24 24">
          <path d="M20 14a8 8 0 1 1-10-10 7 7 0 0 0 10 10Z" />
        </symbol>
        <symbol id="i-menu" viewBox="0 0 24 24">
          <path d="M4 6h16M4 12h16M4 18h16" />
        </symbol>
        <symbol id="i-info" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="9" />
          <path d="M12 11v6M12 7h.01" />
        </symbol>
        <symbol id="i-plus" viewBox="0 0 24 24">
          <path d="M12 5v14M5 12h14" />
        </symbol>
        <symbol id="i-chevron" viewBox="0 0 24 24">
          <path d="m6 9 6 6 6-6" />
        </symbol>
        <symbol id="i-refresh" viewBox="0 0 24 24">
          <path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7" />
        </symbol>
      </defs>
    </svg>
  );
}
