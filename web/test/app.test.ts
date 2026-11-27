import assert from "node:assert/strict";
import { test } from "node:test";
import { Window } from "happy-dom";
import { h, render } from "preact";
import type { LibraryClient } from "../src/api";
import type { Entry, Patch, SearchResult } from "../src/mygo";
import { App } from "../src/App";

const id = "A1B2C3D4-1234-4567-8901-123456789012";
const baseEntry: Entry = {
  id,
  title: "输入框焦点",
  summary: "Track focus in SwiftUI.",
  note: "",
  source: "",
  created_at: "2026-10-27T00:00:00Z",
  updated_at: "2026-10-27T00:00:00Z",
  tags: ["swiftui", "interaction"],
  assets: [
    {
      id: "doc",
      path: "README.md",
      kind: "text",
      readable: true,
      size: 10,
      mime: "text/markdown",
      sha256: "doc",
      local_path: "/owned/doc",
    },
    {
      id: "code",
      path: "FocusState.swift",
      kind: "code",
      readable: true,
      size: 20,
      mime: "text/plain",
      sha256: "code",
      local_path: "/owned/code",
    },
  ],
};

async function until(check: () => unknown): Promise<void> {
  for (let i = 0; i < 80; i++) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail("界面未在预期时间内更新");
}

async function mountApp(overrides: Partial<LibraryClient> = {}) {
  const win = new Window();
  Object.assign(globalThis, {
    window: win,
    document: win.document,
    Node: win.Node,
    Element: win.Element,
    HTMLElement: win.HTMLElement,
    HTMLVideoElement: win.HTMLVideoElement,
    HTMLImageElement: win.HTMLImageElement,
    NodeFilter: win.NodeFilter,
    requestAnimationFrame: (cb: FrameRequestCallback) => setTimeout(() => cb(Date.now()), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    localStorage: win.localStorage,
    matchMedia: win.matchMedia.bind(win),
    getComputedStyle: win.getComputedStyle.bind(win),
    CSS: { escape: (value: string) => value },
  });
  Object.defineProperty(globalThis, "navigator", { value: win.navigator, configurable: true });
  win.HTMLElement.prototype.scrollIntoView = () => {};
  win.document.body.innerHTML = '<div id="app"></div>';

  const calls = {
    get: [] as string[],
    copy: [] as string[],
    search: [] as Array<[string, string[], string]>,
    update: [] as Array<[string, Patch]>,
  };
  let libraryChangedListener: (() => void) | null = null;

  const client: LibraryClient = {
    tags: async () => [
      { slug: "swiftui", name: "SwiftUI", description: "", count: 1 },
      { slug: "interaction", name: "交互设计", description: "", count: 1 },
    ],
    search: async (query, tags, kind): Promise<SearchResult[]> => {
      calls.search.push([query, tags, kind]);
      return [
        {
          ...baseEntry,
          matches: query
            ? [
                {
                  asset_id: "code",
                  path: "FocusState.swift",
                  kind: "code",
                  line: 3,
                  start: 20,
                  end: 28,
                  count: 1,
                  snippet: ".focused($input)",
                },
              ]
            : [],
        },
      ];
    },
    get: async (value) => {
      calls.get.push(value);
      return baseEntry;
    },
    text: async (_id, path) =>
      path.endsWith(".swift")
        ? "struct Demo {\n  var input = false\n  .focused($input)\n}"
        : "# 输入框焦点\n\n保留文档和代码之间的关系。",
    update: async (targetID, patch) => {
      calls.update.push([targetID, patch]);
      return {
        ...baseEntry,
        title: patch.title ?? baseEntry.title,
        summary: patch.summary ?? baseEntry.summary,
        note: patch.note ?? baseEntry.note,
        tags: patch.tags ?? baseEntry.tags,
      };
    },
    importPaths: async () => baseEntry,
    chooseAndImport: async () => baseEntry,
    chooseFilesAndImport: async () => baseEntry,
    copy: async (value) => {
      calls.copy.push(value);
    },
    reveal: async () => {},
    preview: async () => ({ poster: false, duration: 0 }),
    cachePreview: async () => {},
    onLibraryChanged: (listener) => {
      libraryChangedListener = listener;
      return () => {
        libraryChangedListener = null;
      };
    },
    onFileDrop: () => () => {},
    ...overrides,
  };

  const container = win.document.querySelector("#app")!;
  render(h(App, { client }), container);
  await until(() => win.document.querySelector(".card-code-id"));

  const cleanup = async () => {
    render(null, container);
    await win.happyDOM.abort();
    win.close();
  };

  return {
    window: win,
    calls,
    emitLibraryChanged: () => libraryChangedListener?.(),
    $: <T extends Element = HTMLElement>(selector: string) => win.document.querySelector<T>(selector)!,
    cleanup,
  };
}

test("card copy waits for MyGo, copies the CLI short ID, and never opens the reader", async () => {
  let complete!: () => void;
  const copied: string[] = [];
  const app = await mountApp({
    copy: (value) => {
      copied.push(value);
      return new Promise<void>((resolve) => {
        complete = resolve;
      });
    },
  });
  try {
    const button = app.$<HTMLButtonElement>(".card-code-id");
    button.click();
    await until(() => button.disabled);
    assert.deepEqual(copied, ["a1b2c3d4"]);
    assert.equal(app.$("#toast").textContent, "");
    assert.equal(app.$<HTMLDialogElement>("#reader").open, false);
    assert.deepEqual(app.calls.get, []);
    complete();
    await until(() => button.classList.contains("copied"));
    assert.match(app.$("#toast").textContent ?? "", /已复制/);
    assert.equal(button.disabled, false);
  } finally {
    await app.cleanup();
  }
});

test("copy errors do not claim success or navigate away", async () => {
  const app = await mountApp({
    copy: async () => {
      throw new Error("剪贴板不可用");
    },
  });
  try {
    const button = app.$<HTMLButtonElement>(".card-code-id");
    button.click();
    await until(() => (app.$("#toast").textContent ?? "").includes("复制失败"));
    assert.equal(button.classList.contains("copied"), false);
    assert.equal(button.disabled, false);
    assert.equal(app.$<HTMLDialogElement>("#reader").open, false);
  } finally {
    await app.cleanup();
  }
});

test("search opens the matched code asset and location, rather than the first attachment", async () => {
  const app = await mountApp();
  try {
    const input = app.$<HTMLInputElement>("#search");
    input.value = ".focused";
    input.dispatchEvent(new app.window.Event("input", { bubbles: true }));
    await until(() => app.window.document.querySelector(".card-match"));
    assert.equal(app.$("#results").classList.contains("list-view"), true);
    assert.match(app.$(".card-match").textContent ?? "", /FocusState\.swift · 第 3 行/);
    app.$(".card").click();
    await until(() => app.window.document.querySelector(".code-line.hit"));
    assert.equal(app.$<HTMLDialogElement>("#reader").open, true);
    assert.equal(app.$<HTMLElement>(".code-line.hit").dataset.line, "3");
    assert.match(app.$(".code-line.hit").innerHTML, /<mark>\.focused<\/mark>/);
    assert.match(app.$(".file-path").textContent ?? "", /FocusState\.swift/);
  } finally {
    await app.cleanup();
  }
});

test("an archived unsupported file keeps its reveal action and file-list navigation", async () => {
  const app = await mountApp({
    get: async () => ({
      ...baseEntry,
      assets: [{ ...baseEntry.assets[0], id: "pdf", path: "参考.pdf", readable: false }],
    }),
  });
  try {
    app.$(".card").click();
    await until(() => app.window.document.querySelector('[data-reveal="pdf"]'));
    assert.match(app.$("#reader-body").textContent ?? "", /暂不支持预览/);
    app.$<HTMLButtonElement>('[data-tab="files"]').click();
    await until(() => app.window.document.querySelector('.asset-row[data-asset="pdf"]'));
    app.$<HTMLButtonElement>('.asset-row[data-asset="pdf"]').click();
    await until(() => app.window.document.querySelector('[data-reveal="pdf"]'));
    assert.match(app.$("#reader-body").textContent ?? "", /参考\.pdf/);
  } finally {
    await app.cleanup();
  }
});

test("list view groups dates and shows the date outside today", async () => {
  const at = (days: number) => {
    const date = new Date();
    date.setHours(12, 0, 0, 0);
    date.setDate(date.getDate() - days);
    return date.toISOString();
  };
  const entries: SearchResult[] = [
    { ...baseEntry, id: "today", title: "今天条目", created_at: at(0), matches: [] },
    { ...baseEntry, id: "yesterday", title: "昨天条目", created_at: at(1), matches: [] },
    { ...baseEntry, id: "older", title: "几天前条目", created_at: at(3), matches: [] },
  ];
  const app = await mountApp({ search: async () => entries });
  try {
    app.$<HTMLButtonElement>("#list-view").click();
    await until(() => app.window.document.querySelector(".date-group"));
    assert.deepEqual(
      [...app.window.document.querySelectorAll(".date-group span")].map((node) => node.textContent),
      ["今天", "昨天", "近 7 天"],
    );
    assert.match(app.$('[data-id="older"] .meta-date').textContent ?? "", /\d+月\d+日/);
  } finally {
    await app.cleanup();
  }
});

test("grid cards show tags instead of content kind and file counts", async () => {
  const app = await mountApp();
  try {
    assert.deepEqual(
      [...app.window.document.querySelectorAll(".card-meta .mini-tag")].map((node) => node.textContent),
      ["SwiftUI", "交互设计"],
    );
    assert.doesNotMatch(app.$(".card-meta").textContent ?? "", /代码|个文件|文档/);
  } finally {
    await app.cleanup();
  }
});

test("multi-image covers fill the collage by count", async () => {
  const images = [0, 1, 2].map((index) => ({
    ...baseEntry.assets[0],
    id: `image-${index}`,
    path: `image-${index}.png`,
    kind: "image",
    mime: "image/png",
    readable: false,
    sha256: `image-${index}`,
    size: 100,
  }));
  const app = await mountApp({
    search: async () => [{ ...baseEntry, assets: images, matches: [] }],
  });
  try {
    assert.equal(app.$(".gallery-cover").classList.contains("three"), true);
    assert.equal(app.$(".gallery-cover").querySelectorAll("img").length, 3);
  } finally {
    await app.cleanup();
  }
});

test("sidebar reports unique content bytes and the import trigger stays named", async () => {
  const app = await mountApp();
  try {
    assert.match(app.$("#library-state").textContent ?? "", /内容 30 B/);
    assert.equal(app.$("#import-menu").getAttribute("aria-label"), "收录");
  } finally {
    await app.cleanup();
  }
});

test("tags are ordered by count descending", async () => {
  const app = await mountApp({
    tags: async () => [
      { slug: "low", name: "少", description: "", count: 1 },
      { slug: "high", name: "多", description: "", count: 9 },
      { slug: "mid", name: "中", description: "", count: 4 },
    ],
  });
  try {
    assert.deepEqual(
      [...app.window.document.querySelectorAll("#tag-nav .nav-item")].map((node) => node.textContent),
      ["多9", "中4", "少1"],
    );
  } finally {
    await app.cleanup();
  }
});

test("clicking outside the reader closes it", async () => {
  const app = await mountApp();
  try {
    app.$(".card").click();
    await until(() => app.$<HTMLDialogElement>("#reader").open);
    app.$("#reader").dispatchEvent(new app.window.MouseEvent("click", { bubbles: true }));
    await until(() => !app.$<HTMLDialogElement>("#reader").open);
  } finally {
    await app.cleanup();
  }
});

test("libraryChanged refreshes the currently open reader entry", async () => {
  let version = 1;
  const app = await mountApp({
    get: async () => ({
      ...baseEntry,
      title: version === 1 ? "旧标题" : "CLI 更新后的标题",
    }),
  });
  try {
    app.$(".card").click();
    await until(() => app.$("#reader-crumb-title").textContent === "旧标题");
    version = 2;
    app.emitLibraryChanged();
    await until(() => app.$("#reader-crumb-title").textContent === "CLI 更新后的标题");
  } finally {
    await app.cleanup();
  }
});

test("edit dialog sends (id, patch) and updates the reader", async () => {
  const app = await mountApp();
  try {
    app.$(".card").click();
    await until(() => app.$<HTMLDialogElement>("#reader").open);
    app.$<HTMLButtonElement>("#reader-edit").click();
    await until(() => app.$<HTMLDialogElement>("#edit-dialog").open);
    const titleInput = app.$<HTMLInputElement>('#edit-form input[name="title"]');
    titleInput.value = "更新后的标题";
    titleInput.dispatchEvent(new app.window.Event("input", { bubbles: true }));
    app.$<HTMLFormElement>("#edit-form").dispatchEvent(new app.window.Event("submit", { bubbles: true, cancelable: true }));
    await until(() => app.calls.update.length === 1);
    assert.equal(app.calls.update[0][0], id);
    assert.equal(app.calls.update[0][1].title, "更新后的标题");
    await until(() => app.$("#reader-crumb-title").textContent === "更新后的标题");
  } finally {
    await app.cleanup();
  }
});
