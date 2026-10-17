# AGENTS.md

Working notes for coding agents in this repository.

`README.md` is the project overview. `.agents/skills/xclip/SKILL.md` teaches agents how to
*operate* the xclip CLI (ingest, tag, retrieve). This file is about *changing the codebase*.

## Build / test / package

- Swift 6.2 toolchain, macOS 26 deployment target — no backward compatibility.
- `swift build`, `swift test` (must pass before any change is considered done).
- Zero third-party dependencies; do not add any.
- `scripts/package-app.sh [--install] [--launch]` builds `.build/app/XClip.app` (untracked).

## Architecture

`XClipCore` (data layer: actor-based `Database`, SQLite + FTS5) ← `xclip` (CLI) and `XClipApp`
(SwiftUI, single state owner `LibraryStore`). The CLI and the app share one database file; path
resolution lives in `Paths`. The media cache is content-addressed and rebuildable — the database
stores remote URLs only.

## House rules

- **Language**: docs are English; code comments and all CLI/App strings are Chinese by design.
  Do not translate either direction as a drive-by change.
- **Schema**: migrations are incremental through `PRAGMA user_version`, never backward.
- **CLI output is a contract**: `--json` carries `schema_version`; text and summaries are never
  truncated; each media item exposes `local_path`; output stays free of author/metrics/link
  noise. `summary` is enforced by `SummaryValidator` (English, 1–2 sentences, ≤400 chars). Tags
  are (English slug + Chinese name) pairs, unique both ways, normalized by `TagNormalizer`.
- **UI pitfalls are documented**: do not reintroduce `Button` inside custom `Layout` containers
  or `.toolbar` inside sheets, and do not swap `AVPlayerView` back to SwiftUI `VideoPlayer` —
  see `KNOWN-ISSUES.md` for root causes.
- **Tests**: data-layer behavior in `Tests/XClipCoreTests`, layout math in `Tests/XClipAppTests`;
  add cases next to the behavior you touch.
