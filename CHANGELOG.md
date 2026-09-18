# Changelog

All notable changes to this project are documented in this file.

Note:
Older entries below `26.0.0` were backfilled from source history, tests,
and available data fixtures (`test/json_file_v0.json`, `v1`, `v2`).
They represent the functional evolution and are intentionally summarized.

## Unreleased

- Started the CLI cleanup for SQLite repositories: explicit repository
  subcommands now stay in repository mode, `--help` and `--version` return
  success, parser state is local, and `-h` is reserved for help.
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
