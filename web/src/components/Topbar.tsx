import { useEffect, useRef } from "preact/hooks";
import type { RefObject } from "preact";
import { Icon } from "./Icons";

interface TopbarProps {
  title: string;
  searchInput: string;
  searchInputRef: RefObject<HTMLInputElement | null>;
  importMenuOpen: boolean;
  onToggleMobileSidebar: () => void;
  onSearchInput: (value: string) => void;
  onClearSearch: () => void;
  onSetImportMenuOpen: (open: boolean) => void;
  onImportFolder: () => void;
  onImportFiles: () => void;
}

export function Topbar({
  title,
  searchInput,
  searchInputRef,
  importMenuOpen,
  onToggleMobileSidebar,
  onSearchInput,
  onClearSearch,
  onSetImportMenuOpen,
  onImportFolder,
  onImportFiles,
}: TopbarProps) {
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!importMenuOpen) return;
    menuRef.current?.querySelector<HTMLButtonElement>('[role="menuitem"]')?.focus();
  }, [importMenuOpen]);

  useEffect(() => {
    if (!importMenuOpen) return;
    const onDocumentClick = (event: MouseEvent) => {
      if (!(event.target as Element | null)?.closest(".import-wrap")) {
        onSetImportMenuOpen(false);
      }
    };
    document.addEventListener("click", onDocumentClick);
    return () => document.removeEventListener("click", onDocumentClick);
  }, [importMenuOpen, onSetImportMenuOpen]);

  const closeMenu = (restoreFocus: boolean) => {
    onSetImportMenuOpen(false);
    if (restoreFocus) triggerRef.current?.focus();
  };

  const handleMenuKeyDown = (event: KeyboardEvent) => {
    const items = [...(menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]') ?? [])];
    if (!items.length) return;
    const index = items.indexOf(document.activeElement as HTMLButtonElement);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      event.stopPropagation();
      const delta = event.key === "ArrowDown" ? 1 : -1;
      items[(index + delta + items.length) % items.length]?.focus();
    } else if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      event.stopPropagation();
      items[event.key === "Home" ? 0 : items.length - 1]?.focus();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      closeMenu(true);
    }
  };

  return (
    <header class="topbar">
      <button
        class="icon-btn mobile-menu"
        id="mobile-menu"
        aria-label="展开内容导航"
        style={{ display: "none" }}
        onClick={onToggleMobileSidebar}
      >
        <Icon name="menu" />
      </button>

      <div class="topbar-crumb">
        <span>内容库</span>
        <span class="divider">/</span>
        <strong id="breadcrumb">{title}</strong>
      </div>

      <div class="topbar-actions">
        <div class="search-box">
          <Icon name="search" />
          <input
            ref={searchInputRef}
            id="search"
            type="search"
            aria-label="搜索内容"
            placeholder="搜索标题、正文或代码"
            autocomplete="off"
            spellcheck={false}
            value={searchInput}
            onInput={(event) => onSearchInput((event.currentTarget as HTMLInputElement).value)}
          />
          <button
            class="icon-btn"
            id="clear-search"
            aria-label="清除搜索"
            hidden={!searchInput.trim()}
            onClick={() => {
              onClearSearch();
              searchInputRef.current?.focus();
            }}
          >
            <Icon name="close" />
          </button>
          <kbd>⌘ K</kbd>
        </div>

        <div class="import-wrap">
          <button
            ref={triggerRef}
            class="primary-button import-button"
            id="import-menu"
            aria-haspopup="menu"
            aria-expanded={importMenuOpen}
            aria-controls="import-options"
            aria-label="收录"
            onClick={(event) => {
              event.stopPropagation();
              onSetImportMenuOpen(!importMenuOpen);
            }}
          >
            <Icon name="plus" />
            <span>收录</span>
            <Icon name="chevron" className="chevron" />
          </button>

          <div
            ref={menuRef}
            class="import-menu"
            id="import-options"
            role="menu"
            hidden={!importMenuOpen}
            onKeyDown={handleMenuKeyDown}
          >
            <button
              type="button"
              role="menuitem"
              id="import"
              onClick={() => {
                closeMenu(true);
                onImportFolder();
              }}
            >
              <Icon name="folder" />
              <span>
                <b>收录文件夹</b>
                <small>把整个目录作为一条内容</small>
              </span>
            </button>
            <button
              type="button"
              role="menuitem"
              id="import-files"
              onClick={() => {
                closeMenu(true);
                onImportFiles();
              }}
            >
              <Icon name="doc" />
              <span>
                <b>选择文件</b>
                <small>可一次选择多个文件</small>
              </span>
            </button>
          </div>
        </div>
      </div>
    </header>
  );
}
