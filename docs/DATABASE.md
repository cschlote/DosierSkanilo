# SQLite Repository Architecture

This document describes the persistent SQLite repository backend for
DosierSkanilo. The database represents the current state of one directory tree.
It does not contain scan history.

Current schema version: **6**. Version 2 repositories migrate archive rows to
stable ordered/path-occurrence identities when opened. Version 4 replaces those
archive-specific rows with virtual file references, version 5 adds the generated
`is_virtual` classification column, and version 6 moves directory paths into the
same escaped namespace as file references.

## Goals

- Keep the current state of one repository root and its descendants.
- Avoid loading the complete catalog into a D object graph for every query.
- Preserve the content-centric duplicate model of `NamedBinaryBlob`.
- Provide fast, relational queries for the GUI and library clients.
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
```

SQLite may create `catalog.sqlite3-wal` and `catalog.sqlite3-shm` while the
database is open. They are managed by SQLite and must remain beside the main
database file.

The directory has separate responsibilities:

- `catalog.sqlite3`: Current repository state.
- `logs/`: Human-readable or structured operational logs; not query state.
- `exports/`: Optional JSON exports created by the user or CLI.
- `backups/`: Optional database and JSON backups before destructive operations.
- Cross-process operation leases live outside the repository, preferably in
  `$XDG_RUNTIME_DIR/dosierskanilo-operation-leases` and otherwise in a private
  per-user directory below the system temporary directory. They are coordination
  state, not part of the repository catalog.

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
                     -> virtual file_refs -> member blobs
                     -> torrent_info -> torrent_files
```

### Core Tables

- `repository`: One row containing the advisory root path, schema version,
  creation time, update time and tool versions. Catalog references are
  root-relative, so opening a copied, moved, or otherwise remounted repository
  refreshes this path instead of rejecting the repository. The stored path is
  metadata, not a binding constraint.
- `directories`: Relative directory tree, including empty directories when
  they are discovered.
- `blobs`: One row per known binary payload. Contains size, file type and
  content identity data.
- `file_refs`: A path, modification timestamp and existence/observation state
  pointing to a blob.
- `metadata_status`: Per-blob extractor state, version, scan time, and last error.
  Schema v4 and later record archive-index state and shallow/deep completion here.
- `archive_passwords`: Optional clear-text password associated with a blob, added
  in schema version 2. Repository files and JSON exports containing passwords
  are sensitive data.
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

### Schema version 4: virtual archive references

The v3-to-v4 migration converts safe, indexed members to ordinary
`file_refs` whose canonical paths encode archive layers with `!/`. Literal `!`
characters are escaped as `!!`; duplicate path occurrences use the `!~N`
suffix. The migration retains normal `blobs`, `file_refs`, and physical
`directories`, moves archive extractor/version/depth state to the existing
`metadata_status` table, and drops `archive_entries` and `archive_indexes`. Its
existing `metadata_kind` and `extractor_version` values distinguish archive
indexer and shallow/deep completion; no archive-specific table or column is
added. The GUI extraction cache is session data and is never stored in SQLite.

An archive-member `file_ref` is not a path to an extracted cache file. Its
availability and locator are resolved through the encoded container chain. The
backend's deep scraper uses a leased session cache and persists results against
the member's ordinary blob ID; its path is not serialized. GUI archive previews
use the same leased cache service through the catalog backend. Byte-identical
occurrences may share a blob while retaining separate virtual references.
Member references keep the physical container's `directory_id`; the GUI tree
synthesizes inner archive directories beneath the expandable archive file row
rather than storing them as additional database rows.

### Schema version 5: stored virtual classification

The v4-to-v5 migration adds a generated `is_virtual` column to `file_refs`.
SQLite computes it from the canonical path (`!!` escapes removed, then `!/`
detection), so existing and future rows are classified without backfilling or
changing inserts. Queries select the generated column instead of scanning and
rewriting path text.

`torrent_info` references one blob and stores all currently available torrent
fields, including the fields that the current JSON v5 writer does not output.
`torrent_files` stores the torrent-relative path and length for each entry.

### Schema version 6: escaped directory namespace

The v5-to-v6 migration rewrites `directories.relative_path` values into the same
canonical escaped namespace used by `file_refs.relative_path`. A literal `!` is
stored as `!!`, so prefix queries no longer confuse a real directory name with
an archive-layer separator. The migration updates the longest paths first to
avoid temporary collisions in the unique path index.

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

- Import accepts legacy root arrays and wrapper versions 1 through 5, including
  recursively indexed nested archive metadata.
- Import runs inside one SQLite transaction.
- Export can select all data or a filtered relationship closure.
- A filtered export includes the selected file references, their blobs and the
  metadata explicitly selected by the export options.
- All current exports write JSON v5. The version-3 and version-4 format
  selectors remain source-compatible but are rejected as output formats.
- A later JSON version is required before fields not representable in v5, such
  as complete torrent file lists, can be exported losslessly.

Direct JSON mode is an explicit CLI storage target selected with
`--json CATALOG.json`. It can load, scan, analyze, list and write a JSON catalog
without creating or discovering a repository. SQLite commands never silently
switch to this mode.

The database is therefore not required to mimic the JSON shape. It is allowed
to normalize relationships and reconstruct JSON at the boundary.

## Filesystem Compatibility

SQLite locking was validated on the local exFAT volume used for development in
single-process operation. CIFS/SMB mounts are not a supported database location:
catalog initialization fails with `database is locked`, including when WAL is
disabled. SQLite network-filesystem locking must not be bypassed with unsafe
lock-disabling flags.

Decision: keep the repository requirements explicit instead of implying network
support. A supported location must provide:

- advisory locks that exclude other hosts, so SQLite transactions and the
  operation lease work across processes;
- working WAL shared-memory files, or a deliberate non-WAL configuration shared
  by every process;
- atomic rename of the staging catalog after serialization;
- durable `fsync`/directory sync semantics;
- hard links for backup snapshots, or the documented copy fallback.

CIFS/SMB, NFS, WSL `drvfs`, and FUSE mounts remain unsupported unless a
representative environment passes those checks. The observable failure is an
initialization/open error such as `database is locked` or `SQLITE_READONLY`.
Do not disable SQLite locking or place the database on a share that only
pretends to provide POSIX locks.

Opening a repository through a different path is independent of filesystem
locking. Because catalog references are root-relative and `root_path` is
advisory, a copied, moved, or remounted repository opens at its current location.
The SQLite file itself must still reside on a filesystem that meets the locking
and durability requirements above.

The library enforces this boundary: `Repository.initialize` and `Repository.open`
classify the root path from the kernel mount table and reject known FUSE,
sshfs, SMB/CIFS, NFS, 9p, WSL `drvfs`, and similar network filesystems with a
clear `RepositoryException` before opening SQLite. An application-level lock
file on such a mount cannot replace SQLite's own locking, shared-memory, rename,
and sync guarantees; use a local repository or a JSON catalog instead.

Supported deployment options remain:

- Keep the SQLite repository on a local filesystem and keep media on the NAS.
- Remount the CIFS share with a locking configuration known to support SQLite,
  after evaluating corruption risk explicitly.
- Add an explicit external database-root configuration if local metadata with
  remote media is not sufficient.

## Backup and Restore

`dosierskanilo backup [ROOT] [--output FILE]` creates a consistent snapshot with
SQLite `VACUUM INTO` and validates it with `PRAGMA integrity_check`. Without an
output path it writes a timestamped `catalog-*.sqlite3` file below
`.dosierskanilo/backups/`. A backup does not replace JSON export; use the JSON
export when moving a catalog to another machine or a network-mounted directory.

`dosierskanilo restore [ROOT] --input FILE [--force]` validates the source
schema and integrity before changing the target. If a database already exists,
`--force` is required; the current database and its side files are moved into
`backups/` before the validated source is copied into place and the repository
is reopened. The library exposes the same operations as
`Repository.backupTo()` and `Repository.restore()`.

## Corruption and Recovery

`SQLITE_CORRUPT` or `database disk image is malformed` means the database file
is damaged; retrying or adding an application lock file does not repair it.
Stop every process that uses the repository, copy the database (and any
`-wal`/`-shm` files) to local storage, and preserve the original before trying
recovery:

```sh
sqlite3 catalog.sqlite3 "PRAGMA integrity_check;"
sqlite3 catalog.sqlite3 ".recover" | sqlite3 catalog-recovered.sqlite3
sqlite3 catalog-recovered.sqlite3 "PRAGMA integrity_check;"
```

If the recovered database passes, replace `catalog.sqlite3` while no process is
running it. If recovery is incomplete, re-import the source data or rebuild the
repository with a fresh scan. `dosierskanilo init ROOT --force` preserves the
damaged database under `backups/` and creates an empty catalog for a fresh
scan. Do not retry the damaged repository on a network or FUSE mount.

## Public API Boundary

The storage-neutral `CatalogBackend` contract in
`source/dosierskanilo/catalogbackend.d` is the public read/query surface for
both storage formats. `JsonCatalogBackend` and `SqliteCatalogBackend` implement
the same logical directory/file reads, stable identifiers, filters, sorting,
details, archive/torrent projections, and navigation cursors. HMI code depends
on that interface rather than branching on SQLite DTOs or `NamedBinaryBlob`;
SQL drivers and JSON serialization stay private adapters.

`CatalogBackendFactory` creates a backend from an explicit target. The concrete
`Repository` class in `source/dosierskanilo/repository/repository.d`, re-exported
by `import dosierskanilo.repository`, remains the SQLite compatibility facade
for initialization/discovery, normalized queries, JSON transfer, and synchronous
convenience methods for scan, metadata, and analysis. The shared
`runOperation()` API handles explicit SQLite and JSON targets for the operation
kinds each storage mode supports through the same backend selection.

Do not claim generic SQL-database support yet: assess which transaction,
keyset-query, migration, and binary-type capabilities another SQL engine would
need before adding one. The staged design is tracked as WP-13 in
`SQLITE-IMPLEMENTATION-PLAN.md`.

Schema v3 stored `archive_entries` as metadata children of a container blob and
linked deeply fingerprinted members to ordinary content blobs. Schema v4
replaced that archive-specific relation with virtual `file_refs`, schema v5
adds the generated `is_virtual` classification column, and schema v6 escapes
directory paths into the file-reference namespace; the migrations are documented
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
6. Add typed query methods for the GUI.
7. Add CLI commands for repository discovery, initialization and scanning.
8. Add compatibility tests for JSON round trips and database migrations.

These phases record the SQLite rollout sequence and are complete. WP-13.1
through WP-13.6 add the storage-neutral API, JSON v5, the shared extraction
cache, and GUI archive navigation; SQLite schema v6 is the current storage
version. JSON v0-v4 remain readable compatibility inputs.
