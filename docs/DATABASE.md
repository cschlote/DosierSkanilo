# SQLite Repository Architecture

This document describes the persistent SQLite repository backend for
DosierSkanilo. The database represents the current state of one directory tree.
It does not contain scan history in its first version.

Current schema version: **3**. Version 2 repositories migrate archive rows to
stable ordered/path-occurrence identities when opened. WP-13.5 plans schema
version 4 to replace those archive-specific rows with virtual file references.

## Goals

- Keep the current state of one repository root and its descendants.
- Avoid loading the complete catalog into a D object graph for every query.
- Preserve the content-centric duplicate model of `NamedBinaryBlob`.
- Provide fast, relational queries for a future GUI.
- Keep JSON as a complete import and export format.
- Offer a stable library API so the GUI does not depend on SQL details.

Scan history is deliberately outside the initial database model. Operational
logs can be stored as append-only files next to the database without making
historical observations part of the current-state schema.

## Repository Directory

The recommended Git-like layout is:

```text
.dosierskanilo/
    catalog.sqlite3
    logs/
        scan-2026-09-17T12-34-56.jsonl
    exports/
    backups/
    locks/
```

SQLite may create `catalog.sqlite3-wal` and `catalog.sqlite3-shm` while the
database is open. They are managed by SQLite and must remain beside the main
database file.

The directory has separate responsibilities:

- `catalog.sqlite3`: Current repository state.
- `logs/`: Human-readable or structured operational logs; not query state.
- `exports/`: Optional JSON exports created by the user or CLI.
- `backups/`: Optional database and JSON backups before destructive operations.
- Cross-process operation locks currently live in the system temporary directory;
  they are coordination state, not part of the repository catalog.

The database belongs to the repository metadata, similar to `.git`. A command
started below the repository root should search parent directories for
`.dosierskanilo`.

## Current-State Model

The central relationship is:

```text
repository
  -> directories
  -> file_refs -> blobs
                    -> checksums
                    -> media_signature -> media streams
                    -> archive_indexes -> archive_entries -> member blobs
                    -> torrent_info -> torrent_files
```

### Core Tables

- `repository`: One row containing the canonical root path, schema version,
  creation time, update time and tool versions.
- `directories`: Relative directory tree, including empty directories when
  they are discovered.
- `blobs`: One row per known binary payload. Contains size, file type and
  content identity data.
- `file_refs`: A path, modification timestamp and existence/observation state
  pointing to a blob.
- `metadata_status`: Per-blob extractor state, version, scan time, and last error.
  Planned schema v4 records archive index version and shallow/deep completion
  here rather than in archive-specific tables.
- `archive_passwords`: Optional clear-text password associated with a blob, added
  in schema version 2. Repository files and JSON exports containing passwords
  are sensitive data.
- `archive_indexes`: Indexer identity, completion timestamp and whether member
  checksums were deeply extracted for a container blob. `deep_scanned`
  distinguishes a shallow name index from a complete deep pass; a later deep
  metadata request upgrades a shallow index without forcing a rescan.
- `archive_entries`: Ordered, duplicate-aware member descriptors. Stable row IDs
  are reconciled by normalized path and occurrence; deep checksums link a member
  to an existing or newly created content blob through `content_blob_id`.
- `schema_migrations`: Applied database schema migrations.

`file_refs` replaces the JSON model's mixed single-file and multi-file
representation. One blob can have many file references, and each current path
should be unique within a repository.

### Checksums

Checksums should be stored as SQLite `BLOB` values rather than Base64 text.
The first schema can use nullable columns on `blobs`:

```text
md5   BLOB NULL
sha1  BLOB NULL
xxh64 BLOB NULL
```

An identity index must only treat a blob as mergeable when the required digest
set is complete. Partial checksum records must remain valid and must not be
merged solely because SQLite considers nullable values equal.

### Metadata Tables

`media_signatures` has one row per blob and records the extractor version and
extraction state. Separate stream tables preserve the current model without a
large polymorphic table:

- `media_image_streams`
- `media_video_streams`
- `media_audio_streams`
- `media_text_streams`

`archive_entries` references its container blob and stores entry path, size,
modification timestamp, checksums, and an optional `content_blob_id` for a
deep-fingerprinted member. `archive_indexes` records indexer version and
shallow/deep state. A nested archive is indexed by storing its entries against
the member's content blob.

### Planned schema version 4: virtual archive references

The planned v4 migration will convert safe, indexed members to ordinary
`file_refs` whose canonical paths encode archive layers with `!/`. Literal `!`
characters are escaped as `!!`; duplicate path occurrences use the `!~N`
suffix. The migration retains normal `blobs`, `file_refs`, and `directories`,
moves archive extractor/version/depth state to the existing `metadata_status` table,
and drops `archive_entries` and `archive_indexes`. It adds no archive-specific
tables or columns. Its existing `metadata_kind` and `extractor_version` values
distinguish archive indexer and shallow/deep completion. The GUI extraction cache
is session data and is never stored in SQLite.

An archive-member `file_ref` is not a path to an extracted cache file. Its
availability and locator are resolved through the encoded container chain. Scan
and metadata operations use a leased cache path as temporary extractor input,
then persist results against the member's ordinary blob ID. Byte-identical
occurrences share a blob while retaining separate virtual references.

`torrent_info` references one blob and stores all currently available torrent
fields, including the fields that version-3 JSON does not currently output.
`torrent_files` stores the torrent-relative path and length for each entry.

## Directory Rows Versus Derived Paths

The current JSON format stores file paths only. A GUI can derive most parent
directories from those paths, but a `directories` table is recommended for the
database.

Benefits:

- Empty directories can be displayed.
- Directory tree queries become simple and indexed.
- Directory-level counts and aggregate sizes do not require parsing paths.
- Path handling is independent of platform-specific separators.

Costs:

- Scans must update directory rows in addition to file rows.
- Renaming a directory affects more rows if paths are stored redundantly.
- The database contains more records than the current JSON model.

The recommendation is to store canonical root-relative paths and an explicit
directory tree. The additional rows are small compared with media metadata and
avoid rebuilding the tree in every GUI view.

## Metadata Extraction State

The database should distinguish these states for each extractor:

- not requested
- pending
- completed with data
- completed with no data
- failed

This state should be paired with the extractor/tool version and a timestamp.
It prevents unnecessary rescans and makes a forced rescan explicit. It is more
precise than using only `null` and empty arrays as the JSON model currently
does.

## JSON Import and Export

The `.dosierskanilo` SQLite repository is the normal working storage for new
catalogs. JSON remains the complete structured interchange format and the
interchange boundary between repository and non-repository workflows:

- Import accepts all currently supported legacy and version-4 forms, including
  recursively indexed nested archive metadata.
- Import runs inside one SQLite transaction.
- Export can select all data or a filtered relationship closure.
- A filtered export includes the selected file references, their blobs and the
  metadata explicitly selected by the export options.
- Version-3 export remains available for existing consumers.
- An extended JSON version is required before fields not representable in
  version 3, such as complete torrent file lists, can be exported losslessly.

The direct JSON mode is an explicit CLI command group. It can load, scan,
analyze and write a JSON catalog without creating or discovering a repository.
SQLite commands never silently switch to this mode.

The database is therefore not required to mimic the JSON shape. It is allowed
to normalize relationships and reconstruct JSON at the boundary.

## Filesystem Compatibility

SQLite locking was validated on the local exFAT volume used for development in
single-process operation. CIFS/SMB mounts are not a supported database location
yet: the same catalog initialization fails with `database is locked`, including
when WAL is disabled. SQLite network-filesystem locking must be treated as an
open compatibility issue rather than bypassed with unsafe lock-disabling flags.

Current options are tracked as low-priority follow-up work:

- Remount the CIFS share with a locking configuration known to support SQLite,
  with corruption risk evaluated explicitly.
- Store the SQLite catalog on a local filesystem while retaining NAS paths for
  media files.
- Add an explicit external database-root configuration if the second option is
  selected.

## Public API Boundary: Current and Target

The implemented database API is the concrete `Repository` class in
`source/dosierskanilo/repository/repository.d`, re-exported by
`import dosierskanilo.repository`. It owns initialization/discovery, normalized
queries, JSON transfer, and synchronous convenience methods for scan, metadata,
and analysis. `d2sqlite3`, SQL statements, and schema migrations remain behind
this class. Public reads return typed repository DTOs, but some legacy catalog
methods still expose `NamedBinaryBlob`, the JSON serialization model.

The shared long-running `runOperation()` API handles explicit SQLite and JSON
targets for scan/metadata/analysis. It is an operation facade; it is not yet the
polymorphic read/query base class for both storage formats. The GTK directory
view currently combines `Repository` DTO queries with its own JSON projection
through a GUI-owned `DirectorySource`.

The desired API is a storage-neutral catalog/backend interface created by a
factory from an explicit target. JSON and SQLite implementations should expose
the same logical directory/file reads, stable identifiers, filters, sorting,
details, and navigation cursors. HMI code should depend on that interface rather
than branching on SQLite DTOs or `NamedBinaryBlob`; SQL drivers and JSON
serialization stay private adapters. Do not claim generic SQL-database support
yet: first freeze the backend contract and SQLite behavior, then assess which
transaction, keyset-query, migration, and binary-type capabilities another SQL
engine would need. The staged design is tracked as WP-13 in
`SQLITE-IMPLEMENTATION-PLAN.md`.

Schema v3 stores `archive_entries` as metadata children of a container blob and
links deeply fingerprinted members to ordinary content blobs. WP-13.5 replaces
that archive-specific relation with virtual `file_refs`; see the migration plan
in `SQLITE-IMPLEMENTATION-PLAN.md`.

## API and Package Versioning

The public D library API follows Semantic Versioning. Because this repository
ships that API as a DUB package, the repository release tag is also the
package/API version and uses the `vX.Y.Z` form. The CLI shipped from this
repository shares that release tag; it does not have a separate version from
the DUB package.

Existing releases such as `v26.10.2` are valid SemVer versions and remain
historical releases. Keep the current major version rather than rewriting
published tags. From the next release onward, version components describe API
compatibility—not a calendar year or month:

- Increment the major version for incompatible public API changes.
- Increment the minor version for backward-compatible API additions.
- Increment the patch version for backward-compatible fixes.
- Keep database schema/migration versioning separate from the package/API
  version.

## Historical Initial Implementation Phases

The detailed, checkable work breakdown is maintained in
[SQLITE-IMPLEMENTATION-PLAN.md](SQLITE-IMPLEMENTATION-PLAN.md).

1. Add the SQLite dependency and a private connection/migration module.
2. Implement `repository` initialization and schema migration handling.
3. Implement JSON import into the normalized current-state schema.
4. Implement repository scanning without materializing the complete catalog.
5. Implement JSON export and filtered relationship-closure export.
6. Add typed query methods for the future GUI.
7. Add CLI commands for repository discovery, initialization and scanning.
8. Add compatibility tests for JSON round trips and database migrations.

These phases record the SQLite rollout sequence and are complete. Subsequent
storage-neutral API and archive-content work is planned separately under WP-13;
the existing JSON v3 format remains the compatibility boundary during that work.
