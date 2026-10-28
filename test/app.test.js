import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { stripTypeScriptTypes } from "node:module";
import { Window } from "happy-dom";
import { layout, icon } from "../src/layout.ts";
import * as view from "../src/view.ts";

const source = readFileSync(new URL("../src/main.ts", import.meta.url), "utf8").replace(/^import .+;\r?\n/gm, "");
const compiled = stripTypeScriptTypes(source);
const id = "A1B2C3D4-1234-4567-8901-123456789012";
const entry = { id, title: "输入框焦点", summary: "Track focus in SwiftUI.", note: "", source: "", created_at: "2026-10-27T00:00:00Z", updated_at: "2026-10-27T00:00:00Z", tags: ["swiftui", "interaction"], assets: [
  { id: "doc", path: "README.md", kind: "text", readable: true, size: 10, mime: "text/markdown", sha256: "doc", local_path: "/owned/doc" },
  { id: "code", path: "FocusState.swift", kind: "code", readable: true, size: 20, mime: "text/plain", sha256: "code", local_path: "/owned/code" },
] };

async function until(check) { for (let i = 0; i < 60; i++) { if (check()) return; await new Promise((resolve) => setTimeout(resolve, 10)); } assert.fail("界面未在预期时间内更新"); }
async function start(overrides = {}) {
  const window = new Window();
  Object.assign(globalThis, { window, document: window.document });
  Object.defineProperty(globalThis, "navigator", { value: window.navigator, configurable: true });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.document.body.innerHTML = '<div id="app"></div>';
  const calls = { get: [], copy: [], search: [] };
  const Library = {
    tags: async () => [{ slug: "swiftui", name: "SwiftUI", count: 1 }, { slug: "interaction", name: "交互设计", count: 1 }],
    search: async (query, tags, kind) => { calls.search.push([query, tags, kind]); return [{ ...entry, matches: query ? [{ asset_id: "code", path: "FocusState.swift", kind: "code", line: 3, start: 20, end: 28, count: 1, snippet: ".focused($input)" }] : [] }]; },
    get: async (value) => { calls.get.push(value); return entry; },
    text: async (_id, path) => path.endsWith(".swift") ? "struct Demo {\n  var input = false\n  .focused($input)\n}" : "# 输入框焦点\n\n保留文档和代码之间的关系。",
    copy: async (value) => { calls.copy.push(value); },
    ...overrides,
  };
  window.deps = { ...view, esc: view.escapeHTML, Library, events: { libraryChanged: { on: () => {} } }, onFileDrop: () => {}, layout, icon, getPreview: async () => ({ poster: "", duration: 0 }), queuePreview: () => {}, readyPreviews: new Map() };
  window.eval(`const {${Object.keys(window.deps).join(",")}}=window.deps;\n${compiled}`);
  await until(() => window.document.querySelector(".card-code-id"));
  return { window, calls, $: (selector) => window.document.querySelector(selector) };
}

test("card copy waits for MyGo, copies the CLI short ID, and never opens the reader", async () => {
  let complete;
  const copied = [];
  const app = await start({ copy: (value) => { copied.push(value); return new Promise((resolve) => { complete = resolve; }); } });
  try {
    const button = app.$(".card-code-id");
    button.click();
    assert.deepEqual(copied, ["a1b2c3d4"]);
    assert.equal(button.disabled, true);
    assert.equal(app.$("#toast").textContent, "");
    assert.equal(app.$("#reader").open, false);
    assert.deepEqual(app.calls.get, []);
    complete();
    await until(() => button.classList.contains("copied"));
    assert.match(app.$("#toast").textContent, /已复制/);
    assert.equal(button.disabled, false);
  } finally { await app.window.happyDOM.abort(); app.window.close(); }
});

test("copy errors do not claim success or navigate away", async () => {
  const app = await start({ copy: async () => { throw new Error("剪贴板不可用"); } });
  try {
    const button = app.$(".card-code-id"); button.click();
    await until(() => app.$("#toast").textContent.includes("复制失败"));
    assert.equal(button.classList.contains("copied"), false);
    assert.equal(button.disabled, false);
    assert.equal(app.$("#reader").open, false);
  } finally { await app.window.happyDOM.abort(); app.window.close(); }
});

test("search opens the matched code asset and location, rather than the first attachment", async () => {
  const app = await start();
  try {
    const input = app.$("#search"); input.value = ".focused"; input.dispatchEvent(new app.window.Event("input"));
    await until(() => app.$(".card-match"));
    assert.equal(app.$("#results").classList.contains("list-view"), true);
    assert.match(app.$(".card-match").textContent, /FocusState\.swift · 第 3 行/);
    app.$(".card").click();
    await until(() => app.$(".code-line.hit"));
    assert.equal(app.$("#reader").open, true);
    assert.equal(app.$(".code-line.hit").dataset.line, "3");
    assert.match(app.$(".code-line.hit").innerHTML, /<mark>\.focused<\/mark>/);
    assert.match(app.$(".file-path").textContent, /FocusState\.swift/);
  } finally { await app.window.happyDOM.abort(); app.window.close(); }
});

test("an archived unsupported file keeps its reveal action and file-list navigation", async () => {
  const app = await start({ get: async () => ({ ...entry, assets: [{ ...entry.assets[0], id: "pdf", path: "参考.pdf", readable: false }] }) });
  try {
    app.$(".card").click();
    await until(() => app.$('[data-reveal="pdf"]'));
    assert.match(app.$("#reader-body").textContent, /暂不支持预览/);
    app.$('[data-tab="files"]').click();
    await until(() => app.$('.asset-row[data-asset="pdf"]'));
    app.$('.asset-row[data-asset="pdf"]').click();
    await until(() => app.$('[data-reveal="pdf"]'));
    assert.match(app.$("#reader-body").textContent, /参考\.pdf/);
  } finally { await app.window.happyDOM.abort(); app.window.close(); }
});

test("list view groups dates and shows the date outside today", async () => {
  const at = (days) => { const date = new Date(); date.setHours(12, 0, 0, 0); date.setDate(date.getDate() - days); return date.toISOString(); };
  const entries = [
    { ...entry, id: "today", title: "今天条目", created_at: at(0), matches: [] },
    { ...entry, id: "yesterday", title: "昨天条目", created_at: at(1), matches: [] },
    { ...entry, id: "older", title: "几天前条目", created_at: at(3), matches: [] },
  ];
  const app = await start({ search: async () => entries });
  try {
    app.$("#list-view").click();
    await until(() => app.$(".date-group"));
    assert.deepEqual([...app.window.document.querySelectorAll(".date-group span")].map((node) => node.textContent), ["今天", "昨天", "近 7 天"]);
    assert.match(app.$('[data-id="older"] .meta-date').textContent, /\d+月\d+日/);
  } finally { await app.window.happyDOM.abort(); app.window.close(); }
});

test("multi-image covers fill the collage by count", async () => {
  const images = [0, 1, 2].map((index) => ({ ...entry.assets[0], id: `image-${index}`, path: `image-${index}.png`, kind: "image", mime: "image/png", readable: false, sha256: `image-${index}`, size: 100 }));
  const app = await start({ search: async () => [{ ...entry, assets: images, matches: [] }] });
  try {
    assert.equal(app.$(".gallery-cover").classList.contains("three"), true);
    assert.equal(app.$(".gallery-cover").querySelectorAll("img").length, 3);
  } finally { await app.window.happyDOM.abort(); app.window.close(); }
});

test("sidebar reports unique content bytes and the import trigger stays named", async () => {
  const app = await start();
  try {
    assert.match(app.$("#library-state").textContent, /内容 30 B/);
    assert.equal(app.$("#import-menu").getAttribute("aria-label"), "收录");
  } finally { await app.window.happyDOM.abort(); app.window.close(); }
});
