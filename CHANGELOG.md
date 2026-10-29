# Changelog

All notable changes to this project are documented in this file.

Note:
Older entries below `26.0.0` were backfilled from source history, tests,
and available data fixtures (`test/json_file_v0.json`, `v1`, `v2`).
They represent the functional evolution and are intentionally summarized.

## Unreleased

- Catalog queries reject a zero page size with a typed repository error
  instead of crashing on cursor arithmetic, repository page wrappers raise
  typed errors consistently, and JSON catalog directory listings now report
  file counts and aggregate sizes that match the active filter like the
  SQLite backend. The legacy scanner re-escapes canonical `!!` filenames
  when writing back scanned file references, so `!`-named files keep a
  single catalog record across rescans.

- The archive-member content cache no longer loses lease accounting when a
  cached member file disappears externally while it is still leased: leases
  track their entry directly and `close()` refuses while any lease is
  outstanding, so leased paths can no longer be deleted under an extractor
  or preview. Cache sessions are protected by their flock before they become
  visible to stale-session cleanup, and the process-wide cache swap is
  documented as usable only before worker start.

- JSON scans and analysis runs no longer abort on the first unreadable file
  or corrupt archive: metadata extraction now isolates failures per blob and
  per extractor job, counts them in the operation summary, and continues
  with the remaining files. Extracted media signatures no longer store
  unparsable stream references, which could crash later duplicate-merge
  equality checks; existing catalogs containing such entries are tolerated.

- JSON scans and metadata runs no longer fail with `Cannot open file ... in
  mode 'rb'` for archive members that lack digests: the checksum, file-type,
  and media-info jobs now skip purely virtual members (their container archive
  is checked for existence instead, and member digests are filled in by the
  archive scan).
- CI documentation generation now runs `adrdox` with a single job and retries
  it, falling back to another available D compiler when needed, avoiding flaky
  pipeline failures. The source no longer uses named arguments that `adrdox`
  cannot parse.
- CLI `list` now returns archive-member references with canonical virtual
  paths and original display names, including duplicate-name occurrences.
  Canonical virtual paths can be filtered directly. `duplicates` groups all
  matching references by content, including indexed archive members. `export`
  accepts `--path` to write a selected path or virtual archive member with its
  relationship-closed container data and fails without writing a file when the
  selected path has no references. `info` reports reference counts including
  archive members. Archive scans and metadata extraction accept
  `--archive-cache-dir` and `--archive-cache-size` to configure the owned
  temporary member cache; sessions are removed on exit.
- CLI JSON scans and analyses now load the catalog once, skip the query-index
  rebuild that blocked startup on large catalogs, and still archive the previous
  catalog before writing the replacement.
- Interrupting a JSON scan with Ctrl-C now saves the records collected so far
  unless `--dry-run` is active. The CLI waits for the save to finish and a
  second Ctrl-C terminates immediately.
- Saved JSON catalogs are now compact by default. CLI `--pretty` writes
  indented JSON for scans, analyses, exports, and other catalog writes.
- Normal CLI commands now announce the application name and version on stderr
  at startup, keeping stdout clean for command output and JSON formats.
- JSON directory rescans index existing blob paths instead of searching every
  blob for each file, removing a quadratic lookup on large catalogs.
- Verbose JSON scans now print throttled progress lines with phase, item count,
  and current path instead of only reporting phase changes.

## Release 26.12.2 - 2026-10-25

- The Flatpak build now targets the supported Freedesktop 25.08 runtime,
  bundles MediaInfo with ZenLib, and uses the current LDC/LLVM SDK extensions.

## Release 26.12.1 - 2026-10-25

- Archive extraction now terminates option parsing before member names, blocking
  command injection through crafted tar, ZIP, RAR, or 7z entries.
- JSON rescans invalidate checksums, file type, media, archive, and torrent
  metadata when a file's size or modification time changes.
- POSIX filenames containing backslashes are preserved; native separators are
  normalized only on Windows.
- SQLite archive ranges include non-BMP names, and analysis changes invalidate
  repository cursors by updating `repository.updated_at`.
- Malformed torrents with missing keys or excessive nesting fail cleanly instead
  of aborting the process.
- Duplicate JSON merges preserve file type, media, torrent, archive password,
  and archive member metadata from every merged object, reject conflicting
  values, and archive members of containers with `!` in their names track
  availability correctly.
- Release archives without `.git` build using the tracked `VERSION` fallback;
  packaging metadata and the Flatpak build were refreshed for `26.12.1`.
- `--scan-archives` can be repeated to enable deep archive scanning.
- SQLite validates unknown archive/torrent content IDs and rejects cursors
  beyond the end of archive/torrent entry lists, matching JSON behavior;
  directory counts honor filters; member-cache keys include the member path;
  password prompts are bounded; missing JSON catalogs are rejected for
  `list`/`duplicates`; log JSON escapes tabs.
- CI staging deployment is manual, helper scripts resolve the repository root,
  and HADOLINT download avoids shell interpolation.
- The packaging documentation now describes a containerized Debian build that
  keeps host dependencies out of the release process. Packaging builds use
  explicit LDC flags so distributions with mismatched DUB/LDC release flag
  conventions can still build the release binary.

## Release 26.12.0 - 2026-10-24

- Filtered JSON directory listings binary-search the sorted file rows for each
  directory instead of scanning every file per directory. A 200,000-file,
  2,000-directory filter dropped from about `7.4 s` to about `0.06 s`, including
  non-BMP UTF-8 paths.
- Checksum calculation reuses a 64 KiB buffer instead of allocating a 16 MiB
  chunk buffer per file. A 10,000-small-file `metadata --checksums` run dropped
  from about `29 s` to about `0.6 s`; metadata persistence also commits once per
  worker batch instead of once per blob.
- Repository rescans no longer remove each present file from an unindexed
  temporary candidate table. A 10,000-file unchanged rescan dropped from about
  `1.9 s` to about `0.2 s`; staging and unchanged-file updates reuse prepared
  statements, and ordinary files no longer query virtual archive references.
- Opening an initialized SQLite repository no longer writes
  `PRAGMA user_version` when the schema version is already current.
- JSON archive-member pages now use a per-directory member order that is built
  once and merged with physical rows. This removes quadratic same-path counting
  and avoids regenerating and sorting every member for each page. The first page
  now reserves the known member count, cutting a 100,000-member first page from
  about `0.54 s` to about `86 ms`; it still builds the full member order.
- Ctrl-C now cancels catalog imports and exports at the next safe checkpoint.
  Cancelled imports roll back to the previous catalog, and cancelled exports
  leave the destination untouched. Controlled import/export methods and
  `OperationKind.catalogImport`/`catalogExport` progress values were added to
  the public API.
- SQLite duplicate analysis now polls for cancellation while merging inside the
  transaction and rolls the whole merge back, so Ctrl-C no longer waits for a
  large merge to finish and commit.
- JSON catalogs are backed up with a hard link (or a copy where links are
  unavailable) and replaced by an atomic rename, so a killed or crashed writer
  leaves the previous catalog intact at its canonical path.
- JSON file pages refresh reference availability when served instead of using
  the index-build snapshot, and physical file pages no longer materialize and
  sort the whole matching set.

## Release 26.11.4 - 2026-10-22

- JSON catalog writes now serialize into a staging file and rename it into
  place, and the copy-based backup fallback restores the original instead of
  deleting the last remaining catalog.
- Malformed JSON catalogs now raise a dedicated `CatalogFormatException`;
  `--force` only starts from an empty catalog for format errors and never
  swallows I/O failures.
- Duplicate analysis now merges metadata, media streams, torrent data, and
  archive passwords from the dropped blob before deleting it.
- JSON rescans now update the escaped virtual member path instead of creating a
  second record, malformed archive digests no longer abort metadata scans, and
  FNV-1a hashing uses the standard offset basis.
- JSON metadata scans now release their cancellation mirror before returning.
- JSON catalog paging now supports backward continuation with the same
  before-the-cursor semantics as SQLite, and the adapter tests cover it.
- Repository metadata persistence is transactional per blob on every path, and
  worker pools are always stopped. Metadata runs also bump `updated_at`, so
  stale paging cursors are rejected.
- Malformed `.torrent` length fields, missing SHA1 digests, and failing external
  archive tools now fail cleanly instead of aborting a scan.
- Legacy scans compare decoded physical paths, so escaped `!` names and v5
  archive members are no longer treated as missing or mismatched.
- The JSON backend disables tree queries instead of leaking untyped exceptions
  when a virtual path cannot be parsed.
- Repository import and export now take the write lease; backups use
  `VACUUM INTO` for a consistent snapshot. File listings can use the directory
  index again.
- Repository duplicate listings fetch only the reported blob ids, archive
  member pages use bounded keyset reads and fingerprint-only lookups, and the
  SQLite backend reuses one read connection for its lifetime.
- Duplicate merging now always keeps the lowest blob id, so repeated analyses
  pick the same survivor.
- Analyzed duplicates now merge in one transaction and cancellation reports no
  applied changes. Archive scans keep the empty-archive state instead of
  overwriting it with `completed`.
- JSON catalog backups are written next to the catalog, so identically named
  catalogs in different directories no longer share backup names.
- CLI JSON output escapes control characters, and the progress path reads the
  signal flag atomically.
- Digest readers close their file handles deterministically, and torrent
  metadata rejects files larger than 64 MiB.
- Catalog pages load blob flags with one query instead of one query per blob
  and flag. Repository file queries honor `offset`, and limit arithmetic no
  longer overflows at `long.max`.
- Archive password updates are written in one transaction, and a failing
  repository constructor no longer hides the original error while closing.
- The lint script covers the benchmark page and review reports, and CI now
  uses the same Alpine base image everywhere and rejects `vv` version tags.
- Repository scans update or delete virtual members through the escaped
  container-path range instead of walking every virtual reference, and
  directory sizes use an index-friendly range predicate instead of `LIKE`.
- Torrent info hashes now use the original bencoded `info` bytes, so
  non-canonical torrents keep their real info hash.
- Archive password lookup resolves escaped `!` in stored paths and uses SQL
  matching instead of walking every file reference.
- The schema migration also sets SQLite's `PRAGMA user_version`, and catalog
  backends raise typed `CatalogBackendException`s for invalid arguments and
  export failures.
- Member cache failures use typed exceptions derived from
  `MemberContentCacheException`, and lease release is thread-safe.
- JSON archive and torrent entry queries return an empty page for known
  content without an index, like SQLite; unknown ids still fail.
- JSON file pages refresh reference availability when queried instead of using
  the index-build snapshot, and physical file pages no longer materialize and
  sort the whole matching set.
- Content detail snapshots now report the same archive summary and extractor
  statuses on both backends, and JSON refreshes archive counts from the index
  at query time instead of the build-time snapshot.
- Operation leases use portable POSIX open/flock constants and `errno`, and
  keep their lock files in a private per-user directory under
  `XDG_RUNTIME_DIR` or the temporary directory.
- Member cache sessions document that the cache must outlive its leases; the
  cache still has no GC destructor because finalization order is unspecified.
- Removed the unused `useJSONStorage` DUB version flag. `SqliteEnableUnlockNotify`
  stays because d2sqlite3 consumes it.
- Staging deployment is manual instead of running on every `main`/`testing`
  push while `scripts/deploy.sh` is still a no-op.
- Catalog pages load blob details with a fixed set of set-based queries, and
  archive member listings restrict the query to the container path range.
  A 1,000-row page now issues 14 statements instead of about 4,002.

## Release 26.11.3 - 2026-10-21

- JSON catalog list and duplicate queries now work through the CLI backend facade,
  and JSON imports continue to target the SQLite repository.

## Release 26.11.2 - 2026-10-18

- The CLI scan and analyze commands now target the JSON backend directly with
  `--json CATALOG.json` and optional `--base-dir DIR`.
- The CLI JSON target now also accepts read-only `list` and `duplicates`
  commands, so backend-neutral catalog inspection uses the same path.
- The CLI repository commands now route info, list, duplicates, import, export,
  and metadata through the polymorphic backend facade instead of calling the
  concrete SQLite repository API directly.

## Release 26.11.1 - 2026-10-15

- Repeated SQLite metadata runs now load stored digests before deciding whether
  to recompute them, and skip file-type and archive work already recorded as
  complete or empty.
- Recursive JSON scans now consistently skip hidden directory contents with
  relative or trailing-separator roots. JSON metadata work reports its active
  file and checksum/archive subtask progress instead of appearing stalled.
- JSON scans can now optionally merge duplicate records after metadata work;
  `--dry-run` previews JSON scans and analyses without replacing their catalog.
- CLI metadata help and validation now use the accepted kebab-case options.
  Help option descriptions now carry fixed-position scope keys for scan,
  analysis, metadata, queries, repository transfers, and global options.
  Repository progress reports the active phase, blob count, current filename,
  checksum bytes, and archive entries on a terminal-width-aware line;
  `--verbose` keeps per-file detail.
- JSON catalogs now write version 5: safe archive members are ordinary virtual
  file references with escaped paths and duplicate occurrences, while archive
  index state is retained separately. Version 0–4 catalogs remain readable;
  JSON/SQLite exports and JSON catalog queries now project virtual members
  through the common reference model.
- SQLite schema v4 migrates safe archive members into ordinary `file_refs`,
  keeps their physical `directory_id`, moves archive index/depth state into
  `metadata_status`, and removes `archive_entries`/`archive_indexes`.
- Deep archive scraping now uses a bounded, session-scoped extraction cache with
  coalesced requests and explicit leases; cache paths remain transient.
- ZIP and TAR extraction can select exact duplicate-name occurrences when the
  required tool support is available; unsupported adapters avoid deep-hashing
  ambiguous duplicate members.

## Release 26.11.0 - 2026-10-13

- Added the storage-neutral `CatalogBackend` contract, explicit factory boundary,
  opaque domain IDs/locators, common bounded query/detail/export DTOs, and typed
  capability errors. Added JSON v0-v4 and SQLite `CatalogBackend` adapters, with
  explicit storage-mode factory routing and filtered subset export.
- Archive indexes now use normalized member paths plus duplicate occurrence for
  stable entry IDs across rescans. Schema version 3 migrates existing archive
  metadata, and deep-fingerprinted members link to reusable content blobs; a
  shallow index is upgraded when a later scan requests deep checksums.
- JSON and SQLite archive-entry pages expose normalized paths, occurrence/index
  values and linked member content IDs when complete checksums are available.
- Added bounded archive-member reference pages with stable member-reference IDs
  and structured container/entry locators.
- Added JSON v4's recursive `nestedEntries` shape and a roundtrip reader/writer;
  v3 writes now reject nested data instead of silently dropping it. Deep scans
  recursively extract and index nested archives, exposing structured nested
  member locators through the JSON and SQLite adapters. SQLite imports now
  persist nested version-4 archive indexes recursively.
- Deep-indexed archive members can now be included in JSON/SQLite file queries,
  directory visibility, root summaries and relationship-closed JSON subset
  exports (v3 for flat data, v4 when nested metadata is selected); their locators
  remain container/entry values rather than display paths. Virtual member paths
  use `!/` as the archive boundary and `!!` for a literal exclamation mark.
- Added optional per-Blob archive passwords to JSON catalogs and SQLite
  repositories, with a schema-version-2 migration and filename-based repository
  updates.
- Archive inspection now passes supplied passwords to ZIP, RAR, and 7z tools,
  reports password-required/rejected errors, and supports frontend password
  callbacks during entry listing and deep extraction.
- Repository metadata scans now load and persist archive passwords, including
  passwords entered through the metadata scan callback.
- Repository metadata scans can now be scoped to one repository-relative file,
  enabling consumers to scan a selected archive without rescanning the catalog.
- Added frontend-neutral scan, metadata, and analysis request, progress,
  cancellation-control, validation, and result types as the WP-09 API contract.
- Extended the shared operation control contract with safe-checkpoint
  pause/resume requests, pause availability, acknowledgement states, and
  cancellation precedence while paused.
- Added controlled SQLite scan, metadata, and analysis executors with staged
  scan/analysis plans, per-blob metadata commits, progress events, and
  cooperative cancellation/pause checkpoints. Synchronous repository methods
  remain as convenience wrappers.
- SQLite scan requests can include selected metadata extraction, and the CLI
  passes scan plus metadata options through that single shared request.
- Routed repository and explicit JSON scan/analyze CLI commands through the
  shared operation requests; JSON cancellation leaves the original catalog
  untouched before its backup/replacement phase.
- Added cross-process advisory target leases for shared mutating operations and
  typed `targetBusy` results when another writer owns the same repository or
  catalog.
- Operation results report whether any source changes committed, allowing GTK to
  refresh after partial metadata cancellation without refreshing rolled-back work.
- JSON analysis now retains records with unavailable source paths unless
  `drop-missing` was explicitly requested, preventing accidental empty-catalog
  replacement when source files or mounts are temporarily unavailable.
- Forced archive re-indexing now replaces the stored entry list instead of
  appending duplicate `ArchiveSpec` rows.
- The `init` command now reports the initialized repository path by default;
  existing repositories are reported as opened instead of newly initialized;
  verbose mode remains available for additional output.
- `import` and `export` now report missing required JSON filenames instead of
  silently completing without an operation.
- Added bounded repository APIs for listing immediate directories and file
  references, including stable IDs, relative paths, aggregate directory sizes,
  timestamps, and presence flags.
- Added bounded repository APIs for listing archive entries and torrent files by
  blob ID for lazy nested detail views.
- Added a keyset-cursor file query API with `hasMore` and stable continuation
  cursors for bounded repository result chunks.
- Repository file DTOs now expose metadata-presence flags needed for shared
  media, type, archive, and torrent filtering in consumer UIs.
- Repository file queries now accept typed media, file-type, archive, and
  torrent presence filters.
- Repository media filters now use OR semantics within the selected media
  types, support negation, and combine with the other presence filters like the
  GUI's shared filter state.
- Filtered directory queries now omit directories whose descendant subtree has
  no matching file references.
- Repository path-text filters now support an explicit case-sensitive mode in
  file, descendant-directory, and blob-catalog queries.
- Changed-file scans remove old blob rows only when no file references remain;
  per-run `filesMissing` and `filesDropped` counters are documented and covered
  for deferred drops.
- Repository CLI validation now rejects query and transfer options on commands
  that do not support them, rejects extra positional arguments, and JSON mode
  rejects repository-only query options.
- Repository file cursors now preserve a selected path/size sort order across
  chunk boundaries using stable path and ID tie-breakers.
- Added bounded blob-catalog keyset iteration with stable blob-ID cursors and
  continuation state for large repository result sets.
- Blob detail export options can now omit archive-entry and torrent-file arrays
  while retaining lightweight detail metadata.
- Added explicit `nextFilesPage()` and `previousFilesPage()` operations over the
  same filtered and sorted repository sequence.
- Added a bounded root-summary query for child-directory counts, root-file
  counts, and aggregate repository size.
- Changed the project license to GPL-3.0-only and aligned DUB, source headers,
  and packaging metadata.

## Release 26.10.2 - 2026-09-19

- Switched the CLI to explicit storage modes: top-level commands use SQLite,
  while `json scan` and `json analyze` use direct JSON storage.
- Removed the old option-only JSON invocation and legacy CLI option aliases.
- Normal command execution no longer prints a version banner; use `--version`
  when the version is requested.
- Refactored the CLI around explicit SQLite and JSON command modes with typed
  parsing, stable exit codes, and separated storage validation.
- Added the `metadata` repository subcommand for explicit checksum, file type,
  MediaInfo, archive, and torrent extraction operations.
- Added the `info` repository subcommand for repository metadata and blob counts.
- Added the `list` repository subcommand with bounded path and metadata filters.
- Added the read-only `duplicates` repository subcommand for duplicate groups.
- Added `--format=json` output for repository information, listing, and duplicate
  queries.
- Repository subcommands now reject incompatible operation options instead of
  silently ignoring them.
- CLI diagnostics are now written to stderr, keeping repository query results
  available on stdout for pipelines.
- Added `--replace` as the canonical explicit replacement option for repository
  imports.
- Standardized metadata, analysis, JSON, and hidden-file options on kebab-case
  names.
- Added CLI integration smoke tests for mode isolation, repository discovery,
  JSON queries, and SQLite JSON import/export.
- Fixed Linux dependency installation by including the SQLite development and
  runtime libraries required by `d2sqlite3`.

## Release 26.10.1 - 2026-09-18

- Added command aliases for repository operations: `init`, `scan`, `analyse`,
  `import` and `export`.
- Stabilized concurrent SQLite access by avoiding repeated WAL mode switches and
  closing read statements before dependent queries.
- Fixed JSON backup filenames for filesystems such as exFAT by replacing invalid
  colon characters in timestamp-based names.
- Documented `.dosierskanilo` repositories as the normal working mode while
  retaining direct JSON files as a long-term compatibility workflow.

## Release 26.10.0 - 2026-09-17

- Added the initial public repository API for the planned SQLite backend.
- Added `.dosierskanilo` repository initialization and parent-directory
  discovery.
- Added SQLite schema version 1 with repository, directory, blob, file
  reference, media, archive and torrent tables.
- Added `d2sqlite3` as the SQLite access dependency while keeping it behind the
  repository API.
- Made serialization fixture tests independent of installed `file` and
  MediaInfo tool versions.
- Added transactional JSON v3 import and export for initialized repositories,
  including path-prefix filtering and relational metadata reconstruction.
- Added the first incremental repository filesystem scan with root-relative
  paths, unchanged-file detection and missing-file cleanup.
- Added blob-wise repository jobs for checksums and `file` type detection with
  persisted metadata status.
- Added blob-wise repository persistence for MediaInfo, archive and torrent
  metadata, including rescan replacement of related records.
- Added repository-mode CLI options for initialization, scanning, metadata
  updates and JSON import/export while retaining the legacy JSON mode.
- Added SQL-based repository analysis for duplicate blob merging, missing-file
  handling and orphan cleanup.
- Added parallel metadata workers with central SQLite persistence and structured
  repository operation logs.
- Distinguish empty metadata results from completed metadata results so empty
  extractors are not needlessly rerun.
- Added a storage benchmark script and JSON compatibility coverage across all
  supported fixture generations.
- Added the initial JSON/SQLite storage benchmark baseline for 1k, 10k and 100k
  synthetic records.
- Added schema forward-version rejection and empty-directory scan coverage.
- Added repository archive/torrent relationship persistence coverage.
- Added concurrent repository reader/writer integration coverage.
- Stabilized WAL initialization and close behavior for concurrent repository
  readers and writers.
- Protected non-empty JSON imports with `--force` and automatic SQLite backups.
- Added populated GUI repository pagination coverage.
- Repository-mode `--threads` now controls parallel metadata workers.
- Added a library read API for loading repository data into the existing domain
  model, enabling the GUI data-source adapter.
- Added bounded repository catalog page reads for upcoming GUI pagination.
- Added repository-side catalog filtering for path text, SHA1, media streams,
  file type, archive and torrent metadata.

## Release 26.9.3

- Added the `--version` command-line option.
- Handle unknown or malformed command-line options without a stack dump and
  show a useful error message with a hint to use `--help`.
- Normalize JPEG files identified by `file` as still images when MediaInfo
  incorrectly stores their JPEG stream as a video stream.

## Release 26.9.2

- Keep scan results in a dedicated catalog object.
  - store the current scan state together with tool version details
  - keep the saved JSON format aligned with the in-memory catalog

## Release 26.9.1

- Split the CLI-specific code into a dedicated application package:
  - moved CLI entry points and command-line parsing into `dosierskanilo_cli`
  - kept shared logging, options, and progress helpers in the library surface
  - let the CLI depend on `dosierskanilo` and `dosierarkivo` as libraries
  - reduced cross-package imports so the library modules can evolve without
    dragging CLI-only code with them

## Release 26.9.0

- Split the archive helper code into dedicated modules and package facades:
  - `dosierarkivo.archive` now contains the shared archive base class and type
    constants
  - `dosierarkivo.factory` routes archive files to format-specific
    implementations
  - `dosierarkivo.ziparchive`, `tararchive`, `rararchive`, and
    `sevenziparchive` now own the concrete archive backends
  - `dosierarkivo.package` preserves a stable top-level import surface

- Split model types into focused modules and added a stable package facade:
  - `dosierskanilo.model.checksums`, `filespec`, and `archivespec` now live in
    their own modules
  - `dosierskanilo.package` re-exports the library-facing model and metadata
    modules
  - `dosierskanilo.cli` continues to import the package facade instead of the
    individual modules

## Release 26.8.2

- Improved documentation and published metadata consistency:
  - corrected the published `changelogUrl` in `scripts/build.sh` and
    `scripts/build-docs.sh`
  - aligned README wording and module references with the current repository
    layout
  - updated the analysis service module header for clearer generated API docs

- Added markdown linting to the local quality gate:
  - `scripts/lint.sh` now runs `markdownlint-cli2` or `markdownlint`
  - normalized wrapped lines in `README.md`, `CHANGELOG.md`, and `TODO.md`
    for markdown-lint compliance

- Tightened `NamedBinaryBlob` equality/hash semantics and const-correctness:
  - added explicit `toHash()` implementations for `CheckSums` and
    `NamedBinaryBlob`
  - made blob formatting and lookup helpers const-correct
  - kept `fileSpecs` ordering deterministic after construction and mutation
  - extended unittests to cover hash/equality behavior

- Updated project tracking docs:
  - marked the recent documentation, lint, and model maintenance items as
    completed in `TODO.md`

## Release 26.8.1

- Added explicit duplication semantics for metadata payload models:
  - explicit `dup` handling in torrent metadata structures
  - improved `NamedBinaryBlob` formatting and roundtrip stability
  - folded related unittest adjustments into the same behavior change

- Fixed archive-baseclass unittest setup to keep test execution stable.

- Added regression coverage and fixtures for archive/torrent metadata paths:
  - new/updated JSON v2 fixtures for archive and torrent data
  - extended parser regression checks for archive/torrent metadata handling

## Release 26.8.0

- Reorganized source tree into namespaced subpackages to eliminate module
  name collisions when embedding this project as a library dependency:
  - `dosierskanilo.cli.*` — CLI entry point and helpers
    (`cli/main.d`, `cli/commandline.d`, `cli/logging.d`)
  - `dosierskanilo.metadata.*` — adapters for external metadata tools
    (`metadata/digests.d`, `metadata/mediainfosig.d`,
    `metadata/fileutilsig.d`, `metadata/torrentinfo.d`)
  - `dosierskanilo.model.*` — core data structures
    (`model/namedbinaryblob.d`)
  - `dosierskanilo.service.*` — business logic / service layer
    (`service/scanning.d`, `service/analyze.d`, `service/storageio.d`)
  - `scannerpolicy` merged into `service/scanning.d`; separate module removed
  - Updated `dub.json` `mainSourceFile` to new path
  - All cross-module imports updated throughout the source tree
  - All documentation references (README, ARCHITECTURE, skeleton.html) updated

## Release 26.6.2

- Unified MediaInfo rescan behavior in scanner job execution:
  - `--mediasig --rescan-mediasig` now forces refresh in both
    single-thread and multi-thread mode

- Refreshed project documentation to match current runtime behavior:
  - added complete CLI option reference to `README.md`
  - documented JSON argument constraints and help/pickhidden short-option
    ambiguity (`--help` recommended)
  - updated media rescan notes in `README.md` and `ARCHITECTURE.md`

- Stabilized ADRDOX generation in CI for Debian-based environments:
  - `scripts/build.sh` now selects ADRDOX compiler dynamically and prefers
    `gdc` when available (fallback to `DC`), avoiding
    Debian+`ldc2` parser/segfault failures
  - kept manual override support via `ADRDOX_COMPILER`
- Consolidated CI dependency management into `scripts/install-dependencies.sh`:
  - removed hardcoded apt package installation from GitLab `.build` stage
  - added required build packages for docs generation (`gdc` on Debian/Ubuntu,
    `gcc-gdc` on Alpine)
  - aligned common base build tooling (`ca-certificates`, `git`, `bash`,
    `tar`, `zstd`) in script-managed package sets
- Aligned GitHub Actions docs pipeline with GitLab behavior:
  - `build_pages` now reuses `./scripts/build.sh` instead of a duplicated,
    manual ADRDOX invocation block

- Reorganized documentation layout and publication targets:
  - moved markdown docs and ADRDOX template assets under `docs/`
    (`README.md`, `ARCHITECTURE.md`, `CHANGELOG.md`, `TODO.md`,
    `skeleton.html`, `dosierskanilo-icon.svg`)
  - switched ADRDOX generation output from `docs/` to `public/`
    so `public/` is the direct Pages publishing directory
  - updated build scripts, CI workflows, and VS Code tasks accordingly
  - updated `.gitignore` to track `docs/` sources and ignore generated
    `public/` output

- Streamlined local developer operations in scripts and VS Code tasks:
  - added `scripts/build-all.sh` and a new VS Code `rebuild` task chaining
    `clean` then `build-all` for one-shot local rebuilds
  - removed obsolete `build-doxygen` task in favor of ADRDOX-only docs flow
  - added dedicated `scripts/build-docs.sh` and routed docs tasks to scripts
    for CLI/IDE parity
  - moved unittest coverage `.lst` artifacts to `build/coverage/` and kept
    workspace-root symlinks for VS Code coverage overlays

## Release 26.6.1

- Fixed CI documentation instability caused by `adrdox` parser/segfault failures
  on Alpine-based toolchains:
  - GitHub Pages `build_pages` job now runs in `debian:13-slim`
  - GitLab CI now builds docs in a dedicated `build_docs` job on
    `debian:13-slim`
- Hardened docs artifact flow in GitLab CI Pages publication:
  - `pages` now depends on `build_docs` artifacts directly
  - corrected docs archive extraction command to unpack `docs.tar.gz`
    into `public/`

## Release 26.6.0

- Added end-to-end documentation publishing for both CI providers:
  - GitLab CI now builds DDOX docs as artifacts (`docs.tar.gz`, `docs.json`) and
    publishes them via a `pages` job on the default branch
  - GitHub Actions now includes `build_pages` and `deploy_pages` jobs using
    `actions/upload-pages-artifact` and `actions/deploy-pages`
- Improved CI pipeline consistency and diagnostics:
  - moved GitLab runner tags to the global `default` section for uniform job
    scheduling
  - simplified test coverage artifact collection to `source-*.lst`
- Refactored storage write behavior into shared storage I/O module:
  - introduced `writeStorageJsonFile(...)` in `source/storageio.d`
  - `writeStorageFile()` in `source/appmain.d` now delegates to the shared
    helper while preserving backup/restore-on-failure semantics
- Completed documentation and maintenance cleanup:
  - refreshed DDoc comments and wording across scanner, archive, media, digest,
    torrent, logging, and CLI modules
  - updated `.gitignore` binary patterns to match generated artifacts directly
    (without `./` prefix)
  - normalized Markdown list indentation in `CHANGELOG.md` for lint-friendly
    formatting

## Release 26.5.0

- Fixed storage bootstrap and error semantics by introducing
  `readStorageJsonFile(...)` in `source/storageio.d` and delegating
  `readStorageFile()` in `source/appmain.d`:
  - missing JSON storage file now initializes an empty database explicitly
  - malformed/incompatible JSON now fails by default and is only tolerated when
    `--force` is set
  - added regression coverage for missing-file and malformed-JSON-with-force
    paths
- Corrected digest progress accounting in `source/dosierskanilo/digests.d`:
  - progress now advances by actual processed chunk size (`buffer.length`)
    instead of fixed buffer size
  - added unittests for tiny files and non-multiple-of-buffer-size payloads
    to prevent overshoot regressions
- Hardened CI feedback and test reporting:
  - GitLab lint stage is now explicitly required (`allow_failure: false`)
  - `scripts/test.sh` runs coverage mode (`dub test -b unittest-cov -- -v`)
  - GitLab test stage now publishes `.lst` coverage artifacts for diagnostics
- Standardized compiler behavior across local scripts, tasks, and docs:
  - `scripts/build.sh` and `scripts/test.sh` now default to
    `DC=ldc2` and pass compiler explicitly to `dub build/test/run`
  - VS Code `test-host` task now uses `--compiler=ldc2`
  - `README.md` now documents compiler defaults and override mechanism
- Completed low-priority cleanup for naming and wording consistency:
  - renamed `argRecusive` to `argRecursive` and updated call sites
  - corrected stale comments and user-facing typo-prone messages in
    `source/appmain.d` and `source/commandline.d`

## Release 26.4.0

- Removed the archive debug limiter in `updateArchives` so archives with more
  than 10 entries are fully processed.
- Added archive regression coverage in `source/dosierskanilo/namedbinaryblob.d`
  to verify scans include all entries for larger archives.
- Fixed archive job queueing parity between single-thread and multithread scan
  paths by introducing shared scheduling policy logic:
  - new module: `source/dosierskanilo/scannerpolicy.d`
  - both paths now use `shouldQueueArchiveScanJob(...)`
- Hardened ZIP listing against external tool output drift:
  - `FileArchiveZip.getEntries` now prefers `unzip -Z1` (machine-readable)
  - added tolerant fallback parsing for `unzip -l`
  - replaced aborting assumptions with warning logs and graceful skip behavior
- Added parser regression test `zip list parser tolerates output drift` in
  `source/dosierarkivo/baseclass.d`.

## Release 26.3.0

- Hardened archive command execution in `source/dosierarkivo/baseclass.d`:
  - replaced shell-string based `executeShell(...)` calls for `zip`, `tar`,
    `rar`, and `7z` operations with argument-array process execution
    (`execute([...])`)
  - removed shell command composition patterns that were sensitive to
    quoting/metacharacters in archive or entry names
  - replaced pipeline-based `7z` listing (`grep`/`awk`) with in-process
    parsing of `7z -ba` output
- Added regression coverage for special filenames in archive paths and entries:
  - new unittest `archive extraction with special filenames` in
    `source/dosierarkivo/baseclass.d`
  - validates spaces, quotes, and shell metacharacters survive list/extract
    operations for `zip` and `tar`

## Release 26.2.0

- Added GitHub Actions CI workflow (`.github/workflows/main.yml`)
  equivalent to GitLab CI stages:
  - `lint`, `build`, `test`, `deploy_staging`, `deploy_prod`
  - preserves existing CI scripts and stage flow
- Switched GitHub Actions jobs to Alpine container runtime (`alpine:3.20`)
  to keep CI behavior aligned with GitLab and avoid distro package drift.
- Updated GitHub Actions cache paths for containerized execution (`.dub` and `/root/.dub`).
- Hardened CI test execution by creating the scan input directory on demand in `scripts/test.sh`:
  - ensures `dub run -- -p ./docs/ ...` works in clean CI checkouts
    where `docs/` is not tracked

## Release 26.1.0

- Added GitLab CI pipeline for `lint`, `build`, `test`, `deploy` on Alpine.
- Introduced cross-distro dependency installer script:
  - `scripts/install-dependencies.sh`
  - modes: `lint`, `build`, `runtime`
  - supports: Alpine, Debian 12/13, Ubuntu 24.04/26.04, Manjaro/rolling
- Improved CI dependency robustness:
  - hadolint fallback binary install when package is unavailable
  - build-mode linker/toolchain checks (`cc`) and package fixes
  - ensured `rsync` availability for DDOX generation stage
- Fixed torrent parser compatibility for older toolchains (LDC 1.33 / Alpine):
  - replaced fragile `std.sumtype` access patterns with explicit extraction helpers
  - added maintainer note for future simplification when toolchains converge
- Stabilized unit tests across Alpine and local environments:
  - made brittle string/time snapshot assertions in `namedbinaryblob` tests structural
  - made JPEG MediaInfo test tolerant to optional thumbnail stream
  - skipped `FileArchiveRar` unittest when proprietary `rar` binary is not available
- Updated project docs for CI behavior and local stage execution flow.

## Release 26.0.0

- Reworked data structures around `NamedBinaryBlob` payload model.
- Added richer metadata integration from multiple extractors.
- Improved processing flow for scan + analysis + persistence.
- Default branch changed from `master` to `main`.
- Project name updated to `DosierSkanilo`.

## Release 25.0.0 (backfilled)

- Added archive introspection support for `zip`, `tar`, `rar`, `7z`.
- Added per-entry checksum extraction for files inside archives.
- Introduced `ArchiveSpec` storage as part of blob metadata.
- Added archive-focused unit tests in `source/dosierarkivo/baseclass.d`.

## Release 24.0.0 (backfilled)

- Added torrent inspection via internal bencode parser.
- Added extraction of:
  - info-hash
  - magnet URI
  - file list (single/multi file mode)
  - piece length and piece count
- Introduced `TorrentInfo` and `TorrentFileEntry` model.

## Release 23.0.0 (backfilled)

- Added multi-tool metadata pipeline per blob:
  - `file` utility signature (`fileType`)
  - MediaInfo stream extraction (`MediaInfoSig`)
  - digest updates as independent jobs
- Added threaded execution support through `TaskPool`.

## Release 22.0.0 (backfilled)

- Consolidated duplicate handling around binary identity (size + digest).
- Added merge strategy to associate multiple file names with one blob.
- Added cleanup/invalidation workflow for orphaned or merged records.

## Release 21.0.0 (backfilled)

- Introduced JSON wrapper with explicit `dataVersion` metadata.
- Added fixup/migration logic for legacy input/output fields.
- Improved compatibility between historical JSON schema variants.

## Release 1.x - 20.x (backfilled summary)

- Initial scanner implementation with directory traversal.
- Basic checksum generation and JSON persistence.
- Early MediaInfo integration and incremental CLI growth.
