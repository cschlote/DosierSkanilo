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

All algorithms in both repositories are expected to be GC-friendly; changes must
preserve or improve that property. Keep temporary allocation proportional to
active work, reuse per-operation/per-worker scratch storage, avoid duplicate full
catalogs/projections, and bound caches. This does not prohibit the D GC or justify
premature manual allocation. Use representative workload measurements to verify
allocation churn, GC behavior, latency, and peak memory without changing results
or transaction guarantees.

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

## Current Implementation Snapshot (2026-10-10)

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

The shared operation contract, controlled SQLite/JSON executors, CLI adapters,
cross-process target leases, and initial GTK Tools actions are implemented.
Repository and JSON operations share typed requests, progress, cooperative
cancellation, safe pause/resume checkpoints, and operation results. Remaining
work is focused on broader cancellation/race tests and the full CLI/GTK parity
matrix; see WP-09.

WP-12 adds a deterministic D-generated filesystem/archive/torrent corpus, a
reviewed manifest, a single-flight test seed, JSON/SQLite parity coverage, and
CLI integration checks. Existing checked-in audio, image, video, and torrent
fixtures remain as compatibility inputs; the generated corpus supplements them.

WP-13.1 freezes the catalog domain model and WP-13.2 declares the storage-neutral
`CatalogBackend` interface and DTOs in `source/dosierskanilo/catalogbackend.d`.
WP-13.3 implements the JSON v0-v3 adapter. WP-13.4 adds the SQLite adapter over
the public `Repository` facade and an explicit default factory for both targets.

The backend library tests and GUI tests/build are separate checks. GUI-specific
status, test commands, and remaining UI integration tests are maintained in
the GUI plan at `https://gitlab.vahanus.net/dlang/dosierskanilo-gui/blob/main/docs/GUI-REDESIGN.md`.

Last verified on this snapshot:

- Backend: `dub test --config=library --compiler=ldc2` — 123 passed;
  `dub build --config=library --compiler=ldc2` passed.
- GUI: `dub test --compiler=ldc2` — 61 tests; `dub build
  --compiler=ldc2` passed.
- CLI: `dub build --config=cli --compiler=ldc2` and
  `./scripts/test-cli.sh` passed.
- GUI startup: `HOME=/tmp G_DEBUG=fatal-warnings
  ./build/bin/dosierskanilo-gui --self-test --self-test-delay=1000` passed with
  the new Tools menu loaded. Interactive operation dialogs still need a
  display-backed exercise.

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

Status: `[x]`

### WP-00 Objective

Measure the current behavior and freeze the compatibility requirements before
changing the storage path.

### WP-00 Steps

- [x] Create representative JSON datasets with 1,000, 10,000 and 100,000
  records.
- [x] Add `scripts/benchmark-storage.sh` for repeatable JSON/SQLite timings.
- [x] Measure load time and peak memory on representative
  1,000, 10,000 and 100,000-record datasets.
- [x] Record current CLI scan, analysis and JSON export behavior.
- [x] Record current GUI load, filter, duplicate and detail behavior.
- [x] Define the supported JSON compatibility set: legacy arrays, versions 1,
  2 and 3.
- [x] Define the first SQLite repository use cases and query filters.

### WP-00 Deliverables

- A reproducible benchmark command or script.
- A compatibility checklist for CLI and GUI behavior.
- A first list of public repository API operations.

### WP-00 Exit Criteria

- Baseline numbers are recorded.
- Every existing JSON field has an import/export decision.
- No new database code is started with an unresolved compatibility question.

## WP-01: Repository API and DTOs

Status: `[x]`

### WP-01 Objective

Define the initial public SQLite repository boundary and DTOs used by CLI and
GUI. The later storage-neutral JSON/SQLite base interface is WP-13.

### Implemented Modules

```text
source/dosierskanilo/repository/
    package.d
    types.d
    errors.d
    repository.d
    schema.d
    scanner.d
    metadata.d
    analysis.d
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
- [x] Define SemVer for the public API using this repository's DUB package
  release version; keep database schema versions independent.

### WP-01 Deliverables

- Public API module with documented types.
- API-level unit tests that do not require SQLite.
- Decision record for the shared API/DUB package SemVer version and independent
  database schema version.

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

WP-08 closes the verification gaps left after the SQLite/JSON repository and GUI
integration work. The three backend test packages below are complete. The WP-08
umbrella remains in progress only for its broader rollout/performance exit
criteria, which are tracked under WP-11.2.

### WP-08.1: Complete CLI parser contract tests

- [x] Exercise the SQLite command group (`init`, `scan`, `metadata`, `analyze`,
  `info`, `list`, `duplicates`, `import`, and `export`) and the explicit `json`
  group with representative valid inputs.
- [x] Exercise invalid combinations: missing positional paths, extra positional
  arguments, options attached to the wrong command, invalid option values, and
  attempts to use SQLite-only options in JSON mode or vice versa.
- [x] Verify help/version parse as successful actions and malformed input
  produces the documented usage status without starting an operation.
- [x] Verify parser state isolation: parse two different argument vectors
  sequentially in one process and prove values/options from the first parse do
  not leak into the second.
- [x] Keep parser tests at the typed parser boundary where possible; retain CLI
  process integration tests for exit codes and stdout/stderr behavior.

**Exit:** every command group and its rejected option boundaries are covered;
repeated parser calls are independent; the existing CLI integration suite still
passes.

### WP-08.2: Cover an actual version-2 JSON wrapper

- [x] Add a small valid JSON fixture whose wrapper literally declares
  `dataVersion: 2`; do not treat a version-3 fixture with a historical `v2` file
  name as version-2 coverage.
- [x] Include representative version-2 fields that exercise migration/fixup,
  including file references and at least one optional metadata relationship where
  the version-2 schema supports it.
- [x] Import the fixture through the public repository transfer API and verify
  the resulting catalog's semantic content, not only that import returns
  successfully.
- [x] Export the imported repository as current version-3 JSON and verify the
  expected migrated values and relationships are preserved.
- [x] Rename or clarify the broad existing test name
  `repository imports supported JSON fixture versions` so it does not imply
  version-2 coverage before the new fixture is added.

**Exit:** the test proves the declared version-2 input is accepted and migrated
to the current representation; unsupported versions remain rejected.

### WP-08.3: Verify filtered-export relationship closure

- [x] Build a repository fixture where the selected path subset contains a
  shared blob reference and at least one populated relationship such as media,
  archive, or torrent metadata; include unselected paths/blobs as controls.
- [x] Export the subset through the public filtered-export API, re-import or
  deserialize the result, and verify every selected file reference resolves to
  its blob and selected blob metadata is complete.
- [x] Verify references outside the selected path scope and metadata belonging
  only to excluded blobs are not accidentally included.
- [x] Cover the edge case where multiple selected paths reference the same blob:
  preserve one content record and all selected references without dangling or
  duplicated relationship rows.

**Exit:** filtered JSON is self-contained for all selected records and excludes
unselected references; it round-trips through the public import path.

### Existing Verification Coverage

- [x] CLI integration tests verify help/version exit codes and stderr/stdout
  separation; repository discovery from root/nested/no-repository directories;
  explicit JSON scan and analysis; query pagination/filtering/output; and
  storage-mode isolation.
- [x] Typed parser tests cover both command groups, option boundaries, help and
  version, extra positional arguments, invalid values, and state isolation.
- [x] Schema creation and forward-version rejection; legacy-array and
  version-1/version-2/version-3 imports; JSON round trips; filtered export
  relationship closure; duplicate merge and missing-file analysis; directory
  and empty-directory queries; archive/torrent relations; concurrent scanner
  workers and readers/writers.
- [x] GUI cross-source filtering/navigation parity, concurrent tree/detail
  reads, archive/torrent continuation past 250 entries, filtered GUI export
  values, stale GTK reply rejection, and virtual-table eviction/scrolling. Test
  names and opt-in display commands are recorded in the GUI repository's
  `docs/GUI-REDESIGN.md` and `docs/TEST_FIXTURES.md`.

### WP-08 Test Closeout Result

WP-08.1, WP-08.2, and WP-08.3 were implemented as independent tests. The backend
library suite passes with 87 tests; the GUI test suite passes with 45 tests.
No newly discovered issues were folded into these compatibility tests; scanner
and filter fixes are tracked separately in WP-10.

For the current DUB layout, verify with `dub test --config=library
--compiler=ldc2` and `dub build --config=library --compiler=ldc2` in the backend,
then `dub test --compiler=ldc2` and `dub build --compiler=ldc2` in the GUI.

WP-08 contains compatibility and parser tests only. Review-discovered behavior
fixes are tracked separately in WP-10 so their implementation is not hidden in
test-closeout work.

The GUI asynchronous-filter P0, WP-10.1 through WP-10.3 correctness work, and
WP-08.1 through WP-08.3 test closeout are complete and tested in the current
working trees. WP-09.1 and WP-09.1b are complete; controlled executors in
WP-09.2 are the next implementation step.

### Final Exit Criteria

- CLI and GUI use the same public repository API.
- JSON mode tests pass independently of SQLite repositories.
- SQLite schema migrations are documented and tested.
- Large-repository benchmarks show bounded GUI memory use while the logical
  result set remains fully navigable.
- Both explicit CLI modes remain available.

## WP-09: Shared Long-Running Operations for CLI and GUI

Status: `[-]`

### WP-09 Objective

Allow the CLI and GTK UI to start the same scan, metadata-scrape, and analysis
operations through library APIs, with consistent options/results, live progress,
cooperative cancellation, and pause/resume at safe checkpoints. Operation logic
must remain outside GTK and CLI presentation code.

### WP-09 Current State

- `runOperation()` executes controlled SQLite scan, metadata, and analysis
  requests, plus explicit JSON scan/analyze requests. Synchronous `Repository`
  methods remain convenience wrappers and acquire the same target lease.
- Repository and JSON CLI mutating commands now build shared requests, render
  operation progress, and map Ctrl-C into cooperative cancellation.
- The GUI Tools menu starts the shared operations on worker threads and marshals
  progress/state updates onto the GTK main loop; source refresh follows success.
- A backend operation test compares JSON and SQLite scan/metadata/analysis
  summaries and resulting duplicate relationships against the same fixture.
- GUI request-builder and lifecycle tests cover explicit source targets,
  acknowledged pause state, stale progress rejection, and committed-change
  refresh decisions.
- Cross-process target leases protect repository and JSON writes, including while
  an operation is acknowledged as paused. Process-level race and full CLI/GUI
  parity coverage remain to be completed.
- WP-09.1 is complete: frontend-neutral request, progress, control, validation,
  and result types are public in `dosierskanilo.operations`.
- WP-09.1b is complete: cooperative pause/resume lifecycle, availability,
  acknowledgement, resume and cancellation precedence are public in
  `OperationControl`. SQLite and JSON executors now advertise pause only at
  their implemented staging/commit checkpoints.

WP-09 changes operation control and frontend wiring; it does not replace the
existing scanner, repository, or JSON data model. Keep each subpackage narrow so
the public contract can be reviewed before service and UI implementations rely
on it. The same request must reach the same backend operation regardless of
whether CLI or GTK submitted it.

### WP-09 Frozen Contract

WP-09.1 freezes reusable operation requests and a run-control channel independent
of `ArgsArray` and GTK. The control channel carries:

- operation identity and phase (`scan`, each metadata extractor, `analyze`)
- current/total work and an optional path/blob description
- a cooperative cancellation request checked at safe transaction/worker
  boundaries
- a typed completion result, cancellation result, or error

The shared requests should cover the existing CLI capabilities rather than a
smaller GUI-only subset:

- scan: recursion, hidden paths, and drop-missing behavior
- metadata: checksums, file type, MediaInfo, archive scanning, torrents, rescan,
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

Cancellation and partial-result semantics are frozen in
[`OPERATION-API.md`](OPERATION-API.md): SQLite scan and analysis roll back their
single transaction when cancellation is observed; metadata stops scheduling,
drains workers, and commits completed blobs as atomic units; JSON scan/analyze do
not replace the catalog if cancellation arrives before the write phase. Progress
supports status-only events while totals are unknown.

The package should explicitly distinguish the supported targets and existing
operation surface:

- Repository mode targets a discovered or explicitly supplied `.dosierskanilo`
  root and uses the repository scan, metadata, and analysis APIs.
- JSON mode targets an explicit catalog path and filesystem root and preserves
  the existing `json scan` / `json analyze` command behavior. Do not add a new
  JSON command or silently initialize/use SQLite merely to make the interfaces
  look symmetric.
- Map every currently supported option to a request field or document why it is
  frontend-only. If an operation/option is not supported for one mode, return a
  clear validation error rather than pretending the modes are interchangeable.

WP-09.1 freezes these decisions in
[`OPERATION-API.md`](OPERATION-API.md): operation-specific commit units,
terminal states/results, callback behavior, target mapping, and cross-process
write serialization. Later packages implement that contract rather than make
local, incompatible choices.

#### WP-09.1b: Extend run control for pause and resume

Status: `[x]`

Extend the frozen cancellation/progress contract with cooperative pause/resume
before backend executor work begins. Keep GTK and CLI types out of the public
contract. Pause is acknowledged only at a safe checkpoint; it must not interrupt
an active syscall, external extractor, SQLite statement, atomic persistence unit,
or JSON backup/replacement sequence.

- [x] Define `pausing` and `paused` lifecycle states and legal transitions,
  including resume to `running`, cancellation while paused, repeated requests,
  and completion racing with a pause request.
- [x] Add thread-safe pause/resume requests and a worker checkpoint/wait contract.
  Resume and cancellation must wake a paused worker; cancellation takes
  precedence and must not leave a worker blocked indefinitely.
- [x] Define progress behavior while pausing/paused and after resume. Preserve
  operation identity, phase, and counts; do not report `paused` before backend
  acknowledgement.
- [x] Define how clients learn whether pause is supported/available in the
  current phase; state-aware frontends must not offer Pause when no safe
  checkpoint is reachable before completion.
- [x] Require paused operations to have drained child workers and released active
  SQLite transactions/statements. Keep the WP-09.2e target write lease until
  resume or cancellation so competing processes cannot mutate the target.
- [x] Specify pause checkpoints for scan, metadata, analysis, and JSON operations
  without weakening WP-09.1 commit/rollback guarantees. Design a staging or
  commit-boundary strategy where a single transaction otherwise leaves no safe
  mid-operation checkpoint; do not advertise pause for such a slice until tested.
- [x] Add deterministic API tests for lifecycle transitions, pause/resume races,
  cancellation while paused, wake-up behavior, and progress ordering.

**Exit:** the public run-control contract precisely defines pause acknowledgement,
resume, cancellation precedence, callback/state ordering, resource ownership, and
storage-safe checkpoints. No executor or frontend has to invent pause semantics.

### WP-09 Stepwise Migration

#### WP-09.1: Freeze shared request and control contracts

- [x] Inventory the current SQLite and JSON command handlers and map each
  operation, positional target, and option to a typed library request/result.
  Record unsupported combinations and preserve existing CLI validation.
- [x] Define operation identity and lifecycle states; progress events must
  include phase, optional current/total work, and descriptive context without
  requiring a percentage when totals are unknown.
- [x] Define cancellation request/token semantics, terminal outcome shape,
  error propagation, callback invocation/thread guarantees, and ownership/lifetime
  of request data and callbacks.
- [x] Define the serialization scope for competing mutations: the backend
  operation coordinator owns one cross-process write lease per canonical target;
  conflicting direct callers receive a typed busy failure and GUI queues remain
  frontend-local.
- [x] Specify safe cancellation/commit boundaries separately for filesystem
  scan, metadata worker batches, JSON file writes, and analysis transaction
  phases. Define what partial results a cancelled operation may retain.
- [x] Define how operations with no work, failed work, cancellation before
  start, and cancellation arriving after the final checkpoint are reported.
- [x] Add API-level tests for request validation, lifecycle/event invariants, and
  cancellation state semantics that do not need GTK or CLI process setup.
- [x] Document the contract and examples in the public library API; update the
  CLI/GUI plans only after the request and event shapes are stable.

**Deliverable:** a public, frontend-neutral operation API with documented
requests, results, progress/cancel control, threading/ownership, storage-mode
mapping, and safe-boundary policy in `source/dosierskanilo/operations.d`,
re-exported by `dosierskanilo`, with examples in `docs/OPERATION-API.md`.

**Exit:** both clients can construct the same request types; deterministic tests
cover lifecycle and cancellation semantics; no API type depends on GTK,
`ArgsArray`, terminal output, or SQLite implementation types.

#### WP-09.2: Add operation control to backend services

This is an umbrella package, not one implementation change. Complete and verify
each vertical slice independently. A slice must use WP-09.1 and WP-09.1b types,
retain the existing synchronous entry point where required, and have deterministic
tests for progress, cancellation and pause/resume boundaries, and resulting
storage state.

##### WP-09.2a: SQLite filesystem scan

- [x] Route repository scan through the shared operation request/control types;
  report discovery, traversal, and missing-file reconciliation phases and check
  cancellation during traversal and before commit.
- [x] On observed cancellation, roll back the whole scan transaction, including
  missing-file reconciliation and `dropMissing`; do not commit partial directory
  or file-reference state.
- [ ] Test cancellation before iteration, during traversal, before missing-file
  reconciliation, and after the last cancellation checkpoint. Verify summaries
  and unchanged repository state after rollback.
- [x] Define and test pause/resume checkpoints that do not wait inside the
  operation-wide transaction; preserve scan atomicity and prove cancellation
  still rolls back correctly after a resume.
- [x] Preserve `Repository.scan()` as a synchronous convenience wrapper over the
  controlled operation unless WP-09.1 documents a compatibility reason not to.

**Exit:** scan emits ordered phase events, observes cancellation at safe points,
and tests prove the repository is valid with exactly the documented commit or
rollback outcome.

##### WP-09.2b: SQLite metadata extraction

- [x] Add phase and per-blob progress for checksums, file type, MediaInfo,
  archives, and torrents; report unknown totals as status-only progress until
  work discovery establishes a total.
- [x] Stop scheduling new blobs after cancellation; let active extractor calls
  finish, drain all workers before closing resources, and persist only results
  permitted by the WP-09.1 partial-result policy.
- [x] Persist all requested metadata for one blob as one atomic commit unit. On
  cancellation, keep completed blob commits, leave unfinished work retryable,
  and never leave partially inserted child metadata for a blob.
- [ ] Exercise cancellation before a batch, while workers are active, between
  committed blobs, and after the final batch. Cover worker failure and no-work
  cases as well as successful extraction.
- [x] Pause between blob commit units, drain active extractor workers before
  acknowledging `paused`, then resume without losing completed or retryable work.
- [x] Preserve `Repository.updateMetadata()` as a synchronous convenience
  wrapper where possible; prove its summary and state semantics remain compatible.

**Exit:** no worker or callback outlives the operation; completed/failed metadata
states and summaries match the documented partial-result policy; cancellation
tests leave a usable repository.

##### WP-09.2c: SQLite analysis

- [x] Add progress for the analysis phases (missing-file handling, duplicate
  grouping/merge, and orphan cleanup) and check cancellation at safe points
  while preserving one transaction for the full analysis operation.
- [x] Roll back all analysis changes if cancellation is observed before commit;
  report cancellation with no phase reported as persistently completed.
- [ ] Test cancellation between each phase, duplicate-heavy input, missing-file
  cleanup, and a no-op analysis; verify relationships and foreign-key integrity.
- [x] Define and test pause checkpoints without holding the operation-wide write
  transaction or weakening rollback semantics; prove the operation resumes with
  relationships and foreign-key integrity intact.
- [x] Preserve `Repository.analyze()` as a synchronous convenience wrapper where
  possible.

**Exit:** each phase has a defined atomic boundary and repeatable tests for
successful, failed, and cancelled outcomes.

##### WP-09.2d: Direct JSON scan and analysis services

- [x] Adapt the existing JSON `scan` and `analyze` operations to the same
  frontend-neutral control contract; do not add a new JSON command solely for
  symmetry with SQLite metadata operations.
- [x] Keep controlled JSON operation services independent of CLI `ArgsArray`, process-global
  cancellation state, and console-formatted progress while preserving current
  JSON migration, backup, and write policy.
- [ ] Test cancellation before work, at each safe checkpoint, and during file
  processing before write; prove cancellation leaves the original catalog
  untouched. Once backup/replacement begins, defer cancellation until the write
  and restore policy has completed, then report completed or failed.
- [x] Permit pause only before the non-interruptible backup/replacement sequence;
  resume from that checkpoint without rereading or partially replacing the
  catalog. Do not pause while the replacement sequence is active.
- [x] Keep legacy service APIs available while WP-09.3 switches the CLI to the shared
  operation API.

**Exit:** existing JSON commands use the same control types, maintain their
explicit catalog/filesystem targets, and leave a valid catalog after success,
failure, or cancellation.

##### WP-09.2e: Cross-operation lifecycle and serialization

- [ ] Test worker joining, connection/handle lifetime, and callback completion
  for all operation families; no callback may access a destroyed request,
  result sink, database, or JSON output.
- [x] Implement the backend operation coordinator's cross-process exclusive
  target lease using the canonical repository root or JSON catalog path as its
  lock key. A conflicting direct call returns `OperationErrorCode.targetBusy`;
  GUI queues remain local to the frontend.
- [ ] Test competing writes from two callers in one process and from separate
  processes targeting the same repository/catalog. Verify the rejected call
  cannot change state and the lease releases after success, cancellation, or
  failure.
- [x] Verify independent read connections remain usable and define what readers
  may observe while a write is active.

**Umbrella exit:** all supported SQLite and JSON operation families have
controlled and legacy synchronous entry points, deterministic progress,
cancel/pause/resume tests, documented partial-state semantics, and valid storage
after termination.

#### WP-09.3: Make the CLI a console adapter

Implement and verify the CLI adapter incrementally with each backend vertical
slice; do not wait until all operation backends are changed before exercising
the shared contract from a real client. The following adapter slices are ordered.

##### WP-09.3a: SQLite scan CLI adapter

- [x] Implement after WP-09.2a; build the same scan request the GTK client will
  later use and render phase events in the existing CLI output style.
- [x] Verify Ctrl-C requests cancellation, waits for safe worker shutdown, and
  reports the terminal outcome without labeling an incomplete scan successful.
- [ ] Add process-level coverage for successful scan, progress, cancellation,
  exit status, and valid repository state.

##### WP-09.3b: SQLite metadata CLI adapter

- [x] Implement after WP-09.2b; map every existing `metadata` option to the
  shared request without changing defaults or validation.
- [ ] Verify worker progress, Ctrl-C/drain behavior, final `MetadataSummary`,
  stderr/stdout ownership, and repository validity after cancellation.

##### WP-09.3c: SQLite analysis CLI adapter

- [x] Implement after WP-09.2c; map analyze/missing-file/duplicate behavior to
  the shared request while preserving existing options and result output.
- [ ] Verify phase progress and cancellation outcomes against the transaction
  boundary/partial-state contract.

##### WP-09.3d: JSON CLI adapters

- [x] Implement after WP-09.2d; route the existing JSON `scan` and `analyze`
  commands through the shared operation API without changing their explicit
  catalog and filesystem targets.
- [ ] Verify Ctrl-C, progress, catalog backup/write behavior, exit results, and
  storage-mode isolation.

##### WP-09.3e: CLI lifecycle and compatibility closeout

- [ ] Verify cross-operation write serialization and worker shutdown from the
  process boundary after WP-09.2e.
- [ ] Preserve command names, option meanings, defaults, validation, log paths,
  exit codes, final typed summaries, and stdout/stderr separation.
- [ ] Run parser, mode-isolation, command integration, progress, and cancellation
  tests for all supported CLI operation families.

- [x] Replace direct service/repository orchestration in SQLite and JSON command
  handlers with request construction and calls to the shared operation API.
- [x] Adapt Ctrl-C to one cancellation request, wait for worker shutdown, and
  return the documented cancellation exit/result without reporting incomplete
  work as success.
- [x] Render phase/progress events in the terminal while keeping diagnostics on
  stderr and query/result output on stdout; avoid interleaving worker output.
- [ ] Preserve command names, option meanings, defaults, validation, log paths,
  exit codes, and final typed summaries for successful operations.
- [ ] Add process-level integration tests for successful progress output,
  cancellation/exit behavior, stdout/stderr separation, and repository validity
  after cancellation; retain parser and mode-isolation tests.

**Exit:** CLI handlers are presentation adapters over shared operations; existing
commands/options remain compatible; Ctrl-C stops work at a safe boundary and
the process exits only after workers have stopped.

#### WP-09.4: Add the GTK operation task manager

Keep GTK behavior as an adapter to the shared backend contract. The initial Tools
integration is in place; remaining work is lifecycle testing and CLI/GUI parity,
not a separate progress, cancellation, or partial-result policy.

- [x] Add explicit Tools menu entries and operation-specific option dialogs for
  supported scan, metadata, and analysis requests; map each control to the same
  typed request field used by the CLI.
- [x] Require an explicit target consistent with the active document: repository
  root for SQLite operations, or catalog plus filesystem root for supported JSON
  operations. Explain invalid mode/operation combinations before starting work.
- [x] Run backend operations on worker threads; marshal all GTK state changes
  and progress rendering onto the GTK main loop. Ensure closing a tab/window
  cannot leave callbacks targeting destroyed widgets.
- [x] Present queued/running/pausing/paused/cancelling/completed/cancelled/failed
  state, current phase, available progress, and final typed summary in the owning
  tab/status area. Handle unknown totals without displaying misleading
  percentages.
- [x] Add state-aware Pause, Resume, and Cancel actions. Disable Pause when the
  operation has no available safe checkpoint; show `pausing` until the backend
  acknowledges the pause and allow cancellation to wake a paused worker.
- [x] Connect Cancel to backend cancellation, keep the UI responsive while
  workers drain, and distinguish backend cancellation from merely discarding a
  stale UI reply.
- [x] Serialize conflicting writes to one repository/catalog. Define whether
  reads may continue during a write; preserve independent repository read
  connections and prevent refresh/read races from showing stale state as current.
- [x] On success, refresh the affected source and preserve a valid selection,
  filter, sort, and expanded-directory state where the refreshed data allows it.
  On cancellation/failure, display the result and refresh if committed state
  changed.
- [ ] Add GTK-independent task-manager tests for event ordering, cancellation,
  pause/resume, serialization, stale-tab handling, and refresh decisions; add
  opt-in display tests for Tools wiring and main-loop updates.

**Exit:** GTK actions construct the same requests as CLI; GTK remains responsive;
all widget updates run on the main loop; Cancel reaches backend work; conflicting
writes cannot overlap; pause/resume is exposed only at backend-acknowledged safe
checkpoints; successful or partially committed operations refresh the correct
source and show their terminal result.

#### WP-09.5: Verify CLI/GUI operation parity

- [ ] Build a parity matrix from the WP-09.1 request/option inventory. For each
  supported repository operation, run equivalent CLI and GTK requests against
  equivalent fixtures and compare typed summaries plus resulting repository
  state.
- [ ] Repeat for the JSON operations supported by both frontends; verify JSON
  mode never creates/discovers SQLite state and SQLite mode never writes a JSON
  catalog implicitly.
- [ ] Exercise cancellation before start, during scan, during metadata worker
  batches, and between analysis phases. Verify terminal status, partial state,
  joined workers, closed handles, and continued repository/catalog usability.
- [ ] Pause and resume each operation at its documented safe checkpoint from
  both frontends where exposed; verify state/progress continuity, cancellation
  while paused, lease ownership, joined workers, and unchanged atomicity policy.
- [ ] Verify progress phase order and monotonic work counts where counts are
  known; verify unknown-total status events remain usable without percentages.
- [ ] Verify operation errors reach both clients consistently while CLI stream
  ownership/exit behavior and GTK status behavior remain client-appropriate.
- [ ] Verify successful mutations refresh the right document, failed/cancelled
  mutations refresh only when committed state changed, and conflicting writes
  obey the documented serialization policy.
- [ ] Record unsupported mode/operation pairs and confirm both frontends reject
  them consistently rather than silently changing storage modes.

**Exit:** the parity matrix is checked in with test references; backend, CLI, and
GTK tests cover equivalent results, progress, cancellation, errors, refresh, and
mode isolation for every supported request family.

Parity evidence and the remaining WP-09.5 process/display checks are summarized
in [`OPERATION-PARITY.md`](OPERATION-PARITY.md).

### WP-09 Exit Criteria

- CLI and GUI invoke the same public operation logic for the same storage mode.
- GUI work runs off the GTK thread and all UI progress updates run on the main
  loop.
- Cancellation is observed by backend work rather than merely discarding its
  eventual result.
- Pause/resume is exposed only for operations with documented safe checkpoints;
  a paused task holds no active transaction and remains the exclusive writer for
  its target until resumed or cancelled.
- Progress, final summaries, failures, and cancellation are consistent across
  clients; storage modes remain explicit.

## WP-10: Review-Driven Query and Scanner Correctness

Status: `[x]`

This package records concrete consistency/correctness concerns found in the
2026-10-04 reviews. For each suspected defect, add a regression test that
demonstrates the required behavior before changing the implementation. Do not
assume a suspected SQLite cursor issue is a reproduced failure; the test should
establish whether rows can be skipped under the supported driver/runtime.

### WP-10.1: Preserve case-sensitive matching in catalog queries

- [x] Add an explicit `caseSensitive` option to `RepositoryQueryOptions` and
  propagate it from the GUI `SourceQuery` through offset and cursor catalog
  queries.
- [x] Update catalog SQL to apply the requested case rule to file-path matching;
  preserve checksum/SHA1 matching semantics independently of path case.
- [x] Test upper/lower-case path queries through `RepositoryQueryOptions`, both
  offset and cursor pagination, and the GUI Blob table. Compare JSON and SQLite
  results with the tree/file path for case-sensitive and insensitive settings.
- [x] Update public query docs and README parity claims to match the tested
  contract.

**Exit:** the same case preference yields the same matching path sequence in
JSON and SQLite tree and Blob-table views; exact binary SHA1 lookup is unaffected
by path case settings; cursor continuation does not change the result set.

### WP-10.2: Make missing-file reconciliation safe while updating rows

- [x] Add a scan regression fixture with 40 references that become missing in
  the same scan, one still-present reference, and a hidden-file control.
- [x] Confirm every missing reference is marked exactly once on the configured
  SQLite/D2-SQLite target. The regression did not reproduce skipped rows, so no
  materialization workaround was warranted.
- [x] Verify `dropMissing` still removes the intended references and orphan
  blobs transactionally, while hidden-file policy remains unchanged.

**Exit:** the regression test passes on the configured SQLite/D2-SQLite target
and proves all eligible missing references are reconciled without omissions or
duplicate summary counts.

### WP-10.3: Define changed-file blob cleanup and scan summary semantics

- [x] Extend the incremental-scan test to change a file's contents/size or mtime
  more than once and inspect blob/reference counts after each scan.
- [x] When a file changes, remove the old blob only if no remaining file
  reference points to it; cover the shared-blob case and verify foreign-key
  dependent torrent metadata is handled correctly.
- [x] Define and document `ScanSummary.filesMissing` (references newly detected
  as missing during this run) and `filesDropped` (references actually removed
  by this run), or choose clearer field semantics/names if existing behavior is
  inconsistent.
- [x] Test `dropMissing` after missing references were detected by an earlier
  scan, including multiple missing references, to pin down the summary contract.
- [x] Verify repeated scans of changed files do not accumulate unreferenced
  blobs; retain the existing unchanged-scan idempotence checks.

**Exit:** changed and removed files leave no unintended orphan blobs, shared
content remains intact while referenced, summaries have documented per-run
meaning, and repeat-scan tests prove the behavior.

### WP-10 Exit Criteria

- Catalog and tree query filter semantics agree for the supported case rules.
- Missing-file scan behavior is regression-tested against multi-row mutation.
- Changed-file updates have a tested orphan-retention/removal policy and stable
  `ScanSummary` semantics.
- All changes preserve transaction integrity and pass backend plus GUI tests.

## WP-11: Read-Path Cost and API-Boundary Review

Status: `[ ]` (investigation first; implementation only where measurements or
contract needs justify it).

The 2026-10-04 review raised concerns about per-query repository opens,
materialization, JSON parsing, and the GUI's dependency on `NamedBinaryBlob`.
Some are potential costs or intentional transitional behavior rather than
confirmed defects. Measure and inspect actual call paths before optimizing.

### WP-11.1: Measure repository connection-open overhead

- [ ] Measure steady-state directory expansion/query cost separately from
  repository initialization and schema migration, using a representative large
  directory tree and repeated independent source operations.
- [ ] Inspect which statements on `Repository.open()` write on an already
  initialized/current repository; distinguish first-open/migration writes from
  repeated-read behavior.
- [ ] If the measured overhead or write-capable open path is material, design a
  validated read-only open mode or another connection-lifetime policy that keeps
  concurrent operations independent and does not run migrations on readers.
- [ ] Re-run source concurrency tests and benchmark before/after; retain bounded
  root summaries and do not share a non-thread-safe connection between workers.

**Exit:** record measured baseline and a decision. If code changes are
unnecessary, document why; if needed, tests prove read-only opens cannot mutate
repository state and independent query behavior remains correct.

### WP-11.2: Audit JSON paging and virtual-table materialization

- [ ] Trace every production caller of `loadDocumentPage()` and
  `loadDocumentCursorPage()` for JSON sources. The normal JSON document load
  currently uses `loadDocumentSource()`; distinguish that one-time full load from
  helpers that may deserialize again.
- [ ] Verify whether `loadAllRows` remains reachable in normal UI operation and
  whether it is an explicit user choice or an accidental path around bounded
  loading.
- [ ] Measure JSON open/filter memory and latency and repository virtual-table
  cache memory at representative sizes; include large directory counts as well
  as blob counts.
- [ ] If repeated JSON parsing or unbounded materialization occurs in a normal
  workflow, cache/reuse the parsed source or remove that call path without
  changing legacy JSON compatibility. Keep explicit full-materialization modes
  documented if they remain available.

**Exit:** production call paths and costs are documented; any optimization is
justified by a reproducible measurement and tested for result parity and bounded
repository cache behavior.

### WP-11.3: Decide the long-term Blob DTO boundary

- [x] Document the current boundary: directory/file browsing uses typed
  repository projections, while the transitional Blob table and JSON loader use
  `NamedBinaryBlob`.
- [x] Decide the transition: keep the Blob table coupled to the canonical JSON
  model for now; define source-neutral summary/detail DTOs as part of WP-13 before
  migrating or removing that view.
- [ ] If decoupling is selected, define stable IDs, summary flags, lazy detail
  retrieval, JSON/SQLite parity, and migration compatibility before changing the
  public API.
- [x] Keep the JSON serializer's canonical model separate from GTK widgets and
  do not expose SQLite implementation types to the GUI.

**Exit:** an explicit architecture decision with consequences and follow-up
work; implementation is a separate package if it would be larger than a focused
API change.

### WP-11.4: Reconcile architecture and baseline documentation

- [x] Update the backend module dependency diagram to include the public
  repository facade and its internal schema/transfer/scanner/metadata/analysis
  modules.
- [x] Close WP-00 baseline items and track the remaining large-query/allocation
  measurements under WP-11.2/WP-11.5 instead of leaving an ambiguous umbrella.
- [x] Keep README, architecture, benchmark scope, WP-08/WP-09 status, and the
  GUI's cross-repository links consistent with the implemented paths.

**Exit:** a new contributor can trace the actual API/module boundary and tell
which unfinished baseline work is intentional versus forgotten.

### WP-11.5: Reduce GC allocation churn in hot algorithms

- [ ] Profile representative repeated work in SQLite scan/metadata, JSON
  filtering, directory projection, and TreeView filter/clear cycles. Record
  elapsed time, peak process memory, and GC allocation/collection behavior where
  tooling permits.
- [ ] Identify allocations inside per-file/per-directory loops, including
  temporary normalized paths, formatted strings, one-use arrays, duplicate
  filtered row/tree projections, and unbounded retained results.
- [ ] Prefer stable source objects/IDs, in-place match/visibility state,
  per-worker scratch buffers, capacity reservation when counts are known, and
  bounded caches. Do not share mutable scratch across concurrent workers.
- [ ] Keep SQLite result construction bounded by requested pages and active
  workers. For JSON, reuse the parsed source/index rather than copying the full
  catalog or rebuilding its complete tree for each query.
- [ ] Re-run output-parity, cancellation, pause/resume, and transaction tests
  after optimization; compare before/after workload measurements and document
  any retained allocation tradeoff.

**Exit:** hot paths have a measured allocation/memory baseline; repeated
operations do not create avoidable full-catalog/tree copies or unbounded caches;
result parity and storage semantics remain covered by tests.

## WP-12: Reproducible Synthetic Test Catalog

Status: `[x]`

Build one deterministic fixture generator in D and use it from both a standalone
DUB executable configuration and unit-test support. Do not check generated
binary files into the repository. The generator must create the same logical
filesystem/archive corpus across supported D compilers and emit a manifest that
is compared with an independently reviewed expected manifest.

### WP-12.1: Define the canonical fixture and manifest

- [x] Add a versioned expected manifest under `test/fixtures/synthetic/`. It
  records relative paths, roles, sizes, normalized timestamps, content checksums,
  duplicate groups, and archive-member names/sizes/checksums. It contains no
  machine-specific absolute root or wall-clock generation time.
- [x] Include deterministic cases for: identical file contents at multiple
  paths; same-size/different-content files; empty and text files; UTF-8 and
  nested paths; an empty directory; hidden entries; and a fixed `SOURCE_DATE_EPOCH`.
- [x] Include archive cases whose members have stable names and data, including
  a member with the same content as a normal file, a unique member, nested paths,
  and a nested archive. Record current expected archive metadata without
  pretending members are already ordinary catalog blobs.
- [x] Define how optional formats are reported. ZIP and TAR are baseline cases;
  RAR/7z remain explicitly marked skipped outside the deterministic D baseline.

**Exit:** the golden manifest independently describes all logical inputs and
expected invariants; it does not merely copy output fields calculated by the
same assertion being tested.

### WP-12.2: Implement the D generator and CLI

- [x] Put reusable generation code in a D module shared by tests and the
  generator executable. Add a DUB configuration such as
  `synthetic-testdata`; do not add Python or another runtime dependency.
- [x] Default CLI output to `build/test-data/synthetic-catalog`; accept an
  explicit `--output PATH` for debugging/CI. Refuse to overwrite unrelated
  non-empty directories unless an explicit replace option is supplied.
- [x] Generate ZIP data with the D standard-library ZIP writer and deterministic
  timestamps/compression settings. Generate baseline TAR data in D (USTAR) so
  archive creation itself does not depend on a host shell tool. RAR/7z are marked
  skipped in the golden manifest until deterministic D writer support is added.
- [x] Write an actual `manifest.json` beside the generated data. Add an explicit
  `--update-manifest PATH` mode for intentionally refreshing the checked-in
  golden; ordinary generation/tests must never update the golden automatically.
- [x] Stage output in a temporary sibling directory, validate it against the
  expected manifest, then publish it atomically. Keep the manifest independent of
  the absolute destination path.

Example invocation:

```bash
dub run --config=synthetic-testdata -- --output build/test-data/synthetic-catalog
```

**Exit:** repeated generation with the same generator version yields identical
logical files and manifest; generation errors leave no partially published tree.

### WP-12.3: Add single-flight unit-test setup

The backend test runner uses `silly` and executes unit tests in a parallel
`TaskPool`; each test must not race fixture construction or mutate shared input.

- [x] Add a lazy `ensureSyntheticTestCatalog()` helper backed by a process-wide
  `Mutex`/`Condition` state machine: `uninitialized`, `building`, `ready`, or
  `failed`.
- [x] The first caller changes the state to `building`, releases the mutex,
  generates and validates the corpus, then publishes `ready` and notifies all
  waiters. Other callers wait in a condition loop and immediately reuse the
  published path. On failure, publish the error and notify all waiters so none
  can block indefinitely.
- [x] Do not perform generation in a module/static constructor. The first test
  that needs synthetic data triggers it explicitly.
- [x] Make the shared corpus immutable after publication. Tests that scan,
  mutate, remove files, create `.dosierskanilo`, or rewrite catalogs must copy the
  relevant tree into a unique per-test working directory.
- [x] Use a process-specific test output beneath `build/test-data/` so separate
  concurrent `dub test` processes do not share writable repositories. Add that
  generated directory to `.gitignore` and `scripts/clean.sh`.

**Exit:** add a concurrency test that starts many callers at once, proves the
generator runs exactly once, verifies all callers receive the same valid corpus,
and proves all waiters receive a deterministic failure if generation fails.

### WP-12.4: Drive backend and archive tests from the corpus

- [x] Add manifest-validation tests for generator output, file bytes, fixed
  timestamps, directory layout, and exact archive entry listings.
- [x] Exercise `DosierArkivo` listing, single-entry extraction, deep checksums,
  archive rescan idempotence, invalid archives, and password/optional-format
  cases when the requisite runtime/writer tool exists.
- [x] Run the same copied filesystem tree through JSON scan/metadata/analyze and
  SQLite scan/metadata/analyze. Compare normalized summaries, complete checksums,
  duplicate groups, references, and export subsets against manifest expectations.
- [x] Add fixtures for unavailable/missing sources and verify analyze preserves
  records by default, while explicit `drop-missing` removes only the expected
  records.
- [x] Add operation cancellation/failure tests using a private copy of the
  generated corpus; never let a test modify the shared published fixture.
- [x] Extend `scripts/test-cli.sh` or add a focused script that invokes the
  generator and runs both explicit CLI modes against the same corpus.

**Exit:** backend model, JSON, SQLite, archive adapters, and CLI tests consume the
same versioned synthetic scenario; generated data is reproducible and no new
generated binary fixtures are committed. Existing compatibility fixtures remain
tracked until a deliberate history-cleanup decision is made.

## WP-13: Storage-Neutral Catalog API and First-Class Archive Content

Status: `[-]` (WP-13.1 through WP-13.4 complete; WP-13.5 is next.)

The product goal is to index one directory tree, enrich its binary content with
metadata, identify duplicate payloads, and expose filtered logical subsets to
both CLI and GTK. JSON and SQLite are storage implementations of that catalog;
they are not separate domain models. A backend base interface/factory should be
the public HMI boundary. A future SQL implementation may replace SQLite behind
that interface, but generic SQL support is not an initial compatibility promise.

Current implementation facts and limitations:

- `NamedBinaryBlob` is both the JSON v3 serializer record and an in-memory
  content-plus-filesystem-reference object. `FileSpec` stores a physical path
  and observed timestamp.
- `Repository` is a concrete SQLite class with public typed queries and
  synchronous convenience methods. `JsonCatalogBackend` adapts current JSON
  v0-v3 deserialization, queries, subset export, and shared operations; the
  existing JSON CLI still uses the same services through the operation runner.
- The GUI owns `DirectorySource` and adapts JSON projections plus `Repository`
  DTOs. There is not yet one backend catalog/query superclass.
- `ArchiveSpec` is nested under the containing `NamedBinaryBlob`; it stores the
  inner path, size, timestamp, and optional checksums, not a normal blob ID or
  reference. `torrentInfo.files` is likewise nested metadata.
- `FileArchive.getEntries()` returns entry names. Deep `updateArchives()` scans
  each entry by extracting it to a temporary directory and hashing it. It does
  not persist an entry-list fingerprint or incrementally reconcile stable entry
  identities. `ArchiveSpec[]` is replaced on a forced rescan; archive entries
  are not yet queryable/deduplicated as ordinary file content.

### Frozen product invariants

1. **Content and reference are distinct.** One content blob represents one
   payload identity; one or more references say where that payload is addressed.
   A physical file path and an archive member are different reference kinds.
2. **Identity semantics are storage-neutral.** Content IDs and reference IDs
   are opaque and scoped to one catalog source. A rename changes a physical
   reference, not the payload ID; equal complete content digests may merge
   references into one blob. IDs from independent catalog sources are not
   compared directly.
3. **A virtual archive path is not a filesystem path.** Use a structured locator
   containing the container reference and entry ID. Duplicate same-name entries
   and nested archives are disambiguated independently from display paths.
4. **Missing is explicit.** Temporary unavailability of a filesystem or archive
   source must not delete references by default. Destructive removal requires an
   explicit `dropMissing` request and a committed result.
5. **HMI behavior is storage-neutral.** Filters, ordering, navigation, operation
   progress, cancellation, partial-commit status, and selected-content access
   have the same meanings for JSON and SQLite wherever supported.

### WP-13.1: Freeze domain values and locators

- [x] Define names and responsibilities for content (`ContentBlob`/current
  `NamedBinaryBlob`), references, stable IDs, extractor state, and metadata.
- [x] Define a discriminated `ContentLocator` for filesystem paths and archive
  entries, including root-relative vs absolute resolution and path normalization.
- [x] Define archive-entry identity when names collide, and a locator chain for
  nested archives. Keep display paths separate from identity.
- [x] Define how torrent members relate to archive/filesystem references; record
  the current torrent metadata-only behavior as a compatibility constraint.
- [x] Decide whether the public domain values are immutable snapshots/value DTOs
  or mutable unit-of-work objects. Do not expose Jsonizer annotations as the
  storage-neutral API contract.

Decisions and examples are frozen in [CATALOG-DOMAIN.md](CATALOG-DOMAIN.md).

**Exit:** API examples cover one physical file, renamed/shared references, a
duplicate payload, an archive entry, duplicate entry names, and one nested
archive without using a GTK or SQL type. **Met:** the design note contains these
examples and records the compatibility boundaries.

### WP-13.2: Define the public polymorphic catalog contract

Status: `[x]`

The target shape is one public backend interface implemented by JSON and SQL
adapters, not an HMI-side `switch` over storage engines:

```text
CatalogBackend
  sourceInfo() / capabilities()
  rootSummary(query)
  listDirectories(query, cursor)
  listFiles(query, cursor)
  loadContent(contentId, detailMask)
  runOperation(typedRequest, control)
  exportSubset(query, format/options)

JsonCatalogBackend      SqlCatalogBackend
```

The public declarations are in `source/dosierskanilo/catalogbackend.d` and are
re-exported by `dosierskanilo`. Keep the current `OperationTarget` request
distinction explicit. The backend factory selects an adapter, but no adapter
may reinterpret or silently convert a target.

- [x] Define a public `CatalogBackend` interface and explicit target/factory for
  JSON and SQL adapters. Keep `d2sqlite3`, SQL statement types, JSON serializer
  types, GTK, and CLI parser/output types private to their adapters.
- [x] Move or re-export the common directory/file projections, filters, sort
  order, cursors, details, and result subset API from a neutral backend module.
- [x] Define logical root, directory/file listing, detail, next/previous, and
  filtered-subset operations. Internal paging may differ, but user-visible
  ordering, stable identity, and result membership must match.
- [x] Define supported capabilities and typed unsupported-operation errors
  rather than silently changing storage modes.
- [x] Define transaction/snapshot and mutation ownership on the base interface;
  keep synchronous convenience wrappers over controlled operation execution.

**Exit:** a fake in-memory backend can satisfy the interface contract tests;
frontends can compile against the interface without importing `Repository` or
`NamedBinaryBlob` implementation details. **Met:** the interface and neutral DTOs
are exported, and the fake backend contract test passes.

### WP-13.3: Migrate the JSON catalog adapter

Status: `[x]`

- [x] Wrap current v0-v3 deserialization, migration, and v3 serialization behind
  the catalog interface without changing accepted input/output behavior.
- [x] Build/reuse a JSON source index for directory, reference, blob, filter,
  cursor, detail, and selected-subset queries.
- [x] Preserve unavailable source paths unless explicitly removed; verify the
  recently fixed JSON `analyze` default against absent mounts and malformed input.
- [x] Define an extended JSON version only when the chosen reference/archive
  model cannot be represented losslessly by v3. Never silently omit first-class
  archive content on export.

**Exit:** JSON mode implements the common reads and operations with parity tests,
keeps its explicit catalog/root isolation, and preserves legacy fixtures. **Met:**
the JSON adapter tests cover v0-v3 reads, generated-catalog scans/metadata,
queries/cursors, details, subset exports, operation outcomes, and missing-source
retention/removal.

### WP-13.4: Isolate the SQLite adapter and assess SQL portability

- [x] Adapt the public `Repository` facade to the common backend contract while
  retaining its existing methods as compatibility wrappers.
- [x] Keep schema, migrations, SQL, and `d2sqlite3` behind the SQLite adapter.
- [x] Route explicit JSON and repository targets through the default backend
  factory without reinterpreting either target.
- [x] Map bounded directory/file cursors, lazy details, archive/torrent pages,
  typed operations, availability filters, and filtered JSON subset export.
- [x] Identify which interface requirements are genuinely relational/SQL
  capabilities and which are catalog-domain behavior.
- [x] Only then decide whether a second SQL engine is warranted. Document
  transaction, keyset paging, blob/binary, migration, locking, and test
  requirements before promising portability.

**Exit:** the same query/operation contract is implemented by the JSON and
SQLite adapters; an engine-portability decision is explicit and evidence-based.

**Portability assessment:** directory/file/detail DTOs, filters, sort order,
opaque identities, logical cursors, capabilities, typed errors, operations, and
subset-export semantics are catalog-domain behavior. SQLite schema/migrations,
transactions, WAL/busy-timeout configuration, binary digest storage, SQL
filtering, and the SQL portion of keyset paging remain behind `Repository` and
`SqliteCatalogBackend`. The backend cursor carries the last path/row identity/
size needed by the repository keyset query without exposing those fields to
consumers. Target write leases provide cross-process mutation exclusion; each
read uses an independent repository connection.

No second SQL engine is warranted by current product requirements. The public
`CatalogBackend` boundary is storage-neutral, but this package does not promise
generic SQL portability. If another engine is proposed, its design must preserve
transactional scan/import semantics, stable sort-aware keyset paging, raw binary
digest values, versioned migrations, equivalent target locking/read behavior,
and the JSON/SQLite parity suite before it is supported.

WP-13.4 verification: `dub test --config=library --compiler=ldc2` — 123 passed.
The SQLite adapter test scans the generated corpus through both backends and
compares root counts/size, filtering, paging in both directions, lazy metadata,
archive/torrent pages, subset export, missing-reference analysis, and availability.

### WP-13.5: Promote archive members into searchable content references

- [ ] Extend the archive adapter API to return bounded typed entry descriptors
  (stable entry identity, normalized name/path, size, timestamp, and optional
  format-native checksum) separately from extraction.
- [ ] Store a container content identity and archive-index/extractor version so
  unchanged archives reuse their entry index and changed containers invalidate
  only dependent entries.
- [ ] Store archive members as references to normal content blobs. Reuse a blob
  when an archive member and filesystem file have the same complete digest.
- [ ] Reconcile renamed, changed, removed, encrypted, duplicate-name, and nested
  entries with explicit per-container/per-entry commit units and retryable
  failure state.
- [ ] Prefer bounded per-entry or streaming extraction and on-demand preview;
  define temporary-file ownership/cleanup and maximum in-flight work. Do not
  require unpacking an entire archive to answer a listing query.
- [ ] Define tree/CLI display paths from the structured locator and test lookup,
  duplicate analysis, filtered exports, selected-entry preview, and extraction.

**Exit:** archive members participate in normal search/duplicate/subset APIs;
unchanged container rescans do not re-extract every entry; container changes
update only the affected logical content references; legacy `ArchiveSpec[]`
remains readable through a documented migration path.

### WP-13.6: Move HMI adapters onto the backend interface

- [ ] Replace the GUI-owned JSON/SQLite split in `DirectorySource` with the
  public backend query interface; GTK remains a projection/preview client.
- [ ] Make CLI commands build typed requests and consume typed query/result
  values; retain plain and JSON output formats and shell-friendly exit behavior.
- [ ] Add the archive virtual-directory/member workflow to both HMI clients using
  the same locator, filters, subset semantics, and operation contract.
- [ ] Run a cross-backend parity matrix for reads, filtered subsets, scan,
  metadata, analysis, archive members, cancellation, and committed-state refresh.

**Exit:** CLI and GTK are clients of the same polymorphic catalog API; neither
frontend contains storage-specific algorithms or archive identity rules.

## Dependency Order

- **Repository foundation:** WP-00 precedes WP-01/WP-02; WP-03/WP-04/WP-05
  depend on the repository API/schema work; WP-06 uses those backend packages;
  WP-07 integrates the GUI against the public API.
- **Review correctness:** WP-10.1 depends on WP-07's query adapters. WP-10.2 and
  WP-10.3 depend on WP-04's scanner. Complete the missing-file/blob correctness
  fixes before WP-09.2a changes scan transaction behavior.
- **Operation contract:** WP-09.1 depends on the existing repository and service
  operations (WP-04/WP-05/WP-06), but its design may proceed while WP-08/WP-10
  tasks are active. WP-09.1b extends that contract with pause/resume before the
  WP-09.2 controlled operation slices begin.
- **Vertical CLI slices:** implement in this order:
  `WP-09.2a -> WP-09.3a -> WP-09.2b -> WP-09.3b -> WP-09.2c -> WP-09.3c ->
  WP-09.2d -> WP-09.3d -> WP-09.2e -> WP-09.3e`.
- **GTK and parity:** WP-09.4 depends on WP-07 and the CLI reference in
  WP-09.3e. WP-09.5 requires both CLI and GTK adapters; WP-10.1's query parity
  fix must also be complete before declaring full source parity.
- **Independent closeout:** WP-08.1/WP-08.2/WP-08.3 are independent test tasks;
  complete them before WP-09 parity closeout, but they do not block WP-09.1
  contract design. WP-11 is investigation-first and does not gate WP-09 unless it
  discovers a correctness blocker.
- **Synthetic test corpus:** WP-12 builds the deterministic D-generated
  filesystem/archive fixture and expected manifest before it is used by later
  backend/HMI tests.
- **Catalog API/archive model:** WP-13 proceeds bottom-up after WP-12:
  `13.1 domain identities/locators -> 13.2 polymorphic contract -> 13.3 JSON and
  13.4 SQLite adapters -> 13.5 archive content references -> 13.6 CLI/GTK
  migration`. Do not start an alternate SQL-engine implementation before the
  adapter contract and capability requirements are frozen.

## Definition of Done for Each Package

- The package has a focused commit or small commit series.
- Public behavior and migration effects are documented.
- Unit or integration tests cover the new behavior.
- The smallest relevant verification command passes.
- No package silently removes an existing JSON capability.
- Follow-up work is recorded as a new unchecked item in this plan.
