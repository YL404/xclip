import { useCallback, useEffect, useMemo, useRef, useState } from "preact/hooks";
import type { LibraryClient } from "./api";
import type { Entry, Patch, SearchResult, Tag } from "./mygo";
import { uniqueContentBytes } from "./format";
import { createAssetCache } from "./media";
import { applyTheme, readInitialTheme, readSaved, writeSaved, type ThemeMode } from "./storage";
import { primaryAsset, shortID } from "./view";
import { BrowseToolbar, type SortMode, type ViewMode } from "./components/BrowseToolbar";
import { CardGrid, firstMatch } from "./components/CardGrid";
import { EditDialog } from "./components/EditDialog";
import { IconSprite } from "./components/Icons";
import { ImageLightbox } from "./components/ImageLightbox";
import { InfoDialog } from "./components/InfoDialog";
import { ReaderDialog, type ReaderSession, type ReaderTab } from "./components/ReaderDialog";
import { Sidebar, type BrowseScope } from "./components/Sidebar";
import { Topbar } from "./components/Topbar";

const PAGE_SIZE = 60;

const INITIAL_READER: ReaderSession = {
  open: false,
  loading: false,
  error: null,
  entry: null,
  asset: null,
  tab: "overview",
  compare: false,
  line: 0,
  autoplay: false,
  queue: [],
};

function initialTabFor(asset: Entry["assets"][number] | null): ReaderTab {
  if (asset?.kind === "code" && asset.readable) return "code";
  if (asset?.kind === "text" && asset.readable) return "document";
  return asset ? "overview" : "files";
}

interface AppProps {
  client: LibraryClient;
}

export function App({ client }: AppProps) {
  const cache = useMemo(() => createAssetCache(client), [client]);

  // 内容库数据与筛选条件
  const [catalog, setCatalog] = useState<SearchResult[]>([]);
  const [results, setResults] = useState<SearchResult[]>([]);
  const [tags, setTags] = useState<Tag[]>([]);
  const [catalogLoaded, setCatalogLoaded] = useState(false);
  const [resultsError, setResultsError] = useState<string | null>(null);

  const [searchInput, setSearchInput] = useState("");
  const [query, setQuery] = useState("");
  const [selectedTags, setSelectedTags] = useState<string[]>([]);
  const [kind, setKind] = useState("");
  const [scope, setScope] = useState<BrowseScope>("all");
  const [sort, setSort] = useState<SortMode>("new");
  const [view, setView] = useState<ViewMode>(() =>
    readSaved<string>("view", "grid") === "list" ? "list" : "grid",
  );
  const [queryView, setQueryView] = useState<ViewMode>("list");
  const [limit, setLimit] = useState(PAGE_SIZE);

  // 界面偏好与瞬态反馈
  const [history, setHistory] = useState<string[]>(() => readSaved<string[]>("history", []));
  const [tagsExpanded, setTagsExpanded] = useState<boolean>(() => readSaved("tagsExpanded", false));
  const [theme, setTheme] = useState<ThemeMode>(() => readInitialTheme());
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [importMenuOpen, setImportMenuOpen] = useState(false);
  const [importing, setImporting] = useState(false);
  const [toast, setToast] = useState<{ message: string; visible: boolean }>({
    message: "",
    visible: false,
  });

  // 阅读器与子弹窗状态
  const [reader, setReader] = useState<ReaderSession>(INITIAL_READER);
  const [lightboxOpen, setLightboxOpen] = useState(false);
  const [editOpen, setEditOpen] = useState(false);
  const [infoOpen, setInfoOpen] = useState(false);

  const scrollRef = useRef<HTMLDivElement>(null);
  const searchInputRef = useRef<HTMLInputElement>(null);
  const refreshSeq = useRef(0);
  const searchSeq = useRef(0);
  const readerSeq = useRef(0);
  const previousScrollRef = useRef(0);
  const toastTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const searchTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const readerRef = useRef(reader);
  readerRef.current = reader;

  const notify = useCallback((message: string) => {
    if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
    setToast({ message, visible: true });
    toastTimerRef.current = setTimeout(() => {
      setToast((current) => ({ ...current, visible: false }));
    }, 2500);
  }, []);

  useEffect(() => {
    applyTheme(theme);
  }, [theme]);

  useEffect(() => {
    return () => {
      if (toastTimerRef.current) clearTimeout(toastTimerRef.current);
      if (searchTimerRef.current) clearTimeout(searchTimerRef.current);
    };
  }, []);

  const tagMap = useMemo(() => new Map(tags.map((tag) => [tag.slug, tag.name])), [tags]);
  const tagName = useCallback((slug: string) => tagMap.get(slug) ?? slug, [tagMap]);

  const contentBytes = useMemo(() => uniqueContentBytes(catalog), [catalog]);
  const recentCount = useMemo(
    () => catalog.filter((entry) => history.includes(entry.id)).length,
    [catalog, history],
  );
  const pendingCount = useMemo(
    () => catalog.filter((entry) => !entry.summary).length,
    [catalog],
  );

  const visibleEntries = useMemo(() => {
    const filtered = results.filter(
      (entry) =>
        (scope !== "recent" || history.includes(entry.id)) &&
        (scope !== "pending" || !entry.summary),
    );
    return [...filtered].sort((a, b) => {
      if (sort === "title") return a.title.localeCompare(b.title, "zh-CN");
      if (sort === "viewed") return history.indexOf(a.id) - history.indexOf(b.id);
      if (sort === "old") return a.created_at.localeCompare(b.created_at);
      return b.created_at.localeCompare(a.created_at);
    });
  }, [results, scope, history, sort]);

  const visibleEntriesRef = useRef(visibleEntries);
  visibleEntriesRef.current = visibleEntries;

  const refreshCatalog = useCallback(async (syncReader = false) => {
    const seq = ++refreshSeq.current;
    try {
      const [rawTags, rawCatalog] = await Promise.all([
        client.tags(),
        client.search("", [], ""),
      ]);
      if (seq !== refreshSeq.current) return;
      const sortedTags = [...rawTags].sort(
        (a, b) => b.count - a.count || a.name.localeCompare(b.name, "zh-CN"),
      );
      setTags(sortedTags);
      setCatalog(rawCatalog);
      setCatalogLoaded(true);
      setResultsError(null);

      // 外部变更或手动刷新时，若阅读器正打开某条目，同步重拉该条目避免展示过期元数据。
      const activeReader = readerRef.current;
      if (syncReader && activeReader.open && activeReader.entry) {
        const entryID = activeReader.entry.id;
        void client
          .get(entryID)
          .then((fresh) => {
            setReader((current) => {
              if (!current.open || current.entry?.id !== entryID) return current;
              const nextAsset =
                fresh.assets.find((item) => item.id === current.asset?.id) ??
                primaryAsset(fresh.assets) ??
                null;
              return { ...current, entry: fresh, asset: nextAsset };
            });
          })
          .catch(() => {
            // 条目可能已被删除，保留当前阅读界面直至关闭。
          });
      }
    } catch (error) {
      if (seq === refreshSeq.current) {
        setCatalogLoaded(true);
        setResultsError(String(error));
      }
    }
  }, [client]);

  // 初始加载以及订阅外部变更事件和文件拖入事件。
  useEffect(() => {
    void refreshCatalog();
  }, [refreshCatalog]);

  useEffect(() => {
    return client.onLibraryChanged(() => {
      cache.clear();
      void refreshCatalog(true);
    });
  }, [client, cache, refreshCatalog]);

  // 根据 query / selectedTags / kind 刷新检索结果；无关键词时直接过滤内存目录，避免重复 RPC。
  useEffect(() => {
    if (!catalogLoaded && !query) return;
    const seq = ++searchSeq.current;
    setLimit(PAGE_SIZE);

    if (!query) {
      const next = catalog.filter(
        (entry) =>
          selectedTags.every((tag) => entry.tags.includes(tag)) &&
          (!kind || entry.assets.some((asset) => asset.kind === kind)),
      );
      setResults(next);
      setResultsError(null);
      return;
    }

    client
      .search(query, selectedTags, kind)
      .then((found) => {
        if (seq !== searchSeq.current) return;
        setResults(found);
        setResultsError(null);
      })
      .catch((error: unknown) => {
        if (seq === searchSeq.current) setResultsError(String(error));
      });
  }, [client, catalog, catalogLoaded, query, selectedTags, kind]);

  const openEntry = useCallback(
    async (id: string, autoplay = false) => {
      const seq = ++readerSeq.current;
      const wasOpen = readerRef.current.open;
      if (!wasOpen) {
        previousScrollRef.current = scrollRef.current?.scrollTop ?? 0;
      }
      const nextQueue = wasOpen
        ? readerRef.current.queue
        : visibleEntriesRef.current.map((item) => item.id);

      setReader((current) => ({
        ...current,
        open: true,
        loading: true,
        error: null,
        queue: nextQueue,
      }));

      try {
        const entry = await client.get(id);
        if (seq !== readerSeq.current) return;
        const matchedResult = results.find((item) => item.id === id);
        const match = !autoplay && query && matchedResult ? firstMatch(matchedResult) : undefined;
        const targetAsset =
          entry.assets.find((asset) => asset.id === match?.asset_id) ??
          primaryAsset(entry.assets) ??
          null;

        setHistory((prev) => {
          const next = [id, ...prev.filter((item) => item !== id)].slice(0, 300);
          writeSaved("history", next);
          return next;
        });

        setReader((current) => {
          if (!current.open) return current;
          return {
            ...current,
            loading: false,
            error: null,
            entry,
            asset: targetAsset,
            tab: initialTabFor(targetAsset),
            compare: false,
            line: match?.line ?? 0,
            autoplay,
          };
        });
      } catch (error) {
        if (seq !== readerSeq.current) return;
        setReader((current) =>
          current.open ? { ...current, loading: false, error: String(error) } : current,
        );
      }
    },
    [client, results, query],
  );

  const closeReader = useCallback(() => {
    readerSeq.current++;
    const closedEntryID = readerRef.current.entry?.id;
    setLightboxOpen(false);
    setEditOpen(false);
    setReader((current) => ({ ...current, open: false, loading: false, autoplay: false }));
    requestAnimationFrame(() => {
      if (scrollRef.current) scrollRef.current.scrollTop = previousScrollRef.current;
      if (closedEntryID) {
        const card = document.querySelector<HTMLElement>(`.card[data-id="${CSS.escape ? CSS.escape(closedEntryID) : closedEntryID}"]`);
        card?.focus({ preventScroll: true });
      }
    });
  }, []);

  const importContent = useCallback(
    async (action: () => Promise<Entry>) => {
      if (importing) return;
      setImporting(true);
      try {
        const entry = await action();
        if (entry.id) {
          await refreshCatalog();
          await openEntry(entry.id, false);
          notify("内容已收录到本地库");
        }
      } catch (error) {
        notify(String(error));
      } finally {
        setImporting(false);
      }
    },
    [importing, refreshCatalog, openEntry, notify],
  );

  useEffect(() => {
    return client.onFileDrop((paths) => {
      void importContent(() => client.importPaths(paths));
    });
  }, [client, importContent]);

  const copyValue = useCallback(
    async (value: string, label: string): Promise<boolean> => {
      try {
        await client.copy(value);
        notify(`${label}已复制`);
        return true;
      } catch (error) {
        notify(`复制失败：${String(error)}`);
        return false;
      }
    },
    [client, notify],
  );

  const copyEntryID = useCallback(
    (id: string) => copyValue(shortID(id), `内容编码 #${shortID(id)}`),
    [copyValue],
  );

  const handleSearchInput = useCallback((value: string) => {
    setSearchInput(value);
    if (searchTimerRef.current) clearTimeout(searchTimerRef.current);
    searchTimerRef.current = setTimeout(() => {
      setQuery(value.trim());
      if (scrollRef.current) scrollRef.current.scrollTop = 0;
    }, 160);
  }, []);

  const clearSearch = useCallback(() => {
    if (searchTimerRef.current) clearTimeout(searchTimerRef.current);
    setSearchInput("");
    setQuery("");
  }, []);

  const resetBrowse = useCallback(() => {
    if (searchTimerRef.current) clearTimeout(searchTimerRef.current);
    setSearchInput("");
    setQuery("");
    setKind("");
    setSelectedTags([]);
    setScope("all");
    setSort("new");
    if (scrollRef.current) scrollRef.current.scrollTop = 0;
  }, []);

  const selectScope = useCallback((nextScope: "recent" | "pending") => {
    if (searchTimerRef.current) clearTimeout(searchTimerRef.current);
    setScope(nextScope);
    setSelectedTags([]);
    setKind("");
    setSearchInput("");
    setQuery("");
    setSort(nextScope === "recent" ? "viewed" : "new");
  }, []);

  const toggleTag = useCallback((slug: string) => {
    setSelectedTags((prev) =>
      prev.includes(slug) ? prev.filter((item) => item !== slug) : [...prev, slug],
    );
    setScope("all");
    setSort((prev) => (prev === "viewed" ? "new" : prev));
  }, []);

  const handleChangeView = useCallback(
    (nextView: ViewMode) => {
      if (query) {
        setQueryView(nextView);
      } else {
        setView(nextView);
        writeSaved("view", nextView);
      }
    },
    [query],
  );

  const navigateReaderEntry = useCallback(
    (direction: -1 | 1) => {
      const current = readerRef.current;
      if (!current.entry) return;
      const targetID = current.queue[current.queue.indexOf(current.entry.id) + direction];
      if (targetID) void openEntry(targetID, false);
    },
    [openEntry],
  );

  const selectReaderAsset = useCallback((assetID: string) => {
    setReader((current) => {
      const asset = current.entry?.assets.find((item) => item.id === assetID);
      if (!asset) return current;
      const nextTab: ReaderTab =
        asset.kind === "code" && asset.readable
          ? "code"
          : asset.kind === "text" && asset.readable
            ? "document"
            : "overview";
      return {
        ...current,
        asset,
        tab: nextTab,
        compare: asset.kind === "code" && asset.readable ? current.compare : false,
        line: 0,
        autoplay: false,
      };
    });
  }, []);

  const selectReaderTab = useCallback((tab: ReaderTab) => {
    setReader((current) => ({
      ...current,
      compare: false,
      tab,
      line: 0,
      asset:
        tab === "overview" && current.entry
          ? primaryAsset(current.entry.assets) ?? null
          : current.asset,
    }));
  }, []);

  const readerImages = useMemo(
    () => reader.entry?.assets.filter((asset) => asset.kind === "image") ?? [],
    [reader.entry],
  );
  const lightboxIndex = useMemo(() => {
    if (!readerImages.length) return -1;
    const found = readerImages.findIndex((item) => item.id === reader.asset?.id);
    return found >= 0 ? found : 0;
  }, [readerImages, reader.asset?.id]);

  const stepLightbox = useCallback(
    (direction: -1 | 1) => {
      if (!readerImages.length) return;
      const nextIndex = Math.max(0, Math.min(readerImages.length - 1, lightboxIndex + direction));
      setReader((current) => ({ ...current, asset: readerImages[nextIndex] }));
    },
    [readerImages, lightboxIndex],
  );

  const handleSaveEdit = useCallback(
    async (id: string, patch: Patch) => {
      const updated = await client.update(id, patch);
      setReader((current) =>
        current.entry?.id === id ? { ...current, entry: updated } : current,
      );
      await refreshCatalog();
      notify("更改已保存");
    },
    [client, refreshCatalog, notify],
  );

  // 点击侧栏外部时收起移动端侧边栏。
  useEffect(() => {
    if (!sidebarOpen) return;
    const onClick = (event: MouseEvent) => {
      if (!(event.target as Element | null)?.closest(".sidebar, #mobile-menu")) {
        setSidebarOpen(false);
      }
    };
    document.addEventListener("click", onClick);
    return () => document.removeEventListener("click", onClick);
  }, [sidebarOpen]);

  // 全局键盘快捷键。
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as Element | null;
      if (!target) return;
      const editing = /^(INPUT|TEXTAREA|SELECT|VIDEO|AUDIO)$/.test(target.tagName);

      if (editOpen || infoOpen) return;

      if (lightboxOpen) {
        if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
          event.preventDefault();
          stepLightbox(event.key === "ArrowLeft" ? -1 : 1);
        }
        return;
      }

      if (reader.open) {
        if (
          !editing &&
          !target.closest(".code-scroll") &&
          (event.key === "ArrowLeft" || event.key === "ArrowRight")
        ) {
          event.preventDefault();
          navigateReaderEntry(event.key === "ArrowLeft" ? -1 : 1);
        }
        return;
      }

      if (((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") || (event.key === "/" && !editing)) {
        event.preventDefault();
        searchInputRef.current?.focus();
        searchInputRef.current?.select();
        return;
      }

      if (event.key === "Escape") {
        if (importMenuOpen) {
          setImportMenuOpen(false);
          return;
        }
        if (query || searchInput) clearSearch();
        setSidebarOpen(false);
        return;
      }

      if (editing || target.closest("button")) return;
      const card = target.closest<HTMLElement>("[data-id]");
      if (!card) return;

      if (event.key === " " || event.key === "Enter") {
        event.preventDefault();
        card.click();
        return;
      }

      if (["ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight"].includes(event.key)) {
        event.preventDefault();
        const cards = [...document.querySelectorAll<HTMLElement>(".card")];
        const resultsEl = document.querySelector<HTMLElement>("#results");
        const columns =
          !resultsEl || resultsEl.classList.contains("list-view")
            ? 1
            : getComputedStyle(resultsEl).gridTemplateColumns.split(" ").length;
        const offset =
          event.key === "ArrowDown"
            ? columns
            : event.key === "ArrowUp"
              ? -columns
              : event.key === "ArrowRight"
                ? 1
                : -1;
        cards[Math.max(0, Math.min(cards.length - 1, cards.indexOf(card) + offset))]?.focus();
      }
    };

    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [
    editOpen,
    infoOpen,
    lightboxOpen,
    reader.open,
    importMenuOpen,
    query,
    searchInput,
    stepLightbox,
    navigateReaderEntry,
    clearSearch,
  ]);

  const pageTitle = query
    ? "搜索结果"
    : scope === "recent"
      ? "最近查看"
      : scope === "pending"
        ? "待提炼"
        : selectedTags.length === 1
          ? tagName(selectedTags[0])
          : selectedTags.length
            ? "标签筛选"
            : "全部内容";

  const pageSubtitle = query
    ? `在标题、正文与代码中搜索“${query}” · 点击结果直达命中文件`
    : scope === "pending"
      ? "已收录、但还没有英文摘要的内容"
      : scope === "recent"
        ? "按最近打开排序"
        : selectedTags.length
          ? `标签：${selectedTags.map(tagName).join(" + ")}`
          : "";

  const activeView: ViewMode = query ? queryView : view;
  const countLabel = catalogLoaded ? `${visibleEntries.length} 条` : "正在读取…";

  return (
    <div class={importing ? "importing" : undefined} style={{ height: "100%" }}>
      <IconSprite />

      <main class={`app${sidebarOpen ? " sidebar-open" : ""}`} id="workspace">
        <Sidebar
          scope={scope}
          selectedTags={selectedTags}
          tags={tags}
          tagsExpanded={tagsExpanded}
          allCount={catalog.length}
          recentCount={recentCount}
          pendingCount={pendingCount}
          contentBytes={contentBytes}
          theme={theme}
          onReset={resetBrowse}
          onSelectScope={selectScope}
          onToggleTag={toggleTag}
          onToggleTagsExpanded={() => {
            setTagsExpanded((prev) => {
              const next = !prev;
              writeSaved("tagsExpanded", next);
              return next;
            });
          }}
          onRefresh={() => {
            cache.clear();
            void refreshCatalog(true);
          }}
          onToggleTheme={() => setTheme((prev) => (prev === "light" ? "dark" : "light"))}
          onOpenInfo={() => setInfoOpen(true)}
        />

        <section class="main" aria-label="内容浏览">
          <Topbar
            title={pageTitle}
            searchInput={searchInput}
            searchInputRef={searchInputRef}
            importMenuOpen={importMenuOpen}
            onToggleMobileSidebar={() => setSidebarOpen((open) => !open)}
            onSearchInput={handleSearchInput}
            onClearSearch={clearSearch}
            onSetImportMenuOpen={setImportMenuOpen}
            onImportFolder={() => void importContent(() => client.chooseAndImport())}
            onImportFiles={() => void importContent(() => client.chooseFilesAndImport())}
          />

          <div ref={scrollRef} class="content-scroll" id="content-scroll">
            <BrowseToolbar
              title={pageTitle}
              subtitle={pageSubtitle}
              countLabel={countLabel}
              catalog={catalog}
              selectedTags={selectedTags}
              kind={kind}
              sort={sort}
              activeView={activeView}
              tagName={tagName}
              onSelectKind={setKind}
              onChangeSort={setSort}
              onChangeView={handleChangeView}
              onToggleTag={toggleTag}
              onClearTags={() => setSelectedTags([])}
            />

            <CardGrid
              entries={visibleEntries}
              catalogEmpty={catalog.length === 0}
              loading={!catalogLoaded}
              error={resultsError}
              query={query}
              sort={sort}
              activeView={activeView}
              limit={limit}
              cache={cache}
              scrollRootRef={scrollRef}
              tagName={tagName}
              onOpenEntry={(id, play) => void openEntry(id, play)}
              onCopyEntryID={copyEntryID}
              onToggleTag={toggleTag}
              onReset={resetBrowse}
              onLoadMore={() => setLimit((prev) => prev + PAGE_SIZE)}
            />
          </div>
        </section>
      </main>

      <ReaderDialog
        session={reader}
        query={query}
        cache={cache}
        tagName={tagName}
        onClose={closeReader}
        onNavigate={navigateReaderEntry}
        onSelectTab={selectReaderTab}
        onToggleCompare={() =>
          setReader((current) => ({ ...current, compare: !current.compare, line: 0 }))
        }
        onSelectAsset={selectReaderAsset}
        onZoomImage={() => {
          if (readerImages.length) setLightboxOpen(true);
        }}
        onEdit={() => {
          if (reader.entry) setEditOpen(true);
        }}
        onCopyEntryID={copyEntryID}
        onCopyText={copyValue}
        onRevealAsset={(assetID) => {
          void client.reveal(assetID).catch((error: unknown) => notify(String(error)));
        }}
        onFilterTag={(slug) => {
          closeReader();
          toggleTag(slug);
        }}
        onNotify={notify}
        onConsumeAutoplay={() =>
          setReader((current) => (current.autoplay ? { ...current, autoplay: false } : current))
        }
      />

      <ImageLightbox
        open={lightboxOpen}
        images={readerImages}
        index={lightboxIndex}
        onStep={stepLightbox}
        onClose={() => setLightboxOpen(false)}
      />

      <EditDialog
        open={editOpen}
        entry={reader.entry}
        onSave={handleSaveEdit}
        onClose={() => setEditOpen(false)}
      />

      <InfoDialog open={infoOpen} onClose={() => setInfoOpen(false)} />

      <div class={`toast${toast.visible ? " visible" : ""}`} id="toast" role="status" aria-live="polite">
        {toast.message}
      </div>
    </div>
  );
}
