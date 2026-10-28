import "./style.css";
import { Library, events } from "./mygo";
import type { Asset, Entry, Match, Patch, SearchResult, Tag } from "./mygo";
import { onFileDrop } from "mygo-runtime";
import { layout, icon } from "./layout";
import { contentExcerpt, documentAsset, escapeHTML as esc, formatBytes, formatDuration, highlight, highlightCode, kindLabel, mediaURL, primaryAsset, renderMarkdown, shortID } from "./view";
import { getPreview, queuePreview, readyPreviews } from "./media";

const $ = <T extends HTMLElement = HTMLElement>(selector: string, root: ParentNode = document) => root.querySelector<T>(selector)!;
const $$ = <T extends HTMLElement = HTMLElement>(selector: string, root: ParentNode = document) => [...root.querySelectorAll<T>(selector)];
$("#app").innerHTML = layout;
const reader = $<HTMLDialogElement>("#reader");
const readerBody = $("#reader-body");
const readSaved = <T>(key: string, fallback: T): T => { try { return JSON.parse(localStorage.getItem("xclip:" + key) ?? "null") ?? fallback; } catch { return fallback; } };
const save = (key: string, value: unknown) => { try { localStorage.setItem("xclip:" + key, JSON.stringify(value)); } catch { /* 隐私模式下仍可正常阅读。 */ } };
const state = { catalog: [] as SearchResult[], results: [] as SearchResult[], tags: [] as Tag[], query: "", selectedTags: [] as string[], kind: "", scope: "all", sort: "new", view: readSaved("view", "grid"), queryView: "list", history: readSaved<string[]>("history", []), limit: 60, request: 0 };
const reading = { entry: null as Entry | null, asset: null as Asset | null, tab: "overview", line: 0, compare: false, queue: [] as string[], autoplay: false };
const textTasks = new Map<string, Promise<string>>();
const texts = new Map<string, string>();
const progress = readSaved<Record<string, number>>("progress", {});
let searchTimer: ReturnType<typeof setTimeout>;
let toastTimer: ReturnType<typeof setTimeout>;
let readerRequest = 0, renderRequest = 0, refreshRequest = 0, previousScroll = 0;

function notify(message: string): void { clearTimeout(toastTimer); $("#toast").textContent = message; $("#toast").classList.add("visible"); toastTimer = setTimeout(() => $("#toast").classList.remove("visible"), 2500); }
function tagName(slug: string): string { return state.tags.find((tag) => tag.slug === slug)?.name ?? slug; }
function tagHTML(slug: string, inReader = false): string { return `<button class="mini-tag" data-${inReader ? "reader-tag" : "tag"}="${esc(slug)}">${esc(tagName(slug))}</button>`; }
async function text(entry: Entry, asset: Asset): Promise<string> {
  let task = textTasks.get(asset.id);
  if (!task) {
    task = Library.text(entry.id, asset.path).then((value) => { texts.set(asset.id, value); return value; }).catch((error: unknown) => { textTasks.delete(asset.id); throw error; });
    textTasks.set(asset.id, task);
  }
  return task;
}
async function copy(value: string, label: string): Promise<boolean> {
  try { await Library.copy(value); notify(`${label}已复制`); return true; }
  catch (error) { notify(`复制失败：${String(error)}`); return false; }
}
async function copyEntry(id: string, button?: HTMLButtonElement): Promise<void> {
  if (button) button.disabled = true;
  const copied = await copy(shortID(id), `内容编码 #${shortID(id)}`);
  if (button) {
    button.disabled = false;
    if (copied) { const original = button.innerHTML; button.classList.add("copied"); button.innerHTML = `<span>#${shortID(id)}</span>${icon("check")}`; setTimeout(() => { if (button.isConnected) { button.innerHTML = original; button.classList.remove("copied"); } }, 1600); }
  }
}
function visibleEntries(): SearchResult[] {
  const entries = state.results.filter((entry) => (state.scope !== "recent" || state.history.includes(entry.id)) && (state.scope !== "pending" || !entry.summary));
  return [...entries].sort((a, b) => state.sort === "title" ? a.title.localeCompare(b.title, "zh-CN") : state.sort === "viewed" ? state.history.indexOf(a.id) - state.history.indexOf(b.id) : state.sort === "old" ? a.created_at.localeCompare(b.created_at) : b.created_at.localeCompare(a.created_at));
}
function firstMatch(entry: SearchResult): Match | undefined { return entry.matches.find((match) => match.asset_id) ?? entry.matches[0]; }
function renderNav(): void {
  $("#all-count").textContent = String(state.catalog.length);
  $("#recent-count").textContent = String(state.catalog.filter((entry) => state.history.includes(entry.id)).length);
  $("#pending-count").textContent = String(state.catalog.filter((entry) => !entry.summary).length);
  $("#all-nav").classList.toggle("active", state.scope === "all" && !state.selectedTags.length);
  $("#recent-nav").classList.toggle("active", state.scope === "recent");
  $("#pending-nav").classList.toggle("active", state.scope === "pending");
  $("#tag-nav").innerHTML = state.tags.map((tag) => `<button class="nav-item ${state.selectedTags.includes(tag.slug) ? "active" : ""}" data-tag="${esc(tag.slug)}" aria-pressed="${state.selectedTags.includes(tag.slug)}"><span class="tag-dot"></span><span>${esc(tag.name)}</span><span class="count">${tag.count}</span></button>`).join("");
}
function cardCover(entry: Entry): string {
  const asset = primaryAsset(entry.assets);
  if (!asset) return `<div class="card-cover"><div class="card-file">${icon("doc")}<span>尚无附件</span></div></div>`;
  if (asset.kind === "video") {
    const preview = readyPreviews.get(asset.id);
    return `<div class="card-cover video-cover">${preview?.poster ? `<img src="${esc(preview.poster)}" alt="${esc(entry.title)}的演示画面" loading="lazy">` : `<div class="card-loading">${icon("video")}<span>正在读取视频封面…</span></div>`}<span class="kind-badge">${icon("video")}视频${entry.assets.some((item) => item.kind === "code") ? " · 代码" : ""}</span><button class="play-button" data-play-id="${esc(entry.id)}" aria-label="播放${esc(entry.title)}" title="播放视频">${icon("play")}</button><span class="duration" ${preview?.duration ? "" : "hidden"}>${formatDuration(preview?.duration ?? 0)}</span></div>`;
  }
  if (asset.kind === "image") {
    const images = entry.assets.filter((item) => item.kind === "image");
    return `<div class="card-cover gallery-cover ${images.length === 1 ? "single" : ""}">${images.slice(0, 3).map((item) => `<img src="${mediaURL(item)}" alt="${esc(item.path)}" loading="lazy">`).join("")}<span class="gallery-count">${images.length} 张图片</span></div>`;
  }
  if (asset.kind === "code") return `<div class="card-cover card-code"><div class="code-caption">${esc(asset.path)}</div><pre>${highlightCode((texts.get(asset.id) ?? "").split("\n").slice(0, 12).join("\n"))}</pre></div>`;
  if (asset.kind === "text") return `<div class="card-cover paper-cover"><div class="paper-label">${icon("doc")}文档</div><div class="paper-title">${esc(contentExcerpt(texts.get(asset.id) ?? "") || entry.title)}</div><div class="paper-line"></div><div class="paper-line short"></div><span class="paper-corner">${esc(asset.path.split("/").pop() ?? "")}</span></div>`;
  return `<div class="card-cover"><div class="card-file">${icon(asset.kind === "audio" ? "video" : "doc")}<span>${esc(asset.path.split("/").pop() ?? "")}</span><small>${kindLabel(asset.kind)} · ${formatBytes(asset.size)}</small></div></div>`;
}
const observer = new IntersectionObserver((items) => {
  for (const item of items) if (item.isIntersecting) {
    observer.unobserve(item.target);
    const card = item.target as HTMLElement;
    const entry = state.results.find((entry) => entry.id === card.dataset.id);
    if (entry) queuePreview(async () => { if (card.isConnected) await hydrateCard(card, entry); });
  }
}, { root: $("#content-scroll"), rootMargin: "180px" });
async function hydrateCard(card: HTMLElement, entry: Entry): Promise<void> {
  const asset = primaryAsset(entry.assets);
  const doc = documentAsset(entry.assets) ?? (asset?.readable ? asset : undefined);
  await Promise.allSettled([
    (async () => {
      if (!doc) return;
      const source = await text(entry, doc);
      if (!card.isConnected) return;
      $(".card-description", card).innerHTML = highlight(doc.kind === "code" ? entry.note || entry.summary || doc.path : contentExcerpt(source), state.query);
      if (asset?.kind === "code") $(".card-cover pre", card).innerHTML = highlightCode(source.split("\n").slice(0, 12).join("\n"));
      if (asset?.kind === "text") $(".paper-title", card).textContent = contentExcerpt(source) || entry.title;
    })(),
    (async () => {
      if (asset?.kind !== "video") return;
      const preview = await getPreview(asset);
      if (!card.isConnected) return;
      const cover = $(".card-cover", card);
      const loader = $(".card-loading", cover);
      if (loader) {
        const element = document.createElement(preview.poster ? "img" : "video");
        element.setAttribute("src", preview.poster || mediaURL(asset));
        if (element instanceof HTMLVideoElement) { element.muted = true; element.playsInline = true; element.preload = "metadata"; element.setAttribute("aria-label", "视频首帧"); }
        else element.setAttribute("alt", entry.title + "的演示画面");
        loader.replaceWith(element);
      }
      if (preview.duration) { $(".duration", cover).textContent = formatDuration(preview.duration); $(".duration", cover).hidden = false; }
    })(),
  ]);
}
function renderResults(): void {
  renderNav(); observer.disconnect();
  const entries = visibleEntries();
  const title = state.query ? "搜索结果" : state.scope === "recent" ? "最近查看" : state.scope === "pending" ? "待提炼" : state.selectedTags.length === 1 ? tagName(state.selectedTags[0]) : state.selectedTags.length ? "标签筛选" : "全部内容";
  $("#page-title").textContent = title; $("#breadcrumb").textContent = title;
  $("#heading-count").textContent = `${entries.length} 条`;
  $("#page-caption").textContent = state.query ? `在原文、说明与代码中查找「${state.query}」` : state.scope === "pending" ? "已收录的原始内容，可以随时阅读和整理。" : "图文、视频、代码，和它们原本的上下文。";
  $("#clear-search").hidden = !state.query;
  $("#result-count").textContent = `${entries.length} 条${state.query ? "相关内容 · 点击结果直达命中文件" : "内容"}`;
  const base = state.catalog.filter((entry) => state.selectedTags.every((tag) => entry.tags.includes(tag)));
  $("#type-filters").innerHTML = [["", "全部"], ["video", "含视频"], ["image", "含图片"], ["text", "含文档"], ["code", "含代码"], ["audio", "含音频"]].map(([kind, label]) => `<button class="filter-chip ${state.kind === kind ? "active" : ""}" data-kind="${kind}" aria-pressed="${state.kind === kind}">${label}<b>${kind ? base.filter((entry) => entry.assets.some((asset) => asset.kind === kind)).length : base.length}</b></button>`).join("");
  $("#selected-filters").hidden = !state.selectedTags.length;
  $("#selected-filters").innerHTML = state.selectedTags.map((tag) => `<button class="selected-tag" data-tag="${esc(tag)}" aria-label="移除${esc(tagName(tag))}筛选">${esc(tagName(tag))}${icon("close")}</button>`).join("") + (state.selectedTags.length ? '<button class="clear-filters" data-clear-tags>清除标签</button>' : "");
  const view = state.query ? state.queryView : state.view;
  for (const value of ["grid", "list"]) { $(`#${value}-view`).classList.toggle("active", view === value); $(`#${value}-view`).setAttribute("aria-pressed", String(view === value)); }
  $("#results").className = `cards ${view === "list" ? "list-view" : ""}`;
  if (!entries.length) {
    $("#results").className = "";
    $("#results").innerHTML = `<div class="empty">${icon("search")}<h2>${!state.catalog.length ? "收录第一份值得保留的内容" : "没有找到匹配的内容"}</h2><p>${!state.catalog.length ? "选择文件或文件夹，也可以把文件直接拖入窗口。" : "试试其他关键词，或减少筛选条件。"}</p><button class="soft-button" data-reset>查看全部内容</button></div>`;
  } else $("#results").innerHTML = entries.slice(0, state.limit).map((entry) => {
    const match = state.query ? firstMatch(entry) : undefined;
    const doc = documentAsset(entry.assets);
    const description = doc && texts.has(doc.id) ? contentExcerpt(texts.get(doc.id)!) : entry.note || entry.summary || `${entry.assets.length} 个文件，已收录到本地`;
    return `<article class="card" data-id="${esc(entry.id)}" tabindex="0" aria-label="预览${esc(entry.title)}">${cardCover(entry)}<div class="card-body"><h2>${highlight(entry.title, state.query)}</h2><p class="card-description">${highlight(description, state.query)}</p>${match ? `<div class="card-match"><b>${match.path ? esc(match.path) + (match.line ? " · 第 " + match.line + " 行" : "") : "内容信息命中"}</b><span>${highlight(match.snippet, state.query)}</span></div>` : ""}<div class="card-bottom">${entry.tags.slice(0, 2).map((tag) => tagHTML(tag)).join("")}<button class="card-code-id" data-copy-entry="${esc(entry.id)}" title="复制内容编码" aria-label="复制内容编码 #${shortID(entry.id)}"><span>#${shortID(entry.id)}</span>${icon("copy")}</button></div></div></article>`;
  }).join("");
  $$(".card").forEach((card) => observer.observe(card));
  $("#load-more").hidden = entries.length <= state.limit;
}
async function loadResults(): Promise<void> {
  const request = ++state.request;
  try {
    const results = state.query ? await Library.search(state.query, state.selectedTags, state.kind) : state.catalog.filter((entry) => state.selectedTags.every((tag) => entry.tags.includes(tag)) && (!state.kind || entry.assets.some((asset) => asset.kind === state.kind)));
    if (request !== state.request) return;
    state.results = results; state.limit = 60; renderResults();
  } catch (error) { if (request === state.request) $("#results").innerHTML = `<div class="result-error">${esc(String(error))}</div>`; }
}
async function refresh(): Promise<void> {
  const request = ++refreshRequest;
  const [tags, catalog] = await Promise.all([Library.tags(), Library.search("", [], "")]);
  if (request !== refreshRequest) return;
  state.tags = tags; state.catalog = catalog;
  await loadResults();
}
function setSort(value: string): void { state.sort = value; const select = $<HTMLSelectElement>("#sort"); if (value === "viewed" && !select.querySelector('[value="viewed"]')) select.insertAdjacentHTML("afterbegin", '<option value="viewed">最近查看</option>'); select.value = value; if (value !== "viewed") select.querySelector('[value="viewed"]')?.remove(); }
function reset(): void { clearTimeout(searchTimer); state.query = ""; state.kind = ""; state.selectedTags = []; state.scope = "all"; $<HTMLInputElement>("#search").value = ""; setSort("new"); void loadResults(); $("#content-scroll").scrollTop = 0; }
function setTag(tag: string): void { state.selectedTags = state.selectedTags.includes(tag) ? state.selectedTags.filter((item) => item !== tag) : [...state.selectedTags, tag]; state.scope = "all"; if (state.sort === "viewed") setSort("new"); void loadResults(); }
function pauseMedia(): void { $$<HTMLMediaElement>("video, audio", readerBody).forEach((video) => { const key = video.dataset.media; if (key && video.currentTime > 0 && !video.ended) progress[key] = video.currentTime; if (video.ended && key) delete progress[key]; video.pause(); }); save("progress", progress); }
async function openEntry(id: string, play = false): Promise<void> {
  const request = ++readerRequest; renderRequest++; pauseMedia();
  if (!reader.open) { reading.queue = visibleEntries().map((entry) => entry.id); previousScroll = $("#content-scroll").scrollTop; reader.showModal(); }
  $("#reader-tabs").innerHTML = ""; readerBody.innerHTML = '<div class="reader-loading">正在读取内容…</div>';
  try {
    const entry = await Library.get(id);
    if (request !== readerRequest || !reader.open) return;
    reading.entry = entry; reading.compare = false; reading.line = 0; reading.autoplay = play;
    const result = state.results.find((item) => item.id === id);
    const match = !play && state.query && result ? firstMatch(result) : undefined;
    reading.asset = entry.assets.find((asset) => asset.id === match?.asset_id) ?? primaryAsset(entry.assets) ?? null;
    reading.line = match?.line ?? 0;
    reading.tab = reading.asset?.kind === "code" && reading.asset.readable ? "code" : reading.asset?.kind === "text" && reading.asset.readable ? "document" : reading.asset ? "overview" : "files";
    state.history = [id, ...state.history.filter((item) => item !== id)].slice(0, 300); save("history", state.history); renderNav();
    await renderReader();
  } catch (error) { if (request === readerRequest && reader.open) readerBody.innerHTML = `<div class="error-detail">${esc(String(error))}</div>`; }
}
function mediaHTML(asset: Asset, entry: Entry): string {
  if (asset.kind === "image") return `<div class="gallery-stage"><button data-zoom aria-label="放大图片"><img src="${mediaURL(asset)}" alt="${esc(asset.path)}"></button><span class="zoom-indicator">${icon("expand")}点击放大</span></div><div class="image-thumbnails">${entry.assets.filter((item) => item.kind === "image").map((item) => `<button class="image-thumb ${asset.id === item.id ? "active" : ""}" data-asset="${esc(item.id)}" aria-label="查看${esc(item.path)}"><img src="${mediaURL(item)}" alt="" loading="lazy"></button>`).join("")}</div>`;
  const preview = readyPreviews.get(asset.id);
  return `<div class="media-stage"><${asset.kind === "audio" ? "audio" : "video"} src="${mediaURL(asset)}" ${preview?.poster ? `poster="${esc(preview.poster)}"` : ""} data-media="${esc(asset.id)}" controls playsinline preload="metadata" aria-label="${esc(asset.path)}"></${asset.kind === "audio" ? "audio" : "video"}></div><div class="media-caption">${icon("video")}<span>${esc(asset.path)}</span><span>${preview?.duration ? formatDuration(preview.duration) + " · " : ""}${formatBytes(asset.size)}</span></div>`;
}
function entryMeta(entry: Entry): string { return `<details class="entry-info"><summary>来源与收录信息${icon("right")}</summary><dl><dt>来源</dt><dd>${esc(entry.source || "本地收录")}</dd><dt>收录</dt><dd>${new Date(entry.created_at).toLocaleString("zh-CN")}</dd><dt>内容编码</dt><dd><button data-copy-entry="${esc(entry.id)}">#${shortID(entry.id)} ${icon("copy")}</button></dd><dt>英文摘要</dt><dd class="english-summary summary-text">${esc(entry.summary || "尚无摘要")}</dd>${entry.note ? `<dt>个人备注</dt><dd class="summary-text">${esc(entry.note)}</dd>` : ""}</dl></details>`; }
function assetActions(asset: Asset): string { return `<button class="soft-button" data-copy-path="${esc(asset.id)}">${icon("copy")}复制路径</button><button class="soft-button reveal-button" data-reveal="${esc(asset.id)}">${icon("right")}在文件夹中显示</button>`; }
function documentHTML(entry: Entry, asset: Asset, source: string): string {
  return `<div class="doc-wrap"><div class="entry-kicker"><button data-copy-entry="${esc(entry.id)}">#${shortID(entry.id)}</button><span>·</span><span>${esc(asset.path)}</span></div><h1 class="doc-title">${esc(entry.title)}</h1><div class="doc-meta"><span>${esc(entry.tags.map(tagName).join(" · "))}${reading.line ? ` · 命中原文第 ${reading.line} 行` : ""}</span><button class="soft-button" data-copy-text>${icon("copy")}复制全文</button></div>${/\.md$/i.test(asset.path) ? `<article class="markdown">${renderMarkdown(source.replace(/^# [^\n]*\n/, ""), entry.assets, asset.path)}</article>` : `<pre class="text-source">${highlight(source, state.query)}</pre>`}<div class="reader-meta-actions">${assetActions(asset)}</div>${entryMeta(entry)}</div>`;
}
function codePane(entry: Entry, asset: Asset, source: string, compare = false): string {
  const tokens = state.query.toLocaleLowerCase().split(/\s+/).filter(Boolean);
  return `<div class="code-pane"><div class="code-toolbar">${compare ? `<select id="compare-file" aria-label="切换对照的代码文件">${entry.assets.filter((item) => item.kind === "code").map((item) => `<option value="${esc(item.id)}" ${item.id === asset.id ? "selected" : ""}>${esc(item.path)}</option>`).join("")}</select>` : `<span class="file-path">${esc(asset.path)}</span>`}<button class="soft-button" data-copy-text>${icon("copy")}复制代码</button><button class="soft-button reveal-button" data-reveal="${esc(asset.id)}" aria-label="在文件夹中显示">${icon("right")}</button></div><div class="code-scroll" tabindex="0" aria-label="代码内容，可横向和纵向滚动"><pre class="code-lines">${source.split("\n").map((line, index) => `<span class="code-line ${index + 1 === reading.line || tokens.some((token) => line.toLocaleLowerCase().includes(token)) ? "hit" : ""}" data-line="${index + 1}"><span class="line-number" aria-hidden="true">${index + 1}</span><code>${highlightCode(line, state.query)}</code></span>`).join("")}</pre></div></div>`;
}
function filesHTML(entry: Entry): string { return `<div class="files-overview"><h2>全部文件</h2><p>${entry.assets.length} 个文件 · 属于同一条内容</p>${entry.assets.map((asset) => `<button class="asset-row" data-asset="${esc(asset.id)}">${icon(asset.kind === "code" ? "code" : asset.kind === "image" ? "image" : asset.kind === "video" ? "video" : "doc")}<div><b>${esc(asset.path)}</b><small>${kindLabel(asset.kind)} · ${formatBytes(asset.size)}</small></div>${icon("right")}</button>`).join("")}</div>`; }
async function renderReader(): Promise<void> {
  const entry = reading.entry; if (!entry || !reader.open) return;
  const request = ++renderRequest; pauseMedia();
  const docs = entry.assets.filter((asset) => asset.kind === "text" && asset.readable);
  const codes = entry.assets.filter((asset) => asset.kind === "code" && asset.readable);
  const media = entry.assets.find((asset) => asset.kind === "video");
  const index = reading.queue.indexOf(entry.id);
  $("#reader-crumb-title").textContent = entry.title;
  $<HTMLButtonElement>("#reader-prev").disabled = index <= 0;
  $<HTMLButtonElement>("#reader-next").disabled = index < 0 || index >= reading.queue.length - 1;
  const tabs = [["overview", "概览", ""], ...(docs.length ? [["document", docs.length > 1 ? "文档" : "说明文档", docs.length > 1 ? String(docs.length) : ""]] : []), ...(codes.length ? [["code", "代码", String(codes.length)]] : []), ["files", "文件", String(entry.assets.length)]];
  $("#reader-tabs").innerHTML = tabs.map(([key, label, count]) => `<button class="reader-tab ${reading.tab === key && !reading.compare ? "active" : ""}" data-tab="${key}">${label}${count ? `<small>${count}</small>` : ""}</button>`).join("") + (media && codes.length ? `<button class="soft-button compare-button ${reading.compare ? "active" : ""}" data-compare aria-pressed="${reading.compare}">${icon("compare")}并排对照</button>` : "");
  readerBody.innerHTML = '<div class="reader-loading">正在读取内容…</div>';
  try {
    let html = "";
    if (reading.compare && media && codes.length) {
      const asset = reading.asset?.kind === "code" ? reading.asset : codes[0]; reading.asset = asset;
      const source = await text(entry, asset);
      html = `<div class="compare-layout"><div class="compare-media"><h2>${esc(entry.title)}</h2>${mediaHTML(media, entry)}<p class="reader-intro">${esc(entry.note || entry.summary)}</p>${docs.length ? '<button class="text-link" data-tab="document">阅读说明文档</button>' : ""}</div>${codePane(entry, asset, source, true)}</div>`;
    } else if (reading.tab === "code" && codes.length) {
      const asset = reading.asset?.kind === "code" ? reading.asset : codes[0]; reading.asset = asset;
      const source = await text(entry, asset);
      html = `<div class="code-layout"><nav class="file-nav" aria-label="代码文件"><div class="small-label">${codes.length} 个代码文件</div>${codes.map((item) => `<button class="file-item ${item.id === asset.id ? "active" : ""}" data-asset="${esc(item.id)}">${icon("code")}<span>${esc(item.path)}</span></button>`).join("")}</nav>${codePane(entry, asset, source)}</div>`;
    } else if (reading.tab === "document" && docs.length) {
      const asset = reading.asset?.kind === "text" ? reading.asset : documentAsset(entry.assets) ?? docs[0]; reading.asset = asset;
      const source = await text(entry, asset);
      html = (docs.length > 1 ? `<div class="file-nav">${docs.map((item) => `<button class="file-item ${item.id === asset.id ? "active" : ""}" data-asset="${esc(item.id)}">${esc(item.path)}</button>`).join("")}</div>` : "") + documentHTML(entry, asset, source);
    } else if (reading.tab === "overview") {
      const asset = reading.asset ?? primaryAsset(entry.assets);
      if (asset && ["image", "video", "audio"].includes(asset.kind)) {
        reading.asset = asset;
        const doc = documentAsset(entry.assets);
        const source = doc ? await text(entry, doc) : "";
        const description = await text(entry, asset).catch(() => "");
        const section = source.split(/\n## /)[1]?.split("\n").slice(1).join("\n").slice(0, 1200) ?? "";
        html = `<div class="overview"><div class="overview-media">${mediaHTML(asset, entry)}${description ? `<p class="asset-description">${esc(description)}</p>` : ""}<div class="related-strip"><div class="small-label">一起收录的内容</div>${entry.assets.filter((item) => item.id !== asset.id).slice(0, 8).map((item) => `<button class="related-file" data-asset="${esc(item.id)}">${icon(item.kind === "code" ? "code" : item.kind === "image" ? "image" : "doc")}<span>${esc(item.path)}</span>${icon("right")}</button>`).join("")}<div class="reader-meta-actions">${assetActions(asset)}</div></div></div><div class="overview-copy"><div class="entry-kicker"><span>内容条目</span><button data-copy-entry="${esc(entry.id)}">#${shortID(entry.id)}</button></div><h1>${esc(entry.title)}</h1><div class="reader-tag-row">${entry.tags.map((tag) => tagHTML(tag, true)).join("")}</div><p class="reader-intro">${esc(contentExcerpt(source) || entry.note || entry.summary)}</p>${section ? `<h2 class="reader-section-title">内容说明</h2><div class="reader-notes">${renderMarkdown(section, entry.assets, doc!.path)}</div>` : ""}${doc ? `<button class="text-link" data-asset="${esc(doc.id)}">阅读全文与实现笔记${icon("right")}</button>` : ""}${entryMeta(entry)}</div></div>`;
      } else if (asset?.kind === "text" && asset.readable) { reading.asset = asset; html = documentHTML(entry, asset, await text(entry, asset)); }
      else if (asset) { html = `<div class="files-overview"><h2>${esc(asset.path)}</h2><p>原始文件已收录，此格式暂不支持预览。</p><div class="reader-meta-actions">${assetActions(asset)}</div></div>`; }
      else { html = filesHTML(entry); }
    } else html = filesHTML(entry);
    if (request !== renderRequest || !reader.open) return;
    readerBody.innerHTML = html; readerBody.scrollTop = 0;
    if (state.query) markDocument();
    bindMedia();
    if (state.query || reading.line) requestAnimationFrame(() => { const target = reading.tab === "code" || reading.compare ? reading.line ? $(`[data-line="${reading.line}"]`, readerBody) : $(".code-line.hit", readerBody) : $("mark", readerBody); target?.scrollIntoView({ block: "center", inline: "nearest" }); });
  } catch (error) { if (request === renderRequest && reader.open) readerBody.innerHTML = `<div class="error-detail">${esc(String(error))}</div>`; }
}
function markDocument(): void { const article = $(".markdown", readerBody); if (!article) return; const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT); const nodes: Text[] = []; while (walker.nextNode()) nodes.push(walker.currentNode as Text); for (const node of nodes) { const html = highlight(node.textContent ?? "", state.query); if (!html.includes("<mark>")) continue; const template = document.createElement("template"); template.innerHTML = html; node.replaceWith(template.content); } }
function bindMedia(): void {
  const autoplay = reading.autoplay; reading.autoplay = false;
  $$<HTMLMediaElement>("video, audio", readerBody).forEach((element) => {
    const key = element.dataset.media;
    let lastSaved = 0;
    const restore = () => { if (key && progress[key] && Number.isFinite(element.duration) && progress[key] < element.duration - .5) element.currentTime = progress[key]; };
    element.addEventListener("loadedmetadata", restore, { once: true }); if (element.readyState >= 1) restore();
    element.addEventListener("timeupdate", () => { if (key && Math.abs(element.currentTime - lastSaved) > 2) { progress[key] = element.currentTime; lastSaved = element.currentTime; save("progress", progress); } });
    element.addEventListener("ended", () => { if (key) { delete progress[key]; save("progress", progress); } });
    element.addEventListener("error", () => { const message = document.createElement("p"); message.className = "media-placeholder"; message.textContent = "此格式暂无法在 App 内播放，可在文件夹中显示原文件。"; element.replaceWith(message); });
    const asset = reading.entry?.assets.find((asset) => asset.id === key);
    if (element instanceof HTMLVideoElement && asset) void getPreview(asset).then((preview) => { if (preview.poster && element.isConnected) element.poster = preview.poster; });
    if (autoplay) void element.play().catch(() => { if (element.isConnected) notify("点击播放按钮继续观看"); });
  });
}
function openAsset(id: string): void { const asset = reading.entry?.assets.find((item) => item.id === id); if (!asset) return; pauseMedia(); reading.asset = asset; reading.line = 0; reading.autoplay = false; if (asset.kind === "code" && asset.readable) reading.tab = "code"; else if (asset.kind === "text" && asset.readable) { reading.tab = "document"; reading.compare = false; } else { reading.tab = "overview"; reading.compare = false; } void renderReader(); }
function closeReader(): void { readerRequest++; renderRequest++; pauseMedia(); reader.close(); }
function navigateEntry(direction: number): void { if (!reading.entry) return; const id = reading.queue[reading.queue.indexOf(reading.entry.id) + direction]; if (id) void openEntry(id); }
function showImage(direction = 0): void {
  const images = reading.entry?.assets.filter((asset) => asset.kind === "image") ?? []; if (!images.length) return;
  const current = images.findIndex((asset) => asset.id === reading.asset?.id);
  const index = Math.max(0, Math.min(images.length - 1, current + direction)); reading.asset = images[index];
  const imageDialog = $<HTMLDialogElement>("#image-view");
  $<HTMLImageElement>("#large-image").src = mediaURL(images[index]); $<HTMLImageElement>("#large-image").alt = images[index].path;
  $("#image-title").textContent = `${images[index].path} · ${index + 1} / ${images.length}`;
  $<HTMLButtonElement>("#image-prev").disabled = index === 0; $<HTMLButtonElement>("#image-next").disabled = index === images.length - 1;
  if (!imageDialog.open) imageDialog.showModal();
}
function editEntry(): void { const entry = reading.entry; if (!entry) return; const form = $<HTMLFormElement>("#edit-form"); for (const [key, value] of Object.entries({ title: entry.title, summary: entry.summary, note: entry.note, tags: entry.tags.join(", ") })) (form.elements.namedItem(key) as HTMLInputElement | HTMLTextAreaElement).value = value; $("#edit-error").textContent = ""; $<HTMLDialogElement>("#edit-dialog").showModal(); }
async function importContent(action: () => Promise<Entry>): Promise<void> { if ($("#app").classList.contains("importing")) return; $("#app").classList.add("importing"); try { const entry = await action(); if (entry.id) { await refresh(); await openEntry(entry.id); notify("内容已收录到本地库"); } } catch (error) { notify(String(error)); } finally { $("#app").classList.remove("importing"); } }

$("#results").addEventListener("click", (event) => {
  const target = event.target as Element;
  const button = target.closest<HTMLButtonElement>("[data-copy-entry]");
  if (button) { event.stopPropagation(); void copyEntry(button.dataset.copyEntry!, button); return; }
  const tag = target.closest<HTMLElement>("[data-tag]"); if (tag) { setTag(tag.dataset.tag!); return; }
  const play = target.closest<HTMLElement>("[data-play-id]"); if (play) { void openEntry(play.dataset.playId!, true); return; }
  if (target.closest("[data-reset]")) { reset(); return; }
  const card = target.closest<HTMLElement>("[data-id]"); if (card) void openEntry(card.dataset.id!);
});
for (const selector of ["#tag-nav", "#selected-filters"]) $(selector).addEventListener("click", (event) => { const target = event.target as Element; const tag = target.closest<HTMLElement>("[data-tag]"); if (tag) setTag(tag.dataset.tag!); if (target.closest("[data-clear-tags]")) { state.selectedTags = []; void loadResults(); } });
$("#type-filters").addEventListener("click", (event) => { const button = (event.target as Element).closest<HTMLElement>("[data-kind]"); if (button) { state.kind = button.dataset.kind!; void loadResults(); } });
$("#search").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(() => { state.query = $<HTMLInputElement>("#search").value.trim(); void loadResults(); $("#content-scroll").scrollTop = 0; }, 160); });
$("#clear-search").addEventListener("click", () => { clearTimeout(searchTimer); state.query = ""; $<HTMLInputElement>("#search").value = ""; void loadResults(); $("#search").focus(); });
$("#all-nav").addEventListener("click", reset);
for (const [id, scope] of [["recent-nav", "recent"], ["pending-nav", "pending"]]) $(`#${id}`).addEventListener("click", () => { clearTimeout(searchTimer); state.scope = scope; state.selectedTags = []; state.kind = ""; state.query = ""; $<HTMLInputElement>("#search").value = ""; setSort(scope === "recent" ? "viewed" : "new"); void loadResults(); });
$("#sort").addEventListener("change", () => { setSort($<HTMLSelectElement>("#sort").value); renderResults(); });
for (const view of ["grid", "list"]) $(`#${view}-view`).addEventListener("click", () => { if (state.query) state.queryView = view; else { state.view = view; save("view", view); } renderResults(); });
$("#load-more").addEventListener("click", () => { const scroll = $("#content-scroll").scrollTop; state.limit += 60; renderResults(); $("#content-scroll").scrollTop = scroll; });
$("#refresh").addEventListener("click", () => { texts.clear(); textTasks.clear(); void refresh().catch((error: unknown) => notify(String(error))); });
$("#import").addEventListener("click", () => { void importContent(() => Library.chooseAndImport()); });
$("#import-files").addEventListener("click", () => { void importContent(() => Library.chooseFilesAndImport()); });
onFileDrop(({ paths }) => { if (paths.length) void importContent(() => Library.import(paths)); });

function handleReaderClick(event: MouseEvent): void {
  const target = event.target as Element;
  const copyButton = target.closest<HTMLElement>("[data-copy-entry]"); if (copyButton) { void copyEntry(copyButton.dataset.copyEntry!); return; }
  const file = target.closest<HTMLElement>("[data-asset]"); if (file) { event.preventDefault(); openAsset(file.dataset.asset!); return; }
  const tab = target.closest<HTMLElement>("[data-tab]"); if (tab) { reading.compare = false; reading.tab = tab.dataset.tab!; reading.line = 0; if (reading.tab === "overview" && reading.entry) reading.asset = primaryAsset(reading.entry.assets) ?? null; void renderReader(); return; }
  if (target.closest("[data-compare]")) { reading.compare = !reading.compare; reading.line = 0; void renderReader(); return; }
  const tag = target.closest<HTMLElement>("[data-reader-tag]"); if (tag) { closeReader(); setTag(tag.dataset.readerTag!); return; }
  if (target.closest("[data-zoom]")) { showImage(); return; }
  if (target.closest("[data-copy-text]") && reading.entry && reading.asset) { const entry = reading.entry, asset = reading.asset; void text(entry, asset).then((source) => copy(source, "全文")).catch((error: unknown) => notify(String(error))); return; }
  const path = target.closest<HTMLElement>("[data-copy-path]"); if (path) { const asset = reading.entry?.assets.find((asset) => asset.id === path.dataset.copyPath); if (asset) void copy(asset.local_path, "附件路径"); return; }
  const reveal = target.closest<HTMLElement>("[data-reveal]"); if (reveal) void Library.reveal(reveal.dataset.reveal!).catch((error: unknown) => notify(String(error)));
}
readerBody.addEventListener("click", handleReaderClick); $("#reader-tabs").addEventListener("click", handleReaderClick);
readerBody.addEventListener("change", (event) => { if ((event.target as Element).id === "compare-file") openAsset((event.target as HTMLSelectElement).value); });
$("#reader-prev").addEventListener("click", () => navigateEntry(-1)); $("#reader-next").addEventListener("click", () => navigateEntry(1)); $("#reader-close").addEventListener("click", closeReader); $("#reader-edit").addEventListener("click", editEntry);
$("#reader-expand").addEventListener("click", () => reader.classList.toggle("expanded"));
reader.addEventListener("cancel", () => { readerRequest++; renderRequest++; pauseMedia(); });
reader.addEventListener("close", () => { readerRequest++; renderRequest++; pauseMedia(); if (state.scope === "recent") renderResults(); $("#content-scroll").scrollTop = previousScroll; $$(".card").find((card) => card.dataset.id === reading.entry?.id)?.focus({ preventScroll: true }); });
$("#image-prev").addEventListener("click", () => showImage(-1)); $("#image-next").addEventListener("click", () => showImage(1)); $("#image-close").addEventListener("click", () => $<HTMLDialogElement>("#image-view").close()); $("#large-image").addEventListener("click", () => $<HTMLDialogElement>("#image-view").close());
$("#image-view").addEventListener("close", () => { if (reader.open) void renderReader(); });
for (const id of ["about", "help"]) $(`#${id}`).addEventListener("click", () => $<HTMLDialogElement>("#info-dialog").showModal()); $("#info-close").addEventListener("click", () => $<HTMLDialogElement>("#info-dialog").close());
for (const id of ["close-edit", "cancel-edit"]) $(`#${id}`).addEventListener("click", () => $<HTMLDialogElement>("#edit-dialog").close());
$("#edit-form").addEventListener("submit", async (event) => {
  event.preventDefault(); const entry = reading.entry; if (!entry) return;
  const form = new FormData($<HTMLFormElement>("#edit-form"));
  const patch: Patch = { title: String(form.get("title")), summary: String(form.get("summary")), note: String(form.get("note")), tags: String(form.get("tags")).split(",").map((tag) => tag.trim()).filter(Boolean), asset_texts: {} };
  const button = $<HTMLButtonElement>("#save-edit"); button.disabled = true;
  try { const updated = await Library.update(patch, entry.id); $<HTMLDialogElement>("#edit-dialog").close(); reading.entry = updated; await Promise.all([refresh(), renderReader()]); notify("更改已保存"); } catch (error) { $("#edit-error").textContent = String(error); } finally { button.disabled = false; }
});
function setTheme(theme: string): void { document.documentElement.dataset.theme = theme; $("#theme").innerHTML = icon(theme === "light" ? "moon" : "sun"); save("theme", theme); }
$("#theme").addEventListener("click", () => setTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light")); setTheme(readSaved("theme", matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"));
$("#mobile-menu").addEventListener("click", () => $("#app .app").classList.toggle("sidebar-open"));
document.addEventListener("click", (event) => { if (!(event.target as Element).closest(".sidebar,#mobile-menu")) $("#app .app").classList.remove("sidebar-open"); });
document.addEventListener("keydown", (event) => {
  const target = event.target as Element;
  const editing = /^(INPUT|TEXTAREA|SELECT|VIDEO|AUDIO)$/.test(target.tagName);
  if ($<HTMLDialogElement>("#edit-dialog").open || $<HTMLDialogElement>("#info-dialog").open) return;
  if ($<HTMLDialogElement>("#image-view").open) { if (["ArrowLeft", "ArrowRight"].includes(event.key)) { event.preventDefault(); showImage(event.key === "ArrowLeft" ? -1 : 1); } return; }
  if (reader.open) { if (!editing && !target.closest(".code-scroll") && ["ArrowLeft", "ArrowRight"].includes(event.key)) { event.preventDefault(); navigateEntry(event.key === "ArrowLeft" ? -1 : 1); } return; }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k" || event.key === "/" && !editing) { event.preventDefault(); $("#search").focus(); $<HTMLInputElement>("#search").select(); return; }
  if (event.key === "Escape") { if (state.query) $("#clear-search").click(); $("#app .app").classList.remove("sidebar-open"); return; }
  if (editing || target.closest("button")) return;
  const card = target.closest<HTMLElement>("[data-id]"); if (!card) return;
  if ([" ", "Enter"].includes(event.key)) { event.preventDefault(); card.click(); return; }
  if (["ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight"].includes(event.key)) { event.preventDefault(); const cards = $$(".card"); const columns = $("#results").classList.contains("list-view") ? 1 : getComputedStyle($("#results")).gridTemplateColumns.split(" ").length; const offset = event.key === "ArrowDown" ? columns : event.key === "ArrowUp" ? -columns : event.key === "ArrowRight" ? 1 : -1; cards[Math.max(0, Math.min(cards.length - 1, cards.indexOf(card) + offset))]?.focus(); }
});
window.addEventListener("pagehide", pauseMedia);
events.libraryChanged.on(() => { texts.clear(); textTasks.clear(); void refresh().catch((error: unknown) => notify(String(error))); });
void refresh().catch((error: unknown) => { $("#results").innerHTML = `<div class="result-error">${esc(String(error))}</div>`; });
