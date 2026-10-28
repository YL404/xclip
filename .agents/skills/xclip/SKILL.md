---
name: xclip
description: >-
  Manage a local content library with the xclip CLI: save links, files, folders, or supplied
  text; keep originals inside the library; view local Markdown, code, images, and video to write
  a summary; file content under a controlled tag pool; and retrieve references by tag or full-text
  search. Use when saving or organizing references, retrieving design/engineering material from
  the library, or maintaining tags.
---

# xclip

A local content library for people and agents. Each **entry** has an 8-character short ID
(e.g. `bbc02c28`), an English **summary**, a personal **note**, bilingual tags (English slug +
Chinese display name), and one or more **assets** (Markdown, code, images, video, audio, any
file). A folder is one entry, with relative paths preserved.

Originals are copied into the library. After a successful import, the source path is provenance
only: moving or deleting the source does not affect the entry. Do not treat the source directory
as the library.

Data lives in `~/.xclip/library.db` and `~/.xclip/blobs/`; `--home` or `XCLIP_HOME` relocates the
library. Tags always appear as their English slug.

Prerequisite: `xclip` on PATH. `xclip help` prints the command summary.

## Workflow 1: ingest, read, summarize, and tag

1. **Add**: `xclip add <link|file|folder> -t <tag>`. A URL must be added alone; X links use
   fxtwitter, other pages keep title/text/images. A failed fetch still saves the source link.
   The output gives the short ID, every asset's **local path**, and the current tag pool
   (`available_tags` in `--json`).
   Multiple independent `add` commands can run in parallel: the database uses WAL and waits for
   locks.
2. **Read the local assets**, not the source:
   - Markdown and code: read the file at `local_path` directly.
   - Images: read `local_path` with the image tool.
   - Video: read the video or sample frames with `ffprobe`/`ffmpeg` into `"$TMPDIR"`; never write
     into the current working directory. Name frames with the entry's short ID so parallel jobs
     do not collide, then remove them.
3. **File it**: `xclip update <id> -s "English summary." -t <tag>`.
   - `summary` is **English only, 1–2 sentences, one line, ≤400 characters**; a third sentence is
     rejected. Prefer 200–300 characters of reusable points.
   - Tags: reuse slugs from the pool; create inline with `-t <slug>:<中文名称>`. The Chinese name
     must contain Chinese characters (e.g. `swiftui:SwiftUI 开发`).
   - For images/video whose content matters, add a searchable description:
     `xclip update <id> --describe demo.mp4="What the clip shows."`.
   - `update` without `-t` leaves tags unchanged; `--clear-tags` is explicit.

## Workflow 2: retrieve references

1. `xclip tags` — inspect the controlled pool first; do not invent near-synonyms.
2. `xclip search <keyword>` or `xclip search -t <tag>`, optionally
   `--kind text|code|image|video|audio|file`.
   Each result carries the entry, its summary/tags, and per-asset matches with `path`, `line`,
   `snippet`, and hit count. Multiple `-t` flags are AND.
3. `xclip show <id>` — entry metadata and every asset's local path.
   `xclip show <id> --asset <path>` — full text of that asset, never truncated.
   Every command supports `--json` (`schema_version=2`).

## Workflow 3: edits and maintenance

- Summary/note: `xclip update <id> -s "..." -n "..."`; clear with `--clear-summary` /
  `--clear-note`.
- Tags: `-t` replaces the set; `--clear-tags` empties it.
- Delete an entry: `xclip delete <id>`.
- Migrate a v1 Swift library: `xclip migrate --from ~/.xclip/xclip.db --to <new-library>`; the
  target must be empty. Cached media is copied; `missing_media` reports what the old library never
  cached.

## Key points

- Address entries by short ID (`bbc02c28`, `#bbc02c28`), a longer unambiguous prefix, or full ID.
  Ambiguous prefixes fail instead of choosing one.
- Search indexes metadata plus UTF-8 text/code assets. Images and video become searchable only
  after `--describe` or a transcript; otherwise they are archived and playable but not
  content-searchable.
- The library does not delete source files after import. Ask the user before removing originals.
- `local_path` points into the owned blob store. Read it directly; do not reconstruct paths.
