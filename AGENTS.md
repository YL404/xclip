# AGENTS.md

Working notes for coding agents in this repository.

`README.md` is the project overview. `.agents/skills/xclip/SKILL.md` teaches agents how to
*operate* the xclip CLI (ingest, tag, retrieve). This file is about *changing the codebase*.

## Build / test / package

- Go 1.27+; frontend tooling needs Node 22.18+ (or Bun).
- `go test ./...`, `npm test`, `npm run typecheck` must pass before a change is done.
- `npm run build` packages the app with MyGo into `.build/mygo/<os>-<arch>/`; it takes about
  7–10 s, so build a new version after every feature change (not docs-only edits) and tell the
  user the path. The app icon comes from `resources/icon.png`.
- `go run ./cmd/xclip ...` runs the CLI during development.

## Architecture

`internal/core` is the data layer: SQLite through `github.com/egoist/mygo/plugins/sqlite`, an
entry/asset/document model, content-addressed blobs, ingestion, search, and v1 migration.
`internal/service` exposes the same core through MyGo bindings and serves owned media by asset ID.
`cmd/xclip` is the CLI; `src/` is the TypeScript frontend (MyGo web frontend, generated client in
`src/mygo.ts`). Both the app and the CLI open the same library directory; never give the frontend
its own SQL connection.

The library root contains `library.db` and `blobs/`. Originals are copied in; the source path is
provenance only. Do not make display or search depend on the original file.

## House rules

- **Language**: docs are English; code comments and all CLI/App strings are Chinese by design.
  Do not translate either direction as a drive-by change.
- **Schema**: migrations are incremental through `PRAGMA user_version`, never backward. v2 uses
  `library.db`, separate from the legacy Swift `xclip.db`.
- **CLI output is a contract**: `--json` carries `schema_version=2`; text and summaries are never
  truncated; each asset exposes `local_path`; output stays free of author/metrics noise.
  `summary` is validated as English, 1–2 sentences, ≤400 characters. Tags are (English slug +
  Chinese name) pairs, unique both ways.
- **Search**: FTS5 trigram handles terms of three or more characters; shorter terms fall back to
  substring matching. Add cases for CJK, mixed text, and code identifiers next to the behavior
  you touch.
- **Web content**: sanitize Markdown before insertion; never execute archived HTML/SVG in the
  trusted app origin. Media is served only by asset ID, never by an arbitrary path.
- **Tests**: data-layer behavior in `internal/core`, CLI flow in `cmd/xclip`, frontend helpers in
  `Tests/frontend`. Add cases next to the behavior you change.

## Legacy Swift implementation

The Swift `Sources/`, `Tests/XClip*`, and `Package.swift` are the v1 implementation. They remain
until the Go/MyGo app has covered v1 behavior and migration has been accepted; do not add features
there. Remove them only in a dedicated cleanup change, not as a drive-by edit.
