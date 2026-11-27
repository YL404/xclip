import { useEffect, useRef, useState } from "preact/hooks";
import type { JSX, RefObject } from "preact";
import type { Entry, Match, SearchResult } from "../mygo";
import type { AssetCache, MediaPreview } from "../media";
import { dateGroup, formatBytes, formatDuration, kindLabel, relativeDate, shortDate, timeLabel } from "../format";
import { contentExcerpt, documentAsset, highlight, highlightCode, mediaURL, primaryAsset, shortID } from "../view";
import type { SortMode, ViewMode } from "./BrowseToolbar";
import { Icon, assetIconName } from "./Icons";

export function firstMatch(entry: SearchResult): Match | undefined {
  return entry.matches.find((match) => match.asset_id) ?? entry.matches[0];
}

function cssURL(url: string): string {
  return `url("${url.replace(/["\\]/g, "\\$&")}")`;
}

interface EntryCardProps {
  entry: SearchResult;
  query: string;
  groupLabel?: string;
  cache: AssetCache;
  scrollRootRef: RefObject<HTMLDivElement | null>;
  tagName: (slug: string) => string;
  onOpen: (id: string, play?: boolean) => void;
  onCopyEntryID: (id: string) => Promise<boolean>;
  onToggleTag: (slug: string) => void;
}

function EntryCard({
  entry,
  query,
  groupLabel,
  cache,
  scrollRootRef,
  tagName,
  onOpen,
  onCopyEntryID,
  onToggleTag,
}: EntryCardProps) {
  const cardRef = useRef<HTMLElement>(null);
  const asset = primaryAsset(entry.assets);
  const doc = documentAsset(entry.assets) ?? (asset?.readable ? asset : undefined);

  const [docSource, setDocSource] = useState<string | undefined>(() =>
    doc ? cache.peekText(doc.id) : undefined,
  );
  const [preview, setPreview] = useState<MediaPreview | undefined>(() =>
    asset?.kind === "video" ? cache.peekPreview(asset.id) : undefined,
  );
  const [copyState, setCopyState] = useState<"idle" | "busy" | "copied">("idle");
  const copyResetTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  useEffect(() => {
    setDocSource(doc ? cache.peekText(doc.id) : undefined);
    setPreview(asset?.kind === "video" ? cache.peekPreview(asset.id) : undefined);
  }, [cache, entry.id, doc?.id, asset?.id, asset?.kind]);

  useEffect(() => {
    return () => {
      if (copyResetTimer.current) clearTimeout(copyResetTimer.current);
    };
  }, []);

  useEffect(() => {
    const needsDoc = Boolean(doc && docSource === undefined);
    const needsVideo = Boolean(asset?.kind === "video" && preview === undefined);
    if (!needsDoc && !needsVideo) return;

    const element = cardRef.current;
    if (!element) return;

    let cancelled = false;
    const hydrate = () => {
      cache.queuePreview(async () => {
        if (cancelled) return;
        await Promise.allSettled([
          (async () => {
            if (!doc || !needsDoc) return;
            const loaded = await cache.getText(entry.id, doc);
            if (!cancelled) setDocSource(loaded);
          })(),
          (async () => {
            if (asset?.kind !== "video" || !needsVideo) return;
            const loaded = await cache.getPreview(asset);
            if (!cancelled) setPreview(loaded);
          })(),
        ]);
      });
    };

    if (typeof IntersectionObserver === "undefined") {
      hydrate();
      return () => {
        cancelled = true;
      };
    }

    const observer = new IntersectionObserver(
      (items) => {
        if (items.some((item) => item.isIntersecting)) {
          observer.disconnect();
          hydrate();
        }
      },
      { root: scrollRootRef.current, rootMargin: "180px" },
    );
    observer.observe(element);
    return () => {
      cancelled = true;
      observer.disconnect();
    };
  }, [cache, entry.id, doc, asset, docSource, preview, scrollRootRef]);

  const match = query ? firstMatch(entry) : undefined;
  const snippet = match?.snippet.trim() ?? "";
  const showMatch = Boolean(match && !(match.kind === "metadata" && (!snippet || snippet === entry.title)));

  const description = (() => {
    if (doc && docSource !== undefined) {
      return doc.kind === "code" ? entry.note || entry.summary || doc.path : contentExcerpt(docSource);
    }
    return entry.note || entry.summary || `${entry.assets.length} 个文件，已收录到本地`;
  })();

  const dateText = groupLabel
    ? groupLabel === "今天" || groupLabel === "昨天"
      ? timeLabel(entry.created_at)
      : shortDate(entry.created_at)
    : relativeDate(entry.created_at);

  const visibleTags = entry.tags.slice(0, 2);
  const codeID = shortID(entry.id);

  const handleCopy = async (event: MouseEvent) => {
    event.stopPropagation();
    if (copyState === "busy") return;
    setCopyState("busy");
    const ok = await onCopyEntryID(entry.id);
    if (ok) {
      setCopyState("copied");
      if (copyResetTimer.current) clearTimeout(copyResetTimer.current);
      copyResetTimer.current = setTimeout(() => setCopyState("idle"), 1600);
    } else {
      setCopyState("idle");
    }
  };

  const renderTags = () =>
    visibleTags.map((slug) => (
      <button
        key={slug}
        class="mini-tag"
        data-tag={slug}
        onClick={(event) => {
          event.stopPropagation();
          onToggleTag(slug);
        }}
      >
        {tagName(slug)}
      </button>
    ));

  return (
    <article
      ref={cardRef}
      class="card"
      data-id={entry.id}
      tabIndex={0}
      aria-label={`预览${entry.title}`}
      onClick={() => onOpen(entry.id, false)}
    >
      <CardCover
        entry={entry}
        docSource={docSource}
        preview={preview}
        onPlay={(event) => {
          event.stopPropagation();
          onOpen(entry.id, true);
        }}
      />

      <div class="card-body">
        <h2 dangerouslySetInnerHTML={{ __html: highlight(entry.title, query) }} />

        {showMatch && match ? (
          <div class="card-match">
            <b>
              {match.path
                ? `${match.path}${match.line ? ` · 第 ${match.line} 行` : ""}`
                : "内容信息命中"}
            </b>
            <span dangerouslySetInnerHTML={{ __html: highlight(match.snippet, query) }} />
          </div>
        ) : (
          <p
            class="card-description"
            dangerouslySetInnerHTML={{ __html: highlight(description, query) }}
          />
        )}

        <div class="card-bottom">
          {renderTags()}
          <button
            class={`card-code-id${copyState === "copied" ? " copied" : ""}`}
            data-copy-entry={entry.id}
            title="复制内容编码"
            aria-label={`复制内容编码 #${codeID}`}
            disabled={copyState === "busy"}
            onClick={handleCopy}
          >
            <span>#{codeID}</span>
            <Icon name={copyState === "copied" ? "check" : "copy"} />
          </button>
        </div>
      </div>

      <div class="card-meta">
        <span class="meta-kind">
          <Icon name={assetIconName(asset?.kind ?? "file")} />
          <span class="meta-tags">{renderTags()}</span>
        </span>
        <span class="meta-date">{dateText}</span>
      </div>
    </article>
  );
}

interface CardCoverProps {
  entry: Entry;
  docSource?: string;
  preview?: MediaPreview;
  onPlay: (event: MouseEvent) => void;
}

function CardCover({ entry, docSource, preview, onPlay }: CardCoverProps) {
  const asset = primaryAsset(entry.assets);
  if (!asset) {
    return (
      <div class="card-cover">
        <div class="card-file">
          <Icon name="doc" />
          <span>尚无附件</span>
        </div>
      </div>
    );
  }

  if (asset.kind === "video") {
    const poster = preview?.poster ?? "";
    const duration = preview?.duration ?? 0;
    return (
      <div
        class="card-cover video-cover"
        style={poster ? ({ "--cover": cssURL(poster) } as Record<string, string>) : undefined}
      >
        {poster ? (
          <img
            class="cover-fg"
            src={poster}
            alt={`${entry.title}的演示画面`}
            loading="lazy"
          />
        ) : preview !== undefined ? (
          <video
            src={mediaURL(asset)}
            muted
            playsInline
            preload="metadata"
            aria-label="视频首帧"
          />
        ) : (
          <div class="card-loading">
            <Icon name="video" />
            <span>正在读取视频封面…</span>
          </div>
        )}
        <button
          class="play-button"
          data-play-id={entry.id}
          aria-label={`播放${entry.title}`}
          title="播放视频"
          onClick={onPlay}
        >
          <Icon name="play" />
        </button>
        <span class="duration" hidden={!duration}>
          {formatDuration(duration)}
        </span>
      </div>
    );
  }

  if (asset.kind === "image") {
    const images = entry.assets.filter((item) => item.kind === "image");
    if (images.length === 1) {
      const url = mediaURL(images[0]);
      return (
        <div
          class="card-cover gallery-cover single"
          style={{ "--cover": cssURL(url) } as Record<string, string>}
        >
          <img class="cover-fg" src={url} alt={images[0].path} loading="lazy" />
        </div>
      );
    }
    const count = Math.min(images.length, 3);
    return (
      <div class={`card-cover gallery-cover ${count === 2 ? "two" : "three"}`}>
        {images.slice(0, count).map((item) => (
          <img key={item.id} src={mediaURL(item)} alt={item.path} loading="lazy" />
        ))}
        <span class="gallery-count">{images.length} 张</span>
      </div>
    );
  }

  if (asset.kind === "code") {
    const snippet = (docSource ?? "").split("\n").slice(0, 12).join("\n");
    return (
      <div class="card-cover card-code">
        <span class="cover-glyph">
          <Icon name="code" />
        </span>
        <div class="code-caption">{asset.path}</div>
        <pre dangerouslySetInnerHTML={{ __html: highlightCode(snippet) }} />
      </div>
    );
  }

  if (asset.kind === "text") {
    return (
      <div class="card-cover paper-cover">
        <span class="cover-glyph">
          <Icon name="doc" />
        </span>
        <div class="paper-label">
          <Icon name="doc" />
          文档
        </div>
        <div class="paper-title">{contentExcerpt(docSource ?? "") || entry.title}</div>
        <div class="paper-line" />
        <div class="paper-line short" />
        <span class="paper-corner">{asset.path.split("/").pop() ?? ""}</span>
      </div>
    );
  }

  return (
    <div class="card-cover">
      <div class="card-file">
        <Icon name={asset.kind === "audio" ? "video" : "doc"} />
        <span>{asset.path.split("/").pop() ?? ""}</span>
        <small>
          {kindLabel(asset.kind)} · {formatBytes(asset.size)}
        </small>
      </div>
    </div>
  );
}

interface CardGridProps {
  entries: SearchResult[];
  catalogEmpty: boolean;
  loading: boolean;
  error: string | null;
  query: string;
  sort: SortMode;
  activeView: ViewMode;
  limit: number;
  cache: AssetCache;
  scrollRootRef: RefObject<HTMLDivElement | null>;
  tagName: (slug: string) => string;
  onOpenEntry: (id: string, play?: boolean) => void;
  onCopyEntryID: (id: string) => Promise<boolean>;
  onToggleTag: (slug: string) => void;
  onReset: () => void;
  onLoadMore: () => void;
}

export function CardGrid({
  entries,
  catalogEmpty,
  loading,
  error,
  query,
  sort,
  activeView,
  limit,
  cache,
  scrollRootRef,
  tagName,
  onOpenEntry,
  onCopyEntryID,
  onToggleTag,
  onReset,
  onLoadMore,
}: CardGridProps) {
  const shown = entries.slice(0, limit);
  const useDateGroups = activeView === "list" && !query && (sort === "new" || sort === "old");

  const renderContent = () => {
    if (error) {
      return <div class="result-error">{error}</div>;
    }
    if (loading) {
      return <div class="results-loading">正在读取内容…</div>;
    }
    if (!entries.length) {
      return (
        <div class="empty">
          <Icon name="search" />
          <h2>{catalogEmpty ? "收录第一份值得保留的内容" : "没有找到匹配的内容"}</h2>
          <p>
            {catalogEmpty
              ? "选择文件或文件夹，也可以把文件直接拖入窗口。"
              : "试试其他关键词，或减少筛选条件。"}
          </p>
          <button class="soft-button" data-reset onClick={onReset}>
            查看全部内容
          </button>
        </div>
      );
    }

    if (useDateGroups) {
      const groups = new Map<string, SearchResult[]>();
      for (const entry of shown) {
        const key = dateGroup(entry.created_at);
        const bucket = groups.get(key);
        if (bucket) bucket.push(entry);
        else groups.set(key, [entry]);
      }
      const nodes: JSX.Element[] = [];
      for (const [label, items] of groups) {
        nodes.push(
          <div key={`group:${label}`} class="date-group">
            <span>{label}</span>
            <b>{items.length}</b>
          </div>,
        );
        for (const entry of items) {
          nodes.push(
            <EntryCard
              key={entry.id}
              entry={entry}
              query={query}
              groupLabel={label}
              cache={cache}
              scrollRootRef={scrollRootRef}
              tagName={tagName}
              onOpen={onOpenEntry}
              onCopyEntryID={onCopyEntryID}
              onToggleTag={onToggleTag}
            />,
          );
        }
      }
      return nodes;
    }

    return shown.map((entry) => (
      <EntryCard
        key={entry.id}
        entry={entry}
        query={query}
        cache={cache}
        scrollRootRef={scrollRootRef}
        tagName={tagName}
        onOpen={onOpenEntry}
        onCopyEntryID={onCopyEntryID}
        onToggleTag={onToggleTag}
      />
    ));
  };

  const listClass =
    !error && !loading && entries.length > 0 && activeView === "list" ? "cards list-view" : "cards";

  return (
    <div class="results-area">
      <div class={listClass} id="results" aria-live="polite">
        {renderContent()}
      </div>
      <button
        class="soft-button load-more"
        id="load-more"
        hidden={loading || Boolean(error) || entries.length <= limit}
        onClick={onLoadMore}
      >
        显示更多内容
      </button>
    </div>
  );
}
