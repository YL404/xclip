# xclip

A local X (Twitter) post library: save a link, snapshot the post text, cache images/videos to
disk, and file everything under a controlled tag pool. Every post carries an 8-character short ID
and a high-signal "content summary" (`summary`).
The CLI and the app share the same data. The app is just one downstream consumer of the content
pool; the other consumer is an agent — it ingests, tags, and summarizes through the CLI, then
retrieves post text and local media files as references by tag pool and summary index.

## Scope (v1)

- **X only**: links from any other domain are rejected outright.
- **No LLM**: the app never analyzes, tags, or calls any model. Tagging and summarizing are done
  by a human (or an agent driving the CLI) at entry/organization time.
- **Local data only**: a single SQLite file, no account, no cloud sync.
- **Manual link entry**: no browser extension, no share extension, no bulk bookmark import.
- **Chinese UI for now**: the app interface and CLI output are in Chinese; the tag system itself
  is bilingual by design (English slug + Chinese display name).

## Layout

```
Package.swift              SwiftPM: core library + CLI + app targets, zero third-party dependencies
Sources/XClipCore/         Data layer: SQLite, schema migrations, fetching, tags, normalization, error copy
Sources/xclip/             CLI (hand-rolled argument parsing)
Sources/XClipApp/          SwiftUI shell: masonry/compact list, entry panel, detail editing
Tests/XClipCoreTests/      Swift Testing (data layer)
Tests/XClipAppTests/       Swift Testing (layout algorithms)
designs/xclip-app/         Design prototype (offline single-file HTML, three-column / masonry dual main pages)
scripts/package-app.sh     One-shot packaging of an ad-hoc-signed XClip.app (--install copies to /Applications and installs the xclip CLI to ~/.local/bin)
.agents/skills/xclip/      The xclip usage skill for agents (shipped with this repo)
```

The app has a single state owner, `LibraryStore` (`@MainActor @Observable`): it holds the database
connection, exposes posts and tags, and funnels all writes (entry, tag/note edits, deletion)
through itself, refreshing right after each write. Views never hold their own database handles;
the entry panel and the detail view are just consumers.

Database location: `--db <path>` > `XCLIP_DB` environment variable > `~/.xclip/xclip.db`.
The CLI and the app read the same file.

## Build & Run

```bash
swift build
swift test

swift run xclip --help
swift run XClipApp        # SwiftUI shell; runs the bare executable, not a .app bundle
```

Deployment target is macOS 26 (`platforms: [.macOS(.v26)]` in `Package.swift`); older versions are
not supported. `XClipApp` is a SwiftPM executable target; `scripts/package-app.sh` produces an
ad-hoc-signed `XClip.app` in one shot (release build → render icon → icns → assemble bundle →
codesign). `--install` copies it to /Applications and installs `.build/release/xclip` as
`~/.local/bin/xclip` (so any agent in your shell can call it directly); `--launch` starts it and
verifies the process stays up. Artifacts land in `.build/app/` and are not tracked.

## CLI

```bash
xclip add <link> [--summary <summary>] [--note <note>] [--tag <tag>] [--clear-tags] [--no-fetch] [--json]
xclip update <entry> [--summary|--clear-summary] [--note|--clear-note]
           [--tag|--add-tag|--remove-tag|--clear-tags] [--refetch] [--json]   # alias: edit
xclip list [--tag <tag>] [--query <keyword>] [<keyword>...] [--sort latest|bookmarks|likes]
           [--limit <n>] [--json]                                             # aliases: search, index
xclip show <entry> [--json]
xclip tags [--json]
xclip tag create <slug> <chinese-name> [--desc <description>]
xclip tag set <slug> [chinese-name] [description]          # or explicit --name/--desc
xclip tag rename <old-slug> <new-slug> [--name <new-chinese-name>]
xclip tag merge <source-slug> <target-slug>
xclip tag delete <slug>
xclip warm [--json]
xclip delete <entry> [--json]                                              # alias: rm
xclip help <command>      # detailed help per command, same as <command> --help
```

**Addressing entries**: `show`/`update`/`delete` accept the 8-character short ID (`e895bf71`,
optionally prefixed with `#`), the full internal id, the bare tweet id, or an X link. `--db` works
before or after the subcommand. Multiple `--tag` flags are AND.
`--json` output carries a `schema_version`; post text and summaries are never truncated, and every
media item includes a `local_path` — an agent can read images / preview videos straight from it.

Tagging/filtering arguments take the English slug; new tags can also be **created inline** outside
`xclip tag create`: `-t`/`--tag`/`--add-tag` accepts `<new-english-slug>:<new-chinese-name>`
(e.g. `-t spatial-ui:空间交互`); the system verifies uniqueness in both languages, then creates and
attaches the tag. A successful `xclip add` also prints the current tag pool on its own line
(`可选标签: ai(人工智能), ...`) — `available_tags` in `--json`.

```bash
xclip list --tag product-design --json
```

Hard conventions for agent consumption:

- **`summary` spec**: English only, 1–2 sentences, ≤400 characters, single line, no newlines — a
  high-density digest of reusable design/engineering points. `SummaryValidator` enforces this at
  the `add`/`update` entry points and rejects non-conforming input before any network request is
  made.
- **Clean, localized output**: `list` prints only `[short ID] + tags + summary` (`--json` carries
  the three fields `short_id`/`tags`/`summary`); `show` prints ID/tags/summary/note/text/local
  media paths only — no author, metrics, original post link, or other upstream noise.
- **Duplicate-entry guard**: `xclip add` refuses a post already in the library and points to its
  existing short ID; changes go through `xclip update <id>`.

### Agent workflow

- **Ingest**: `xclip add <link> -t <tag>` fetches the snapshot and caches images/videos into
  `media/`; the output directly provides the short ID, local media paths, and the current tag pool
  (`available_tags` in `--json`, with slug/name/description/count); `xclip show <id>` reads the
  text and local media paths for viewing; `xclip update <id> --summary "English summary" --add-tag
  <tag>` completes the filing. When nothing in the pool fits, create a tag inline with `--add-tag
  <new-slug>:<chinese-name>` or explicitly with `xclip tag create`.
  `.agents/skills/xclip/SKILL.md` is the full usage guide for agents.
- **Retrieval**: `xclip tags` shows the controlled tag pool → `xclip list --tag <slug>` or
  `xclip list <keyword>` scans the `[short ID] + tags + summary` index → `xclip show <id>` reads
  the full text and local media.
- **Maintenance**: `xclip update` edits summary/note/tags (`--refetch` re-fetches the snapshot and
  fills in media); `xclip tag create|set|rename|merge|delete` maintains the vocabulary.

## Data model

Four tables; the schema version lives in `PRAGMA user_version`; migrations are incremental and
never go backward.

| Table | Purpose |
|---|---|
| `posts` | Post snapshot: text, content summary (`summary`), author, media, metrics, note, fetch status, posted/saved timestamps |
| `posts_fts` | FTS5 external-content table over text, handle, display name, note, summary |
| `tags` | Controlled vocabulary: `slug` (unique), `name` (Chinese display name, unique), `description`; counts derived from associations |
| `post_tags` | Many-to-many associations, cascade delete |

Every post also has an **8-character short ID** (`short_id`, e.g. `e895bf71`) derived from the
internal id — readable and typeable for both humans and agents; `show`/`update`/`delete` all
address posts by it (also accepting a `#` prefix, the full id, a tweet id, or an X link).

Key trade-offs:

- **The dedup key is `(platform, external_id)`, not the URL**. A screen_name can change; a status
  id can't; the URL is for display only. Upsert is a single `INSERT ... ON CONFLICT DO UPDATE`,
  naturally atomic: when two processes first-save the same post concurrently, the later one blocks
  until the earlier commits, then takes the DO UPDATE branch — no UNIQUE collision. On duplicate
  writes (`update --refetch` takes this path): a failed fetch does not overwrite an existing
  snapshot (it only updates the note); an empty new note/summary keeps the old value; **omitting
  `--tag` leaves existing tags untouched — clearing requires an explicit `--clear-tags`**.
  The CLI's `xclip add` checks for duplicates by external_id before writing and refuses early
  (see "Duplicate-entry guard" above).
- **`summary` and `note` are separate**: `summary` is the retrieval-facing content digest (shown
  directly in list indexes, indexed in FTS) with a hard spec — English, 1–2 sentences, ≤400
  characters, single line; `note` is a personal note, free-form. `xclip update` goes through
  `PostStore.patch`, touching only these two plus tags — never the snapshot, never `saved_at`;
  editing shouldn't bump a post to the top of the list.
- **media / metrics are JSON columns**: media items carry type, remote URL, thumbnail/preview
  URLs and dimensions; large images and video mp4s are already cached locally under `media/`
  (see below). JSON is sufficient for v1's query needs.
- **metrics are a snapshot at save time**; they go stale, and v1 does not refresh them.
- **Full-text search uses FTS5 trigram tokenization** (swapped in by the v2 migration): the
  default unicode61 tokenizer treats a run of CJK as a single token, breaking Chinese substring
  search entirely. trigram matches substrings for both Chinese and English; it never matches
  terms shorter than 3 characters, so those automatically fall back to case-insensitive `LIKE`
  substring matching (`\`, `%`, `_` escaped literally), AND-combined with FTS conditions for
  longer terms.
- **Known gap**: threads and quote tweets store only the single post's snapshot; there is no
  parent/child relationship.

## Tag conventions

Every tag is an (English slug + Chinese display name) pair, **unique in both directions**: the
slug is the machine identity (tagging, filtering, list/show output), the Chinese name is for
humans (`xclip tags`, the app UI). The `description` column is the discipline tool of this system:
without an LLM safety net, one human-readable line is the cheapest consistency mechanism.

Normalization rules (one shared implementation in CLI and core):

1. trim whitespace; 2. lowercase ASCII; 3. collapse runs of spaces, `_`, `/` and other
punctuation into a single `-`; 4. merge consecutive `-`, trim leading/trailing `-`; 5. reject an
empty result.

`Product Design` → `product-design`, `ui/ux` → `ui-ux`, `--a--b--` → `a-b`.
CJK passes through unchanged: no forced English validation — the point is to prevent accidental
variants caused by case/spaces/punctuation, not to police deliberate choices.

Vocabulary maintenance via `xclip tag`: `create <slug> <chinese-name> [--desc <description>]`
creates a tag; `set <slug> [chinese-name] [description]` (or `--name`/`--desc`) updates the
Chinese name/description; `rename <old-slug> <new-slug> [--name <new-chinese-name>]` renames
(historical associations follow); `merge` unions the tags and deletes the source; `delete` removes
a tag and all its associations.

Tags can also be created inline while tagging: `-t`/`--tag`/`--add-tag` on `xclip add`/`xclip
update` accepts `<new-english-slug>:<new-chinese-name>` (e.g. `-t spatial-ui:空间交互`); the system
verifies bi-directional uniqueness, then creates the tag and attaches it to that post; existing
tags are passed by English slug.

The seed vocabulary has 13 tags covering design reference and software development:
`product-design` `ui-design` `ux-design` `design-system` `typography` `color` `motion`
`app-development` `software-development` `web-development` `dev-tools` `ai` `essay`.
Operating rules: prefer existing tags (pick from `xclip tags` or the pool printed by `xclip add`);
fix history with `tag rename` / `tag merge`. Flat, no hierarchy.

## Fetching

The primary source is fxtwitter's free, unauthenticated API
(`api.fxtwitter.com/<user>/status/<id>`), returning full JSON: text, author, media with
dimensions, engagement counts. Link normalization happens before insert: `x.com` / `twitter.com`,
with or without `www`, `/photo/1`-style suffixes, and `?s=20&t=...` tracking parameters are all
accepted and canonicalized to `https://x.com/<handle>/status/<id>`.

Fetch is layered: fxtwitter → (none) → manual fallback. **Saving must never be blocked by a fetch
failure**: if the fetch fails, the link and note are still saved with `fetch_status = failed`;
`--no-fetch` skips it deliberately. `/i/status/<id>` links carry no username, so fxtwitter cannot
fetch them by path — they take the degraded path.

## Media cache

On ingest, images and videos are downloaded synchronously to a `media/` directory next to the
database (`~/.xclip/media/`; follows `--db` when relocated). The database stores **remote URLs
only** — local files are a derived cache: delete them and they rebuild; nothing in the database
depends on them.

- Cached objects come from `MediaCache.collectibleURLs(for: post)`: each media URL, video preview
  image URLs, author avatars
- `xclip show` / `update --refetch` silently fill in missing cache entries; the `local_path` of
  each media item in `list`/`show --json` is a directly readable local file; for videos, look at
  the preview image's local path
- Images use the `large` variant (2048px long edge, ~100–150KB each); original URLs remain fully
  recorded in the database, recoverable later
- Filenames are the SHA1 prefix of the resolved URL plus the original extension — content
  addressed: the same URL always maps to the same file, with dedup for free
- Writes go to a temp file and then a move; a half-written image is never treated as cache
- **2xx only**: URLSession does not throw on 404, it returns an error page; without a status check
  that page would be content-addressed and cached forever with no self-healing path (the filename
  depends only on the URL). Verified against a real 404: failure count +1, nothing added to media/
- Downloads use a dedicated URLSession (15s request / 60s resource timeouts, URLCache off to avoid
  double disk use); the shared session's resource timeout is 7 days — one hung connection would
  block the entire warm queue
- Download failures don't block saving; cards keep using the remote URL and retry on next display
- The app tops up missing cache for visible posts on every list load (canceling the previous
  incomplete fill); historical data self-heals this way, no separate migration needed
- `xclip warm` does a manual full prefetch (idempotent, existing files skipped), `--json` prints stats

## Main screen

The masonry view is the default; a compact list view is available and toggled from the toolbar.

- **Masonry** uses a custom `MasonryLayout`: equal column widths, each card goes into the
  currently shortest column, natural variable heights; the column count is derived from available
  width and a minimum card width (264pt) and follows window resizing. Cards are image-first, with
  author, ♥/🔖 metrics, and clickable tag chips below; text-only posts get a tinted background to
  break up the rhythm
- **Compact list** is single-column dense rows: thumbnail on the left (single image / 2×2 grid /
  initial letter / failed-fetch warning), a line of author + preview in the middle, up to 2 tags
  (overflow folds into +N) and metrics on the right
- Masonry is not a lazy layout — it needs every card height up front — so posts **render in
  batches of 60**, with "Show more" at the bottom to continue. `LibraryStore.sortedPosts` is the
  sorted result shared by both views

Sorting (latest / most bookmarked / most liked, done in SQL), tag filtering, and search live in
the toolbar and the top filter bar; light/dark follows the system. The toolbar's "Tag Management"
panel supports rename and merge, with historical post associations following along; when a
filtered tag is renamed or merged, the filter automatically points at the new slug.

## Entry and editing in the app

The toolbar's "New Post" opens a sheet mirroring the CLI flow one-to-one, with three result states:

- **Fetch succeeded**: preview card (author, text or "no text, N images", media thumbnails,
  metrics) → pick tags → write a note → save
- **Already in the library**: the post id is checked before fetching; on a hit, the existing
  content is previewed with tags and note prefilled, and save becomes "Update" — only note and
  tags change, the snapshot stays, `saved_at` stays too (editing shouldn't bump a post to the top
  of the list)
- **Fetch failed**: the status line gives the real reason (e.g. "link has no username"); you can
  "Save link only" or "Retry"

Tag selection is a multi-select over vocabulary chips plus a create field that shows the
normalized slug live, with the same rules as the CLI. The detail view's "Edit" goes through the
same tag/note editing; "Delete" has a confirmation layer; posts with `fetch_status = failed` can
re-fetch from the detail view to backfill the snapshot — note and tags are kept, and new images
get cached along the way. The entry panel's failure state can retry the fetch too.

## Concurrency design

`Database` is an actor: all SQL is actor-isolated, so exactly one task touches the connection at a
time; when the app `await`s a query from the main actor it suspends onto the actor's executor
without blocking the main thread. The connection opens with FULLMUTEX + WAL mode, so the CLI and
the app can read/write the same file concurrently. The handle is closed via `isolated deinit`
(no `nonisolated(unsafe)` needed once the deployment target moved to macOS 26).

The app's filtering uses `.task(id:)` instead of starting a Task in onChange: the former
automatically cancels the previous task, and with the `Task.isCancelled` check inside `reload()`,
a fast typist's stale results never overwrite fresh ones.

## License

MIT — see [LICENSE](LICENSE).

