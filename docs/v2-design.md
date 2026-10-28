# xclip v2: a local content library for people and agents

Status: confirmed product direction; implementation design. The working name and CLI name
remain `xclip` until a separate naming decision.

## Product boundary

xclip archives a self-contained piece of content and makes it useful to both a person in the
desktop app and an agent through the CLI. An X post, a web article, a note, or a directory of
related files can each become one entry. The agent that drives the CLI understands the content,
writes the retrieval summary, and maintains tags. The app and CLI do not call an LLM.

Keep the existing short IDs, controlled bilingual tag vocabulary, separate summary and personal
note, full-text search, local-only data, and versioned JSON CLI output. Replace the post-centric
model rather than adding unrelated fields to `Post`.

"Any content" has two levels: every regular file can be archived, while supported formats are
also readable and searchable. Unsupported or not-yet-described binary content is explicitly
reported as archived-only; saving a file does not imply semantic understanding of its contents.

## Entry, asset, and document

### Entry

An entry is the unit the user intended to save. It has an ID and stable 8-character short ID,
title, summary, note, source information, ingestion state, and created/updated timestamps. Tags
attach to entries. Its title, summary, and note participate in search.

A directory is one entry by default, not one entry per contained file. An X post remains one
entry, now represented with the same generic model as other content.

### Asset

An asset is one original file belonging to an entry. It records the entry-relative path,
original filename, media kind, MIME type when known, byte size, SHA-256 content hash, and a
reference to the owned blob. Relative paths preserve directory structure and let agents locate
code or documentation without flattening names.

Asset order and optional roles distinguish primary content from previews and supporting files.
The blob store is content-addressed and may deduplicate identical bytes across assets. Asset
identity is not its blob hash: equal files in different entries remain independently manageable.
An asset must remain retrievable after its source URL or original local path disappears.

### Document

A document is searchable representation of an entry or one asset. It has a kind (metadata, text,
code, image description, video/audio transcript, or agent-provided description), text, and a
source locator. A file locator retains its relative path and may add line ranges; media locators
may add time ranges. Search results expose these locations so agents can read the relevant
asset rather than inspect the entire entry.

Start with one document per supported text/code asset and agent-provided media descriptions.
Do not introduce a general OCR, transcription, chunking, or vector-search pipeline in the first
implementation. Those can add documents later without changing what an entry or asset means.

## Owned storage and ingestion

The library root contains a SQLite database, content-addressed `blobs/`, and rebuildable
`cache/`. Original blobs and derived thumbnails/keyframes are separate: cache cleanup must never
remove the only copy of archived content.

Local ingestion copies files into a staging area inside the library, computes hashes, then
commits blob placement and database records with explicit failure handling. A successful import
leaves no runtime dependency on the original path. Source paths are provenance only; there is no
external-file lookup, live directory watch, automatic synchronization, or deletion of source
content in v2. Refreshing from a source is a later, explicit operation.

Do not follow directory symlinks during recursive ingestion or copy sockets/devices. Define the
handling of an explicitly selected symlink and unsupported special files in the ingestion tests;
a recursive import must not unexpectedly escape its selected directory. Preserve relative paths,
reject unsafe `..` paths, and avoid writing outside the library. Atomic staging must not leave a
partial import looking complete.

Remote ingestion stores snapshots and downloaded media in the same owned blob store. It may keep
the canonical URL and fetch metadata for provenance, but normal display and agent consumption
use local data. X remains a specialized fetcher; generic web pages and user-supplied text/files
use generic ingestion. A failed fetch must not erase usable supplied content or an existing
snapshot.

No online account, cloud sync, browser/share extension, bulk import, automatic media analysis,
or vector database is required for this iteration.

## CLI contract

Keep the agent workflow:

1. Add a URL, file, directory, or supplied text; return the entry ID, readable text, local asset
   paths, extraction status, and available tags.
2. Let the agent inspect those local assets and update title, summary, tags, note, and optional
   asset descriptions/transcripts.
3. List a compact index of short ID, title, tags, and full summary.
4. Search entry metadata and document text; return the matching entry, asset, source location,
   and enough context to choose what to read.
5. Show the entry and its asset manifest, or select one asset's full content by entry ID and
   relative path. Full text and summaries are never silently truncated.

Keep `add`, `update`, `list`, `show`, `tags`, `tag`, and `delete` where their meaning remains
clear. Add explicit search/asset operations only where `list` and `show` cannot express the
needed result. Preserve `--json` as a contract; the entry-based schema uses a new
`schema_version` rather than silently renaming `post` fields in version 1. Keep output focused
on locally consumable content.

Short IDs remain stable across migration. Ambiguous prefixes must fail rather than select an
entry. Omitting tag options leaves tags unchanged; clearing is explicit. Existing database and
library path overrides need one shared Go implementation used by both CLI and app.

## Retrieval

Use SQLite FTS5 through MyGo's SQLite support. Index entry metadata and asset documents with
consistent update/delete behavior. Preserve Chinese substring behavior and short-query fallback
from v1; add tests for CJK, two-character queries, mixed English/Chinese, punctuation, and code
identifiers. Search and list have different output shapes and jobs.

Exact keywords, paths, tags, content type, and human/agent-written descriptions are the initial
retrieval baseline. Semantic/vector search is a later evaluation, not a prerequisite for the
content model. Images and video become content-searchable only when a description, transcript,
or other derived text exists; the UI must show when that representation is absent.

## App

Use MyGo with a TypeScript web frontend. An independent Go core package owns models, ingestion,
storage, migrations, and queries. The CLI is a thin adapter; MyGo-bound Go services call the
same core. The frontend never writes SQL or owns a separate database connection. Typed bindings
carry requests and results; events notify open windows after library changes.

Use topic navigation beside a visual content grid, with a compact list as an alternative. Search
initially uses the list to expose matching excerpts, asset paths, and line numbers. Type filters
mean an entry contains that type; multiple topic tags are AND filters. Each card exposes its short
ID and a dedicated native-clipboard copy button.

Open a reading workspace over the collection and preserve scroll position when it closes. Put
original media and text first; keep summaries and provenance secondary. Support media/document/code
tabs, image enlargement, and video/code comparison. Relative Markdown references resolve to owned
assets. Search opens the matching file and location. Retain importing, editing, copying asset paths,
and revealing managed files. Do not add an in-app AI chat or a second summarization engine.

Generate visible video posters with the system WebView's decoder and validate/cache them in Go by
content hash. These derived JPEGs and duration metadata are rebuildable and separate from original
blobs. Unsupported formats keep their original files accessible.

Serve managed media through narrowly scoped local handlers that resolve asset IDs to library
files, never arbitrary paths. Range requests are needed for video. Archived HTML, SVG, Markdown,
and other active content must not inherit the trusted frontend origin or gain MyGo bridge access;
use isolated/untrusted rendering and sanitize markup where required. Never expose the whole
library through an unauthenticated loopback file server.

## Migration and delivery

Build the new core and CLI before replacing the UI. Validate MyGo SQLite FTS5, typed bindings,
local media delivery, and CLI/app access to one library in a small vertical slice. Then implement
local files/directories and text retrieval, migrate X, and rebuild the app around the stable core.

Migration operates on a copy of the real v1 database during development and creates a backup
before a real upgrade. Preserve IDs, short IDs, tags, notes, summaries, post text, source
metadata, and available cached media. Remote media that was never cached cannot be represented
as an already-owned blob; migration must report it and define an explicit fetch/backfill path,
not claim a complete offline archive. Do not let old Swift and new Go implementations write
conflicting schemas to the same database.

Add Go tests next to core behavior and frontend tests for meaningful state/interaction logic.
Keep the existing Swift build and tests passing until their replacement is ready. Update the
agent skill, CLI help, README, and AGENTS.md with the implementation; documentation and the JSON
schema ship with the behavior they describe.

## Acceptance for the first vertical slice

- Import the supplied `SwiftUI FocusState` example directory into a temporary library as one
  entry with three assets and correct relative paths.
- Move or rename the source after import in the test fixture; all managed assets remain usable.
- Search Chinese metadata and a Swift identifier, locate the relevant asset, and read its full
  text through the CLI as JSON.
- Read the same entry in the MyGo app; view Markdown/code and play the managed video without
  access to the original directory.
- Exercise concurrent read/write behavior and verify that an interrupted/failed import does not
  produce a complete-looking partial entry.
- Run `go test ./...`, the frontend checks, the MyGo production build, and the existing Swift
  tests while they remain in the repository.
