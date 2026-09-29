# SQLite Backend Implementation Plan

This document turns the SQLite repository design into an incremental work plan.
Each work package has a clear result and an exit criterion. A package should be
completed and verified before the next dependent package is started.

The plan covers both repositories:

- `DosierSkanilo`: library, CLI, scanner, SQLite backend and JSON transfer.
- `DosierSkanilo-Gui`: GUI data source, query integration and lazy details.

The initial database stores the current state of one repository root. Scan
history is not part of the first database schema. Operational logs live beside
the database in `.dosierskanilo/logs/`.

## Target Architecture

```text
CLI -------------------+
                       |
GUI -------------------+--> dosierskanilo.repository API
                                      |
                         +------------+------------+
                         |                         |
                   SQLite backend            JSON transfer
```

The GUI and CLI must not depend on `d2sqlite3` or issue SQL directly. The
SQLite implementation remains behind the public repository API.

## Shared Query Contract

The public read API must be opaque across JSON and SQLite. The logical consumer
contract is:

```text
open(path)
root(filterState, sortOrder)
listDirectories(parentId, filterState, sortOrder)
listFiles(directoryId, filterState, sortOrder, cursor)
loadFileDetails(fileId)
loadArchiveDetails(fileId)
loadTorrentDetails(fileId)
next(fileId, filterState, sortOrder)
previous(fileId, filterState, sortOrder)
close()
```

The API may use internal chunks, `nextCursor`, and `hasMore`. These are memory
and transport controls, not user-visible SQL pages. JSON can use an in-memory
index; SQLite should use stable keyset/cursor queries. Both sources must expose
the same DTOs, filter semantics, sort order, stable IDs, and logical navigation.

## Current Implementation Snapshot (2026-09-27)

Implemented in the backend:

- The repository lifecycle, normalized SQLite schema, JSON v0-v3 import/export,
  scanner persistence core, SQL-based analysis, and explicit SQLite/JSON CLI
  modes.
- Typed directory, file, blob-summary, archive-entry, and torrent-file DTOs.
- Bounded directory/file, blob-cursor, archive-entry, and torrent-file queries.
- Stable forward blob cursors and stable next/previous file cursors, including
  sort-aware keyset queries.
- Lazy blob-detail options that omit archive-entry and torrent-file arrays when
  the GUI uses separate bounded queries.

The companion `DosierSkanilo-Gui` repository uses cursor-backed virtual blob
rows, lazy archive/torrent trees, source-level typed filters, bounded root
summary queries, and independent repository connections per directory-source
operation. Initial JSON/SQLite parity tests, adapter-level continuation tests
for 251 archive/torrent entries, and GTK model/signal checks for continuation,
stale replies, and later-page path copying are in place.

The CLI and GUI operation parity is not implemented yet. SQLite `scan`,
`updateMetadata`, and `analyze` already share the public `Repository` methods,
but those methods are synchronous and do not accept progress or cancellation
callbacks. The SQLite CLI reports phase start and completion summaries; the GUI
does not expose these mutating operations. The JSON CLI scanner uses the older
service path, whose cancellation flag and progress callback are tied to
`ArgsArray`/console progress. WP-09 plans one operation contract and adapters
for both explicit storage modes and both clients.

The backend library tests and GUI tests/build are separate checks. GUI-specific
status, test commands, and remaining UI integration tests are maintained in
the GUI plan at `https://gitlab.vahanus.net/dlang/dosierskanilo-gui/blob/main/docs/GUI-REDESIGN.md`.

Last verified on this snapshot:

- Backend: `dub test --config=library --compiler=ldc2` — 81 passed;
  `dub build --config=library --compiler=ldc2` passed.
- GUI: `dub test --compiler=ldc2` — 35 tests; `dub build
  --compiler=ldc2` passed.
- GTK: opt-in TreeView continuation and leaf activation tests passed with a
  display available.
- GUI self-test under `G_DEBUG=fatal-warnings` passed with audio, archive,
  torrent, and large-repository inputs.

## CLI Target Contract

The CLI has two explicit, non-overlapping storage modes. Top-level commands
use SQLite; the `json` keyword selects direct JSON mode. There is no implicit
option-only mode and no requirement to keep old spelling aliases.

SQLite is the default mode for top-level commands. The repository commands are:

```text
dosierskanilo init [ROOT]
dosierskanilo scan [ROOT] [OPTIONS]
dosierskanilo metadata [ROOT] [OPTIONS]
dosierskanilo analyze [ROOT] [OPTIONS]
dosierskanilo info [ROOT]
dosierskanilo list [ROOT] [FILTERS]
dosierskanilo duplicates [ROOT]
dosierskanilo import [ROOT] INPUT.json [--replace]
dosierskanilo export [ROOT] --output OUTPUT.json
```

The pure JSON commands are:

```text
dosierskanilo json scan ROOT CATALOG.json [OPTIONS]
dosierskanilo json analyze CATALOG.json [OPTIONS]
```

JSON commands operate only on the specified catalog and filesystem path. They
must never create or discover a `.dosierskanilo` repository. SQLite commands
must never silently switch to JSON storage. `ROOT` is optional for top-level
SQLite commands; if omitted, the CLI starts at the current directory and uses the
nearest parent containing
`.dosierskanilo`. `init` uses the current directory when no root is given.
Commands that require an existing repository must fail with an actionable
message when discovery finds none. JSON scan output is written to the
explicitly supplied catalog path.

`analyze` is the only analysis spelling. New options use canonical kebab-case
names such as `--drop-missing`, `--file-types`, `--media-info`, and `--output`.
The CLI does not promise aliases for previous camelCase or short-option names.
`--replace` is valid only for SQLite imports; JSON overwrite behavior is
controlled by the JSON command's explicit catalog output policy.

The parser must return a typed action and value options rather than mutating
process-global state. Help and version are successful actions with exit code
0, usage errors use exit code 2, and operation failures use exit code 1.
Human-readable diagnostics go to stderr; command results go to stdout. Query
commands additionally support a stable machine-readable format.

## Status Legend

- `[ ]` not started
- `[-]` in progress
- `[x]` completed

The checklist is intentionally kept in this document so progress can be
committed in small, reviewable steps.

## WP-00: Baseline and Contracts

Status: `[-]`

### WP-00 Objective

Measure the current behavior and freeze the compatibility requirements before
changing the storage path.

### WP-00 Steps

- [ ] Create representative JSON datasets with 1,000, 10,000 and 100,000
  records.
- [x] Add `scripts/benchmark-storage.sh` for repeatable JSON/SQLite timings.
- [x] Measure load time and peak memory on representative
  1,000, 10,000 and 100,000-record datasets.
- [ ] Record current CLI scan, analysis and JSON export behavior.
- [ ] Record current GUI load, filter, duplicate and detail behavior.
- [ ] Define the supported JSON compatibility set: legacy arrays, versions 1,
  2 and 3.
- [ ] Define the first SQLite repository use cases and query filters.

### WP-00 Deliverables

- A reproducible benchmark command or script.
- A compatibility checklist for CLI and GUI behavior.
- A first list of public repository API operations.

### WP-00 Exit Criteria

- Baseline numbers are recorded.
- Every existing JSON field has an import/export decision.
- No new database code is started with an unresolved compatibility question.

## WP-01: Repository API and DTOs

Status: `[-]`

### WP-01 Objective

Define the public library boundary used by both CLI and GUI.

### Proposed Modules

```text
source/dosierskanilo/repository/
    api.d
    types.d
    errors.d
    repository.d
    query.d
    transfer.d
```

### WP-01 Steps

- [x] Define repository lifecycle operations: initialize, open, close and
  discover root.
- [x] Define bounded read operations for logical blob summaries and stable blob
  cursors; do not expose those internal chunks as user-visible SQL pages.
- [x] Define detail operations for one blob and separate bounded archive/torrent
  entry reads.
- [x] Define scan write operations and transaction boundaries.
- [x] Define JSON import and export options.
- [x] Define typed filters for paths, sizes, checksums, file type, media,
  archives and torrents.
- [x] Define initial read-only directory/file DTOs for GUI use.
- [x] Prove identical JSON/SQLite DTOs, filter/sort ordering, and logical
  `next`/`previous` behavior with cross-source integration tests.
- [x] Keep `d2sqlite3` types out of public signatures.
- [x] Assign an independent initial API version, proposed as `1.0.0`.

### WP-01 Deliverables

- Public API module with documented types.
- API-level unit tests that do not require SQLite.
- Decision record for API SemVer versus application version `26.x.y`.

### WP-01 Exit Criteria

- CLI and GUI can depend on the same API types.
- A GUI query does not require materializing the complete catalog.
- API ownership and transaction behavior are documented.

## WP-02: Repository Layout and SQLite Foundation

Status: `[x]`

### WP-02 Objective

Create and migrate a Git-like `.dosierskanilo` repository.

### WP-02 Steps

- [x] Add `d2sqlite3 ~>1.0.0` to `dub.json`.
- [x] Implement parent-directory discovery for `.dosierskanilo`.
- [x] Implement repository initialization for the current directory.
- [x] Create the following directories when needed:
  `.dosierskanilo/logs/`, `exports/` and `backups/`.
- [x] Add a SQLite connection factory hidden behind the repository module.
- [x] Enable foreign keys and define busy-timeout behavior.
- [x] Decide and test WAL-mode behavior.
- [x] Add `schema_migrations` and the first schema migration.

### Initial Tables

- `repository`
- `directories`
- `blobs`
- `file_refs`
- `media_signatures`
- `media_image_streams`
- `media_video_streams`
- `media_audio_streams`
- `media_text_streams`
- `archive_entries`
- `torrent_info`
- `torrent_files`
- `schema_migrations`

### WP-02 Exit Criteria

- `init` creates a valid repository.
- Opening a repository validates the schema version.
- Migrations can be applied more than once safely.
- Foreign keys, indexes and uniqueness constraints are tested.

## WP-03: JSON Import and Export

Status: `[x]`

### WP-03 Objective

Preserve JSON as the compatible exchange format while normalizing its
relationships in SQLite.

### WP-03 Steps

- [x] Import legacy root arrays and JSON versions 1, 2 and 3.
- [x] Reuse the existing JSON migration logic as the canonical input step.
- [x] Map `FileSpec` values to `file_refs`.
- [x] Map shared binary content to one `blobs` row.
- [x] Store checksums as binary SQLite values.
- [x] Import media, archive and torrent relationships transactionally.
- [x] Implement complete export of the current repository.
- [x] Implement filtered export by root-relative path prefix.
- [x] Preserve version-3 output for existing consumers.
- [x] Design an extended JSON version before exporting fields absent from v3.

### WP-03 Exit Criteria

- [x] All existing JSON fixtures import successfully.
- [x] Import followed by export preserves the supported v3 content.
- [x] A filtered export never references a missing blob or related record.
- [x] Failed imports leave the database unchanged.

## WP-04: Scanner Persistence

Status: `[x]`

### WP-04 Objective

Run scans against SQLite without keeping the complete catalog in memory.

### WP-04 Steps

- [x] Replace absolute or invocation-dependent paths with canonical
  root-relative paths in the repository layer.
- [x] Persist discovered directories, including empty directories if enabled.
- [x] Look up existing `file_refs` by path.
- [x] Skip unchanged files based on size and modification time.
- [x] Mark missing paths and optionally remove them with `dropMissing`.
- [x] Queue metadata jobs only when requested results are missing or a rescan
  is requested; changed files receive fresh blob metadata.
- [x] Persist checksum and file type results with metadata status.
- [x] Run MediaInfo, archive and torrent jobs blob-wise and persist their
  relational results.
- [x] Represent extractor states explicitly: pending, completed, empty and
  failed; absent rows represent not requested.
- [x] Refactor worker jobs to return result DTOs instead of mutating a shared
  global catalog.
- [x] Add a single-writer persistence queue or equivalent transaction policy.
- [x] Keep scanner computation parallel while serializing SQLite writes safely.

### WP-04 Exit Criteria

- A scan can be interrupted without corrupting the database.
- A second unchanged scan performs no unnecessary digest work.
- Parallel workers never share an unsafe SQLite connection.
- Existing scanner options have equivalent SQLite behavior.

## WP-05: SQL-Based Analysis

Status: `[x]`

### WP-05 Objective

Move duplicate and missing-file analysis from D arrays into repository queries.

### WP-05 Steps

- [x] Query complete checksum candidates by file size.
- [x] Group candidates by complete checksums in SQL.
- [x] Merge duplicate blobs by moving `file_refs` to one blob.
- [x] Detect missing paths and support keep-versus-drop behavior.
- [x] Remove unreferenced blobs and dependent metadata safely.
- [x] Add indexes for path, size, SHA1, file type and metadata presence.
- [x] Expose analysis results through typed repository DTOs.

### WP-05 Exit Criteria

- [x] Duplicate results match the current content-identity behavior.
- [x] Missing-file behavior matches `--dropMissing`.
- [x] Analysis does not require loading all blobs into a D array.
- [x] Merge and cleanup are atomic transactions.

## WP-06: CLI Integration and Cleanup

Status: `[x]`

### WP-06 Objective

Define a clean dual-mode CLI: explicit SQLite repository commands and explicit
direct-JSON commands. Neither mode may fall back to the other. Each command
maps to one operation and uses only the public repository or JSON service API.

### Proposed Operations

```text
dosierskanilo init [ROOT]
dosierskanilo scan [ROOT]
dosierskanilo metadata [ROOT]
dosierskanilo analyze [ROOT]
dosierskanilo info [ROOT]
dosierskanilo list [ROOT]
dosierskanilo duplicates [ROOT]
dosierskanilo import [ROOT] INPUT.json [--replace]
dosierskanilo export [ROOT] --output OUTPUT.json
dosierskanilo json scan ROOT CATALOG.json
dosierskanilo json analyze CATALOG.json
```

### WP-06 Steps

- [x] Implement repository root discovery in the repository API.
- [x] Resolve an omitted repository root from the current directory and its
  parent directories for every top-level SQLite command.
- [x] Parse top-level SQLite commands and the explicit `json` command group.
- [x] Define positional root/catalog arguments for both modes.
- [x] Ensure JSON commands never open or create a SQLite repository.
- [x] Ensure SQLite commands never fall back to direct JSON storage.
- [x] Remove the option-only implicit mode.
- [x] Remove obsolete spelling aliases from the parser.
- [x] Route scan, analysis and metadata operations through the repository API.
- [x] Pass the CLI worker count through to repository metadata workers.
- [x] Add phase progress reporting for database-backed jobs.
- [x] Write operational logs to `.dosierskanilo/logs/`.
- [x] Add clear errors for missing repositories and schema incompatibility.
- [x] Use `analyze` as the only analysis spelling.
- [x] Define a typed parser result containing the selected action, validated
  values, and a structured parse status.
- [x] Remove the process-global CLI option state from the parser path.
- [x] Move CLI parsing behind a dedicated `dosierskanilo_cli.parser` module.
- [x] Separate repository and JSON validation into dedicated
  `repositoryvalidation` and `jsonvalidation` modules.
- [x] Reject options that do not belong to the selected repository subcommand.
- [x] Split repository execution into focused handlers for initialization,
  scanning, metadata extraction, analysis, import, export, and queries.
- [x] Make `scan`, `metadata`, `analyze`, `info`, `list`, and `duplicates`
  repository operations independent of JSON-mode validation.
- [x] Add `info`, `list`, and `duplicates` commands using the existing typed
  repository query API, including pagination and filters.
- [x] Add stable human-readable table output for query and summary commands
  without exposing SQLite types in the CLI.
- [x] Add machine-readable JSON output for query and summary commands.
- [x] Reserve `-h` for help and move hidden-file selection to an unambiguous
  option.
- [x] Define canonical kebab-case option names.
- [x] Return distinct exit codes for success, usage errors, and operation
  failures.
- [x] Write CLI diagnostics to stderr while keeping command results on stdout.
- [x] Make destructive repository import replacement explicit with `--replace`
  and keep it separate from JSON-mode catalog handling.

### WP-06 Exit Criteria

- Both explicit command groups work independently and never fall back to the
  other storage mode.
- Every SQLite command works from the repository root and a subdirectory
  without requiring an explicit repository option.
- JSON scan and analysis work without a `.dosierskanilo` directory.
- Each repository subcommand has one documented operation and rejects
  incompatible options.
- Help and version are successful, scriptable commands with exit code 0.
- Query output supports both human-readable and machine-readable consumers.
- CLI output distinguishes JSON mode from SQLite repository mode.
- No CLI module imports the SQLite implementation directly.

## WP-07: GUI Data-Source Integration

Status: `[x]`

Repository: `DosierSkanilo-Gui`.

### WP-07 Objective

Allow the GUI to browse JSON files and SQLite repositories through one data
source abstraction.

### WP-07 Steps

- [x] Introduce the GUI `DirectorySource` and source-query/page adapters for
  JSON and SQLite sources.
- [x] Keep the current JSON loader as the first adapter implementation.
- [x] Add SQLite source opening and repository-root discovery.
- [x] Replace repository Blob-table materialization with virtual cursor-backed
  rows and use source cursors for tree-file navigation. Remaining large-scroll
  interaction testing is listed under WP-08.
- [x] Move text, media, file-type, archive, and torrent filters into typed source
  query state for repository results.
- [x] Use summary `BlobRow`s without a full `NamedBinaryBlob` until a repository
  row is selected.
- [x] Load per-blob repository details and known-file references only for the
  selected row; query archive and torrent entries separately.
- [x] Keep preview paths and media details available through the detail API.
- [x] Preserve the GUI's preference JSON separately from repository data.
- [x] Replace eager root file-reference enumeration in `RepositoryDirectorySource`
  with bounded root summary/count queries.
- [x] Give each background operation its own repository read connection.
- [x] Add cross-source integration tests for filtered/sorted sequences and
  backward/forward navigation.

### WP-07 Exit Criteria

- [x] GUI can open both a JSON file and `.dosierskanilo`.
- [x] Opening a large repository does not load all file references into memory
  for the root summary.
- [x] Repository filtering uses typed source-side queries.
- [x] Existing detail widgets and image/audio/video previews work with SQLite
  data.
- [x] JSON remains usable when no repository is present.

## WP-08: Verification and Rollout

Status: `[-]`

### Tests

- [ ] Parser tests cover both explicit command groups, invalid combinations,
  and parser state isolation.
- [x] CLI integration tests verify help/version exit codes and stderr/stdout
  separation.
- [x] CLI integration tests verify SQLite discovery from the root, a nested
  directory, and a directory without a repository.
- [x] CLI integration tests verify explicit JSON scan and analysis without a
  repository directory.
- [x] Query tests verify pagination, filters, duplicate output, and stable
  machine-readable output.
- [x] Mode-isolation tests verify JSON commands never create SQLite state and
  SQLite commands never write direct JSON state implicitly.
- [x] Schema creation and forward-version rejection tests.
- [x] Import tests for the legacy root array and checked-in version-1/version-3
  JSON fixtures (`repository imports supported JSON fixture versions`).
- [ ] Add an explicit wrapper `dataVersion: 2` import test; no checked-in
  fixture currently declares version 2.
- [x] JSON round-trip tests.
- [ ] Filtered export tests.
- [x] Duplicate merge and missing-file tests.
- [x] Directory-tree and empty-directory tests.
- [x] Archive and torrent relationship tests.
- [x] Concurrent scanner-worker and reader/writer tests.
- [x] GUI cross-source filtering/navigation parity: `JSON and repository
  sources preserve filtered sorted navigation parity` in the GUI's
  `source/model/datasource.d`.
- [x] GUI concurrent tree/detail reads: `repository tree and detail queries
  use independent concurrent connections` in the GUI's
  `source/model/datasource.d`.
- [x] GUI archive/torrent continuation beyond 250 entries: `archive and
  torrent detail adapters continue beyond 250 entries` in the GUI's
  `source/model/datasource.d`.
- [x] GUI filtered export values and row parity: tests in the GUI's
  `source/ui/dataexport.d`.
- [x] GTK continuation offsets and stale-reply rejection: opt-in test
  `GTK continuation activation preserves offsets and rejects stale selection
  replies` in the GUI's `source/ui/nestedentrysignals.d`.
- [x] Virtual-table eviction and bidirectional scrolling: test
  `Virtual blob model scrolls through evicted chunks in both directions` in
  the GUI's `source/ui/virtualblobtable.d`.

GUI fixture descriptions and opt-in test commands are maintained in the GUI
repository's [`docs/TEST_FIXTURES.md`](https://gitlab.vahanus.net/dlang/dosierskanilo-gui/blob/main/docs/TEST_FIXTURES.md)
and [`docs/GUI-REDESIGN.md`](https://gitlab.vahanus.net/dlang/dosierskanilo-gui/blob/main/docs/GUI-REDESIGN.md#verification-baseline).

The bounded root summary and independent read-connection requirements are
implementation milestones tracked under WP-07, not test cases. Performance
measurements are recorded separately in [BENCHMARKS.md](BENCHMARKS.md).

The WP-08 checklist remains in progress while parser coverage, explicit
version-2 wrapper import coverage, and backend filtered-export
relationship-closure tests remain outstanding.

### Rollout Sequence

1. Freeze the explicit SQLite/JSON command contract.
2. Implement the two command groups and positional path arguments.
3. Enable automatic SQLite root discovery from the current directory.
4. Remove the old implicit JSON mode and compatibility aliases.
5. Split scan, metadata, analysis, import, and export into single-purpose
   handlers with stable exit codes.
6. Add repository info, list, and duplicate queries through the public API.
7. Compare JSON and SQLite results on the same input trees.
8. Enable SQLite browsing in the GUI while retaining JSON support.

### Final Exit Criteria

- CLI and GUI use the same public repository API.
- JSON mode tests pass independently of SQLite repositories.
- SQLite schema migrations are documented and tested.
- Large-repository benchmarks show bounded GUI memory use while the logical
  result set remains fully navigable.
- Both explicit CLI modes remain available.

## WP-09: Shared Long-Running Operations for CLI and GUI

Status: `[ ]`

### WP-09 Objective

Allow the CLI and GTK UI to start the same scan, metadata-scrape, and analysis
operations through library APIs, with consistent options/results, live progress,
and cooperative cancellation. Operation logic must remain outside GTK and CLI
presentation code.

### WP-09 Current State

- SQLite already exposes `Repository.scan()`, `Repository.updateMetadata()`,
  and `Repository.analyze()`; they synchronously return typed summaries.
- The SQLite CLI calls those methods and logs start/completion summaries but
  cannot report operation progress or cancel work inside them.
- Direct JSON scan/analyze uses `service.scanning` and `service.analyze`, with
  `ArgsArray`, a shared Ctrl-C flag, and console-oriented progress callbacks.
- The GUI currently supports browsing/filtering and its cancel button only
  invalidates a pending UI load result; it does not stop backend work.

### WP-09 Planned Contract

Introduce reusable operation requests and a run-control channel independent of
`ArgsArray` and GTK. The control channel should carry:

- operation identity and phase (`scan`, each metadata extractor, `analyze`,
  import/export where applicable)
- current/total work and an optional path/blob description
- a cooperative cancellation request checked at safe transaction/worker
  boundaries
- a typed completion result, cancellation result, or error

The shared requests should cover the existing CLI capabilities rather than a
smaller GUI-only subset:

- scan: recursion, hidden paths, and drop-missing behavior
- metadata: checksums, file type, MediaInfo, archive depth, torrents, rescan,
  and worker count
- analyze: duplicate merge and missing-file cleanup options

The task lifecycle should distinguish queued, running, cancelling, completed,
cancelled, and failed work. Progress events should identify the current
operation phase; metadata progress should include blob/extractor work and may
include nested archive-entry progress. Final typed summaries should match the
existing `ScanSummary`, `MetadataSummary`, and `AnalysisSummary` results.

The GUI should offer separate actions in a `Tools` menu and an options dialog for
each operation. It should run work off the GTK thread, show the active operation
and current phase in status/progress feedback, disable conflicting writes to the
same repository, and refresh the affected tab after completion. Existing
read-only browsing and independent tree/detail reads should remain available
when they do not conflict with a repository write.

The API must define callback threading and ownership. GUI callbacks must marshal
progress onto the GTK main loop; CLI callbacks retain their existing textual
output contract. Mutating operations for one repository must be serialized, and
workers must be joined before their repository connection is closed.

Cancellation must respect operation boundaries. A cancelled filesystem scan must
roll back its active transaction or follow a documented checkpoint policy.
Metadata work should stop scheduling new blobs, signal active workers, join them,
and persist only completed worker results. SQL analysis should stop between
atomic phases/transactions and report which phases completed. Filesystem scans
may have an indeterminate total until discovery finishes, so progress events
must support phase/status text without a percentage.

### WP-09 Stepwise Migration

#### WP-09.1: Freeze shared request and control contracts

- [ ] Map every CLI operation and option to a typed library request and result.
- [ ] Define progress events, cancellation token semantics, task identity, and
  callback/thread ownership without depending on GTK or `ArgsArray`.
- [ ] Define safe cancellation points and partial-result semantics for scan,
  metadata, and analysis.

Exit: backend API types can be constructed by either frontend; cancellation and
progress callbacks are safe to invoke from workers.

#### WP-09.2: Add operation control to backend services

- [ ] Add progress and cancellation checkpoints to the SQLite repository scan.
- [ ] Add per-blob/extractor progress and stop-scheduling/drain behavior to
  parallel metadata batches.
- [ ] Add phase progress and safe transaction boundaries to SQL analysis.
- [ ] Adapt JSON scan/analyze services to the same control contract, replacing
  service dependencies on CLI `ArgsArray` and the global console callback.
- [ ] Keep synchronous convenience wrappers for existing library callers if
  they can be implemented over the same operation functions.

Exit: repository and JSON operations return the existing typed summaries plus
consistent progress/cancel/error outcomes; cancelled writes leave valid state.

#### WP-09.3: Make the CLI a console adapter

- [ ] Route SQLite and JSON command handlers through the shared operation
  request/control API.
- [ ] Adapt Ctrl-C into a cancellation request and wait for safe worker shutdown.
- [ ] Render progress to the terminal while preserving command names, options,
  stdout/stderr ownership, exit codes, and final summaries.

Exit: existing CLI scripts and command contracts pass unchanged apart from
additional progress output for long-running operations.

#### WP-09.4: Add the GTK operation task manager

- [ ] Add explicit `Tools` actions and operation-specific options for scan,
  metadata extraction, and analysis.
- [ ] Resolve an explicit target mode: repository root or JSON catalog plus
  filesystem root where required; never implicitly convert storage modes.
- [ ] Run shared operations off the GTK thread and marshal progress events to
  GTK's main loop.
- [ ] Show queued/running/cancelling/completed/cancelled/failed states and
  operation summaries in the owning tab/status UI.
- [ ] Implement cooperative cancellation, serialize conflicting writes to one
  repository, and refresh the affected document after successful mutations.
- [ ] Keep tree/detail readers on independent connections and define behavior
  when an operation and browsing target the same repository.

Exit: GUI actions construct the same operation requests as CLI commands; GTK
remains responsive, progress is visible, cancellation is observed by backend
work, and repository/JSON views refresh from returned summaries.

#### WP-09.5: Verify CLI/GUI operation parity

- [ ] Compare scan, metadata, and analysis results and state changes between CLI
  and GUI for identical repository requests.
- [ ] Compare explicit JSON scan/analyze behavior for both frontends.
- [ ] Test cancellation before work, during scan, during metadata batches, and
  between analysis transactions; verify worker shutdown and repository validity.
- [ ] Test progress phase ordering, error propagation, source refresh, and
  conflicting same-repository operation policy.

Exit: shared operation behavior and user-visible status are covered by backend,
CLI integration, and GTK integration tests.

### WP-09 Exit Criteria

- CLI and GUI invoke the same public operation logic for the same storage mode.
- GUI work runs off the GTK thread and all UI progress updates run on the main
  loop.
- Cancellation is observed by backend work rather than merely discarding its
  eventual result.
- Progress, final summaries, failures, and cancellation are consistent across
  clients; storage modes remain explicit.

## Dependency Order

```text
WP-00
  +--> WP-01
  +--> WP-02
          +--> WP-03
          +--> WP-04
          +--> WP-05
                  +--> WP-06

WP-01 + WP-02
  +--> WP-06
  +--> WP-07

WP-03 + WP-04 + WP-05 + WP-06 + WP-07
  +--> WP-08

WP-04 + WP-05 + WP-06
  +--> WP-09.1 --> WP-09.2 --> WP-09.3
                       +--> WP-09.4 <-- WP-07
                               +--> WP-09.5
```

WP-01 and WP-02 can proceed in parallel after WP-00. WP-03 through WP-05
depend on the schema. WP-07 can begin API integration before the scanner is
fully migrated, provided the JSON adapter remains available.
WP-09 can start after the repository/CLI contracts exist; final shared-operation
rollout depends on WP-09.5 parity and cancellation tests.

## Definition of Done for Each Package

- The package has a focused commit or small commit series.
- Public behavior and migration effects are documented.
- Unit or integration tests cover the new behavior.
- The smallest relevant verification command passes.
- No package silently removes an existing JSON capability.
- Follow-up work is recorded as a new unchecked item in this plan.
