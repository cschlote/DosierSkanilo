
# DosierSkanilo

`DosierSkanilo` scans files (optionally recursive), calculates content digests,
extracts media metadata, inspects archive contents, and reads torrent metadata.
All results are persisted in JSON and can be used to detect duplicates by
binary identity.

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
- Archive tools used by `source/dosierarkivo/baseclass.d`:
  - `unzip`
  - `tar`
  - `unrar`
  - `7z`

## CLI Reference

Current command-line options (from `source/dosierskanilo/cli/commandline.d`):

- `-p`, `--path`: path to scan
- `-j`, `--json`: JSON file name for load/store
- `-r`, `--recursive`: recurse into subdirectories
- `-s`, `--scan`: discover files from the scan path
- `-c`, `--checksum`: calculate digests
- `-y`, `--filetypes`: detect file type via `file`
- `-m`, `--mediasig`: extract MediaInfo signatures
- `--rescan-mediasig`: force MediaInfo refresh (see notes below)
- `-z`, `--scanArchives`: inspect archive contents
- `-o`, `--scanTorrents`: inspect torrent metadata
- `-a`, `--analyse`: run duplicate/missing-file analysis
- `-d`, `--dropMissing`: remove non-existing files from DB during analysis
- `-w`, `--writeJSON`: write updated JSON
- `-t`, `--threads`: worker-thread count (default: `1`)
- `-f`, `--force`: allow overwrite/force load behavior
- `-h`, `--pickhidden`: include hidden files/directories in scan
- `-v`, `--verbose`: verbose output
- `--help`: print help

Operational notes:

- `--json` currently accepts a filename ending in `.json`; passing a path is
  rejected by argument validation.
- `--rescan-mediasig` forces a media refresh when combined with `--mediasig`
  (single-thread and multi-thread).
- `-h` is bound to `--pickhidden`; use `--help` for help output to avoid
  ambiguity.

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

## Architecture

Detailed architecture and diagrams:

- `docs/ARCHITECTURE.md`

## Source Map

- `source/dosierskanilo/cli/main.d`: main workflow, scanner orchestration, analysis
- `source/dosierskanilo/cli/commandline.d`: CLI options and progress rendering
- `source/dosierskanilo/cli/logging.d`: logging wrapper
- `source/dosierskanilo/service/scanning.d`: directory scanning + job scheduling
- `source/dosierskanilo/service/analyze.d`: duplicate/missing-file analysis
- `source/dosierskanilo/service/storageio.d`: JSON storage read/write and backup
- `source/dosierskanilo/model/namedbinaryblob.d`: core blob model,
  serialization, migrations, update jobs, merge/cleanup
- `source/dosierskanilo/metadata/digests.d`: digest calculation
- `source/dosierskanilo/metadata/mediainfosig.d`: MediaInfo mapping
- `source/dosierskanilo/metadata/fileutilsig.d`: file type extraction via `file`
- `source/dosierskanilo/metadata/torrentinfo.d`: torrent parser and metadata extraction
- `source/dosierarkivo/baseclass.d`: archive adapters and extraction logic
