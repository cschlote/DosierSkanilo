# Archive Support

This document describes the `dosierarkivo` package: supported formats, the
descriptor model, shallow and deep scans, tool requirements, and the safety
boundaries of member extraction.

## Package Layout

- `dosierarkivo.archive`: the `FileArchive` base class, `ArchiveEntryDescriptor`,
  the archive virtual-path grammar (`!` escaping, `!/` member separator,
  `!~N` duplicate occurrence) with its SQL helpers, and the cancellable
  `runArchiveTool` runner that maps tool failures to
  `ArchivePasswordRequiredException` and `ArchiveToolException`
  (`enforceArchiveToolResult`).
- `dosierarkivo.factory`: `fileArchive()` selects the adapter from the longest
  matching filename suffix.
- `dosierarkivo.ziparchive`, `dosierarkivo.tararchive`, `dosierarkivo.rararchive`,
  `dosierarkivo.sevenziparchive`: one adapter per format, each backed by an
  external command-line tool.
- `dosierarkivo.testsupport`: shared unittest fixtures.

## Supported Formats

| Format | Extension | Listing tool | Shallow metadata | Deep extraction |
|---|---|---|---|---|
| ZIP | `.zip` | `unzip` | names, sizes, timestamps | `unzip` or index-based Python `zipfile` |
| TAR | `.tar`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz2`, `.tbz`, `.tar.xz`, `.txz`, `.tar.zst`, `.tzst`, `.tar.lz`, `.tlz`, `.tar.lzma`, `.tar.Z`, `.taz` | `tar` plus the matching decompressor | names, sizes, timestamps | `tar` |
| RAR | `.rar` | `unrar` | names, sizes, timestamps | `unrar` |
| 7z | `.7z` | `7z` | names, sizes, timestamps | `7z` |

`fileArchive()` matches the longest known suffix case-insensitively. Compressed
tar variants use the same TAR adapter; the `tar` tool performs decompression
transparently. Plain single-file `.gz`, `.xz`, or `.zst` archives are not
supported; only tar containers are.

## Descriptor Model

`ArchiveEntryDescriptor` is the stable shape returned by every adapter:

- `index`: position in the listing order.
- `name`: raw member name used for extraction.
- `relativePath`: normalized slash-separated path when safe.
- `occurrence`: zero-based occurrence among identical normalized paths.
- `size` / `hasSize`: uncompressed size from the listing when available.
- `modifiedAt` / `hasModifiedAt`: listing timestamp when available.
- `isDirectory`: explicit directory entry.
- `hasSafePath`: false for absolute paths, traversal components, NUL bytes,
  or drive-qualified names.
- `hasDuplicateName`: another entry has the same identity.

Identity is normalized path plus occurrence, not the raw display name. Literal
`!` characters are escaped as `!!` in stored virtual paths; `!/` introduces an
archive member and `!~N` a duplicate occurrence.

## Shallow Scans

A shallow scan uses `getEntryDescriptors()` and does not extract member bytes.
It records:

- member names and safe normalized paths,
- uncompressed sizes when the listing supplies them,
- member timestamps when the listing supplies them.

ZIP, TAR, RAR, and 7z all provide size and timestamp metadata from their
listings. Timestamps are normalized to `YYYY-MM-DDTHH:MM:SS`; formats that do
not expose seconds use `:00`.

Shallow scans never calculate member checksums, file types, or MediaInfo. An
`ArchiveSpec` with empty or zero values can therefore mean "listed but not
deeply inspected", not necessarily an empty member.

## Deep Scans

A deep scan extracts member bytes and records:

- MD5, SHA1, and XXH64 digests,
- optional file type and MediaInfo,
- optional nested archive indexes, up to the configured depth.

By default the scanner extracts one archive once into a bounded staging tree,
hashes the members from that tree, and removes the tree when the archive is
done. This is the **bulk extraction** path. If bulk extraction is unavailable
or unsafe, the scanner falls back to the shared member-content cache and
extracts one member at a time.

The extracted files are scratch data: staging and cache paths are never stored
as catalog references. Damaged or non-extractable members remain in the index
without a deep fingerprint. Cancellation aborts the currently running archive
after the member in flight. Members completed so far are stored as a resumable
partial index, and the next run continues at the first unprocessed member.
Bulk extraction stops its external archive tool when cancellation is requested.

### Bulk Extraction

Bulk extraction avoids one archive-tool process per member and avoids
re-decompressing sequential streams from the beginning for every member. It is
especially effective for:

- compressed tar archives (`.tar.gz`, `.tar.xz`, `.tar.zst`, and aliases),
- solid RAR archives,
- solid 7z archives,
- archives with many small members.

Policy:

- `--archive-bulk=auto` (default) bulk-extracts archives with at least two
  file members and known sizes. Archives with unsafe member paths, unknown
  member sizes, or no member bytes stay on the per-member path.
- `--archive-bulk=always` bulk-extracts every eligible archive regardless of
  member count.
- `--archive-bulk=never` keeps the per-member cache path for every archive.

The staging area is a session directory below the system temporary directory,
or below `--archive-staging-dir`. Its default limit is half of the currently
available space, capped at 16 GiB. `--archive-staging-size MiB` sets an
explicit limit. A reservation is rejected when the declared member sizes plus
slack exceed the limit or half of the current free space.

If the whole archive does not fit, extraction falls back to bounded chunks
instead of one member per process. A chunk contains at most 512 member names
and targets a configurable uncompressed size. The adaptive target is one
quarter of the staging limit, capped at 4 GiB; `--archive-chunk-size MiB`
selects an explicit target. Each chunk is extracted once, hashed member by
member, and removed before the next chunk starts. Solid RAR/7z archives and
compressed tar archives benefit most because process startup and repeated
decompression are amortized across the chunk.

Duplicate-name members, symlink members, and members that are missing from the
staged tree are not read from bulk extraction. They use the per-member cache
fallback, which preserves occurrence selection and the symlink guard.

### Partial and Resumed Member Scans

A cancelled deep scan stores the members it already completed together with a
`partial` archive state and a resume cursor. Chunked scans resume at the first
member of the unfinished chunk; completed chunks are never extracted again. The next deep scan lists the
archive again, skips descriptors before the cursor, and continues with the
remaining members. For SQLite repositories this state lives in
`metadata_status`; JSON v5 stores the optional `archiveScanCursor` field.
Already completed members are not extracted or hashed again.

The preview path does not use bulk staging. It keeps using the member cache,
so a future GUI prefetch feature can reuse the same cache API without coupling
previews to scanner staging.

The CLI closes the staging session after its workers stop. A crashed or killed
process may leave a `session-*` directory behind; the next process removes it
after acquiring the session lease.

### Compressed TAR Variants

Recognized suffixes include `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz2`/`.tbz`,
`.tar.xz`/`.txz`, `.tar.zst`/`.tzst`, `.tar.lz`/`.tlz`, `.tar.lzma`, and
`.tar.Z`/`.taz`. The corresponding decompressor (`gzip`, `bzip2`, `xz`,
`zstd`, `lzip`/`lzma`, or `compress`) must be available to `tar`. If the local
`tar` build does not support a compressor, the adapter reports
`ArchiveToolException` for that archive and the scanner records a per-item
failure instead of aborting the run.

## Tool Output and Fallbacks

- Names are taken from a names-only listing where possible (`unzip -Z1`,
  `tar -tf`, `unrar lb`, `7z l -ba`).
- ZIP and TAR pair those names with rows from a second verbose listing; if the
  row count differs, descriptors fall back to names without metadata.
- Listing commands use a stable numeric locale so date and size columns do not
  drift: `LC_ALL=C` for `unzip`, `tar`, and `7z`; a UTF-8-capable C locale
  (`C.UTF-8`/`C.utf8`, probed once) for `unrar`, whose member-name output
  follows the console encoding and would otherwise lose every non-ASCII byte.
- ZIP duplicate names and glob-like member names use index-based extraction
  through Python `zipfile` when `python3` is available.
- RAR and 7z cannot select duplicate-name occurrences; those entries remain
  without deep fingerprints.

## Safety

- `normalizeArchiveEntryPath()` rejects absolute paths, `..`, NUL bytes, and
  drive-qualified names.
- Listing commands receive absolute archive paths; extraction commands use an
  explicit `--` end-of-options marker where the tool supports it.
- The member-content cache and the bulk staging reader reject symbolic-link
  members and never follow a link target as member content. This protects the
  scanner and preview paths; direct `FileArchive` consumers must still treat
  extraction as untrusted input.
- Bulk extraction is disabled for archives that declare unsafe member paths.
  After extraction, each candidate path is checked component by component for
  symlinks and must resolve to a regular file inside the staging tree.
- Archive passwords are passed through the adapter API and are not persisted
  in logs.

## Tests

Adapter tests cover:

- descriptor normalization, duplicate occurrences, and unsafe paths,
- ZIP/TAR/7z shallow sizes and timestamps,
- shallow persistence in the blob model without fabricated checksums,
- option-like member names, duplicate ZIP occurrences, and wildcard names,
- RAR listings and extraction preserving heavy UTF-8 member names,
- plain RAR archives staying indexed by the deep archive scan,
- bulk extraction for ZIP, TAR, RAR, and 7z,
- bulk policy selection, staging budgets, and reservation cleanup,
- symlink rejection in the shared cache and the bulk staging reader.

Run the focused tests with:

```bash
dub test --compiler=ldc2 -- -i archive
```

Run the complete backend gate with:

```bash
DC=ldc2 ./scripts/test.sh
DC=ldc2 ./scripts/lint.sh
```
