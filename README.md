
# DosierSkanilo

`DosierSkanilo` scans files (optionally recursive), calculates content digests,
extracts media metadata, inspects archive contents, and reads torrent metadata.
The normal working storage is a local `.dosierskanilo` SQLite repository. JSON
remains the complete interchange format for structured import and export.
The CLI exposes SQLite and direct JSON as separate explicit command groups.

The central idea is: one `NamedBinaryBlob` represents one binary payload,
while multiple file names can reference that same payload.

## Feature Overview

- Directory scan with optional recursion and hidden-file handling
- Blob-centric data model (`NamedBinaryBlob`) with multiple `FileSpec` entries
- Checksums: MD5, SHA1, XXH64
- File type detection via `file` utility
- Media stream metadata via MediaInfo
- Archive inspection (`zip`, `tar`, `rar`, `7z`) with per-entry checksums
- Torrent inspection (`.torrent`) with info-hash and magnet URI
- Duplicate detection and merge by size + digest
- JSON storage with migration/fixup for older schema variants
- Local `.dosierskanilo` SQLite repositories with JSON import/export
- Aggregate `status` reports for SQLite repositories and JSON catalogs

## Storage Modes

The CLI has two explicit storage modes. Top-level commands use a normalized
`.dosierskanilo` repository. It stores the current catalog beside the scanned
directory, similar to a `.git` directory, and avoids loading the complete
catalog for every query:

```bash
./build/bin/dosierskanilo init /data/library
./build/bin/dosierskanilo scan /data/library --recursive
./build/bin/dosierskanilo metadata /data/library --checksums --media-info
./build/bin/dosierskanilo list /data/library --video --format=json
```

Use the explicit JSON target when no SQLite repository should be created. JSON
mode reads and writes only the supplied catalog file and uses the selected base
directory for its relative paths:

```bash
./build/bin/dosierskanilo scan /data/library --json library-scan.json \
  --recursive --checksums --media-info

./build/bin/dosierskanilo analyze --json library-scan.json
```

SQLite and JSON are separate explicit storage targets. A JSON command never
discovers or creates `.dosierskanilo`; a SQLite command never silently falls
back to direct JSON storage. JSON remains the structured exchange format for
explicit SQLite import and export:

```bash
./build/bin/dosierskanilo import /data/library library-scan.json --replace
./build/bin/dosierskanilo export /data/library --output library-export.json
```

Both modes share the catalog contract and the same top-level commands; the
storage target is selected explicitly with `--json` for direct JSON work.

## Shared Catalog API

Library consumers such as the GUI or a web UI do not need to know whether a
source is JSON or SQLite. `CatalogBackend` provides typed directory and file
projections, typed filters, stable reference sorting, bounded cursors,
next/previous reference navigation, and separate archive/torrent detail pages.
`CatalogBackendFactory` opens the adapter from an explicit target, and
`CatalogDocument` adds explicit save/discard semantics for JSON documents.

The GUI keeps storage chunks internal and presents one logical filtered
sequence. JSON/SQLite parity coverage includes case-sensitive path filtering in
the directory tree and catalog view, size sorting, forward/backward paging,
archive-member pages, and shared previews. Cross-adapter evidence is recorded
in [docs/OPERATION-PARITY.md](docs/OPERATION-PARITY.md); remaining GUI-only
interaction coverage is tracked in the
[GUI TODO](https://github.com/cschlote/DosierSkanilo-Gui/blob/main/TODO.md).

The GUI exposes shared scan, metadata, and analysis requests from its Tools
menu, with background progress, cooperative cancellation, safe pause/resume, and
explicit SQLite/JSON targets. The CLI uses the same operation requests.

## Build and Test

Build:

```bash
export DC=ldc2
dub build
```

Run tests:

```bash
export DC=ldc2
dub test -b unittest-cov -- -v
```

Build and runtime dependencies for each distribution package are listed in
[`packaging/README.md`](packaging/README.md#dependencies).

Generate API docs:

```bash
./scripts/build-docs.sh
```

Benchmark JSON and SQLite storage paths:

```bash
./scripts/benchmark-storage.sh ./test/json_file_v2.json 3
```

Compiler strategy:

- CI and local helper scripts use `ldc2` as default for `build`, `test`, and `run`.
- `dub` resolves the D compiler from the `DC` environment variable,
  analogous to `CC` in C toolchains.
- If `DC` is unset, the helper scripts initialize it to `ldc2`.
- Override compiler explicitly when needed: `DC=dmd ./scripts/test.sh`.
- The project is tested primarily with `ldc2`; other compilers are best-effort.

## CI and Linting

The GitLab pipeline runs one lint job and three build jobs:

- `lint`: installs lint dependencies only (`ldc2`, `dub`, `hadolint`,
  `shellcheck`, and a Markdown linter)
- `build:debian13`, `build:ubuntu24.04`, `build:alpine`: each installs build and
  runtime dependencies, builds the project, and runs the test suite

Dependency installation is orchestrated by `.gitlab-ci.yml`. Local helper scripts
(`scripts/build.sh`, `scripts/test.sh`, `scripts/lint.sh`) assume required tools
are already present. Documentation generation runs `adrdox` with a single job,
retries it, and falls back to another available D compiler if needed.

Note on tests in Alpine CI: the `FileArchiveRar` unittest requires the
proprietary `rar` writer binary. If `rar` is not available, this specific test
is skipped while the rest of the suite continues.

Run the same stage order locally:

```bash
./scripts/build-all.sh
```

## Runtime Dependencies

- `file` utility
- MediaInfo library (`libmediainfo`)
- Archive tools used by `source/dosierarkivo/archive.d` and the
  format-specific archive modules:
  - `unzip`
  - `tar`
  - `unrar`
  - `7z`

## CLI Reference

The supported command forms are:

```text
dosierskanilo init [ROOT] [--force]
dosierskanilo scan [ROOT] [OPTIONS]
dosierskanilo metadata [ROOT] [OPTIONS]
dosierskanilo analyze [ROOT] [OPTIONS]
dosierskanilo info [ROOT]
dosierskanilo status [ROOT] [--format=table|json]
dosierskanilo list [ROOT] [FILTERS]
dosierskanilo duplicates [ROOT]
dosierskanilo import [ROOT] INPUT.json [--replace]
dosierskanilo export [ROOT] --output OUTPUT.json [--path VIRTUAL_PATH]
dosierskanilo backup [ROOT] [--output OUTPUT.sqlite3]
dosierskanilo restore [ROOT] --input INPUT.sqlite3 [--force]
dosierskanilo recover CATALOG.json [--restore-from FILE] [--dry-run]

dosierskanilo scan [ROOT] --json CATALOG.json [--base-dir DIR] [OPTIONS]
dosierskanilo analyze [ROOT] --json CATALOG.json [--base-dir DIR] [OPTIONS]
dosierskanilo status --json CATALOG.json [--base-dir DIR] [--format=table|json]
dosierskanilo list [ROOT] --json CATALOG.json [FILTERS]
dosierskanilo duplicates [ROOT] --json CATALOG.json
```

Common options use kebab-case: `--recursive`, `--checksums`, `--file-types`,
`--media-info`, `--scan-archives`, `--scan-torrents`, `--all`, `--drop-missing`,
`--pick-hidden`, `--threads`, `--archive-limit`, `--verbose`, `--pretty`,
`--force` (init/restore), `--output` (export/backup), `--input` (restore), and
`--format=table|json` for query and status commands. `--all` enables checksums,
file types, media info, one shallow archive scan, and torrent scanning;
repeating `--scan-archives` still
selects a deep archive scan. On `analyze`, requested metadata runs before the
duplicate and missing-file analysis. Saved JSON catalogs are compact by
default; `--pretty` indents them for human reading. Archive scans and metadata
extraction accept
`--archive-cache-dir` and `--archive-cache-size` (MiB) to control the temporary
member cache; each run uses an owned session directory and removes it on exit.
`init --force` creates a `VACUUM INTO` safety snapshot (including committed WAL
rows) under `.dosierskanilo/backups/` and starts a new empty catalog; stop other
processes using the repository first. `backup` writes a consistent,
integrity-checked SQLite snapshot; without `--output` it uses a timestamped file
below `.dosierskanilo/backups/`. `restore --input FILE --force` stages and
validates the replacement before swapping it in, preserves the previous database
under `backups/`, and restores it if the reopen fails. SQLite repositories must
reside on a local filesystem; the guard follows symlinks and overmounts. Scans
prune unsupported network/FUSE/autofs mounts and never catalog the repository's
own `.dosierskanilo` directory, even with `--pick-hidden`. For catalogs on
network or FUSE mounts, keep SQLite local and `export` the catalog to JSON
locally before copying it to the other machine.
Deep archive scans can be resumed. Completed archives are recorded with a deep
archive index and are skipped on the next run. With `--archive-limit N` an
archive-only metadata run stops after N pending archives:

```bash
dosierskanilo metadata /data/library --scan-archives --scan-archives \
  --archive-limit 50 --threads 4
```

The first Ctrl-C finishes the currently running archive jobs, commits their
complete results, and stops before the next batch. A second Ctrl-C terminates
immediately without committing the active batch.

`status` reports storage mode, schema or catalog version, timestamps, blob and
reference counts (physical and archive members), directory count, physical
size, missing physical references, metadata coverage for checksums, file types,
media info, archives and torrents, duplicate groups, and for SQLite the
database, WAL and SHM sizes plus the backup count. `--format=json` emits one
machine-readable object for scripts and the GUI.
Help is `--help`; version is `--version`. Normal commands print
`DosierSkanilo <version>` and a compact one-line `Settings:` summary to stderr at
startup so stdout stays usable for command output and JSON formats. `--verbose`
expands the settings into command, target, storage, scope, metadata, worker,
cache, and flag details; verbose diagnostics go to stderr so JSON output remains
machine-readable. Long-running operations print the operation and
target once, followed by compact phase, count, elapsed-time, and path updates.
On a terminal the progress line is rewritten in place and colored; redirected
output emits timestamped records every few seconds, and a heartbeat marks long
gaps without progress callbacks. Each command ends with one
`Elapsed time: ...` line; for `--format=json` queries the line goes to stderr so
stdout stays valid JSON. After the first Ctrl-C the line changes to
`cancelling` and keeps showing the active phase and byte/count progress; the
final message states whether completed batches were committed. A second Ctrl-C
terminates immediately. `--verbose` prints one-second records with rates
and includes the full error trace on failure. `NO_COLOR` and `TERM=dumb` disable
color; `CLICOLOR_FORCE=1` forces it. Query commands include indexed archive
members:
`list` reports canonical `container!/member` paths and a separate display name
without occurrence suffixes. Interrupting a JSON scan with Ctrl-C saves the
records collected so far unless `--dry-run` is active; press Ctrl-C a second time
to terminate immediately.

SQLite commands may discover `ROOT` from the current directory and its parent
directories. JSON commands require an explicit catalog path and never create a
`.dosierskanilo` directory.

## Typical Usage

Initialize and scan a SQLite repository:

```bash
./build/bin/dosierskanilo init /data/library
./build/bin/dosierskanilo scan /data/library --recursive --all
# Replace an existing database but preserve it under .dosierskanilo/backups/
./build/bin/dosierskanilo init /data/library --force
./build/bin/dosierskanilo metadata /data/library --checksums --media-info
./build/bin/dosierskanilo analyze /data/library --all
./build/bin/dosierskanilo backup /data/library
./build/bin/dosierskanilo restore /data/library \
  --input /backup/library.sqlite3 --force
```

Scan and analyze a direct JSON catalog:

```bash
./build/bin/dosierskanilo scan /data/library --json library.json \
  --recursive --checksums --media-info
./build/bin/dosierskanilo analyze --json library.json
```

## Architecture

Detailed architecture and diagrams:

- `docs/ARCHITECTURE.md`
- `docs/CATALOG-DOMAIN.md` - storage-neutral catalog identity and locator model
- `docs/JSON-FORMAT.md` - current JSON import/export format and migrations
- `docs/ARCHIVE-SUPPORT.md` - archive formats, shallow/deep scans, and tools
- `docs/DATABASE.md` - normalized SQLite repository architecture
- `docs/SQLITE-IMPLEMENTATION-PLAN.md` - historical implementation record
- `docs/OPERATION-API.md` - shared CLI/GTK operation request and control contract
- `docs/OPERATION-PARITY.md` - CLI/GTK operation and adapter parity evidence
- `docs/BENCHMARKS.md` - JSON/SQLite storage baseline measurements
- `docs/RELEASE-CHECKLIST.md` - backend and GUI release procedure
- `docs/development/engineering-workflow.md` - change, verification,
  versioning, and release rules
- `docs/development/testing.md` - internal, integration, and external test layers
- `docs/development/d-language-guide.md` - D style, module structure, and
  Ddoc conventions

## License

DosierSkanilo is licensed under [GPL-3.0-only](LICENSE.md).

## Source Map

- `source/dosierskanilo_cli/main.d`: main workflow, scanner orchestration, analysis
- `source/dosierskanilo_cli/parser.d`: CLI parsing and progress rendering
- `source/dosierskanilo_cli/repositoryvalidation.d` and
  `source/dosierskanilo_cli/jsonvalidation.d`: storage-mode validation
- `source/dosierskanilo_cli/logging.d`: logging wrapper
- `source/dosierskanilo/service/scanning.d`: legacy JSON scanner/job entrypoints
- `source/dosierskanilo/service/jsonoperations.d`: controlled JSON scan/analysis
  execution used by the shared operation runner
- `source/dosierskanilo/service/analyze.d`: duplicate/missing-file analysis
- `source/dosierskanilo/service/storageio.d`: JSON storage read/write and backup
- `source/dosierskanilo/operations.d`: frontend-neutral operation requests,
  progress, cancellation/pause control, validation, and results
- `source/dosierskanilo/operationrunner.d`: controlled SQLite/JSON operation
  dispatch and execution
- `source/dosierskanilo/operationlease.d`: per-target writer leases and JSON
  replacement/read coordination
- `source/dosierskanilo/repository/*`: SQLite repository, schema and JSON
  transfer API
- `source/dosierskanilo/repository/scanner.d`: incremental filesystem scan
- `source/dosierskanilo/repository/metadata.d`: blob-wise checksum and file
  type, media, archive and torrent jobs
- `source/dosierskanilo/model/namedbinaryblob.d`: core blob model,
  serialization, migrations, update jobs, merge/cleanup
- `source/dosierskanilo/metadata/digests.d`: digest calculation
- `source/dosierskanilo/metadata/mediainfosig.d`: MediaInfo mapping
- `source/dosierskanilo/metadata/fileutilsig.d`: file type extraction via `file`
- `source/dosierskanilo/metadata/torrentinfo.d`: torrent parser and metadata extraction
- `source/dosierarkivo/archive.d` and `source/dosierarkivo/*archive.d`: archive
  adapters and extraction logic
