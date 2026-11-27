import type { Tag } from "../mygo";
import { formatBytes } from "../format";
import type { ThemeMode } from "../storage";
import { Icon } from "./Icons";

export type BrowseScope = "all" | "recent" | "pending";

const brandIconURL = new URL("../icon.svg", import.meta.url).href;
const COLLAPSED_TAG_LIMIT = 10;

interface SidebarProps {
  scope: BrowseScope;
  selectedTags: string[];
  tags: Tag[];
  tagsExpanded: boolean;
  allCount: number;
  recentCount: number;
  pendingCount: number;
  contentBytes: number;
  theme: ThemeMode;
  onReset: () => void;
  onSelectScope: (scope: "recent" | "pending") => void;
  onToggleTag: (slug: string) => void;
  onToggleTagsExpanded: () => void;
  onRefresh: () => void;
  onToggleTheme: () => void;
  onOpenInfo: () => void;
}

export function Sidebar({
  scope,
  selectedTags,
  tags,
  tagsExpanded,
  allCount,
  recentCount,
  pendingCount,
  contentBytes,
  theme,
  onReset,
  onSelectScope,
  onToggleTag,
  onToggleTagsExpanded,
  onRefresh,
  onToggleTheme,
  onOpenInfo,
}: SidebarProps) {
  const visible = tagsExpanded ? tags : tags.slice(0, COLLAPSED_TAG_LIMIT);
  const extra = tags.filter((tag) => selectedTags.includes(tag.slug) && !visible.includes(tag));
  const displayedTags = [...visible, ...extra];

  return (
    <aside class="sidebar" aria-label="内容导航">
      <div class="brand">
        <img src={brandIconURL} alt="" />
        <span class="brand-word">xclip</span>
      </div>

      <nav class="primary-nav" aria-label="内容范围">
        <button
          class={`nav-item${scope === "all" && selectedTags.length === 0 ? " active" : ""}`}
          id="all-nav"
          onClick={onReset}
        >
          <Icon name="grid" />
          <span>全部内容</span>
          <span class="count" id="all-count">{allCount}</span>
        </button>
        <button
          class={`nav-item${scope === "recent" ? " active" : ""}`}
          id="recent-nav"
          onClick={() => onSelectScope("recent")}
        >
          <Icon name="clock" />
          <span>最近查看</span>
          <span class="count" id="recent-count">{recentCount}</span>
        </button>
        <button
          class={`nav-item${scope === "pending" ? " active" : ""}`}
          id="pending-nav"
          onClick={() => onSelectScope("pending")}
        >
          <Icon name="doc" />
          <span>待提炼</span>
          <span class="count" id="pending-count">{pendingCount}</span>
        </button>
      </nav>

      <div class="tag-section">
        <div class="nav-heading">
          <span>标签</span>
          <button
            class="tags-toggle"
            id="tags-toggle"
            aria-expanded={tagsExpanded}
            hidden={tags.length <= COLLAPSED_TAG_LIMIT}
            onClick={onToggleTagsExpanded}
          >
            {tagsExpanded ? "收起" : `全部 ${tags.length}`}
          </button>
        </div>
        <nav id="tag-nav" aria-label="按标签筛选">
          {displayedTags.map((tag) => {
            const active = selectedTags.includes(tag.slug);
            return (
              <button
                key={tag.slug}
                class={`nav-item tag-item${active ? " active" : ""}`}
                data-tag={tag.slug}
                aria-pressed={active}
                onClick={() => onToggleTag(tag.slug)}
              >
                <span class="tag-dot" />
                <span>{tag.name}</span>
                <span class="count">{tag.count}</span>
              </button>
            );
          })}
        </nav>
      </div>

      <div class="sidebar-footer">
        <div class="local-state">
          <span class="local-dot" />
          <span id="library-state">{`仅存本地 · 内容 ${formatBytes(contentBytes)}`}</span>
        </div>
        <div class="footer-tools">
          <button
            class="icon-btn"
            id="refresh"
            title="刷新内容库"
            aria-label="刷新内容库"
            onClick={onRefresh}
          >
            <Icon name="refresh" />
          </button>
          <button
            class="icon-btn theme-button"
            id="theme"
            title="切换深浅模式"
            aria-label="切换深浅模式"
            onClick={onToggleTheme}
          >
            <Icon name={theme === "light" ? "moon" : "sun"} />
          </button>
          <button
            class="icon-btn"
            id="about"
            title="快捷键与帮助"
            aria-label="快捷键与帮助"
            onClick={onOpenInfo}
          >
            <Icon name="info" />
          </button>
        </div>
      </div>
    </aside>
  );
}
