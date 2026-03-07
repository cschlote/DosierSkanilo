
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
dub build --compiler=ldc2
```

Run tests:

```bash
dub test -b unittest-cov -- -v
```

## Runtime Dependencies

- `file` utility
- MediaInfo library (`libmediainfo`)
- Archive tools used by `source/dosierarkivo/baseclass.d`:
	- `unzip`
	- `tar`
	- `unrar`
	- `7z`

## Typical Usage

Scan recursively, compute checksums, file type, media info, run analysis, and
write JSON:

```bash
./dosierskanilo \
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
./dosierskanilo \
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
./dosierskanilo \
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

- `ARCHITECTURE.md`

## Source Map

- `source/appmain.d`: main workflow, scanner orchestration, analysis
- `source/commandline.d`: CLI options and progress rendering
- `source/dosierskanilo/namedbinaryblob.d`: core blob model, serialization,
	migrations, update jobs, merge/cleanup
- `source/dosierskanilo/digests.d`: digest calculation
- `source/dosierskanilo/mediainfosig.d`: MediaInfo mapping
- `source/dosierskanilo/fileutilsig.d`: file type extraction via `file`
- `source/dosierskanilo/torrentinfo.d`: torrent parser and metadata extraction
- `source/dosierarkivo/baseclass.d`: archive adapters and extraction logic
