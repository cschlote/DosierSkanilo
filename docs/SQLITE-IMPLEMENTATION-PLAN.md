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

## Status Legend

- `[ ]` not started
- `[-]` in progress
- `[x]` completed

The checklist is intentionally kept in this document so progress can be
committed in small, reviewable steps.

## WP-00: Baseline and Contracts

Status: `[ ]`

### WP-00 Objective

Measure the current behavior and freeze the compatibility requirements before
changing the storage path.

### WP-00 Steps

- [ ] Create representative JSON datasets with 1,000, 10,000 and 100,000
  records.
- [ ] Measure load time, peak memory and GC-related runtime.
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
- [ ] Define read operations for paginated blob summaries.
- [ ] Define detail operations for one blob and its related records.
- [ ] Define scan write operations and transaction boundaries.
- [ ] Define JSON import and export options.
- [ ] Define typed filters for paths, sizes, checksums, file type, media,
  archives and torrents.
- [ ] Define read-only result DTOs for GUI use.
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

Status: `[-]`

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

Status: `[-]`

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

- All existing JSON fixtures import successfully.
- [x] Import followed by export preserves the supported v3 content.
- [x] A filtered export never references a missing blob or related record.
- [x] Failed imports leave the database unchanged.

## WP-04: Scanner Persistence

Status: `[-]`

### WP-04 Objective

Run scans against SQLite without keeping the complete catalog in memory.

### WP-04 Steps

- [x] Replace absolute or invocation-dependent paths with canonical
  root-relative paths in the repository layer.
- [x] Persist discovered directories, including empty directories if enabled.
- [x] Look up existing `file_refs` by path.
- [x] Skip unchanged files based on size and modification time.
- [x] Mark missing paths and optionally remove them with `dropMissing`.
- [ ] Queue only new or changed files for metadata extraction.
- [ ] Represent extractor state explicitly: not requested, pending, completed,
  empty or failed.
- [ ] Refactor worker jobs to return result DTOs instead of mutating a shared
  global catalog.
- [ ] Add a single-writer persistence queue or equivalent transaction policy.
- [ ] Keep scanner computation parallel while serializing SQLite writes safely.

### WP-04 Exit Criteria

- A scan can be interrupted without corrupting the database.
- A second unchanged scan performs no unnecessary digest work.
- Parallel workers never share an unsafe SQLite connection.
- Existing scanner options have equivalent SQLite behavior.

## WP-05: SQL-Based Analysis

Status: `[ ]`

### WP-05 Objective

Move duplicate and missing-file analysis from D arrays into repository queries.

### WP-05 Steps

- [ ] Query complete checksum candidates by file size.
- [ ] Group candidates by SHA1 in SQL or a bounded result stream.
- [ ] Merge duplicate blobs by moving `file_refs` to one blob.
- [ ] Detect missing paths and support keep-versus-drop behavior.
- [ ] Remove unreferenced blobs and dependent metadata safely.
- [ ] Add indexes for path, size, SHA1, file type and metadata presence.
- [ ] Expose analysis results through typed repository DTOs.

### WP-05 Exit Criteria

- Duplicate results match the current `analyse.d` behavior.
- Missing-file behavior matches `--dropMissing`.
- Analysis does not require loading all blobs into a D array.
- Merge and cleanup are atomic transactions.

## WP-06: CLI Integration

Status: `[ ]`

### WP-06 Objective

Add repository operation to the CLI while retaining the existing JSON mode.

### Proposed Operations

```text
dosierskanilo init
dosierskanilo scan
dosierskanilo analyse
dosierskanilo import
dosierskanilo export
```

### WP-06 Steps

- [ ] Add repository root discovery to command-line startup.
- [ ] Add explicit repository and JSON input/output options.
- [ ] Preserve existing JSON invocation behavior during migration.
- [ ] Route scan and analysis operations through the repository API.
- [ ] Add progress reporting for database-backed jobs.
- [ ] Write operational logs to `.dosierskanilo/logs/`.
- [ ] Add clear errors for missing repositories and schema incompatibility.

### WP-06 Exit Criteria

- Existing JSON command lines still work.
- New repository commands work from the root and a subdirectory.
- CLI output distinguishes JSON mode from SQLite repository mode.
- No CLI module imports the SQLite implementation directly.

## WP-07: GUI Data-Source Integration

Status: `[ ]`

Repository: `DosierSkanilo-Gui`.

### WP-07 Objective

Allow the GUI to browse JSON files and SQLite repositories through one data
source abstraction.

### WP-07 Steps

- [ ] Introduce a `DocumentSource` abstraction for JSON and SQLite sources.
- [ ] Keep the current JSON loader as the first adapter implementation.
- [ ] Add SQLite source opening and repository-root discovery.
- [ ] Replace complete `loadedRows` loading with paginated summaries.
- [ ] Move text, media, archive and torrent filters to repository queries.
- [ ] Refactor `BlobRow` so it does not require a complete `NamedBinaryBlob`.
- [ ] Load details and file references only for the selected row.
- [ ] Keep preview paths and media details available through the detail API.
- [ ] Preserve the GUI's own preference JSON separately from repository data.
- [ ] Give each background operation its own repository read connection.

### WP-07 Exit Criteria

- GUI can open both a JSON file and `.dosierskanilo`.
- Opening a large repository does not load all metadata into memory.
- Filtering does not scan all GUI rows locally.
- Existing detail widgets and previews work with SQLite data.
- JSON remains usable when no repository is present.

## WP-08: Verification and Rollout

Status: `[ ]`

### Tests

- [ ] Schema creation and migration tests.
- [ ] JSON v0/v1/v2/v3 import tests.
- [ ] JSON round-trip tests.
- [ ] Filtered export tests.
- [ ] Duplicate merge and missing-file tests.
- [ ] Directory-tree and empty-directory tests.
- [ ] Archive and torrent relationship tests.
- [ ] Concurrent scanner-worker tests.
- [ ] GUI data-source and pagination tests.
- [ ] Performance tests against the WP-00 datasets.

### Rollout Sequence

1. Keep JSON as the default for existing invocations.
2. Release repository initialization and JSON import.
3. Enable SQLite-backed scanning behind an explicit option.
4. Enable SQLite browsing in the GUI while retaining JSON support.
5. Compare JSON and SQLite results on the same input trees.
6. Make SQLite the default for newly initialized repositories.
7. Retain explicit JSON import and export indefinitely.

### Final Exit Criteria

- CLI and GUI use the same public repository API.
- JSON compatibility tests pass.
- SQLite schema migrations are documented and tested.
- Large-repository benchmarks show bounded GUI memory use.
- Existing JSON workflows remain available.

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
  +--> WP-07

WP-03 + WP-04 + WP-05 + WP-06 + WP-07
  +--> WP-08
```

WP-01 and WP-02 can proceed in parallel after WP-00. WP-03 through WP-05
depend on the schema. WP-07 can begin API integration before the scanner is
fully migrated, provided the JSON adapter remains available.

## Definition of Done for Each Package

- The package has a focused commit or small commit series.
- Public behavior and migration effects are documented.
- Unit or integration tests cover the new behavior.
- The smallest relevant verification command passes.
- No package silently removes an existing JSON capability.
- Follow-up work is recorded as a new unchecked item in this plan.
