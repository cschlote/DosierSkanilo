# Archive Support

This document describes the `dosierarkivo` package: supported formats, the
descriptor model, shallow and deep scans, tool requirements, and the safety
boundaries of member extraction.

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

A deep scan extracts each member through the shared member-content cache and
records:

- MD5, SHA1, and XXH64 digests,
- optional file type and MediaInfo,
- optional nested archive indexes, up to the configured depth.

The extracted files are scratch data: cache paths are never stored as catalog
references, and the cache session removes them when closed. Damaged or
non-extractable members remain in the index without a deep fingerprint.
Cancellation finishes the currently running archive jobs, commits their
complete results, and stops before starting new ones.

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
- Listing commands use `LC_ALL=C` so date and size columns are stable.
- ZIP duplicate names and glob-like member names use index-based extraction
  through Python `zipfile` when `python3` is available.
- RAR and 7z cannot select duplicate-name occurrences; those entries remain
  without deep fingerprints.

## Safety

- `normalizeArchiveEntryPath()` rejects absolute paths, `..`, NUL bytes, and
  drive-qualified names.
- Listing commands receive absolute archive paths; extraction commands use an
  explicit `--` end-of-options marker where the tool supports it.
- The member-content cache rejects symbolic-link members and never follows a
  link target as member content. This protects the scanner and preview paths;
  direct `FileArchive` consumers must still treat extraction as untrusted
  input.
- Archive passwords are passed through the adapter API and are not persisted
  in logs.

## Tests

Adapter tests cover:

- descriptor normalization, duplicate occurrences, and unsafe paths,
- ZIP/TAR/7z shallow sizes and timestamps,
- shallow persistence in the blob model without fabricated checksums,
- option-like member names, duplicate ZIP occurrences, and wildcard names,
- symlink rejection in the shared cache.

Run the focused tests with:

```bash
dub test --compiler=ldc2 -- -i archive
```

Run the complete backend gate with:

```bash
DC=ldc2 ./scripts/test.sh
DC=ldc2 ./scripts/lint.sh
```
