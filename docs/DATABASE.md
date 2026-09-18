# SQLite Repository Architecture

This document describes the persistent SQLite repository backend for
DosierSkanilo. The database represents the current state of one directory tree.
It does not contain scan history in its first version.

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
- `locks/`: Optional application lock files if SQLite locking alone is
  insufficient for a workflow.

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
                    -> archive_entries
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

`archive_entries` references the archive blob and stores entry path, size,
modification timestamp and entry checksums.

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
compatibility boundary between repository and non-repository workflows:

- Import accepts all currently supported legacy and version-3 forms.
- Import runs inside one SQLite transaction.
- Export can select all data or a filtered relationship closure.
- A filtered export includes the selected file references, their blobs and the
  metadata explicitly selected by the export options.
- Version-3 export remains available for existing consumers.
- An extended JSON version is required before fields not representable in
  version 3, such as complete torrent file lists, can be exported losslessly.

The direct JSON-file workflow remains supported independently of SQLite. It can
load, scan, analyze and write a JSON catalog without creating a repository.
There is no short-term removal plan for this mode; existing scripts and JSON
catalogs are long-term compatibility inputs and outputs.

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

## Library API Boundary

The GUI should depend on a library-facing repository API, not on `d2sqlite3`
or raw SQL. A possible public surface is:

```text
Repository.open(path)
Repository.initialize(rootPath)
Repository.scan(options)
Repository.importJson(path, options)
Repository.exportJson(path, filter)
Repository.loadCatalog(options)
Repository.loadCatalogPage(offset, limit, options)
Repository.queryFiles(filter)
Repository.queryDuplicates(filter)
Repository.queryMedia(filter)
Repository.close()
```

The exact D types are to be designed separately. Query results should be
read-only value types or DTOs so the GUI cannot accidentally mutate database
state outside a transaction.

The implementation can use `d2sqlite3`, already used by
`eterna-kosmo-server` as `d2sqlite3 ~>1.0.0`, but this dependency should remain
behind the repository module.

## API Versioning

The application currently uses versions such as `26.9.3`. Strictly coupling
the public database API to every application release would make API support
hard to reason about. The recommended initial policy is:

- Keep the application version at the existing `26.x.y` scheme.
- Give the public database API its own SemVer identity, initially `1.0.0`.
- Document the supported API version in the library and generated API docs.
- Bump the API major version only for source or behavior incompatibilities.
- Keep database schema migration versioning separate from both versions.

If project policy requires one shared version, `26.9.3` can still be a valid
SemVer version. In that case, the API compatibility promise must be explicit:
application patch releases cannot break the public DB API, and a breaking DB
API change must increment the major component.

## Initial Implementation Phases

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

The existing JSON backend should remain untouched until the SQLite path has
equivalent import, export and scan coverage.
