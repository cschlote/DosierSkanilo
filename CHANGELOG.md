# Changelog

All notable changes to this project are documented in this file.

Note:
Older entries below `26.0.0` were backfilled from source history, tests,
and available data fixtures (`test/json_file_v0.json`, `v1`, `v2`).
They represent the functional evolution and are intentionally summarized.

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
