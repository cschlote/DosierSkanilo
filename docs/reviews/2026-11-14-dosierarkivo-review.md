# Package Review - dosierarkivo - 2026-11-14

- Repository: `DosierSkanilo`
- Version reviewed: unreleased `main` after `26.16.0`, base commit `66be250`
- Scope: `source/dosierarkivo` (`archive.d`, `factory.d`, ZIP/TAR/RAR/7z
  adapters, test support) and its integration with blob metadata extraction
- Method: source reading, real tool probes (`unzip`, `tar`, `unrar`, `7z`),
  focused adapter tests, and the full backend test gate

## Summary

The package is in good shape after the previous security hardening: member
operands are passed after end-of-options markers, archive paths are normalized,
tool failures are typed, and the shared member cache rejects symbolic links.
No Critical finding remains.

The main functional gap was shallow metadata: ZIP, TAR, and 7z exposed only
member names, so a shallow scan could not populate member size or timestamp.
That gap is fixed in this review cycle. RAR already supplied the metadata.

## Findings

### Fixed in this cycle

#### A1 - Shallow ZIP/TAR/7z descriptors lacked size and timestamp

`ArchiveEntryDescriptor` already carried `size`, `hasSize`, `modifiedAt`, and
`hasModifiedAt`, and `updateArchives()` persisted those fields for shallow
entries. Only RAR populated them. ZIP, TAR, and 7z built descriptors from
names-only listings.

Fix: each adapter now pairs names from its names-only listing with a verbose
listing:

- ZIP: `unzip -Z1` names plus `unzip -l` size/date/time rows.
- TAR: `tar -tf` names plus `tar --full-time --numeric-owner -tvf` rows.
- 7z: one `7z l -ba` listing parsed into names, sizes, and timestamps.

Names remain authoritative from the names-only listing, so spaces and symlink
decorations such as `-> target` cannot shift the descriptor identity. If the
row count differs, the adapter falls back to names-only descriptors.

#### A2 - Descriptor finalization was duplicated

The occurrence, path normalization, and duplicate-name calculation lived in the
base `getEntryDescriptors()` and would have been copied into every adapter.
They now live in `FileArchive.finalizeDescriptors()`. The base class and the
ZIP, TAR, and 7z adapters use the same implementation.

### Remaining Minor findings

#### R1 - RAR duplicate-name metadata is keyed by name

`rararchive.d:87-93` builds a `Metadata[string]` map and looks it up by
`entry.name` at `:132`. Duplicate names with different sizes or timestamps
therefore share the last metadata row. RAR cannot select duplicate occurrences
for deep extraction, but shallow sizes/timestamps can still be misleading.

#### R2 - ZIP long-list fallback still strips whitespace

The primary `unzip -Z1` path preserves names. When it fails,
`parseUnzipLongListOutput()` uses `m.captures[1]` and cannot preserve leading or
trailing spaces in member names. This only affects the fallback path.

#### R3 - 7z leading whitespace in names is ambiguous

`sevenziparchive.d:65-75` uses `\s+` before `(.+)`; leading spaces in a member
name are consumed as column separators. Trailing spaces are preserved. The
format's line-oriented listing is the limiting factor.

#### R4 - Descriptors do not classify link entries

`ArchiveEntryDescriptor` has `isDirectory` but no link kind. Direct
`FileArchive` consumers can therefore extract a symlink member; the scanner and
preview paths are protected by the central `MemberContentCache` symlink guard.
A package-level API consumer must apply its own guard.

#### R5 - Names and metadata come from two listings for ZIP/TAR

If the archive changes between the names-only and verbose listings, the row
counts can differ. The adapters fall back to names-only descriptors instead of
mispairing rows, but metadata may then be absent for that scan.

#### R6 - Listing failures are not fully uniform

ZIP and 7z generally return an empty listing on a non-password tool failure;
TAR and RAR throw `ArchiveToolException`. The scanner's per-item isolation
handles both, but direct callers see different contracts.

## Strengths

- Path normalization rejects absolute paths, traversal, NUL bytes, and
  drive-qualified names.
- Member operands after `--` close the option-injection path.
- Listing commands use absolute archive paths and `LC_ALL=C` for stable
  columns.
- ZIP wildcard/duplicate names use index-based extraction when Python is
  available.
- Password failures are typed and retry-bounded at the blob layer.
- Nested archive scanning is bounded by depth and reuses the leased member
  cache.
- Shallow scans do not fabricate checksums; deep scans own that work.

## Verification

- New tests cover ZIP, TAR, and 7z shallow size/timestamp descriptors and
  shallow persistence without fabricated checksums.
- Existing tests cover option-like names, duplicate ZIP occurrences, wildcard
  names, path normalization, and symlink rejection in the cache.
- Full backend gate: see `docs/development/testing.md`.
- Tool probes used `LC_ALL=C` to verify the parsed listing formats.

## Follow-ups

- Harden RAR duplicate-name metadata pairing and the ZIP fallback whitespace
  parser.
- Consider adding an explicit link-kind field to the package descriptor and
  rejecting links in `FileArchive.extractEntry()` for direct consumers.
- Keep the shallow/deep matrix in
  [`../ARCHIVE-SUPPORT.md`](../ARCHIVE-SUPPORT.md) in sync with adapter changes.
