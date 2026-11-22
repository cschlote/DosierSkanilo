# Code Review Report - DosierSkanilo Backend

**Date:** 2026-11-22
**Reviewer:** Automated agent review
**Scope:** Backend repository at `/home2/cschlote/build/dlang/DosierSkanilo`,
branch `testing` (commit `a37b054`), DUB package `dosierskanilo` 26.18.0.
**Method:** Static inspection of source, documentation, build/CI scripts, and
test layout. The existing reports under `docs/reviews/` were deliberately not
read, so this report is an independent assessment.

## 1. Scope and Method

Reviewed areas:

- Core domain: `source/dosierskanilo/model/namedbinaryblob.d`,
  `source/dosierskanilo/model/*.d`.
- Storage backends: `catalogbackend.d`, `jsoncatalogbackend.d`,
  `sqlitecatalogbackend.d`, `repository/*`.
- Operations and services: `operations.d`, `operationrunner.d`,
  `operationlease.d`, `service/*.d`.
- Archive handling: `source/dosierarkivo/*`.
- Metadata: `source/dosierskanilo/metadata/*`.
- CLI: `source/dosierskanilo_cli/*`.
- Documentation: README, ARCHITECTURE, DATABASE, CATALOG-DOMAIN,
  JSON-FORMAT, ARCHIVE-SUPPORT, OPERATION-API, OPERATION-PARITY, BENCHMARKS.
- Build and CI: `dub.json`, scripts, `.gitlab-ci.yml`, GitHub workflows,
  packaging.

Not reviewed in depth: the GUI repository (separate project), Flatpak/AppImage
packaging internals, and the generated API docs under `public/`.

## 2. Executive Summary

DosierSkanilo is a mature, well-documented backend with a clear domain model
and a large, exercised test suite. The codebase shows deliberate attention to
safety (parameterized SQL, normalized archive paths, filesystem guards) and to
operational concerns (cancellation, leases, crash-safe writes).

The main risks are not acute security holes but rather **complexity debt** and
**documentation drift**:

- Two overlapping persistence layers (JSON in-memory document vs. SQLite
  repository) plus a legacy `Repository` facade create a wide surface where
  behavior can diverge.
- Very large single modules (`namedbinaryblob.d` ~4k lines,
  `repository.d` ~3.4k, `jsoncatalogbackend.d` ~2.9k, `catalogbackend.d`
  ~2.9k, `transfer.d` ~2.8k) make localized review and change risky.
- The CLI help in README documents commands that the codebase has been
  migrating away from (`metadata` only for SQLite, no standalone JSON
  metadata), which is correct but easy to misread.
- Coverage is reported around 36-37% on the GUI side; backend coverage is
  not quoted in the backend docs, only in CI output. The unittest count
  (275 named cases) is healthy but concentrated in a few modules.

Overall: **no blocking security or correctness defects found in the sampled
code**. The findings below are improvements and watch items, not regressions.

## 3. Positive Observations

- SQL is consistently parameterized via `db.execute(..., params)`. No string
  concatenation of user input into SQL was found outside of schema-version
  integers.
- Archive member paths are normalized and validated against traversal
  (`normalizeArchiveEntryPath` rejects `..`, absolute paths, drive letters,
  NUL). `parseArchiveVirtualPath` enforces the canonical grammar.
- Filesystem safety: `ensureSupportedFilesystem` rejects network/FUSE/autofs
  mounts for SQLite repositories and follows symlinks/overmounts.
- Crash-safe JSON writes: staging file plus atomic rename, with cancellation
  leaving the original catalog untouched (covered by `test-cli.sh`).
- Cooperative cancellation with two-stage Ctrl-C semantics and partial
  commit of completed batches.
- Per-target write leases prevent concurrent mutating operations.
- Ddoc is present on most public declarations; module headers include author,
  copyright, and license.
- Test infrastructure is extensive: 275 named unittests plus a large CLI
  integration script with cancellation, lease, and crash scenarios.

## 4. Architecture and Design

### 4.1 Layered persistence (P2)

The system maintains three overlapping entry points to the same catalog:

1. `NamedBinaryBlob` / `NamedBinaryBlobCatalog` in-memory document (JSON).
2. `Repository` SQLite facade.
3. `CatalogBackend` polymorphic interface with `JsonCatalogBackend` and
   `SqliteCatalogBackend`.

`Repository` is documented as a compatibility facade, but it still owns a
large amount of logic (scan, metadata, analysis wrappers, JSON transfer).
The risk is that fixes applied to one path are not mirrored in the other.
The CLI parity tests (`test-cli.sh`) compare JSON vs. SQLite output for
list/duplicates/archive members, which mitigates this, but only for the
query surface, not for metadata extraction edge cases.

Recommendation: continue the WP-13 migration and add a parity assertion for
metadata results (checksums, file types, media info counts) between JSON and
SQLite on the synthetic corpus.

### 4.2 Module size (P2)

Several modules exceed 2,500 lines. This is a maintainability and review
hazard rather than a functional defect:

- `source/dosierskanilo/model/namedbinaryblob.d` (4,045 lines)
- `source/dosierskanilo/repository/repository.d` (3,358 lines)
- `source/dosierskanilo/repository/transfer.d` (2,849 lines)
- `source/dosierskanilo/catalogbackend.d` (2,907 lines)
- `source/dosierskanilo/jsoncatalogbackend.d` (large)
- `source/dosierskanilo/repository/metadata.d` (1,865 lines)
- `source/dosierskanilo_cli/parser.d` (1,934 lines)
- `source/dosierskanilo_cli/main.d` (2,086 lines)

Recommendation: split `namedbinaryblob.d` into model / serialization /
migration / update-job files; split `repository.d` into lifecycle, query,
and transfer; split `catalogbackend.d` into interface and shared helpers.
No behavior change required.

### 4.3 Legacy schema and format compatibility (P3)

`ArchiveSpec` legacy JSON v0-v4 fields and `fixupDataClassArrayIn` remain
for read/import compatibility. This is intentional and documented. The cost
is a large migration surface that is exercised by `test/json_file_v*.json`
fixtures. No action needed, but any change to serialization must be
validated against all four legacy fixtures plus the v2 wrapper fixture.

## 5. Security

### 5.1 SQL injection (P3 - low risk)

All observed SQL uses bound parameters. The only dynamic SQL construction
found is `PRAGMA user_version =` concatenated with `to!string(int)`, which
is safe because the value is an integer. No user-controlled string is
interpolated into SQL.

### 5.2 Command injection (P3 - low risk)

External tools (`file`, `unzip`, `tar`, `rar`, `7z`, `mediainfo`) are invoked
via `std.process.execute` with argument arrays, not through a shell. Paths
flow from the scanned filesystem; there is no shell interpolation. The one
concatenation `execute(["zip", "-q", "-j", archivePath] ~ memberPaths)` uses
an array, which is safe.

### 5.3 Path traversal (P3 - low risk)

Archive member paths are validated by `normalizeArchiveEntryPath` and
`parseArchiveVirtualPath`. Physical extraction targets should be verified to
stay under the staging/cache directory; the existing tests cover the virtual
path grammar (`test-cli.sh` occurrence suffix checks). Recommend adding a
fuzz test for `parseArchiveVirtualPath` with `../`, NUL, and backslash inputs.

### 5.4 Filesystem mount guard (P2 - operational)

`ensureSupportedFilesystem` is a meaningful safety feature for SQLite
repositories. It is worth verifying that the guard is applied on every entry
path (init, open, restore, backup), not only on the root. The code shows
calls in `repository.d` at init/open/restore paths; backup writes into the
repository's own `.dosierskanilo/backups/`, which is already local. No
defect found in the sampled calls.

## 6. Correctness and Edge Cases

### 6.1 Empty-collection indexing (P2 - watch)

Several access points index `[0]` after a length check:

- `namedbinaryblob.d:615` `ef.length ? ef[0].fileName : ""` (guarded).
- `namedbinaryblob.d:644` `return names[0];` (guarded by `names.length == 0`
  return above).
- `namedbinaryblob.d:686` `return found[0];` (guarded by `found.length`).
- `namedbinaryblob.d:735` `auto fs = found[0];` (guarded by `!found.empty`).

These are correct today. The risk is future edits removing the guard. A
small helper or invariant comment would help. No change required.

### 6.2 Legacy fixture coverage (P2)

Serialization has four legacy input fixtures (`json_file_v0.json` ...
`v2.json`, plus `json_file_v2_archive.json`, `json_file_v2_torrent.json`,
`json_file_v1_wrongversion.json`). Any change to `fixupDataClassArrayIn` or
`fixupDataClassArrayOutV5` must be re-tested against all of them. Recommend
adding a unittest that round-trips each fixture through load + save + reload
and asserts stability.

### 6.3 MediaInfo and archive rescan semantics (P2)

`--rescan-media-info` forces MediaInfo and archive indexes again. The
interaction with `--archive-limit` (stop after N pending archives) and
deep scans (repeat `--scan-archives`) is documented but complex. Recommend a
matrix test in `test-cli.sh` style covering: shallow scan, deep scan with
limit, rescan, and resume.

### 6.4 Torrent parser (P3)

`metadata/torrentinfo.d` contains a hand-rolled bencode parser with
`to!long` conversions on sliced data. Malformed torrents are a realistic
input. The existing tests should include truncated/malformed torrent
fixtures; if not present, add them.

## 7. Concurrency and Thread Safety

### 7.1 Job pool (P2)

`runScannerJobs` uses `std.parallelism.TaskPool`. The digest function writes
through `shared(bool)* gotCtrlC`. The cancellation path sets output buffers
to `null` (covered by the "digest cancellation clears output buffers"
unittest). This is correct for the sampled code. Risk: any new job type that
captures mutable state without synchronization would reintroduce races.
Recommend documenting the threading contract in `service/scanning.d`.

### 7.2 SQLite access (P2)

SQLite is opened per operation; the write lease serializes mutating
operations. Read queries during an active write depend on SQLite's
locking. The `SqliteEnableUnlockNotify` version enables unlock notification,
which is good. Recommend verifying that long-running reads do not block
writers and vice versa under load; no measurement exists in BENCHMARKS.md
for concurrent access.

## 8. Performance

Performance work is well documented in `docs/BENCHMARKS.md` and the GUI
redesign notes. Key points:

- GC is intentionally left unchanged; measured overhead is small and stable.
- Archive-member first page was optimized (0.92s -> 0.22s) via reserved
  member arrays, hoisted container path, lazy size-order indexes.
- JSON tabs load the complete sortable row set (required by product
  decision); repository tabs stay virtualized/paged.

Findings:

### 8.1 95,001-row JSON memory footprint (P2)

A 14 MB JSON catalog costs ~700 MB RSS and ~4s load in the GUI. The 32 MiB
open guard in the GUI is a reasonable mitigation. Backend-side, the JSON
backend loads the entire catalog into memory; there is no streaming query
path. This is an inherent limitation of the JSON mode and is documented.
No action needed beyond keeping the guard and pointing users to repository
import.

### 8.2 Digest progress callback overhead (P3)

`calculatesDigests` calls `progressCallBack.report` per 64 KiB chunk. For
very large files this is ~16k calls per GB, which is cheap. No change
needed.

## 9. API and Compatibility

### 9.1 Public API surface (P2)

`source/dosierskanilo/package.d` publicly imports 23 modules, including
`repository`, `service.scanning`, and `service.storageio`. This exposes
internal implementation details as public API. Consumers (GUI) depend on
`CatalogBackend` and `CatalogBackendFactory`, which is the intended surface,
but the package facade invites direct use of `Repository` and storage
services. Recommend narrowing the public facade to the catalog/operation/
model modules and keeping `repository`/`service` as package-private, with
a deprecation path.

### 9.2 Schema version (P3)

Current schema version is 6. The migration chain from v1 to v6 is in
`schema.d`. Major 27 (is_virtual / STORED, legacy format removal) is
deferred to 2027 per project decision. No action needed now, but the
migration chain must keep working for old databases; the test suite should
include a v1-era database fixture. If none exists, add one.

## 10. Testing and Coverage

### 10.1 Test distribution (P2)

- 275 named unittests across 43 files.
- Backend coverage percentage is not quoted in backend docs (GUI reports
  36.66%). The CI computes per-file coverage but does not enforce a
  threshold.
- `test-cli.sh` is the strongest integration test: it exercises both
  storage modes, backup/restore, cancellation, leases, crash safety, and
  archive members. It is long (~700 lines) and slow, but valuable.

Gaps:

- No fuzz tests for parsers (bencode, archive virtual paths, JSON).
- No load/concurrency tests for SQLite.
- No property-based tests for digest/merge invariants.
- Coverage threshold not enforced; regressions in coverage would not fail CI.

Recommendation: add a minimum coverage gate (e.g. 30% on changed files) and
fuzz harnesses for the two parsers that accept untrusted input (bencode and
archive path grammar).

### 10.2 Test isolation (P3)

Unittests use `tempDir()` and random UUIDs for file names, which is good.
Some tests reference `test/dummy-*.txt` relative paths, which assumes the
working directory is the repo root. Running tests from another directory
would fail. The CI runs from the repo root, so this is acceptable but
fragile.

## 11. Documentation and Consistency

### 11.1 README vs. code (P2)

README documents `metadata` as a SQLite-only command, which matches the
code. It also documents `--json` mode for `scan` and `analyze` only, which
is correct. However, the CLI reference lists `info [ROOT]` and `status`
without clarifying that `info` requires a repository root discovery; the
test-cli.sh shows `info` works from a nested directory. This is fine but
could be stated explicitly.

### 11.2 OPERATION-PARITY.md (P2)

This file is short (90 lines) and tracks WP-09.5 parity evidence. The
summary checkpoint lists it as an open next step ("Confirm WP-09.5
CLI/GUI parity evidence and update"). Recommend completing it before the
next release, as it is a release-evidence artifact.

### 11.3 CHANGELOG (P3)

CHANGELOG is maintained under `## Unreleased` per workflow. The backend
CHANGELOG is large (64k). Ensure the next release moves the Unreleased
section to `## Release X.Y.Z` as per the release checklist. No defect found.

### 11.4 Ddoc completeness (P3)

Most public declarations have Ddoc. Private/package declarations are
required to have headers per AGENTS.md. Spot checks show `digests.d` and
`catalogstatus.d` are well documented. Recommend a lint rule or CI check
that fails on missing module headers.

## 12. Build, CI, and Release

### 12.1 CI matrix (P3)

CI runs on Debian 13, Ubuntu 24.04, and Alpine 3.23. This is a good matrix
for a D project with system dependencies. The `lint` job runs on Alpine only.

### 12.2 Disabled CI on GitHub (P2 - operational)

Per the project summary, GitHub Actions CI and Release workflows are
`disabled_manually` in both repos; releases are created manually with
`gh release create`. This means the GitHub-side CI is not exercising
changes. Recommend either re-enabling or documenting that GitLab CI is the
authoritative pipeline, and removing the misleading GitHub workflow files if
they are not intended to run.

### 12.3 Flatpak hash pins (P3)

Flatpak `sha256` pins are updated in untagged follow-up commits after a
release, never on the tag. This is documented in AGENTS.md and the release
checklist. No defect found; the procedure is sound.

### 12.4 Build artifacts in working tree (P3)

The repo working tree contains many coverage `.lst` symlinks and a
`build/` directory with large artifacts. `.gitignore` covers `.dub`,
`build/bin/`, `build/coverage/`, and `*.lst`, but the root-level symlinks
created by `test.sh` (`source-*.lst` -> `build/coverage/...`) are tracked
as untracked at times. The current `git status` reports a clean tree, so
the symlinks are either ignored or removed. Verify `.gitignore` ignores
root-level `*.lst` symlinks (it does: `*.lst`). Good.

## 13. Prioritized Findings

| ID | Severity | Area | Summary |
| ---- | ---------- | ------ | --------- |
| F-01 | P2 | Architecture | Three overlapping persistence entry points; parity only on query surface |
| F-02 | P2 | Maintainability | Several modules >2.5k lines; split recommended |
| F-03 | P2 | API | Public package facade exposes `repository`/`service` internals |
| F-04 | P2 | Testing | No coverage gate; no fuzz tests for bencode/archive parsers |
| F-05 | P2 | Operations | OPERATION-PARITY.md incomplete (WP-09.5) |
| F-06 | P2 | CI | GitHub Actions disabled; clarify authoritative pipeline |
| F-07 | P2 | Correctness | Legacy fixture round-trip not asserted |
| F-08 | P3 | Security | Add fuzz tests for `parseArchiveVirtualPath` |
| F-09 | P3 | Testing | Add v1-era SQLite database fixture for migration chain |
| F-10 | P3 | Docs | State `info` root discovery explicitly in README |
| F-11 | P3 | Performance | No concurrent-access measurement for SQLite |
| F-12 | P3 | Docs | Ddoc/module-header lint rule in CI |

## 14. Recommendations

1. Complete WP-09.5 parity evidence (F-05) before the next release.
2. Add a coverage gate and fuzz harnesses (F-04, F-08).
3. Narrow the public package facade (F-03) with a deprecation window.
4. Split the largest modules (F-02) as a non-behavioral refactor.
5. Add legacy round-trip and migration fixtures (F-07, F-09).
6. Document which CI pipeline is authoritative (F-06).
7. Keep GC and performance decisions as documented; no change needed.

## 15. Verification Performed

- Read `README.md`, `docs/ARCHITECTURE.md`, `docs/OPERATION-API.md`,
  `docs/DATABASE.md`, `docs/CATALOG-DOMAIN.md`, `docs/JSON-FORMAT.md`,
  `docs/ARCHIVE-SUPPORT.md`, `docs/OPERATION-PARITY.md`,
  `docs/BENCHMARKS.md`, `docs/development/testing.md`,
  `docs/development/engineering-workflow.md`.
- Inspected source modules: `package.d` (both), `catalogstatus.d`,
  `options.d`, `digests.d`, `archive.d` (path safety section),
  `namedbinaryblob.d` (indexing sites), `repository.d` (filesystem guard).
- Inspected build/CI: `dub.json`, `scripts/test.sh`, `scripts/lint.sh`,
  `scripts/build.sh`, `scripts/test-cli.sh`, `.gitlab-ci.yml`,
  `.github/workflows/*`, `.gitignore`, `.markdownlint.json`.
- Searched for security-relevant patterns: SQL construction, shell
  execution, path traversal, unsafe casts, empty-collection indexing.
- Did not run the full test suite (already green per project status:
  280 backend tests). Did not read existing reports under
  `docs/reviews/`.

## 16. Limitations

This review is based on static inspection and targeted searches, not on a
full line-by-line read of all ~29k lines of backend source. Findings are
prioritized by risk and maintainability impact. A deeper audit of
`repository/metadata.d`, `jsoncatalogbackend.d`, and `operationrunner.d`
would be a sensible follow-up, as those modules contain the most complex
control flow.
