import type { SearchResult } from "../mygo";
import { Icon } from "./Icons";

export type SortMode = "new" | "old" | "title" | "viewed";
export type ViewMode = "grid" | "list";

const KIND_FILTERS: ReadonlyArray<[string, string]> = [
  ["", "全部"],
  ["video", "视频"],
  ["image", "图片"],
  ["text", "文档"],
  ["code", "代码"],
  ["audio", "音频"],
];

interface BrowseToolbarProps {
  title: string;
  subtitle: string;
  countLabel: string;
  catalog: SearchResult[];
  selectedTags: string[];
  kind: string;
  sort: SortMode;
  activeView: ViewMode;
  tagName: (slug: string) => string;
  onSelectKind: (kind: string) => void;
  onChangeSort: (sort: SortMode) => void;
  onChangeView: (view: ViewMode) => void;
  onToggleTag: (slug: string) => void;
  onClearTags: () => void;
}

export function BrowseToolbar({
  title,
  subtitle,
  countLabel,
  catalog,
  selectedTags,
  kind,
  sort,
  activeView,
  tagName,
  onSelectKind,
  onChangeSort,
  onChangeView,
  onToggleTag,
  onClearTags,
}: BrowseToolbarProps) {
  const baseEntries = catalog.filter((entry) =>
    selectedTags.every((tag) => entry.tags.includes(tag)),
  );

  return (
    <>
      <header class="page-head">
        <div class="title-row">
          <h1 id="page-title">{title}</h1>
          <span class="library-count" id="heading-count">{countLabel}</span>
        </div>
        <p class="page-sub" id="page-sub" hidden={!subtitle}>{subtitle}</p>
      </header>

      <div class="toolbar-wrap">
        <div class="toolbar">
          <div class="type-filters" id="type-filters" aria-label="按包含的内容类型筛选">
            {KIND_FILTERS.map(([value, label]) => {
              const count = value
                ? baseEntries.filter((entry) => entry.assets.some((asset) => asset.kind === value)).length
                : baseEntries.length;
              const description = value ? `包含${label}的内容` : "全部内容";
              const active = kind === value;
              return (
                <button
                  key={value || "all"}
                  class={`filter-chip${active ? " active" : ""}`}
                  data-kind={value}
                  aria-pressed={active}
                  title={description}
                  aria-label={`${description}，${count} 条`}
                  onClick={() => onSelectKind(value)}
                >
                  {label}
                  <b>{count}</b>
                </button>
              );
            })}
          </div>

          <div class="view-tools">
            <select
              id="sort"
              class="sort-select"
              aria-label="内容排序"
              value={sort}
              onChange={(event) =>
                onChangeSort((event.currentTarget as HTMLSelectElement).value as SortMode)
              }
            >
              {sort === "viewed" && <option value="viewed">最近查看</option>}
              <option value="new">最近收录</option>
              <option value="old">最早收录</option>
              <option value="title">按标题排列</option>
            </select>

            <div class="view-toggle" aria-label="显示方式">
              <button
                class={`icon-btn${activeView === "grid" ? " active" : ""}`}
                id="grid-view"
                title="网格视图"
                aria-label="网格视图"
                aria-pressed={activeView === "grid"}
                onClick={() => onChangeView("grid")}
              >
                <Icon name="grid" />
              </button>
              <button
                class={`icon-btn${activeView === "list" ? " active" : ""}`}
                id="list-view"
                title="列表视图"
                aria-label="列表视图"
                aria-pressed={activeView === "list"}
                onClick={() => onChangeView("list")}
              >
                <Icon name="list" />
              </button>
            </div>
          </div>
        </div>

        <div class="selected-filters" id="selected-filters" hidden={!selectedTags.length}>
          {selectedTags.map((slug) => (
            <button
              key={slug}
              class="selected-tag"
              data-tag={slug}
              aria-label={`移除${tagName(slug)}筛选`}
              onClick={() => onToggleTag(slug)}
            >
              {tagName(slug)}
              <Icon name="close" />
            </button>
          ))}
          {selectedTags.length > 0 && (
            <button class="clear-filters" data-clear-tags onClick={onClearTags}>
              清除标签
            </button>
          )}
        </div>
      </div>
    </>
  );
}
