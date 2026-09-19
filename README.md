
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

Use the explicit `json` mode when no SQLite repository should be created. JSON
mode reads and writes only the supplied catalog file:

```bash
./build/bin/dosierskanilo json scan \
  /data/library library-scan.json --recursive --checksums --media-info

./build/bin/dosierskanilo json analyze library-scan.json
```

SQLite and JSON are separate command groups. A JSON command never discovers or
creates `.dosierskanilo`; a SQLite command never silently falls back to direct
JSON storage. JSON remains the structured exchange format for explicit SQLite
import and export:

```bash
./build/bin/dosierskanilo import /data/library library-scan.json --replace
./build/bin/dosierskanilo export /data/library --output library-export.json
```

Both modes use the same catalog concepts but have independent command contracts.

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

The GitLab pipeline uses Alpine and separates dependencies by stage:

- `lint`: installs lint dependencies only (`dub`, `hadolint`, `shellcheck`)
- `build`: installs build dependencies only
- `test`: installs build + runtime dependencies

Dependency installation is orchestrated by `.gitlab-ci.yml`. Local helper scripts
(`scripts/build.sh`, `scripts/test.sh`, `scripts/lint.sh`) assume required tools
are already present.

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

The target command groups are:

```text
dosierskanilo init [ROOT]
dosierskanilo scan [ROOT] [OPTIONS]
dosierskanilo metadata [ROOT] [OPTIONS]
dosierskanilo analyze [ROOT] [OPTIONS]
dosierskanilo info [ROOT]
dosierskanilo list [ROOT] [FILTERS]
dosierskanilo duplicates [ROOT]
dosierskanilo import [ROOT] INPUT.json --replace
dosierskanilo export [ROOT] --output OUTPUT.json

dosierskanilo json scan ROOT CATALOG.json [OPTIONS]
dosierskanilo json analyze CATALOG.json [OPTIONS]
```

Common options use kebab-case: `--recursive`, `--checksums`, `--file-types`,
`--media-info`, `--scan-archives`, `--scan-torrents`, `--drop-missing`,
`--pick-hidden`, `--threads`, `--verbose`, and `--format=table|json` for query
commands. Help is `--help`; version is `--version`.

SQLite commands may discover `ROOT` from the current directory and its parent
directories. JSON commands require an explicit catalog path and never create a
`.dosierskanilo` directory.

## Typical Usage

Initialize and scan a SQLite repository:

```bash
./build/bin/dosierskanilo init /data/library
./build/bin/dosierskanilo scan /data/library --recursive
./build/bin/dosierskanilo metadata /data/library --checksums --media-info
./build/bin/dosierskanilo analyze /data/library --drop-missing
```

Scan and analyze a direct JSON catalog:

```bash
./build/bin/dosierskanilo json scan /data/library library.json \
  --recursive --checksums --media-info
./build/bin/dosierskanilo json analyze library.json
```

## Architecture

Detailed architecture and diagrams:

- `docs/ARCHITECTURE.md`
- `docs/JSON-FORMAT.md` - current JSON import/export format and migrations
- `docs/DATABASE.md` - normalized SQLite repository architecture
- `docs/SQLITE-IMPLEMENTATION-PLAN.md` - staged implementation checklist
- `docs/BENCHMARKS.md` - JSON/SQLite storage baseline measurements

## Source Map

- `source/dosierskanilo_cli/main.d`: main workflow, scanner orchestration, analysis
- `source/dosierskanilo_cli/parser.d`: CLI parsing and progress rendering
- `source/dosierskanilo_cli/repositoryvalidation.d` and
  `source/dosierskanilo_cli/jsonvalidation.d`: storage-mode validation
- `source/dosierskanilo_cli/logging.d`: logging wrapper
- `source/dosierskanilo/service/scanning.d`: directory scanning + job scheduling
- `source/dosierskanilo/service/analyze.d`: duplicate/missing-file analysis
- `source/dosierskanilo/service/storageio.d`: JSON storage read/write and backup
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
