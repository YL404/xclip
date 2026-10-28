const iconURL = new URL("./icon.svg", import.meta.url).href;

export const layout = `
<svg aria-hidden="true" style="position:absolute;width:0;height:0;overflow:hidden"><defs>
<symbol id="i-grid" viewBox="0 0 24 24"><rect x="4" y="4" width="6" height="6" rx="1"></rect><rect x="14" y="4" width="6" height="6" rx="1"></rect><rect x="4" y="14" width="6" height="6" rx="1"></rect><rect x="14" y="14" width="6" height="6" rx="1"></rect></symbol>
<symbol id="i-list" viewBox="0 0 24 24"><path d="M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01"></path></symbol>
<symbol id="i-search" viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="6.5"></circle><path d="m16 16 4.5 4.5"></path></symbol>
<symbol id="i-clock" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"></circle><path d="M12 7v5l3 2"></path></symbol>
<symbol id="i-folder" viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v10H3Z"></path></symbol>
<symbol id="i-close" viewBox="0 0 24 24"><path d="m6 6 12 12M6 18 18 6"></path></symbol>
<symbol id="i-check" viewBox="0 0 24 24"><path d="m5 12 4 4L19 6"></path></symbol>
<symbol id="i-play" viewBox="0 0 24 24"><path d="m7 4 13 8-13 8Z"></path></symbol>
<symbol id="i-video" viewBox="0 0 24 24"><rect x="3" y="5" width="13" height="14" rx="2"></rect><path d="m16 10 5-3v10l-5-3"></path></symbol>
<symbol id="i-image" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="2"></rect><circle cx="8" cy="8" r="1.5"></circle><path d="m4 17 5-5 4 4 3-3 5 5"></path></symbol>
<symbol id="i-doc" viewBox="0 0 24 24"><path d="M14 3H5v18h14V8Zm0 0v5h5M8 12h8M8 16h6"></path></symbol>
<symbol id="i-code" viewBox="0 0 24 24"><path d="m8 6-6 6 6 6M16 6l6 6-6 6M14 4l-4 16"></path></symbol>
<symbol id="i-right" viewBox="0 0 24 24"><path d="m9 5 7 7-7 7"></path></symbol>
<symbol id="i-left" viewBox="0 0 24 24"><path d="m15 5-7 7 7 7"></path></symbol>
<symbol id="i-copy" viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="13" rx="2"></rect><path d="M16 8V3H3v13h5"></path></symbol>
<symbol id="i-expand" viewBox="0 0 24 24"><path d="M8 3H3v5M16 3h5v5M21 16v5h-5M3 16v5h5"></path></symbol>
<symbol id="i-compare" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"></rect><path d="M12 4v16M6 8h3M15 8h3M15 12h3"></path></symbol>
<symbol id="i-sun" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"></circle><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M5 19l1.5-1.5M17.5 6.5 19 5"></path></symbol>
<symbol id="i-moon" viewBox="0 0 24 24"><path d="M20 14a8 8 0 1 1-10-10 7 7 0 0 0 10 10Z"></path></symbol>
<symbol id="i-menu" viewBox="0 0 24 24"><path d="M4 6h16M4 12h16M4 18h16"></path></symbol>
<symbol id="i-info" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"></circle><path d="M12 11v6M12 7h.01"></path></symbol>
</defs></svg>
<main class="app" id="workspace" data-screen-label="内容库">
<aside class="sidebar" aria-label="内容导航">
<div class="brand"><img src="${iconURL}" alt=""><span class="brand-word">xclip</span><small>个人内容库</small></div>
<div class="import-actions"><button class="soft-button" id="import">收录文件夹</button><button class="soft-button" id="import-files">选择文件</button></div><div class="nav-heading">内容库</div>
<button class="nav-item active" id="all-nav"><svg aria-hidden="true"><use href="#i-grid"></use></svg><span>全部内容</span><span class="count" id="all-count">0</span></button>
<button class="nav-item" id="recent-nav"><svg aria-hidden="true"><use href="#i-clock"></use></svg><span>最近查看</span><span class="count" id="recent-count">0</span></button>
<button class="nav-item" id="pending-nav"><svg aria-hidden="true"><use href="#i-doc"></use></svg><span>待提炼</span><span class="count" id="pending-count">0</span></button><div class="tag-section"><div class="nav-heading">标签</div><nav id="tag-nav" aria-label="按标签筛选"></nav></div>
<div class="sidebar-footer"><div class="local-state"><span class="local-dot"></span>本地内容库</div><div class="footer-tools"><button class="prototype-help" id="about">快捷键与帮助</button><button class="icon-btn" id="refresh" title="刷新内容库" aria-label="刷新内容库"><svg aria-hidden="true"><use href="#i-clock"></use></svg></button><button class="icon-btn theme-button" id="theme" title="切换深浅模式" aria-label="切换深浅模式"><svg aria-hidden="true"><use href="#i-moon"></use></svg></button></div></div>
</aside>
<section class="main" aria-label="内容浏览">
<header class="topbar"><button class="icon-btn mobile-menu" id="mobile-menu" aria-label="展开内容导航" style="display:none"><svg aria-hidden="true"><use href="#i-menu"></use></svg></button><svg aria-hidden="true" style="width:15px;height:15px"><use href="#i-folder"></use></svg><span>我的内容库</span><span class="divider">/</span><span class="crumb" id="breadcrumb">全部内容</span><div class="topbar-right"><span>原始内容，随时可读</span><button class="icon-btn" id="help" title="使用说明与快捷键" aria-label="使用说明与快捷键"><svg aria-hidden="true"><use href="#i-info"></use></svg></button></div></header>
<div class="content-scroll" id="content-scroll">
<div class="library-head"><div class="heading-line"><h1 id="page-title">全部内容</h1><span class="library-count" id="heading-count">0 条</span></div><p class="library-caption" id="page-caption">图文、视频、代码，和它们原本的上下文。</p>
<div class="search-box"><svg aria-hidden="true"><use href="#i-search"></use></svg><input id="search" type="search" aria-label="搜索内容" placeholder="搜索标题、正文或代码…" autocomplete="off" spellcheck="false"><button class="icon-btn" id="clear-search" aria-label="清除搜索" hidden><svg aria-hidden="true"><use href="#i-close"></use></svg></button><kbd>⌘ K</kbd></div>
<div class="toolbar"><div class="type-filters" id="type-filters" aria-label="按包含的内容类型筛选"></div><div class="view-tools"><select id="sort" class="sort-select" aria-label="内容排序"><option value="new">最近收录</option><option value="old">最早收录</option><option value="title">按标题排列</option></select><div class="view-toggle" aria-label="显示方式"><button class="icon-btn active" id="grid-view" title="卡片视图" aria-label="卡片视图" aria-pressed="true"><svg aria-hidden="true"><use href="#i-grid"></use></svg></button><button class="icon-btn" id="list-view" title="列表视图" aria-label="列表视图" aria-pressed="false"><svg aria-hidden="true"><use href="#i-list"></use></svg></button></div></div></div>
<div class="selected-filters" id="selected-filters" hidden></div></div>
<div class="results-area"><div class="results-meta"><span id="result-count">正在读取内容…</span><span class="keyboard-hint"><kbd>空格</kbd> 快速查看 <span style="margin:0 4px">·</span> <kbd>Esc</kbd> 返回浏览</span></div><div class="cards" id="results" aria-live="polite"></div><button class="soft-button load-more" id="load-more" hidden>显示更多内容</button></div>
</div></section></main>
<dialog class="reader" id="reader" aria-label="内容阅读" data-screen-label="阅读预览"><div class="reader-shell"><header class="reader-top"><div class="reader-crumb"><span>内容库</span><span>/</span><strong id="reader-crumb-title"></strong></div><div class="reader-actions"><button class="soft-button reader-edit" id="reader-edit">编辑</button><button class="icon-btn" id="reader-prev" title="上一条 ←" aria-label="上一条内容"><svg aria-hidden="true"><use href="#i-left"></use></svg></button><button class="icon-btn" id="reader-next" title="下一条 →" aria-label="下一条内容"><svg aria-hidden="true"><use href="#i-right"></use></svg></button><span class="separator"></span><button class="icon-btn expand-button" id="reader-expand" title="切换全屏阅读" aria-label="切换全屏阅读"><svg aria-hidden="true"><use href="#i-expand"></use></svg></button><button class="icon-btn" id="reader-close" title="关闭 Esc" aria-label="关闭阅读"><svg aria-hidden="true"><use href="#i-close"></use></svg></button></div></header><nav class="reader-tabs" id="reader-tabs" aria-label="阅读内容"></nav><div class="reader-body" id="reader-body"></div></div></dialog>
<dialog class="image-view" id="image-view" aria-label="放大图片"><div class="image-shell"><header class="image-toolbar"><span id="image-title"></span><button class="icon-btn" id="image-prev" aria-label="上一张图片"><svg aria-hidden="true"><use href="#i-left"></use></svg></button><button class="icon-btn" id="image-next" aria-label="下一张图片"><svg aria-hidden="true"><use href="#i-right"></use></svg></button><button class="icon-btn" id="image-close" aria-label="关闭放大图片"><svg aria-hidden="true"><use href="#i-close"></use></svg></button></header><div class="image-canvas"><img id="large-image" alt=""></div></div></dialog>
<dialog class="info-dialog" id="info-dialog" aria-labelledby="info-title"><header class="info-head"><h2 id="info-title">阅读与检索</h2><button class="icon-btn" id="info-close" aria-label="关闭说明"><svg aria-hidden="true"><use href="#i-close"></use></svg></button></header><p>一条内容可以同时保存说明、代码、图片和视频。通过标签或关键词找回内容，直接打开命中的文件。</p><p>卡片右下角的编码按钮可直接复制内容编码。文件和文件夹可通过收录按钮或拖入窗口添加。</p><div class="shortcut-list"><span>搜索内容</span><kbd>⌘ / Ctrl K</kbd><span>打开选中的内容</span><kbd>空格 / Enter</kbd><span>上一条 / 下一条</span><kbd>← / →</kbd><span>关闭阅读</span><kbd>Esc</kbd></div></dialog>
<dialog class="edit-dialog" id="edit-dialog"><form id="edit-form"><div class="dialog-head"><h2>编辑内容</h2><button type="button" class="icon-btn" id="close-edit" aria-label="关闭编辑"><svg aria-hidden="true"><use href="#i-close"></use></svg></button></div><label>标题<input name="title" required></label><label>英文摘要<textarea name="summary" rows="4" placeholder="用一至两句英文概括内容"></textarea><small>单行英文，不超过 400 字符。</small></label><label>个人备注<textarea name="note" rows="3"></textarea></label><label>标签<input name="tags" placeholder="swiftui, interaction:交互设计"><small>逗号分隔；已有标签使用英文 slug，新标签使用 slug:中文名称。</small></label><div id="edit-error" class="form-error" role="alert"></div><div class="dialog-actions"><button type="button" id="cancel-edit" class="soft-button">取消</button><button type="submit" class="primary-button" id="save-edit">保存更改</button></div></form></dialog>
<div class="toast" id="toast" role="status" aria-live="polite"></div>
`;

export function icon(name: string): string { return `<svg aria-hidden="true"><use href="#i-${name}"></use></svg>`; }
