
# DosierSkanilo

`DosierSkanilo` scans files (optionally recursive), calculates content digests,
extracts media metadata, inspects archive contents, and reads torrent metadata.
The normal working storage is a local `.dosierskanilo` SQLite repository. JSON
remains the complete interchange format for structured import and export.
The direct JSON-file workflow is still supported for compatibility and is
expected to remain supported for a long time.

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

Use a `.dosierskanilo` repository as the normal working mode. The repository
stores the current catalog beside the scanned directory, similar to a `.git`
directory, and avoids loading the complete catalog for every query:

```bash
./build/bin/dosierskanilo init --path=/data/library
./build/bin/dosierskanilo scan --path=/data/library --recursive
```

JSON is the structured exchange and migration boundary. Import an existing
catalog or export the current repository state as follows:

```bash
./build/bin/dosierskanilo import \
  --path=/data/library \
  --json=library-scan.json \
  --replace

./build/bin/dosierskanilo export \
  --path=/data/library \
  --json=library-export.json
```

The legacy direct-JSON mode remains available. It loads and updates one JSON
file directly, without requiring a `.dosierskanilo` directory, and should be
used when compatibility with existing scripts or catalogs is more important
than repository queries:

```bash
./build/bin/dosierskanilo \
  --path=/data/library \
  --json=library-scan.json \
  --recursive \
  --scan \
  --checksum \
  --writeJSON \
  --force
```

Both modes use the same catalog concepts. The JSON mode is not deprecated or
scheduled for removal; it is retained as a supported long-term compatibility
path and as a practical way to exchange catalog data.

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

Current command-line options (from `source/dosierskanilo_cli/commandline.d`):

- `-p`, `--path`: path to scan
- `-j`, `--json`: JSON file name for load/store
- `--repository`: repository root or path below a `.dosierskanilo` repository
- `--init-repository`: initialize a repository at `--repository` or `--path`
- `--import-json`: import a JSON catalog into a repository
- `--export-json`: export a repository as JSON
- `-r`, `--recursive`: recurse into subdirectories
- `-s`, `--scan`: discover files from the scan path
- `-c`, `--checksum`: calculate digests
- `-y`, `--file-types` (`--filetypes`): detect file type via `file`
- `-m`, `--media-info` (`--mediasig`): extract MediaInfo signatures
- `--rescan-media-info` (`--rescan-mediasig`): force MediaInfo refresh
- `-z`, `--scan-archives` (`--scanArchives`): inspect archive contents
- `-o`, `--scan-torrents` (`--scanTorrents`): inspect torrent metadata
- `-a`, `--analyze`, `--analyse`: run duplicate/missing-file analysis
- `-d`, `--drop-missing` (`--dropMissing`): remove non-existing files from DB
- `-w`, `--write-json` (`--writeJSON`): write updated JSON
- `-t`, `--threads`: worker-thread count (default: `1`)
- `-f`, `--force`: allow overwrite/force load behavior
- `-H`, `--pick-hidden` (`--hidden`, `--pickhidden`): include hidden files/directories
- `-v`, `--verbose`: verbose output
- `--version`: show the application version
- `--help`: print help
- `--format`: `table` or `json` output for `info`, `list`, and `duplicates`

Repository command aliases are also available:

- `init`
- `scan`
- `metadata`
- `analyze` (with `analyse` retained as an alias)
- `info`
- `list`
- `duplicates`
- `import`
- `export`

Operational notes:

- `--json` currently accepts a filename ending in `.json`; passing a path is
  rejected by argument validation.
- Importing JSON into a non-empty repository requires `--force` and creates a
  timestamped SQLite backup under `.dosierskanilo/backups/`.
- `--replace` is the canonical explicit replacement option for the repository
  `import` command; `--force` remains accepted there as a compatibility alias.
- `--rescan-mediasig` forces a media refresh when combined with `--mediasig`
  (single-thread and multi-thread).
- `-h` and `--help` print help. Use `-H` or `--hidden` to include hidden files
  and directories in a scan.

## Typical Usage

Scan recursively, compute checksums, file type, media info, run analysis, and
write JSON:

```bash
./build/bin/dosierskanilo \
  --path=/media/user/films \
  --json=media-user-films.json \
  --recursive \
  --scan \
  --checksum \
  --filetypes \
  --mediasig \
  --analyse \
  --writeJSON \
  --force
```

Minimal duplicate scan (checksums + analysis only):

```bash
./build/bin/dosierskanilo \
  --path=/data/library \
  --json=library-scan.json \
  --recursive \
  --scan \
  --checksum \
  --analyse \
  --writeJSON \
  --force
```

Enable archive and torrent analysis:

```bash
./build/bin/dosierskanilo \
  --path=/data/incoming \
  --json=incoming.json \
  --recursive \
  --scan \
  --checksum \
  --scanArchives \
  --scanTorrents \
  --writeJSON \
  --force
```

Initialize and scan a SQLite repository:

```bash
./build/bin/dosierskanilo \
  --repository=/data/library \
  --init-repository \
  --recursive \
  --scan \
  --checksum \
  --filetypes \
  --mediasig \
  --scanTorrents
```

Import or export JSON through a repository:

```bash
./build/bin/dosierskanilo \
  --repository=/data/library \
  --import-json=library-scan.json

./build/bin/dosierskanilo \
  --repository=/data/library \
  --export-json=library-export.json
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
- `source/dosierskanilo_cli/commandline.d`: CLI options and progress rendering
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
