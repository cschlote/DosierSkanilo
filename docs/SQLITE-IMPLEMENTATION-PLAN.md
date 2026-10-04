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

WP-08 closes the verification gaps left after the SQLite/JSON repository and GUI
integration work. Three backend tests remain. They test different contracts and
can be implemented independently; each should use a fixture that would fail if
the behavior under test were accidentally bypassed.

### WP-08.1: Complete CLI parser contract tests

- [ ] Exercise the SQLite command group (`init`, `scan`, `metadata`, `analyze`,
  `info`, `list`, `duplicates`, `import`, and `export`) and the explicit `json`
  group with representative valid inputs.
- [ ] Exercise invalid combinations: missing positional paths, extra positional
  arguments, options attached to the wrong command, invalid option values, and
  attempts to use SQLite-only options in JSON mode or vice versa.
- [ ] Verify help/version parse as successful actions and malformed input
  produces the documented usage status without starting an operation.
- [ ] Verify parser state isolation: parse two different argument vectors
  sequentially in one process and prove values/options from the first parse do
  not leak into the second.
- [ ] Keep parser tests at the typed parser boundary where possible; retain CLI
  process integration tests for exit codes and stdout/stderr behavior.

**Exit:** every command group and its rejected option boundaries are covered;
repeated parser calls are independent; the existing CLI integration suite still
passes.

### WP-08.2: Cover an actual version-2 JSON wrapper

- [ ] Add a small valid JSON fixture whose wrapper literally declares
  `dataVersion: 2`; do not treat a version-3 fixture with a historical `v2` file
  name as version-2 coverage.
- [ ] Include representative version-2 fields that exercise migration/fixup,
  including file references and at least one optional metadata relationship where
  the version-2 schema supports it.
- [ ] Import the fixture through the public repository transfer API and verify
  the resulting catalog's semantic content, not only that import returns
  successfully.
- [ ] Export the imported repository as current version-3 JSON and verify the
  expected migrated values and relationships are preserved.
- [ ] Rename or clarify the broad existing test name
  `repository imports supported JSON fixture versions` so it does not imply
  version-2 coverage before the new fixture is added.

**Exit:** the test proves the declared version-2 input is accepted and migrated
to the current representation; unsupported versions remain rejected.

### WP-08.3: Verify filtered-export relationship closure

- [ ] Build a repository fixture where the selected path subset contains a
  shared blob reference and at least one populated relationship such as media,
  archive, or torrent metadata; include unselected paths/blobs as controls.
- [ ] Export the subset through the public filtered-export API, re-import or
  deserialize the result, and verify every selected file reference resolves to
  its blob and selected blob metadata is complete.
- [ ] Verify references outside the selected path scope and metadata belonging
  only to excluded blobs are not accidentally included.
- [ ] Cover the edge case where multiple selected paths reference the same blob:
  preserve one content record and all selected references without dangling or
  duplicated relationship rows.

**Exit:** filtered JSON is self-contained for all selected records and excludes
unselected references; it round-trips through the public import path.

### Existing Verification Coverage

- [x] CLI integration tests verify help/version exit codes and stderr/stdout
  separation; repository discovery from root/nested/no-repository directories;
  explicit JSON scan and analysis; query pagination/filtering/output; and
  storage-mode isolation.
- [x] Schema creation and forward-version rejection; legacy-array and
  version-1/version-3 imports; JSON round trips; duplicate merge and missing-file
  analysis; directory and empty-directory queries; archive/torrent relations;
  concurrent scanner workers and readers/writers.
- [x] GUI cross-source filtering/navigation parity, concurrent tree/detail
  reads, archive/torrent continuation past 250 entries, filtered GUI export
  values, stale GTK reply rejection, and virtual-table eviction/scrolling. Test
  names and opt-in display commands are recorded in the GUI repository's
  `docs/GUI-REDESIGN.md` and `docs/TEST_FIXTURES.md`.

### Recommended Closeout Order

1. Complete WP-08.1, WP-08.2, and WP-08.3. They have no implementation
   dependency on each other and can be reviewed as three small test-only
   changes.
2. Run the backend library tests and build, then the GUI tests/build to retain
   the cross-repository integration baseline.
3. Record any newly found gaps as separate work packages rather than expanding
   the scope of these tests.

For the current DUB layout, verify with `dub test --config=library
--compiler=ldc2` and `dub build --config=library --compiler=ldc2` in the backend,
then `dub test --compiler=ldc2` and `dub build --compiler=ldc2` in the GUI.

WP-08 contains compatibility and parser tests only. Review-discovered behavior
fixes are tracked separately in WP-10 so their implementation is not hidden in
test-closeout work.

The GUI's current asynchronous-filter work and the case-sensitivity parity fix
are tracked in the GUI backlog and WP-10.1 respectively. Recommended execution
order is: verify the current GUI P0, close WP-10.1 through WP-10.3 and WP-08.1
through WP-08.3, then start backend operation implementation. WP-09.1 contract
design may proceed in parallel with those bounded fixes; WP-09.2 must wait until
the scan and query semantics it will control are stable.

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

WP-09 changes operation control and frontend wiring; it does not replace the
existing scanner, repository, or JSON data model. Keep each subpackage narrow so
the public contract can be reviewed before service and UI implementations rely
on it. The same request must reach the same backend operation regardless of
whether CLI or GTK submitted it.

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

WP-09.1 must decide and document any unresolved API choices (for example,
whether cancellation is represented as a typed terminal result or a distinct
error, how callback exceptions are handled, and which partial results are
committed). Later packages should implement that recorded contract rather than
make local, incompatible choices.

### WP-09 Stepwise Migration

#### WP-09.1: Freeze shared request and control contracts

- [ ] Inventory the current SQLite and JSON command handlers and map each
  operation, positional target, and option to a typed library request/result.
  Record unsupported combinations and preserve existing CLI validation.
- [ ] Define operation identity and lifecycle states; progress events must
  include phase, optional current/total work, and descriptive context without
  requiring a percentage when totals are unknown.
- [ ] Define cancellation request/token semantics, terminal outcome shape,
  error propagation, callback invocation/thread guarantees, and ownership/lifetime
  of request data and callbacks.
- [ ] Define the serialization scope for competing mutations: tasks within one
  frontend process versus separate CLI/GUI processes targeting the same
  repository/catalog. Record which layer enforces each scope and how conflicts
  are reported.
- [ ] Specify safe cancellation/commit boundaries separately for filesystem
  scan, metadata worker batches, JSON file writes, and analysis transaction
  phases. Define what partial results a cancelled operation may retain.
- [ ] Define how operations with no work, failed work, cancellation before
  start, and cancellation arriving after the final checkpoint are reported.
- [ ] Add API-level tests for request validation, lifecycle/event invariants, and
  cancellation state semantics that do not need GTK or CLI process setup.
- [ ] Document the contract and examples in the public library API; update the
  CLI/GUI plans only after the request and event shapes are stable.

**Deliverable:** a public, frontend-neutral operation API with documented
requests, results, progress/cancel control, threading/ownership, storage-mode
mapping, and safe-boundary policy.

**Exit:** both clients can construct the same request types; deterministic tests
cover lifecycle and cancellation semantics; no API type depends on GTK,
`ArgsArray`, terminal output, or SQLite implementation types.

#### WP-09.2: Add operation control to backend services

This is an umbrella package, not one implementation change. Complete and verify
each vertical slice independently. A slice must use WP-09.1 types, retain the
existing synchronous entry point where required, and have deterministic tests
for progress, cancellation boundaries, and resulting storage state.

##### WP-09.2a: SQLite filesystem scan

- [ ] Route repository scan through the shared operation request/control types;
  report discovery and persistence phases and observe cancellation only at the
  WP-09.1-approved transaction boundary.
- [ ] Define whether scan cancellation rolls back the whole scan transaction or
  commits a documented checkpoint; do not add checkpoints that expose a
  half-updated missing-file/drop-missing state.
- [ ] Test cancellation before iteration, during traversal, before missing-file
  reconciliation, and after the final safe checkpoint. Verify summaries and
  repository state for every case.
- [ ] Preserve `Repository.scan()` as a synchronous convenience wrapper over the
  controlled operation unless WP-09.1 documents a compatibility reason not to.

**Exit:** scan emits ordered phase events, observes cancellation at safe points,
and tests prove the repository is valid with exactly the documented commit or
rollback outcome.

##### WP-09.2b: SQLite metadata extraction

- [ ] Add phase and per-blob progress for checksums, file type, MediaInfo,
  archives, and torrents; report unknown totals as status-only progress until
  work discovery establishes a total.
- [ ] Stop scheduling new blobs after cancellation; define whether active
  extractors are interruptible, drain all workers before closing resources, and
  persist only results permitted by the WP-09.1 partial-result policy.
- [ ] Exercise cancellation before a batch, while workers are active, between
  persisted results, and after the final batch. Cover worker failure and no-work
  cases as well as successful extraction.
- [ ] Preserve `Repository.updateMetadata()` as a synchronous convenience
  wrapper where possible; prove its summary and state semantics remain compatible.

**Exit:** no worker or callback outlives the operation; completed/failed metadata
states and summaries match the documented partial-result policy; cancellation
tests leave a usable repository.

##### WP-09.2c: SQLite analysis

- [ ] Add progress for the analysis phases (missing-file handling, duplicate
  grouping/merge, and orphan cleanup) and permit cancellation only between
  atomic transaction phases.
- [ ] Return which phases completed if earlier phase commits survive a later
  cancellation; otherwise roll back according to the frozen contract.
- [ ] Test cancellation between each phase, duplicate-heavy input, missing-file
  cleanup, and a no-op analysis; verify relationships and foreign-key integrity.
- [ ] Preserve `Repository.analyze()` as a synchronous convenience wrapper where
  possible.

**Exit:** each phase has a defined atomic boundary and repeatable tests for
successful, failed, and cancelled outcomes.

##### WP-09.2d: Direct JSON scan and analysis services

- [ ] Adapt the existing JSON `scan` and `analyze` operations to the same
  frontend-neutral control contract; do not add a new JSON command solely for
  symmetry with SQLite metadata operations.
- [ ] Remove service-layer dependence on CLI `ArgsArray`, process-global
  cancellation state, and console-formatted progress while preserving current
  JSON migration, backup, and write policy.
- [ ] Test cancellation before work, at each safe checkpoint, and during file
  replacement; prove the catalog is either valid old state, valid committed new
  state, or the documented valid checkpoint state.
- [ ] Keep CLI compatibility wrappers until WP-09.3 has switched to the shared
  operation API.

**Exit:** existing JSON commands use the same control types, maintain their
explicit catalog/filesystem targets, and leave a valid catalog after success,
failure, or cancellation.

##### WP-09.2e: Cross-operation lifecycle and serialization

- [ ] Test worker joining, connection/handle lifetime, and callback completion
  for all operation families; no callback may access a destroyed request,
  result sink, database, or JSON output.
- [ ] Enforce one mutating operation at a time per repository/catalog according
  to the WP-09.1 ownership decision; test two attempted writes and error/report
  behavior for the rejected or queued operation.
- [ ] Verify independent read connections remain usable and define what readers
  may observe while a write is active.

**Umbrella exit:** all supported SQLite and JSON operation families have
controlled and legacy synchronous entry points, deterministic progress/cancel
tests, documented partial-state semantics, and valid storage after termination.

#### WP-09.3: Make the CLI a console adapter

Implement and verify the CLI adapter incrementally with each backend vertical
slice; do not wait until all operation backends are changed before exercising
the shared contract from a real client. The following adapter slices are ordered.

##### WP-09.3a: SQLite scan CLI adapter

- [ ] Implement after WP-09.2a; build the same scan request the GTK client will
  later use and render phase events in the existing CLI output style.
- [ ] Verify Ctrl-C requests cancellation, waits for safe worker shutdown, and
  reports the terminal outcome without labeling an incomplete scan successful.
- [ ] Add process-level coverage for successful scan, progress, cancellation,
  exit status, and valid repository state.

##### WP-09.3b: SQLite metadata CLI adapter

- [ ] Implement after WP-09.2b; map every existing `metadata` option to the
  shared request without changing defaults or validation.
- [ ] Verify worker progress, Ctrl-C/drain behavior, final `MetadataSummary`,
  stderr/stdout ownership, and repository validity after cancellation.

##### WP-09.3c: SQLite analysis CLI adapter

- [ ] Implement after WP-09.2c; map analyze/missing-file/duplicate behavior to
  the shared request while preserving existing options and result output.
- [ ] Verify phase progress and cancellation outcomes against the transaction
  boundary/partial-state contract.

##### WP-09.3d: JSON CLI adapters

- [ ] Implement after WP-09.2d; route the existing JSON `scan` and `analyze`
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

- [ ] Replace direct service/repository orchestration in SQLite and JSON command
  handlers with request construction and calls to the shared operation API.
- [ ] Adapt Ctrl-C to one cancellation request, wait for worker shutdown, and
  return the documented cancellation exit/result without reporting incomplete
  work as success.
- [ ] Render phase/progress events in the terminal while keeping diagnostics on
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

Start operation integration after the supported CLI operation families have
become working references. The GUI may prepare presentation widgets earlier, but
must not define separate progress, cancellation, exit-state, or partial-result
semantics.

- [ ] Add explicit Tools menu entries and operation-specific option dialogs for
  supported scan, metadata, and analysis requests; map each control to the same
  typed request field used by the CLI.
- [ ] Require an explicit target consistent with the active document: repository
  root for SQLite operations, or catalog plus filesystem root for supported JSON
  operations. Explain invalid mode/operation combinations before starting work.
- [ ] Run backend operations on worker threads; marshal all GTK state changes
  and progress rendering onto the GTK main loop. Ensure closing a tab/window
  cannot leave callbacks targeting destroyed widgets.
- [ ] Present queued/running/cancelling/completed/cancelled/failed state, current
  phase, available progress, and final typed summary in the owning tab/status
  area. Handle unknown totals without displaying misleading percentages.
- [ ] Connect Cancel to backend cancellation, keep the UI responsive while
  workers drain, and distinguish backend cancellation from merely discarding a
  stale UI reply.
- [ ] Serialize conflicting writes to one repository/catalog. Define whether
  reads may continue during a write; preserve independent repository read
  connections and prevent refresh/read races from showing stale state as current.
- [ ] On success, refresh the affected source and preserve a valid selection,
  filter, sort, and expanded-directory state where the refreshed data allows it.
  On cancellation/failure, display the result and refresh if committed state
  changed.
- [ ] Add GTK-independent task-manager tests for event ordering, cancellation,
  serialization, stale-tab handling, and refresh decisions; add opt-in display
  tests for Tools wiring and main-loop updates.

**Exit:** GTK actions construct the same requests as CLI; GTK remains responsive;
all widget updates run on the main loop; Cancel reaches backend work; conflicting
writes cannot overlap; successful or partially committed operations refresh the
correct source and show their terminal result.

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

### WP-09 Exit Criteria

- CLI and GUI invoke the same public operation logic for the same storage mode.
- GUI work runs off the GTK thread and all UI progress updates run on the main
  loop.
- Cancellation is observed by backend work rather than merely discarding its
  eventual result.
- Progress, final summaries, failures, and cancellation are consistent across
  clients; storage modes remain explicit.

## WP-10: Review-Driven Query and Scanner Correctness

Status: `[ ]`

This package records concrete consistency/correctness concerns found in the
2026-10-04 reviews. For each suspected defect, add a regression test that
demonstrates the required behavior before changing the implementation. Do not
assume a suspected SQLite cursor issue is a reproduced failure; the test should
establish whether rows can be skipped under the supported driver/runtime.

### WP-10.1: Preserve case-sensitive matching in catalog queries

- [ ] Add an explicit `caseSensitive` option to `RepositoryQueryOptions` and
  propagate it from the GUI `SourceQuery` through offset and cursor catalog
  queries.
- [ ] Update catalog SQL to apply the requested case rule to file-path matching;
  preserve checksum/SHA1 matching semantics independently of path case.
- [ ] Test upper/lower-case path queries through `RepositoryQueryOptions`, both
  offset and cursor pagination, and the GUI Blob table. Compare JSON and SQLite
  results with the tree/file path for case-sensitive and insensitive settings.
- [ ] Update public query docs and README parity claims to match the tested
  contract.

**Exit:** the same case preference yields the same matching path sequence in
JSON and SQLite tree and Blob-table views; SHA1 lookups still work regardless of
hex letter case; cursor continuation does not change the result set.

### WP-10.2: Make missing-file reconciliation safe while updating rows

- [ ] Add a repository scan regression fixture with multiple existing,
  non-hidden file references that become missing in the same scan, plus present
  and hidden-path controls.
- [ ] Confirm the scan marks every eligible missing row exactly once and does
  not skip rows while changing `exists_on_disk` during iteration.
- [ ] If the test demonstrates unsafe live-cursor mutation, materialize the
  required IDs/paths or use a two-phase update so the result set is stable before
  writes occur.
- [ ] Verify `dropMissing` still removes the intended references and orphan
  blobs transactionally, while hidden-file policy remains unchanged.

**Exit:** the regression test passes on supported SQLite/D2-SQLite builds and
proves all eligible missing references are reconciled without omissions or
duplicate summary counts.

### WP-10.3: Define changed-file blob cleanup and scan summary semantics

- [ ] Extend the incremental-scan test to change a file's contents/size or mtime
  more than once and inspect blob/reference counts after each scan.
- [ ] When a file changes, remove the old blob only if no remaining file
  reference points to it; cover the shared-blob case and verify foreign-key
  dependent metadata is handled correctly.
- [ ] Define and document `ScanSummary.filesMissing` (references newly detected
  as missing during this run) and `filesDropped` (references actually removed
  by this run), or choose clearer field semantics/names if existing behavior is
  inconsistent.
- [ ] Test `dropMissing` after missing references were detected by an earlier
  scan, including multiple missing references, to pin down the summary contract.
- [ ] Verify repeated scans of changed files do not accumulate unreferenced
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

- [ ] Document the current boundary: directory/file browsing uses typed
  repository projections, while the transitional Blob table and JSON loader use
  `NamedBinaryBlob`.
- [ ] Decide whether the Blob table should migrate to source-neutral summary and
  detail DTOs, or remain explicitly coupled to the canonical JSON model until
  that view is removed.
- [ ] If decoupling is selected, define stable IDs, summary flags, lazy detail
  retrieval, JSON/SQLite parity, and migration compatibility before changing the
  public API.
- [ ] Keep the JSON serializer's canonical model separate from GTK widgets and
  do not expose SQLite implementation types to the GUI.

**Exit:** an explicit architecture decision with consequences and follow-up
work; implementation is a separate package if it would be larger than a focused
API change.

### WP-11.4: Reconcile architecture and baseline documentation

- [ ] Update the backend module dependency diagram to include the public
  repository facade and its internal schema/transfer/scanner/metadata/analysis
  modules.
- [ ] Clarify why WP-00 remains in progress, list its still-open baseline
  deliverables, and state whether each is a gate for future work packages.
- [ ] Keep README, architecture, benchmark scope, WP-08/WP-09 status, and the
  GUI's cross-repository links consistent with the implemented paths.

**Exit:** a new contributor can trace the actual API/module boundary and tell
which unfinished baseline work is intentional versus forgotten.

## Dependency Order

- **Repository foundation:** WP-00 precedes WP-01/WP-02; WP-03/WP-04/WP-05
  depend on the repository API/schema work; WP-06 uses those backend packages;
  WP-07 integrates the GUI against the public API.
- **Review correctness:** WP-10.1 depends on WP-07's query adapters. WP-10.2 and
  WP-10.3 depend on WP-04's scanner. Complete the missing-file/blob correctness
  fixes before WP-09.2a changes scan transaction behavior.
- **Operation contract:** WP-09.1 depends on the existing repository and service
  operations (WP-04/WP-05/WP-06), but its design may proceed while WP-08/WP-10
  tasks are active. WP-09.2 operation slices depend on WP-09.1.
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

## Definition of Done for Each Package

- The package has a focused commit or small commit series.
- Public behavior and migration effects are documented.
- Unit or integration tests cover the new behavior.
- The smallest relevant verification command passes.
- No package silently removes an existing JSON capability.
- Follow-up work is recorded as a new unchecked item in this plan.
