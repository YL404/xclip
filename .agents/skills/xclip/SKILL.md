---
name: xclip
description: >-
  Manage a local X (Twitter) post library with the xclip CLI: save links and fetch snapshots,
  cache images/videos locally to view and summarize the key points, retrieve reference material
  by controlled tag pool and summary index, edit the summary/note/tags of saved posts, and
  maintain the tag vocabulary. Use when a task involves saving or organizing X posts, retrieving
  design/engineering references from archived posts, or maintaining post tags.
---

# xclip

A local X post library designed for agent workflows: every post has an 8-character **short ID**
(e.g. `e895bf71`), a user/agent-written **content summary** (`summary`), a personal note
(`note`), controlled tags (English slug + Chinese display name, unique in both directions), and
images and videos cached into a local `media/` directory. Data lives in a single SQLite database
(default `~/.xclip/xclip.db`; `--db` or `XCLIP_DB` relocates it), media in `media/` next to the
database. When tagging/filtering/displaying, tags always present as their English slug.

Prerequisite: `xclip` on PATH (the packaging script `scripts/package-app.sh --install` installs it
to `~/.local/bin/xclip`). Every subcommand supports `xclip help <command>` for detailed options
and examples.

## Workflow 1: ingest + view images/videos to summarize + tag

1. **Straight to** `xclip add <link>` — fetches the snapshot and caches images/videos locally; the
   output directly gives the **short ID**, **post text**, **per-item local media paths (including
   video mp4 and static preview images)** and the **current tag pool** (`--json` provides the same
   via `available_tags`) — **no need to run `xclip tags` first**; after viewing the images/videos,
   add the summary and tags in step 3 in one go (unless the user explicitly asks for a specific
   existing tag only, without viewing, in which case pass `-t <tag>`).
   If the post is already in the library, add refuses it and points to the existing short ID; do
   not re-add — make changes with `xclip update <id>`.
   A failed fetch still saves the link (`fetch_status=failed`); backfill later with
   `xclip update <id> --refetch` (non-JSON output also carries text, local media paths, and the
   tag pool).
   The `媒体: 新缓存/已就绪` (media: newly cached / ready) stats in the output cover post
   attachments only — author avatars are cached silently and don't appear in the list.
   **Ingest multiple links in parallel within one round**: the database enables WAL and a
   15-second lock-retry backoff, so when several links arrive at once, fire multiple `xclip add`
   calls in parallel in the same round — no need to split into serial rounds for SQLite locks.
2. **View images/videos** (media paths are right there in the add / show / update --refetch
   output; use them directly):
   - **Photo posts**: open the local file after `本地路径:` (local path) directly with the
     image-reading tool (Read).
   - **Video posts**: first open the file after `预览图:` (preview image) with the image-reading
     tool; when the static cover can't show the core interaction/motion, use ffprobe for the
     duration and sample 6 frames evenly across the clip into a temp directory
     — **never write into the current working directory**:
     `dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 <mp4 local path>) && ffmpeg -y -loglevel error -i <mp4 local path> -vf "fps=6/${dur:-6},scale='min(960,iw)':-2" -frames:v 6 "$TMPDIR/xclip_<id>_%02d.png"`
     Six evenly spaced frames cover the intro, mid-clip transitions, and the final frame, and
     avoid same-phase frame loss against 4–5s looping animations (with 4 frames against a ~5s
     loop, all 4 can land on the same state; `scale` caps the width at 960px to speed up reading).
     **Frame filenames must carry the post's short ID** (`xclip_<id>_NN.png`): when processing
     several videos in parallel in one round, frames never overwrite each other. View the
     extracted frames with the image-reading tool, and after summarizing delete
     `"$TMPDIR"/xclip_<id>_*.png`.
   - For the full text use `xclip show <id>`.
3. `xclip update <id> --summary "..." --tag <tag1>,<tag2>` — one command fills in the English
   summary and tags: reuse English `slug`s from the tag pool; when the pool doesn't fit, create
   inline with `-t <new-english-slug>:<new-chinese-name>`. **The Chinese name must contain Chinese
   characters** — English proper nouns like `App Store`, `SwiftUI`, `Metal` need a Chinese
   category word appended (e.g. `app-store:"App Store 设计"`, `swiftui:SwiftUI 开发`); a
   pure-English name is rejected.
   The `标签:` line in `update` output echoes `slug(chinese name)` directly — inline creations are
   confirmed in both languages at a glance, no extra `xclip tags` run needed to verify.

   **`--summary` hard spec**: **English only**, **strictly 1–2 sentences ending in periods** —
   when enumerating points across multiple images/screens, join clauses with semicolons `;` or
   em-dashes `—`; a third period gets rejected by the CLI and retried. Single line, no newlines;
   a high-density digest of directly reusable design/engineering points (topic, method,
   conclusion), not a play-by-play; 200–300 characters recommended (hard cap 400).
   Inline-created tags attach only to the post currently being ingested — unless the user
   explicitly asks, do not go back and `xclip update` previously archived posts.

## Workflow 2: retrieve reference material

1. `xclip tags` — check the controlled tag pool first, pick existing tags, don't invent
   near-synonyms.
2. `xclip list --tag <tag>` or `xclip list <keyword>` (equivalent to `xclip search <keyword>`) —
   a clean local index: each entry is just `[short ID] tag list` plus a second line with the full
   English summary (never truncated); `[untagged]` for untagged, `[pending summary]` for
   unsummarized. Multiple `--tag` flags are AND. Sort with `--sort latest|bookmarks|likes`, limit
   with `-n`.
3. `xclip show <id>` — on a hit, read the full text and local media paths (missing cache is filled
   in automatically) and view images / preview images directly.
   For structured data, every command supports `--json` (`schema_version=1`; list items carry only
   `short_id`/`tags`/`summary`, show carries `text` and each media item's
   `local_path`/`preview_image_local_path`). Output contains only what's in the local database —
   no author, metrics, original post links, or other upstream noise.

## Workflow 3: edits and vocabulary maintenance

- Summary/note: `xclip update <id> -s "..." -n "..."` (clear with
  `--clear-summary`/`--clear-note`).
- Tags: `--tag` replaces wholesale; `--add-tag`/`--remove-tag` add/remove; `--clear-tags` empties.
  `--tag`/`--add-tag` both accept `<new-english-slug>:<new-chinese-name>` for inline creation.
- Vocabulary: `xclip tag create <slug> <chinese-name> [--desc <description>]` creates;
  `xclip tag set <slug> [chinese-name] [description]` (or `--name`/`--desc`) updates the Chinese
  name/description; `xclip tag rename <old-slug> <new-slug> [--name <new-chinese-name>]`;
  `xclip tag merge|delete`.
- Delete a post: `xclip delete <id>` (alias `rm`; media/ cache files are kept).

## Key points

- Address posts uniformly by short ID: `show`/`update`/`delete` all accept `e895bf71`,
  `#e895bf71`, the full id, a tweet id, or an X link.
- Tags are (English slug + Chinese name) pairs, unique in both directions; slugs normalize to
  lowercase-hyphenated (`Product Design` → `product-design`). Tag/filter with the English slug;
  create with `-t <new-slug>:<chinese-name>` or `xclip tag create`; the Chinese name must contain
  Chinese characters (English proper nouns get a Chinese category word, e.g.
  `app-store:"App Store 设计"`). `xclip tags` / `xclip add` output both list the current pool.
- `summary` accepts English only: 1–2 sentences, single line, 200–300 characters recommended
  (hard cap 400). View the images/videos and text before writing it.
- A repeated `xclip add` for the same post is refused, pointing at the existing short ID; omitting
  `--tag` leaves existing tags untouched (tags only apply at creation).
- Full-text search is FTS5 trigram; terms shorter than 3 characters fall back to substring
  matching; Chinese works directly: `xclip list 留白`.
- `--refetch` re-fetches the snapshot and tops up the media cache, keeping summary/note/tags — it
  repairs `fetch_status=failed` entries.
