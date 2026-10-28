# xclip

A local content library shared by a person and an agent. Save a link, a file, a folder, or supplied
text; xclip copies the original into the library. An agent reads it, writes a compact English
summary, and files it under a controlled tag pool. Then search from the app or the CLI.

An entry is the unit you meant to save and owns one or more assets: Markdown, code, images, video,
audio, or any other file. A folder is one entry with relative paths preserved. The app and CLI share
one SQLite library and blob store; neither calls an LLM.

## Scope

- **Local only**: `library.db` plus a content-addressed `blobs/` directory; no account or sync.
- **Owned originals**: importing copies the file into the library. The source path is provenance
  only, so moving or deleting it does not affect the entry.
- **Ingestion**: files, folders, supplied text, web pages, and X posts (via fxtwitter). A failed
  remote fetch still saves the source URL.
- **Searchable text, archived everything**: UTF-8 text and code are indexed. Images, video, and
  audio are playable and become searchable after `--describe` or a transcript.
- **Controlled tags**: English slug plus Chinese display name, unique both ways. Chinese UI and CLI
  copy.

## Build & Run

Go 1.27+; Node 22.18+ (or Bun) for the frontend.

```bash
npm install
npm run generate          # typed Go → TypeScript client
npm run dev               # MyGo development app with live reload
npm run build             # packaged app in .build/mygo/<os>-<arch>/

go test ./...
npm test
npm run typecheck
```

`scripts/package-app.sh [--install] [--launch]` builds the app and CLI; `--install` copies the app
to `/Applications` and the CLI to `~/.local/bin`.

## Layout

```
main.go                MyGo app: window, bound Library service, media protocol
internal/core/         Data layer: entry/asset model, ingestion, search, migration
internal/service/      MyGo bindings and the scoped media handler
cmd/xclip/             CLI
src/                   TypeScript frontend
test/                  Frontend tests
docs/                  Product design and v1 notes
legacy/swift/          v1 Swift app and CLI (frozen)
```

The library defaults to `~/.xclip/`. Put `--home <dir>` before the command, or set `XCLIP_HOME`,
to relocate it. v2 uses `library.db`; the v1 Swift `xclip.db` in the same folder is never opened.

## CLI

```bash
xclip add <link> [--title <title>] [-s <summary>] [-n <note>] [-t <tag>] [--json]
xclip add <file-or-folder>... [--title <title>] [-s <summary>] [-n <note>] [-t <tag>] [--json]
xclip add --text-file <path|-> [--name <asset-name>] [--title <title>] [-s <summary>] [-n <note>] [-t <tag>]
xclip search [keyword...] [-t <tag>] [--kind text|code|image|video|audio|file] [--limit <n>] [--json]
xclip show <entry> [--asset <relative-path>] [--json]
xclip update <entry> [--title <title>] [-s <summary>] [-n <note>] [-t <tag>]
                     [--clear-summary] [--clear-note] [--clear-tags]
                     [--describe <asset-path>=<description>] [--json]
xclip tags [--json]
xclip delete <entry> [--json]
xclip prune [--json]
xclip migrate --from <old xclip.db> [--media <old media dir>] [--to <new library>] [--json]
```

- **Addressing**: `show`, `update`, and `delete` take the 8-character short ID (`#bbc02c28`), a
  longer unambiguous prefix, or the full ID. Ambiguous prefixes fail rather than pick one.
- **Files and folders**: a folder becomes one entry; nested relative paths are preserved. Symlinks
  and non-regular files inside it are skipped.
- **URLs**: one per `add`. X links use fxtwitter; other pages keep a title, extracted text, and
  linked images.
- **Tags**: pass an existing slug, or create inline with `slug:中文名称`. On `update`, `-t`
  replaces the tag set; omitting it leaves tags unchanged.
- **Deletion**: `delete` removes the entry; blobs it alone referenced stay on disk until
  `prune` collects them and reports the freed bytes.
- **JSON**: `schema_version` is `2`. Summaries, text, and local paths are never truncated; every
  asset carries `local_path`, `sha256`, `kind`, `size`, and `readable`.
- **Search results**: one row per matching asset, with path, line, snippet, and hit count. Read it
  with `xclip show <entry> --asset <path>`.

### Summary spec

`summary` is English only, one or two sentences, one line, at most 400 characters. `note` is the
person's own free-form note and is not subject to this rule.

### Agent workflow

1. **Ingest**: `xclip add <link|path> -t <tag>`, then read the local assets in the output.
2. **Summarize and file**: `xclip update <short-id> -s "English summary." -t <tag>`; for media whose
   content matters, add `--describe <path>="What it shows."`.
3. **Retrieve**: `xclip tags`, then `xclip search <keyword>` or `xclip search -t <tag>`, then
   `xclip show <short-id> --asset <path>`.
4. **Maintain**: `xclip update` for metadata, `xclip delete` for an entry. Deleting removes rows;
   unreferenced blobs can be reclaimed by a maintenance command that is not implemented yet.

## Data model

| Table | Purpose |
|---|---|
| `entries` | Title, summary, note, source, timestamps |
| `assets` | Entry-relative path, kind, MIME, size, SHA-256, position |
| `blobs` | Content-addressed original bytes, deduplicated by SHA-256 |
| `documents` | Searchable text: metadata, text, code, description, transcript |
| `documents_fts` | FTS5 trigram index over documents |
| `tags`, `entry_tags` | Bilingual vocabulary and associations |

The same bytes can belong to several entries; the blob hash is not an asset identity. Ingestion
stages and hashes first, publishes blobs, then inserts the entry in one transaction, so a failed
import cannot leave a partial entry. Search uses FTS5 trigram for three or more characters and
substring matching for shorter terms.

## App

A media-first workspace with content cards, a list view, tag filters, and search that opens the
matching file at its line. Cards copy their 8-character ID. The reader keeps related media,
documentation, and code together, with image zoom, a video/code comparison view, playback progress,
and recently viewed entries.

Markdown is sanitized; relative links resolve only to assets owned by the entry. HTML and SVG stay
source text and never execute. Images, video, and audio stream through `xclip-media://` by asset ID;
poster and duration previews are rebuildable derivatives in `cache/previews/`. The app can import
files or folders (including drops) and edit metadata, but does not generate summaries or tags.

## Migration

`xclip migrate --from <old xclip.db> [--media <dir>] [--to <dir>]` opens the old database read-only
and requires an empty v2 library. It preserves IDs, summaries, notes, post text, tags, sources, and
cached media. Media the old library never cached is reported as `missing_media`.

## License

MIT — see [LICENSE](LICENSE).
