# Changelog

All notable changes to this project are documented in this file.

Note:
Older entries below `26.0.0` were backfilled from source history, tests,
and available data fixtures (`test/json_file_v0.json`, `v1`, `v2`).
They represent the functional evolution and are intentionally summarized.

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
    `DUB_COMPILER=ldc2` and pass compiler explicitly to `dub build/test/run`
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
  - replaced shell-string based `executeShell(...)` calls for `zip`, `tar`, `rar`, and `7z` operations with argument-array process execution (`execute([...])`)
  - removed shell command composition patterns that were sensitive to quoting/metacharacters in archive or entry names
  - replaced pipeline-based `7z` listing (`grep`/`awk`) with in-process parsing of `7z -ba` output
- Added regression coverage for special filenames in archive paths and entries:
  - new unittest `archive extraction with special filenames` in `source/dosierarkivo/baseclass.d`
  - validates spaces, quotes, and shell metacharacters survive list/extract operations for `zip` and `tar`

## Release 26.2.0

- Added GitHub Actions CI workflow (`.github/workflows/main.yml`) equivalent to GitLab CI stages:
  - `lint`, `build`, `test`, `deploy_staging`, `deploy_prod`
  - preserves existing CI scripts and stage flow
- Switched GitHub Actions jobs to Alpine container runtime (`alpine:3.20`) to keep CI behavior aligned with GitLab and avoid distro package drift.
- Updated GitHub Actions cache paths for containerized execution (`.dub` and `/root/.dub`).
- Hardened CI test execution by creating the scan input directory on demand in `scripts/test.sh`:
  - ensures `dub run -- -p ./docs/ ...` works in clean CI checkouts where `docs/` is not tracked

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
