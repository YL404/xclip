import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import type { Asset, Entry } from "../mygo";
import type { AssetCache } from "../media";
import { formatBytes, formatDuration, kindLabel, pathParts, relativeDate, sourceLabel } from "../format";
import { readPlaybackProgress, writePlaybackProgress } from "../storage";
import { contentExcerpt, documentAsset, highlight, highlightCode, mediaURL, primaryAsset, renderMarkdown, shortID } from "../view";
import { Icon, assetIconName } from "./Icons";

export type ReaderTab = "overview" | "document" | "code" | "files";

export interface ReaderSession {
  open: boolean;
  loading: boolean;
  error: string | null;
  entry: Entry | null;
  asset: Asset | null;
  tab: ReaderTab;
  compare: boolean;
  line: number;
  autoplay: boolean;
  queue: string[];
}

interface ReaderDialogProps {
  session: ReaderSession;
  query: string;
  cache: AssetCache;
  tagName: (slug: string) => string;
  onClose: () => void;
  onNavigate: (direction: -1 | 1) => void;
  onSelectTab: (tab: ReaderTab) => void;
  onToggleCompare: () => void;
  onSelectAsset: (assetID: string) => void;
  onZoomImage: () => void;
  onEdit: () => void;
  onCopyEntryID: (id: string) => Promise<boolean>;
  onCopyText: (value: string, label: string) => Promise<boolean>;
  onRevealAsset: (assetID: string) => void;
  onFilterTag: (slug: string) => void;
  onNotify: (message: string) => void;
  onConsumeAutoplay: () => void;
}

function flushAndPauseMedia(container: HTMLElement | null): void {
  if (!container) return;
  const mediaElements = container.querySelectorAll<HTMLMediaElement>("video, audio");
  if (!mediaElements.length) return;
  const progress = readPlaybackProgress();
  let dirty = false;
  mediaElements.forEach((media) => {
    const key = media.dataset.media;
    if (key) {
      if (media.ended) {
        delete progress[key];
        dirty = true;
      } else if (media.currentTime > 0) {
        progress[key] = media.currentTime;
        dirty = true;
      }
    }
    media.pause();
  });
  if (dirty) writePlaybackProgress(progress);
}

function FileNavItem({
  asset,
  active,
  iconName,
  onSelect,
}: {
  asset: Asset;
  active: boolean;
  iconName: "code" | "doc";
  onSelect: (id: string) => void;
}) {
  const { name, dir } = pathParts(asset.path);
  return (
    <button
      class={`file-item${active ? " active" : ""}`}
      data-asset={asset.id}
      title={asset.path}
      onClick={() => onSelect(asset.id)}
    >
      <Icon name={iconName} />
      <span class="file-item-text">
        <b>{name}</b>
        {dir && <small>{dir}</small>}
      </span>
    </button>
  );
}

function AssetActions({
  asset,
  onCopyPath,
  onReveal,
}: {
  asset: Asset;
  onCopyPath: (asset: Asset) => void;
  onReveal: (assetID: string) => void;
}) {
  return (
    <>
      <button
        class="soft-button"
        data-copy-path={asset.id}
        onClick={() => onCopyPath(asset)}
      >
        <Icon name="copy" />
        复制路径
      </button>
      <button
        class="soft-button reveal-button"
        data-reveal={asset.id}
        onClick={() => onReveal(asset.id)}
      >
        <Icon name="folder" />
        在文件夹中显示
      </button>
    </>
  );
}

function EntryMetaDetails({
  entry,
  onCopyEntryID,
}: {
  entry: Entry;
  onCopyEntryID: (id: string) => void;
}) {
  return (
    <details class="entry-info">
      <summary>
        来源与收录信息
        <Icon name="right" />
      </summary>
      <dl>
        <dt>来源</dt>
        <dd>{entry.source || "本地收录"}</dd>
        <dt>收录</dt>
        <dd>{new Date(entry.created_at).toLocaleString("zh-CN")}</dd>
        <dt>内容编码</dt>
        <dd>
          <button data-copy-entry={entry.id} onClick={() => onCopyEntryID(entry.id)}>
            #{shortID(entry.id)} <Icon name="copy" />
          </button>
        </dd>
        <dt>英文摘要</dt>
        <dd class="english-summary summary-text">{entry.summary || "尚无摘要"}</dd>
        {entry.note && (
          <>
            <dt>个人备注</dt>
            <dd class="summary-text">{entry.note}</dd>
          </>
        )}
      </dl>
    </details>
  );
}

function MediaStage({
  asset,
  entry,
  cache,
  onSelectAsset,
  onZoomImage,
}: {
  asset: Asset;
  entry: Entry;
  cache: AssetCache;
  onSelectAsset: (id: string) => void;
  onZoomImage: () => void;
}) {
  if (asset.kind === "image") {
    const images = entry.assets.filter((item) => item.kind === "image");
    return (
      <>
        <div class="gallery-stage">
          <button data-zoom aria-label="放大图片" onClick={onZoomImage}>
            <img src={mediaURL(asset)} alt={asset.path} />
          </button>
          <span class="zoom-indicator">
            <Icon name="expand" />
            点击放大
          </span>
        </div>
        <div class="image-thumbnails">
          {images.map((item) => (
            <button
              key={item.id}
              class={`image-thumb${asset.id === item.id ? " active" : ""}`}
              data-asset={item.id}
              aria-label={`查看${item.path}`}
              onClick={() => onSelectAsset(item.id)}
            >
              <img src={mediaURL(item)} alt="" loading="lazy" />
            </button>
          ))}
        </div>
      </>
    );
  }

  const preview = cache.peekPreview(asset.id);
  const isAudio = asset.kind === "audio";
  return (
    <>
      <div class="media-stage">
        {isAudio ? (
          <audio
            key={asset.id}
            src={mediaURL(asset)}
            data-media={asset.id}
            controls
            preload="metadata"
            aria-label={asset.path}
          />
        ) : (
          <video
            key={asset.id}
            src={mediaURL(asset)}
            poster={preview?.poster || undefined}
            data-media={asset.id}
            controls
            playsInline
            preload="metadata"
            aria-label={asset.path}
          />
        )}
      </div>
      <div class="media-caption">
        <Icon name="video" />
        <span>{asset.path}</span>
        <span>
          {preview?.duration ? `${formatDuration(preview.duration)} · ` : ""}
          {formatBytes(asset.size)}
        </span>
      </div>
    </>
  );
}

function CodePane({
  entry,
  asset,
  source,
  query,
  hitLine,
  compare,
  onSelectAsset,
  onCopySource,
  onReveal,
}: {
  entry: Entry;
  asset: Asset;
  source: string;
  query: string;
  hitLine: number;
  compare: boolean;
  onSelectAsset: (id: string) => void;
  onCopySource: () => void;
  onReveal: (assetID: string) => void;
}) {
  const tokens = useMemo(
    () => query.toLocaleLowerCase().split(/\s+/).filter(Boolean),
    [query],
  );
  const lines = useMemo(() => source.split("\n"), [source]);
  const codeAssets = entry.assets.filter((item) => item.kind === "code");

  return (
    <div class="code-pane">
      <div class="code-toolbar">
        {compare ? (
          <select
            id="compare-file"
            aria-label="切换对照的代码文件"
            value={asset.id}
            onChange={(event) => onSelectAsset((event.currentTarget as HTMLSelectElement).value)}
          >
            {codeAssets.map((item) => (
              <option key={item.id} value={item.id}>
                {item.path}
              </option>
            ))}
          </select>
        ) : (
          <span class="file-path">{asset.path}</span>
        )}
        <button class="soft-button" data-copy-text onClick={onCopySource}>
          <Icon name="copy" />
          复制代码
        </button>
        <button
          class="soft-button reveal-button"
          data-reveal={asset.id}
          aria-label="在文件夹中显示"
          title="在文件夹中显示"
          onClick={() => onReveal(asset.id)}
        >
          <Icon name="folder" />
        </button>
      </div>
      <div class="code-scroll" tabIndex={0} aria-label="代码内容，可横向和纵向滚动">
        <pre class="code-lines">
          {lines.map((lineText, index) => {
            const lineNumber = index + 1;
            const lowerLine = lineText.toLocaleLowerCase();
            const isHit =
              lineNumber === hitLine ||
              tokens.some((token) => lowerLine.includes(token));
            return (
              <span
                key={lineNumber}
                class={`code-line${isHit ? " hit" : ""}`}
                data-line={lineNumber}
              >
                <span class="line-number" aria-hidden="true">
                  {lineNumber}
                </span>
                <code dangerouslySetInnerHTML={{ __html: highlightCode(lineText, query) }} />
              </span>
            );
          })}
        </pre>
      </div>
    </div>
  );
}

function DocumentPane({
  entry,
  asset,
  source,
  query,
  hitLine,
  tagName,
  onCopyEntryID,
  onCopySource,
  onCopyPath,
  onReveal,
  onSelectAsset,
}: {
  entry: Entry;
  asset: Asset;
  source: string;
  query: string;
  hitLine: number;
  tagName: (slug: string) => string;
  onCopyEntryID: (id: string) => void;
  onCopySource: () => void;
  onCopyPath: (asset: Asset) => void;
  onReveal: (assetID: string) => void;
  onSelectAsset: (assetID: string) => void;
}) {
  const articleRef = useRef<HTMLElement>(null);
  const isMarkdown = /\.md$/i.test(asset.path);
  const renderedMarkdown = useMemo(() => {
    if (!isMarkdown) return "";
    return renderMarkdown(source.replace(/^# [^\r\n]*\r?\n/, ""), entry.assets, asset.path);
  }, [isMarkdown, source, entry.assets, asset.path]);

  // 在安全渲染后的 Markdown 文本节点中标注搜索关键词，不破坏 DOM 结构。
  useEffect(() => {
    const article = articleRef.current;
    if (!article || !query) return;
    const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
    const nodes: Text[] = [];
    while (walker.nextNode()) nodes.push(walker.currentNode as Text);
    for (const node of nodes) {
      const markedHTML = highlight(node.textContent ?? "", query);
      if (!markedHTML.includes("<mark>")) continue;
      const template = document.createElement("template");
      template.innerHTML = markedHTML;
      node.replaceWith(template.content);
    }
  }, [renderedMarkdown, query]);

  const handleMarkdownClick = (event: MouseEvent) => {
    const target = (event.target as Element | null)?.closest<HTMLElement>("[data-asset]");
    if (target?.dataset.asset) {
      event.preventDefault();
      onSelectAsset(target.dataset.asset);
    }
  };

  return (
    <div class="doc-wrap">
      <div class="entry-kicker">
        <button data-copy-entry={entry.id} onClick={() => onCopyEntryID(entry.id)}>
          #{shortID(entry.id)}
        </button>
        <span>·</span>
        <span>{asset.path}</span>
      </div>
      <h1 class="doc-title">{entry.title}</h1>
      <div class="doc-meta">
        <span>
          {entry.tags.map(tagName).join(" · ")}
          {hitLine ? ` · 命中原文第 ${hitLine} 行` : ""}
        </span>
        <button class="soft-button" data-copy-text onClick={onCopySource}>
          <Icon name="copy" />
          复制全文
        </button>
      </div>
      {isMarkdown ? (
        <article
          ref={articleRef}
          class="markdown"
          onClick={handleMarkdownClick}
          dangerouslySetInnerHTML={{ __html: renderedMarkdown }}
        />
      ) : (
        <pre
          class="text-source"
          dangerouslySetInnerHTML={{ __html: highlight(source, query) }}
        />
      )}
      <div class="reader-meta-actions">
        <AssetActions asset={asset} onCopyPath={onCopyPath} onReveal={onReveal} />
      </div>
      <EntryMetaDetails entry={entry} onCopyEntryID={onCopyEntryID} />
    </div>
  );
}

export function ReaderDialog({
  session,
  query,
  cache,
  tagName,
  onClose,
  onNavigate,
  onSelectTab,
  onToggleCompare,
  onSelectAsset,
  onZoomImage,
  onEdit,
  onCopyEntryID,
  onCopyText,
  onRevealAsset,
  onFilterTag,
  onNotify,
  onConsumeAutoplay,
}: ReaderDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const bodyRef = useRef<HTMLDivElement>(null);
  const [expanded, setExpanded] = useState(false);

  const entry = session.entry;
  const docs = useMemo(
    () => entry?.assets.filter((asset) => asset.kind === "text" && asset.readable) ?? [],
    [entry],
  );
  const codes = useMemo(
    () => entry?.assets.filter((asset) => asset.kind === "code" && asset.readable) ?? [],
    [entry],
  );
  const primaryVideo = useMemo(
    () => entry?.assets.find((asset) => asset.kind === "video"),
    [entry],
  );

  // 计算当前视图实际要展示的目标附件与需要加载正文的附件。
  const viewModel = useMemo(() => {
    if (!entry) return null;
    if (session.compare && primaryVideo && codes.length) {
      const codeAsset = session.asset?.kind === "code" ? session.asset : codes[0];
      return { mode: "compare" as const, media: primaryVideo, asset: codeAsset, textAsset: codeAsset };
    }
    if (session.tab === "code" && codes.length) {
      const codeAsset = session.asset?.kind === "code" ? session.asset : codes[0];
      return { mode: "code" as const, asset: codeAsset, textAsset: codeAsset };
    }
    if (session.tab === "document" && docs.length) {
      const docAsset =
        session.asset?.kind === "text"
          ? session.asset
          : documentAsset(entry.assets) ?? docs[0];
      return { mode: "document" as const, asset: docAsset, textAsset: docAsset };
    }
    if (session.tab === "overview") {
      const asset = session.asset ?? primaryAsset(entry.assets) ?? null;
      if (asset && ["image", "video", "audio"].includes(asset.kind)) {
        const doc = documentAsset(entry.assets);
        return { mode: "overview-media" as const, asset, doc, textAsset: doc ?? null };
      }
      if (asset?.kind === "text" && asset.readable) {
        return { mode: "overview-doc" as const, asset, textAsset: asset };
      }
      if (asset) {
        return { mode: "unsupported" as const, asset, textAsset: null };
      }
    }
    return { mode: "files" as const, asset: null, textAsset: null };
  }, [entry, session.compare, session.tab, session.asset, primaryVideo, codes, docs]);

  const textAsset = viewModel?.textAsset ?? null;
  const [loadedText, setLoadedText] = useState<{ assetID: string; content: string } | null>(null);
  const [textError, setTextError] = useState<string | null>(null);

  useEffect(() => {
    if (!session.open || !entry || !textAsset) {
      setLoadedText(null);
      setTextError(null);
      return;
    }
    const cached = cache.peekText(textAsset.id);
    if (cached !== undefined) {
      setLoadedText({ assetID: textAsset.id, content: cached });
      setTextError(null);
      return;
    }
    let cancelled = false;
    setLoadedText(null);
    setTextError(null);
    cache
      .getText(entry.id, textAsset)
      .then((content) => {
        if (!cancelled) setLoadedText({ assetID: textAsset.id, content });
      })
      .catch((error: unknown) => {
        if (!cancelled) setTextError(String(error));
      });
    return () => {
      cancelled = true;
    };
  }, [session.open, entry, textAsset, cache]);

  // 同步原生 <dialog> 打开与关闭状态。
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (session.open) {
      if (!dialog.open) {
        dialog.showModal();
        dialog.focus({ preventScroll: true });
      }
    } else if (dialog.open) {
      flushAndPauseMedia(bodyRef.current);
      dialog.close();
    }
  }, [session.open]);

  // 切页或切条目时回到顶部。
  useEffect(() => {
    if (bodyRef.current) bodyRef.current.scrollTop = 0;
  }, [entry?.id, session.tab, session.compare, viewModel?.asset?.id]);

  // 绑定视频/音频播放进度、封面与自动播放，并在切换或卸载时统一暂停并落盘。
  const contentReady = !textAsset || loadedText?.assetID === textAsset.id;
  useEffect(() => {
    if (!session.open || !entry || !contentReady) return;
    const container = bodyRef.current;
    if (!container) return;

    const shouldAutoplay = session.autoplay;
    if (shouldAutoplay) onConsumeAutoplay();

    const progress = readPlaybackProgress();
    const cleanups: Array<() => void> = [];

    container.querySelectorAll<HTMLMediaElement>("video, audio").forEach((element) => {
      const key = element.dataset.media;
      let lastSaved = 0;
      const restore = () => {
        if (key && progress[key] && Number.isFinite(element.duration) && progress[key] < element.duration - 0.5) {
          element.currentTime = progress[key];
        }
      };
      const onTimeUpdate = () => {
        if (key && Math.abs(element.currentTime - lastSaved) > 2) {
          progress[key] = element.currentTime;
          lastSaved = element.currentTime;
          writePlaybackProgress(progress);
        }
      };
      const onEnded = () => {
        if (key) {
          delete progress[key];
          writePlaybackProgress(progress);
        }
      };
      const onError = () => {
        const message = document.createElement("p");
        message.className = "media-placeholder";
        message.textContent = "此格式暂无法在 App 内播放，可在文件夹中显示原文件。";
        element.replaceWith(message);
      };

      element.addEventListener("loadedmetadata", restore, { once: true });
      if (element.readyState >= 1) restore();
      element.addEventListener("timeupdate", onTimeUpdate);
      element.addEventListener("ended", onEnded);
      element.addEventListener("error", onError);

      cleanups.push(() => {
        element.removeEventListener("loadedmetadata", restore);
        element.removeEventListener("timeupdate", onTimeUpdate);
        element.removeEventListener("ended", onEnded);
        element.removeEventListener("error", onError);
      });

      const mediaAsset = entry.assets.find((item) => item.id === key);
      if (element instanceof HTMLVideoElement && mediaAsset) {
        void cache.getPreview(mediaAsset).then((preview) => {
          if (preview.poster && element.isConnected) element.poster = preview.poster;
        });
      }
      if (shouldAutoplay) {
        void element.play().catch(() => {
          if (element.isConnected) onNotify("点击播放按钮继续观看");
        });
      }
    });

    const onPageHide = () => flushAndPauseMedia(container);
    window.addEventListener("pagehide", onPageHide);

    return () => {
      window.removeEventListener("pagehide", onPageHide);
      cleanups.forEach((fn) => fn());
      flushAndPauseMedia(container);
    };
  }, [session.open, entry, viewModel?.mode, viewModel?.asset?.id, contentReady, session.autoplay, cache, onNotify, onConsumeAutoplay]);

  // 搜索命中时滚动到首个命中的代码行或高亮标记。
  useEffect(() => {
    if (!session.open || !contentReady || (!query && !session.line)) return;
    const container = bodyRef.current;
    if (!container) return;
    const frame = requestAnimationFrame(() => {
      const target =
        session.tab === "code" || session.compare
          ? session.line
            ? container.querySelector<HTMLElement>(`[data-line="${session.line}"]`)
            : container.querySelector<HTMLElement>(".code-line.hit")
          : container.querySelector<HTMLElement>("mark");
      target?.scrollIntoView({ block: "center", inline: "nearest" });
    });
    return () => cancelAnimationFrame(frame);
  }, [session.open, contentReady, query, session.line, session.tab, session.compare, viewModel?.asset?.id]);

  const queueIndex = entry ? session.queue.indexOf(entry.id) : -1;
  const tabs: Array<{ key: ReaderTab; label: string; count: string }> = entry
    ? [
        { key: "overview", label: "概览", count: "" },
        ...(docs.length
          ? [{ key: "document" as const, label: docs.length > 1 ? "文档" : "说明文档", count: docs.length > 1 ? String(docs.length) : "" }]
          : []),
        ...(codes.length ? [{ key: "code" as const, label: "代码", count: String(codes.length) }] : []),
        { key: "files", label: "文件", count: String(entry.assets.length) },
      ]
    : [];

  const handleCopyPath = (asset: Asset) => {
    void onCopyText(asset.local_path, "附件路径");
  };

  const handleCopyCurrentText = () => {
    if (!entry || !textAsset) return;
    void cache
      .getText(entry.id, textAsset)
      .then((source) => onCopyText(source, "全文"))
      .catch((error: unknown) => onNotify(String(error)));
  };

  const renderBody = () => {
    if (session.loading) return <div class="reader-loading">正在读取内容…</div>;
    if (session.error) return <div class="error-detail">{session.error}</div>;
    if (!entry || !viewModel) return null;
    if (textError) return <div class="error-detail">{textError}</div>;
    if (textAsset && loadedText?.assetID !== textAsset.id) {
      return <div class="reader-loading">正在读取内容…</div>;
    }

    const source = loadedText?.content ?? "";

    if (viewModel.mode === "compare") {
      return (
        <div class="compare-layout">
          <div class="compare-media">
            <h2>{entry.title}</h2>
            <MediaStage
              asset={viewModel.media}
              entry={entry}
              cache={cache}
              onSelectAsset={onSelectAsset}
              onZoomImage={onZoomImage}
            />
            <p class="reader-intro">{entry.note || entry.summary}</p>
            {docs.length > 0 && (
              <button class="text-link" data-tab="document" onClick={() => onSelectTab("document")}>
                阅读说明文档
              </button>
            )}
          </div>
          <CodePane
            entry={entry}
            asset={viewModel.asset}
            source={source}
            query={query}
            hitLine={session.line}
            compare={true}
            onSelectAsset={onSelectAsset}
            onCopySource={handleCopyCurrentText}
            onReveal={onRevealAsset}
          />
        </div>
      );
    }

    if (viewModel.mode === "code") {
      return (
        <div class="code-layout">
          <nav class="file-nav" aria-label="代码文件">
            <div class="small-label">{codes.length} 个代码文件</div>
            {codes.map((item) => (
              <FileNavItem
                key={item.id}
                asset={item}
                active={item.id === viewModel.asset.id}
                iconName="code"
                onSelect={onSelectAsset}
              />
            ))}
          </nav>
          <CodePane
            entry={entry}
            asset={viewModel.asset}
            source={source}
            query={query}
            hitLine={session.line}
            compare={false}
            onSelectAsset={onSelectAsset}
            onCopySource={handleCopyCurrentText}
            onReveal={onRevealAsset}
          />
        </div>
      );
    }

    if (viewModel.mode === "document") {
      return (
        <>
          {docs.length > 1 && (
            <div class="file-nav">
              {docs.map((item) => (
                <FileNavItem
                  key={item.id}
                  asset={item}
                  active={item.id === viewModel.asset.id}
                  iconName="doc"
                  onSelect={onSelectAsset}
                />
              ))}
            </div>
          )}
          <DocumentPane
            entry={entry}
            asset={viewModel.asset}
            source={source}
            query={query}
            hitLine={session.line}
            tagName={tagName}
            onCopyEntryID={onCopyEntryID}
            onCopySource={handleCopyCurrentText}
            onCopyPath={handleCopyPath}
            onReveal={onRevealAsset}
            onSelectAsset={onSelectAsset}
          />
        </>
      );
    }

    if (viewModel.mode === "overview-media") {
      const intro = entry.note || contentExcerpt(source) || entry.summary;
      const related = entry.assets.filter((item) => item.id !== viewModel.asset.id);
      return (
        <div class="overview">
          <div class="overview-media">
            <MediaStage
              asset={viewModel.asset}
              entry={entry}
              cache={cache}
              onSelectAsset={onSelectAsset}
              onZoomImage={onZoomImage}
            />
            <div class="related-strip">
              <div class="small-label">同一条内容中的文件</div>
              {related.slice(0, 8).map((item) => (
                <button
                  key={item.id}
                  class="related-file"
                  data-asset={item.id}
                  onClick={() => onSelectAsset(item.id)}
                >
                  <Icon name={assetIconName(item.kind)} />
                  <span>{item.path}</span>
                  <Icon name="right" />
                </button>
              ))}
              {related.length > 8 && (
                <div class="small-label">还有 {related.length - 8} 个文件</div>
              )}
              <div class="reader-meta-actions">
                <AssetActions
                  asset={viewModel.asset}
                  onCopyPath={handleCopyPath}
                  onReveal={onRevealAsset}
                />
              </div>
            </div>
          </div>

          <div class="overview-copy">
            <div class="entry-kicker">
              <span>内容条目</span>
              <button data-copy-entry={entry.id} onClick={() => void onCopyEntryID(entry.id)}>
                #{shortID(entry.id)}
              </button>
            </div>
            <h1>{entry.title}</h1>
            <div class="reader-byline">
              <span>{relativeDate(entry.created_at)}</span>
              <span class="sep">·</span>
              <span>{entry.assets.length} 个文件</span>
              {entry.source && (
                <>
                  <span class="sep">·</span>
                  <span>{sourceLabel(entry.source)}</span>
                </>
              )}
            </div>
            <div class="reader-tag-row">
              {entry.tags.map((slug) => (
                <button
                  key={slug}
                  class="mini-tag"
                  data-reader-tag={slug}
                  onClick={() => onFilterTag(slug)}
                >
                  {tagName(slug)}
                </button>
              ))}
            </div>
            {intro && <p class="reader-intro">{intro}</p>}
            {viewModel.doc && (
              <button
                class="text-link"
                data-asset={viewModel.doc.id}
                onClick={() => onSelectAsset(viewModel.doc!.id)}
              >
                阅读全文与实现笔记
                <Icon name="right" />
              </button>
            )}
            <EntryMetaDetails entry={entry} onCopyEntryID={onCopyEntryID} />
          </div>
        </div>
      );
    }

    if (viewModel.mode === "overview-doc") {
      return (
        <DocumentPane
          entry={entry}
          asset={viewModel.asset}
          source={source}
          query={query}
          hitLine={session.line}
          tagName={tagName}
          onCopyEntryID={onCopyEntryID}
          onCopySource={handleCopyCurrentText}
          onCopyPath={handleCopyPath}
          onReveal={onRevealAsset}
          onSelectAsset={onSelectAsset}
        />
      );
    }

    if (viewModel.mode === "unsupported") {
      return (
        <div class="files-overview">
          <h2>{viewModel.asset.path}</h2>
          <p>原始文件已收录，此格式暂不支持预览。</p>
          <div class="reader-meta-actions">
            <AssetActions
              asset={viewModel.asset}
              onCopyPath={handleCopyPath}
              onReveal={onRevealAsset}
            />
          </div>
        </div>
      );
    }

    return (
      <div class="files-overview">
        <h2>全部文件</h2>
        <p>{entry.assets.length} 个文件 · 属于同一条内容</p>
        {entry.assets.map((asset) => (
          <button
            key={asset.id}
            class="asset-row"
            data-asset={asset.id}
            onClick={() => onSelectAsset(asset.id)}
          >
            <Icon name={assetIconName(asset.kind)} />
            <div>
              <b>{asset.path}</b>
              <small>
                {kindLabel(asset.kind)} · {formatBytes(asset.size)}
              </small>
            </div>
            <Icon name="right" />
          </button>
        ))}
      </div>
    );
  };

  return (
    <dialog
      ref={dialogRef}
      class={`reader${expanded ? " expanded" : ""}`}
      id="reader"
      aria-label="内容阅读"
      tabIndex={-1}
      onClick={(event) => {
        if (event.target === dialogRef.current) onClose();
      }}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
    >
      <div class="reader-shell">
        <header class="reader-top">
          <div class="reader-crumb">
            <span>内容库</span>
            <span>/</span>
            <strong id="reader-crumb-title">{entry?.title ?? ""}</strong>
          </div>
          <div class="reader-actions">
            <button
              class="icon-btn"
              id="reader-prev"
              title="上一条 ←"
              aria-label="上一条内容"
              disabled={queueIndex <= 0}
              onClick={() => onNavigate(-1)}
            >
              <Icon name="left" />
            </button>
            <button
              class="icon-btn"
              id="reader-next"
              title="下一条 →"
              aria-label="下一条内容"
              disabled={queueIndex < 0 || queueIndex >= session.queue.length - 1}
              onClick={() => onNavigate(1)}
            >
              <Icon name="right" />
            </button>
            <span class="separator" />
            <button class="soft-button reader-edit" id="reader-edit" onClick={onEdit}>
              编辑
            </button>
            <button
              class="icon-btn expand-button"
              id="reader-expand"
              title="切换全屏阅读"
              aria-label="切换全屏阅读"
              onClick={() => setExpanded((value) => !value)}
            >
              <Icon name="expand" />
            </button>
            <button
              class="icon-btn"
              id="reader-close"
              title="关闭 Esc"
              aria-label="关闭阅读"
              onClick={onClose}
            >
              <Icon name="close" />
            </button>
          </div>
        </header>

        <nav class="reader-tabs" id="reader-tabs" aria-label="阅读内容">
          {tabs.map((tab) => (
            <button
              key={tab.key}
              class={`reader-tab${session.tab === tab.key && !session.compare ? " active" : ""}`}
              data-tab={tab.key}
              onClick={() => onSelectTab(tab.key)}
            >
              {tab.label}
              {tab.count && <small>{tab.count}</small>}
            </button>
          ))}
          {primaryVideo && codes.length > 0 && (
            <button
              class={`soft-button compare-button${session.compare ? " active" : ""}`}
              data-compare
              aria-pressed={session.compare}
              onClick={onToggleCompare}
            >
              <Icon name="compare" />
              并排对照
            </button>
          )}
        </nav>

        <div ref={bodyRef} class="reader-body" id="reader-body">
          {renderBody()}
        </div>
      </div>
    </dialog>
  );
}
