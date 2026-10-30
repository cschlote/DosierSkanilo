# Catalog Domain Values and Locators

Status: WP-13.1 through WP-13.5.3 are implemented. JSON v5 and SQLite schema v4
store archive members as normal virtual references; the shared extraction cache
and GUI navigation remain planned work.

This document freezes the concepts needed by a storage-neutral catalog API.
It distinguishes payload identity from the places where that payload is
addressed, and keeps physical paths, archive display paths, and storage keys
from becoming interchangeable strings.

## Domain values

- **`ContentId`** — Opaque identity of one content record in a catalog.
- **`ContentBlob`** — Content size, complete identity fingerprint when
  available, and content-level metadata/extractor state.
- **`ReferenceId`** — Opaque identity of one address of content.
- **`ContentReference`** — Links one `ReferenceId` and locator to a
  `ContentId`; carries observed location metadata and availability.
- **`ContentLocator`** — Discriminated location value used to resolve bytes from
  a source.
- **`FilesystemLocator`** — A path relative to the filesystem root bound to the
  open catalog.
- **`ArchiveEntryLocator`** — An entry identity within a particular archive
  reference; it may itself be the container for nested entries.
- **`ArchiveEntryId`** — Identity of one entry occurrence in one version of one
  container's archive index.
- **`TorrentManifestEntry`** — A name and size described by torrent metadata;
  it is not a filesystem or archive reference.

These are value snapshots. Modifying a returned value is local to the caller and
does not mutate the catalog. Mutations go through typed backend operations and
their commit/result contract. The mutable Jsonizer classes (`NamedBinaryBlob`,
`FileSpec`, `ArchiveSpec`, and `TorrentInfo`) remain compatibility/adapter
representations; they do not define the new public API.

## Identity rules

- IDs are opaque typed values, not SQL row IDs, array positions, paths, or
  display strings. Their representations are private to an adapter.
- IDs are scoped to one open catalog source. Do not compare or persist IDs from
  independently opened JSON/SQLite catalogs as if they were globally portable.
- Within a source, an ID remains stable while its record remains present. A
  committed replacement or duplicate merge may invalidate an ID; the surviving
  record keeps one ID and operations report committed changes so clients refresh.
- `ContentId` names content, not a filename. Moving or renaming a reference does
  not by itself change the content identity. Replacing the bytes at a location
  links that reference to the new content identity; other references to the old
  bytes remain attached to the old content.
- Content equality requires equal size and the complete configured fingerprint.
  Partial checksums, matching names, timestamps, file type, and archive display
  paths are not proof of content equality. The current complete fingerprint is
  MD5 + SHA1 + XXH64; changing that set is a separate compatibility decision.
- When duplicate content is merged, references are redirected to the canonical
  surviving content record. IDs of removed duplicate records expire; callers
  must use the operation result and refresh rather than infer which ID survives.
- `ReferenceId` identifies a location, not content. An explicit rename can update
  a reference's locator while retaining its ID. A filesystem scan does not infer
  rename intent: it reports the old path unavailable and discovers the new path
  as a reference. Duplicate analysis may subsequently associate it with the same
  `ContentId`.
- UI models use `CatalogBackend.uiHandle` as an opaque key. Handles are stable
  only while that backend instance is open, are distinct per identifier kind, and
  must never be parsed or persisted. Persist the reference or directory path
  instead and restore it with `resolveDirectory`/`resolveReference`; an
  unresolved path is an ordinary state change, not a backend error.
- Pure-virtual content has no payload fingerprint of its own. Digests, file
  types, and media info are computed only for content reachable as a physical
  file; a member's digest is supplied by the container's `ArchiveSpec.checkSums`
  and is not promoted to the member content record. Duplicate analysis therefore
  excludes member-only content by design unless the archive index supplies a
  member fingerprint. Adapters must not treat a missing member digest as
  corruption or invent one from the archive file.

IDs are stable only within the catalog-source contract above. JSON v3 has no
serialized content/reference IDs, so its adapter may assign source-scoped IDs;
no cross-import or cross-adapter ID equality is promised. Adding portable IDs to
an interchange format requires an explicit JSON schema decision, not an
incidental Jsonizer field.

## Locator rules

### Filesystem locations

- A `FilesystemLocator` contains a root-relative path. The opened backend binds
  that path to its explicit source root (`Repository.rootPath` or the JSON
  operation's filesystem root); the absolute machine path is not part of the
  locator identity.
- Use `/` as the domain separator on every host. Preserve case and Unicode text;
  locator equality uses that canonical spelling and does not case-fold or
  Unicode-normalize names. A source adapter must reject two locator spellings
  that resolve to the same source entry; case-insensitive query filters do not
  change locator identity.
- Locators must not contain a root prefix, drive prefix, empty path, or `.`/`..`
  traversal component. Paths outside the bound root are rejected rather than
  reinterpreted as a second source.
- Display names and parent-directory projections are derived from the locator;
  they are not IDs. Modification time and presence are observations, not identity.

### Archive locations

- An `ArchiveEntryLocator` contains a `containerReferenceId` and an
  `ArchiveEntryId`. A nested archive entry becomes a container reference in its
  own right, so nested locations are a chain of typed references, not one
  flattened path string.
- Entry names are display/query metadata, not unique identifiers. Duplicate
  names are distinguished by occurrence within the container's ordered index.
  The entry identity is scoped to the container content version, archive-indexer
  version, and occurrence; it therefore remains stable for an unchanged
  container/index and changes when those inputs change.
- The locator records which container reference owns the entry. If identical
  archive bytes occur at two filesystem paths, those are distinct reference
  chains even though their content IDs may be shared.
- A rendered path such as
  `archives/photos.zip!/nested.zip!/readme.txt` is presentation only. `!/`
  separates archive layers, `!!` encodes a literal exclamation mark, and `!~N`
  encodes a zero-based duplicate-name occurrence. Literal display names omit the
  occurrence suffix. The resulting path is reversible, but typed locators remain
  authoritative for identity.
- An extracted member can share a `ContentId` with a physical file or another
  archive member. Each address remains a separate `ContentReference`.

## Availability and metadata states

Availability belongs to a reference and is distinct from whether metadata was
requested or extracted successfully:

- `notChecked`: the source has not been tested during this view/operation.
- `available`: the location can currently be resolved.
- `unavailable`: the physical file, container, or entry cannot currently be
  resolved (including a temporarily unavailable mount).

An unavailable reference is retained by default. Removal requires an explicit
`dropMissing` operation and a committed result. Archive indexing/password
failures are extractor/index states, not evidence that content is empty or that
the reference should be deleted. Metadata state is tracked per extractor, with
at least `notRequested`, `pending`, `completed`, `empty`, and `failed` kept
distinct where the adapter supports persistence.

## Torrent compatibility

`TorrentManifestEntry` records what a `.torrent` describes: path components
relative to the torrent root and expected byte length. It does not assert that
those bytes exist locally, does not create a `ContentId`, and is not linked to a
filesystem reference by matching its display name. A later explicit matching
operation may create that relationship. Until then, torrent entries remain
metadata associated with the `.torrent` content record. The current JSON v3
writer's reduced torrent fields remain a compatibility constraint; exporting
additional fields requires an extended JSON version.

## Backend contract

The storage-specific implementation of
`CatalogBackendFactory.open(OperationTarget)` selects exactly the requested
source: an initialized repository root or an explicit JSON catalog plus
filesystem root. It does not discover a different source, create a repository,
or convert between storage modes. A JSON catalog may be opened without a
filesystem root for analysis; tree queries and filtered file subsets are then
reported unsupported through capabilities. An operation submitted to an opened
backend must name the same catalog/repository; a scan root must also match. JSON
analysis may omit its unused filesystem root but may not name a different one.
Mismatches are typed `invalidTarget` errors.

The public `CatalogBackend` surface is in `dosierskanilo.catalogbackend`. Its
directory/file projections, filters, sort order, cursors, content details,
archive/torrent pages, archive-member reference pages, and subset-export requests
use neutral value types. It
does not expose SQL statements, d2sqlite3 values, Jsonizer records, GTK types, or
CLI parser/output types.

- Returned query/detail values are detached snapshots. Editing them locally
  never writes through to the backend.
- `resolveDirectory`/`resolveReference` translate display paths back to typed
  identities for state restoration and return invalid IDs for unknown paths.
  `loadReference` loads one reference row on demand. `acquireMemberContent`
  resolves a member's container chain and stored passwords and returns a shared
  cache lease that the caller releases; frontends never open archives or compute
  member identities themselves.
- `listFilesFrom` returns the files adjacent to a named reference so clients can
  implement previous/next navigation without holding a cursor. An unknown anchor
  yields an empty page, and an empty anchor starts at the first file forward.
- `listContents` returns one row per stored content record in source order for
  table projections. Adapters that keep unmerged duplicate records report one
  row per record, so row counts may differ between storage modes; clients must
  not infer a global content count from them. `CatalogFilter.pathText` also
  accepts an exact base64 SHA-1 digest.
- A page cursor is opaque and bound to the opened source, full query/filter,
  sort order, and page size. Reusing it with another source/query is a typed
  `invalidCursor` error. A committed mutation may invalidate the cursor.
- `capabilities()` reports supported operations, rooted tree queries, subset
  export, archive/torrent entry queries, first-class archive references, and
  concurrent-read behavior.
  Unsupported operations/features fail explicitly with
  `CatalogBackendException`; adapters do not silently substitute another mode.
- `JsonCatalogBackend` reads legacy arrays and JSON versions 1-4. It requires an
  explicit filesystem root for tree queries and scans; analysis of an explicit
  catalog can run without one. JSON v3 omits torrent file-list details, so the
  adapter reports torrent-entry queries unsupported when that data is absent.
- Each `runOperation` call is synchronous at the method boundary, accepts the
  shared `OperationControl`, joins its workers before returning, and reports its
  terminal `OperationResult` including `changesCommitted`. The caller must keep
  the backend alive until the call returns. `close()` is called after active
  operations have joined; later calls report the typed `closed` error.
- Filtered export takes an explicit subset and format. The adapter exports a
  coherent selected-reference/content relationship closure and publishes the
  output according to that format's atomic-write policy.

The contract test uses a fake in-memory implementation to exercise root and
directory reads, cursor-based forward/backward pages, content details, subset
export, explicit target checking, capabilities, unsupported operations, and
close behavior without importing `Repository` or `NamedBinaryBlob`.

## Examples

### Shared content and a renamed file

```text
Content c-A: size=1200, fingerprint=F
Reference r-1 -> FilesystemLocator("photos/a.jpg") -> c-A
Reference r-2 -> FilesystemLocator("backup/a-copy.jpg") -> c-A
```

An explicit rename to `photos/vacation.jpg` changes the reference locator, not
the payload identity. If a scanner only observes the old path missing and the
new path present, it reports two location changes; after checksums establish
fingerprint `F`, duplicate analysis can attach the new reference to `c-A`.

### Duplicate and nested archive entries

```text
Reference r-zip -> FilesystemLocator("archives/photos.zip") -> c-zip
Reference r-entry-4 -> ArchiveEntryLocator(r-zip, e-4) -> c-A
Reference r-nested -> ArchiveEntryLocator(r-zip, e-9) -> c-nested-zip
Reference r-readme -> ArchiveEntryLocator(r-nested, e-2) -> c-readme
```

If the ZIP also contains another entry named `a.jpg`, its occurrence receives a
different `ArchiveEntryId` even if its displayed member path is identical. If its
bytes match `c-A`, its reference points to `c-A` while remaining a distinct
archive location. The nested display path can be rendered as
`archives/photos.zip!/nested.zip!/readme.txt`, but the structured reference chain
is authoritative.

## Mapping from the current implementation

- `NamedBinaryBlob` approximates `ContentBlob` but also owns `FileSpec[]` source
  references; it is mutable and JSON-versioned. JSON v5 stores archive members
  as normal content records with virtual `FileSpec` paths. JSON v0-v4 nested
  `ArchiveSpec[]` remains an import-compatibility shape.
- SQLite `blobs.id` approximates `ContentId`; `file_refs.id` approximates
  `ReferenceId`; schema v4 uses `file_refs.relative_path` for physical and
  virtual path layers. These integer IDs remain adapter-private.
- `RepositoryArchiveEntry` exposes a stable row ID, normalized path, ordered
  index/duplicate occurrence, size/time/checksums, and a linked content ID after
  deep extraction. `CatalogBackend.listArchiveMembers` combines that entry ID
  with a selected container `ReferenceId` to return a structured locator and a
  stable member-reference ID. `CatalogFile.hasArchive` identifies expandable
  physical/member file rows. Setting `CatalogFilter.includeArchiveMembers`
  includes safe, deeply indexed member references in the ordinary file query,
  directory visibility, root summary, and relationship-closed JSON subsets (v3
  for flat data and v4 when nested entries are selected). Nested locator chains
  are supported. The TreeView can expand the existing file row and group member
  paths beneath it without adding a database directory relation.
- `ArchiveSpec` is the JSON v0-v4 compatibility representation. JSON v5 stores
  each scraped member as a normal content record with a virtual `FileSpec`;
  legacy nested `ArchiveSpec` trees remain readable and are promoted on export.
- SQL schema v4 stores members in normal `file_refs` and `blobs`; archive index
  version/depth state lives in `metadata_status`. The former
  `archive_entries`/`archive_indexes` tables are removed, and inner directories
  remain a TreeView projection rather than persisted directory rows.
