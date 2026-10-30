# Code Review Report - 2026-10-28

- Repository: `DosierSkanilo`
- Version reviewed: unreleased `main` head, commit `f67309d`
  (merged branch `feature/wp-13.6.1-cli-references`, library version `26.12.2`)
- Branch: `main`
- Scope: library, domain model, JSON and SQLite backends, repository layer,
  CLI, archive adapters, metadata extraction, archive-member content cache,
  operation layer, scripts, CI, packaging
- Method: manual reading and four parallel read-only audits of the
  operation/backend, CLI/scripts, archive/metadata, and model/repository
  layers, followed by source-side verification of every Major finding raised
  by the audits

## Summary

The tree is in the best condition of the three reviews so far. All Critical
and Major findings of the 2026-10-24 review (C1, C2, M1-M8) are fixed with
regression tests, the CLI gained the WP-13.6.1 reference features
(`list`/`duplicates`/`export --path`/`info`, `--archive-cache-dir`,
`--pretty`), and the recent virtual-archive-member metadata skipping is
correctly implemented, including canonical `!!` escaping round-trips.

The new findings are concentrated in error isolation and cache lifecycle:

1. A single bad file (corrupt archive, malformed torrent) aborts the whole
   JSON metadata batch because the threaded path propagates the first
   `Exception` (M1).
2. `MemberContentCache` forgets lease accounting for a stale entry and its
   `close()` can delete the session tree under an outstanding lease path (M2).
3. `MediaInfoSig` parsers append null stream objects that crash
   `toString()`, `opEquals()`, and `dup()` far from the parse point (M3).
4. The public free function `loadCatalogQueryPageWithIdsFromDatabase()`
   crashes with `RangeError` for `limit == 0` + cursor paging (M4).
5. `getExistingFiles()` de-escapes physical `!!` names and legacy scanning
   writes that corruption back, orphaning scans of `!`-named files (M5).

No new Critical findings. All prior items are either fixed (with tests) or
carried over below with their residual status.

### Verification status

- Full test run: `DC=ldc2 ./scripts/test.sh` green - `180 passed`,
  `0 failed`, CLI integration checks passed, `89.46%` line coverage.
- Every Major finding in this report was re-read in the source at `f67309d`;
  line numbers refer to that commit and may drift after changes.
- Prior-findings status is based on code reading, not on rerunning the
  2026-10-24 targeted probes.

Severity scale: **Critical** = data loss, security compromise, memory
unsafety, or silent corruption. **Major** = incorrect observable behavior,
scalability failure, release failure, or missing protection on a reachable
path. **Minor** = limited impact, robustness, maintainability, or
documentation.

## Critical

None. Option injection via archive member names (prior C1) is fixed: all four
adapters now pass member names after an explicit `--` end-of-options marker
(`tararchive.d:44`, `:63-66`, `ziparchive.d:111`, `rararchive.d:45`,
`sevenziparchive.d:64-65`) and each has a `--to-command`-style regression
test asserting no command runs.

## Major

### M1 - JSON metadata batch aborts the whole run on the first per-blob error

`source/dosierskanilo/service/jsonoperations.d:483-531` (`runJsonMetadataWork`),
`:568-590` (`runJsonMetadataBatch`)

The threaded batch propagates the first worker exception:

```d
foreach (worker; tasks)
    worker.workForce();   /* first Exception escapes */
```

`runJsonMetadataWork` calls `updateArchives` without a per-item `try`/`catch`.
A corrupt ZIP whose `unzip -l` fallback also fails, a deep-extraction tool
failure (`ArchiveToolException` from `ziparchive.d:115`, `tararchive.d:46`,
`rararchive.d:49`, `sevenziparchive.d:69`), or an encrypted archive with no
password callback (`ArchivePasswordRequiredException`) therefore aborts the
entire `scan`/`analyze`. The single-threaded branch (`:570-574`) has the same
gap, and the threaded `finally { pool.finish(true); pool.stop(); }` discards
every other pending result. The repository metadata path already records
per-item failures (`repository/metadata.d`); the JSON path does not, so no
partial summary or progress is persisted.

Impact: one hostile file turns a full scan of thousands of good files into an
aborted run with no failure record - the same user-visible class as the fixed
prior M4, now on the JSON scan path.

Fix: catch `Exception` per `runJsonMetadataWork` item, count it into a
metadata summary (`itemsFailed`), mirror the repository path, and only let
cancellation-related exceptions pass. Add a regression test with one corrupt
archive among good files.

### M2 - Member cache loses lease accounting for stale entries

`source/dosierskanilo/membercontentcache.d:213-223` (acquire), `:318-332`
(`close`), `:340-352` (`release`)

If a cached member file disappears externally while it is leased:

```d
cachedBytes -= entry.size;
membersByKey.remove(key);
if (entry.leaseCount == 0)
    removeDirectory(entry.directory);
```

the entry is dropped from `membersByKey`, so its `leaseCount` is forgotten.
`release(key)` then finds nothing to decrement, and the `close()` guard
`enforce(!entry.materializing && entry.leaseCount == 0)` never sees the
orphaned lease. `close()` proceeds to `removeDirectory(sessionRoot)` - the
directory tree that an outstanding `MemberContentLease.path` still points
into. A consumer holding the lease reads a vanished file mid-operation
(`RelativePathNotFoundException` inside an extractor run).

Impact: silent violation of the documented lease contract; crashes surfaced
far from the cause. Combined with the disposed-entry callable path this is
the remaining lifetime defect of the member cache (prior Minor, now sharper).

Fix: keep disposed-but-leased entries in the map with a `stale` flag so both
`release()` and `close()` still observe their lease count, and make the
`close()` guard check a separate outstanding-lease counter. Add a test that
closes a cache while a lease on a removed member file is outstanding.

### M3 - Media info parsers append null stream objects; crashes surface far away

`source/dosierskanilo/metadata/mediainfosig.d:708-727` (parsing loop),
`:339-343` (`toString`), `:352-357` (`opEquals`), `:318-321` (`dup`)

Each `parse*Stream` helper catches internal failures and returns `null`, but
the callers append unconditionally:

```d
auto ms = parseAudioStream(info, i);
mediasigs.audioStreams ~= ms;   /* null appended */
```

A `MediaInfoSig` can therefore contain `null` audio/video/image/text entries.
Every later `toString()`, `opEquals()`, or `dup()` dereferences them. The
worst reachable path is duplicate analysis:
`mergeDataClassObjects()` (`namedbinaryblob.d:2524-2617`) compares signatures
with `==`, so a null-entry signature makes the comparison crash instead of
raising the intended `Mismatching MediaInfoSig`, and the JSON metadata run of
M1 loses its only isolation by crashing with an `Error` instead of throwing
an `Exception` that could be caught.

Impact: a pathological media file triggers a segfault-grade crash in merge,
export, or summary printing instead of a failed metadata item. Only media
files that pass `getCount` while individual stream parsing fails are affected,
which is rare but real (the helpers exist precisely to tolerate those).

Fix: skip null stream results (`if (ms) arr ~= ms;`) or discard the whole
signature when a stream fails; keep `opEquals` null-safe on both sides. Add a
test driving `parseAudioStream` into its catch path and asserting later
`toString`/`opEquals`/merge do not crash.

### M4 - Public paging function crashes with `RangeError` for `limit == 0`

`source/dosierskanilo/repository/transfer.d:765-780`
(`loadCatalogQueryPageWithIdsFromDatabase`)

`Repository.command()`/`loadCatalogQueryPage*` enforce `limit > 0`
(`repository.d:330-354`), but the free function is public library API and
does not itself validate:

```d
if (options.useCursor && blobIds.length > options.limit)
{
    page.hasMore = true;
    page.nextCursor = blobIds[options.limit - 1];  /* limit == 0 -> RangeError */
```

A `RangeError` derives from `Error`, so no `catch (Exception)` in callers
intercepts it - the same process-abort class as prior M4.

Impact: any library caller using cursor paging with a computed (or user
supplied) `limit == 0` aborts the process instead of getting a typed
`RepositoryException`.

Fix: `enforce(options.limit > 0, ...)` with a typed repository exception, and
mirror the same guard inside the other public `*FromDatabase` functions that
use `options.limit - 1`. Add a limit-0 unit test.

### M5 - `getExistingFiles()` de-escapes physical `!!` names

`source/dosierskanilo/model/namedbinaryblob.d:504-531` (`getExistingFiles`);

`source/dosierskanilo/service/scanning.d:308-312`, `:332-335` (write-back)

For a non-virtual spec stored in canonical escaped form (`dir!!/sample!!.zip`),
`getExistingFiles()` replaces it with `new FileSpec(parsed.physicalPath, ...)`,
i.e. `dir!/sample!!.zip` - a stray unescaped `!` that no longer round-trips
through `parseArchiveVirtualPath()`. The virtual branch deliberately keeps the
original spec (comment at `:519-520`); the physical branch does not. Legacy
scanning then writes the damaged list back with `obj.fileSpecs =
existingFiles;`.

Impact: the next scan cannot match the damaged spec (`hasFileName` and the
`physicalPathForSpec` fallback both fail), so a duplicate blob is created for
the same file and the orphaned blob is left without digests, file type, or
media info. Today only the legacy `scanning.d` flow (v3 catalogs, still
publicly exported via `package.d:29`) triggers the write-back, hence Major
rather than Critical.

Fix: in `getExistingFiles()`, keep the original spec for non-virtual paths
exactly like the virtual branch does (or re-escape before constructing the
replacement). Add a round-trip test with `!` in the filename through the
legacy job runner.

### M6 - JSON backend directory counts still ignore the active catalog filter

`source/dosierskanilo/jsoncatalogbackend.d:1980-1986` (index build),
`:2134-2148` (`matchingDirectories`); fixed counterpart
`repository/transfer.d:249-261`

The 2026-10-24 Minor on directory `fileCount`/`aggregateSize` is now fixed on
the SQLite side (the JSON backend is rank-filtered in the SQL via
`directoryFileFilterSql(options)`). The JSON side still reports counts
precomputed at index-build time:

```d
directoryRows[parentIndex].fileCount++;
directoryRows[index].aggregateSize += row.size;
```

and `matchingDirectories()` returns those precomputed rows untouched, so any
active `CatalogFilter` has no effect on them.

Impact: a filtered JSON `listDirectories` reports counts and sizes that do
not match the listed rows, contradicting the contract documented at
`catalogbackend.d:441-442` ("matching", "Aggregate size of matching
descendant content"). Backend parity is lost exactly where the new reference
features depend on JSON/SQLite consistency.

Fix: recompute `fileCount`/`aggregateSize` per filter in `matchingDirectories`
(reusing `directoryHasMatch`), or relax the doc to state that JSON directory
counts are unfiltered. Add a JSON `listDirectories` filter-count parity test.

## Minor

- `source/dosierskanilo/repository/archiveindex.d:9-12`,
  `scanner.d:41`, `transfer.d:79`, `metadata.d:155-165` -
  `isVirtualFileReferenceSql()` classifies virtual references by textual
  `'!!' -> ''` replacement instead of the real grammar. It is sound for
  today's singly-escaped canonical paths (its own unittest covers
  `literal!!!/archive.zip`), but a doubly-escaped import or a future
  producer bug silently misclassifies references: scans, root aggregates, and
  drop-missing candidacy exclude them, a deleted physical file could stay
  `exists_on_disk = 1`. Prefer a stored `is_virtual` column or a SQL-side
  prefilter plus the parser.
- `source/dosierskanilo/repository/metadata.d:196-208`, `:349-361` -
  `updateRepositoryMetadata` runs `resolveArchiveMemberBlobLinks`,
  `deleteUnreachableBlobs`, and the unconditional `updated_at` bump via
  `scope (exit)` outside the per-blob transactions. A crash between the
  rewrites can leave transient unreferenced blobs (recoverable on the next
  run), and an absolutely no-op run still invalidates cursors. Consider a
  final transaction plus `analysisChanged`-style gating.
- `source/dosierskanilo/repository/metadata.d:74-797` vs `:218` - the
  uncontrolled parallel path adds `items.length` to `blobsVisited` while the
  single-thread path counts only loaded blobs; the summary overstates visited
  blobs when some failed to load.
- `source/dosierskanilo/service/storageio.d:41-61` - a deserialization
  failure under `--force` is treated like a missing file, silently replacing
  a truncated rich v5 catalog with a v3 skeleton. A hard-link backup exists,
  but its recovery path is not named in the message.
- `source/dosierskanilo/service/storageio.d:154-163`, `:179-207`;
  `repository/repository.d:209-219` - backup names (`getBackupFileName`,
  `backupDatabase()`) use second-resolution timestamps; two writes within one
  second abort the catalog write or import (`EEXIST`/`FileExistsException`).
  Append a counter or UUID.
- `source/dosierskanilo/model/namedbinaryblob.d:511-527` - for virtual specs
  `getExistingFiles()` checks only that the container exists, not that the
  member is in its index; combined with `updateTorrentInfo` this is
  correct-by-accident and deserves an explicit comment or index check.
- `source/dosierskanilo/model/namedbinaryblob.d:2016` -
  `auto filespecs = obj.fileSpecs.sort;` is dead code.
- `source/dosierskanilo/model/namedbinaryblob.d:2524-2617` -
  `mergeDataClassObjects()` takes `fileSpecsUseArchiveVirtualGrammar` from
  `objs[0]` only; mixing records with different grammar flags would merge a
  hybrid spec list. Unreachable today (merge requires identical SHA1).
- `source/dosierskanilo/service/jsonoperations.d:614-651` - a metadata
  batch (up to `threads * 4` blobs) drains fully before the next
  cancellation checkpoint, and the file-type/media/torrent phases do not
  receive the cancellation flag; responsiveness after Ctrl-C can lag by
  whole media-decode times. No data loss.
- `source/dosierskanilo/membercontentcache.d:167-173` - a second process's
  `cleanupStaleSessions` can see a freshly created `sessionRoot` before the
  module acquires its target lease and remove the live session directory;
  millisecond race window between parallel CLI invocations.
- `source/dosierskanilo/membercontentcache.d:459-470` -
  `configureSharedMemberContentCache()` swaps the process-wide cache without
  waiting on active users of the old one; `close()` under leases throws or
  (before M2) deletes leased trees. Document the serialization requirement or
  pool/ref-count the cache.
- `source/dosierskanilo/progress.d:138-165` - `makeProgressString` uses a
  shared unsynchronized `static int` spinner index and module-level rate-limit
  globals mutated by concurrent metadata workers, and formats `nan` for
  `total == 0`; cosmetic corruption only, but fix with thread-local state and
  a zero guard.
- `source/dosierskanilo/sqlitecatalogbackend.d` (`withRepository`) - does not
  translate stray `Error`s into typed backend exceptions, while claiming
  `capabilities().supportsConcurrentReads = true` while serializing all work
  on `synchronized (this)`. Fix the capability documentation or the enum
  value.
- `source/dosierskanilo/sqlitecatalogbackend.d:167`, `:239`,
  `:350-381` - offset pagers report `hasPrevious` for an empty EOF page and
  the archive-member path lacks the stable-snapshot `hasPrevious` semantics
  JSON's `pageSlice` has. Cosmetic asymmetry.
- `source/dosierskanilo/jsoncatalogbackend.d:688-710` -
  `contentTokenForBlobIndex()` does a linear scan per result row
  (`queryBlobs` page loop); build a `string[size_t]` inverse map at index
  rebuild time.
- `source/dosierarkivo/ziparchive.d:111`, `rararchive.d:44-45`,
  `sevenziparchive.d:62-64` - archive passwords pass via process argv
  (`-P`/`-p`) and are readable in `/proc/<pid>/cmdline` by local users while
  a scan runs. Low practical risk (catalog already stores passwords by
  design); consider env-var or pipe-based supply.
- `source/dosierarkivo/testsupport.d:46-52` - test temp dirs are removed in
  `scope (success)` only; failed tests leak them until the next tmp cleanup.
- `source/dosierskanilo/service/scanning.d` (whole file) - legacy module is
  dead code except for `package.d` re-export; remove or gate it explicitly.
- `source/dosierskanilo_cli/jsonvalidation.d:88-124` - JSON `list` and
  `duplicates` accept any `--format` value; non-`json` values print a table
  with headers ("silently ignore the format"), while the SQLite path
  rejects a bad format (`repositoryvalidation.d:74-80`). Align the JSON
  validation.
- `source/dosierskanilo_cli/main.d:446-456`, `:623-637`, `:745-764` -
  `--pretty` is a silent no-op for `info`, `list`, and `duplicates`
  (they always emit compact hand-built JSON), while it works for scan/analyze
  and export. Honor it or reject it on the query commands.
- `source/dosierskanilo_cli/main.d:709-713` - `--duplicate-limit 0` is
  rejected as a `CatalogBackendException` after the backend was opened,
  surfaced as `Catalog operation failed ...` with exit 1 instead of a usage
  error with exit 2. Validate it in `jsonvalidation.d`/
  `repositoryvalidation.d`.
- `source/dosierskanilo_cli/main.d:484-543`, `:719-743` - query commands
  load the entire filtered catalog into memory; `catalogHasPath` walks every
  file to ask a yes/no question, then `export --path` re-filters the same
  catalog on the backend. Add an early-exit existence query.
- `source/dosierskanilo_cli/main.d:664-683`, `:696` - on the legacy non-
  `supportsTreeQueries` JSON path, a `duplicates` group member missing from
  `pathByBlobId` prints `"name":"","path":""` instead of a warning.
- `source/dosierskanilo_cli/main.d:92-93`, `:116` - the exit-code contract
  (0 success, 1 operation failure, 2 usage) is undocumented in help text or
  `main()`'s doc comment.
- `scripts/test-cli.sh:6-9` - `ROOT_DIR="$(pwd)"` makes the script caller-CWD
  dependent; derive it from `$(dirname -- "$0")/..` (same pattern fixed in
  the 2026-10-24 `clean.sh` note).
- `scripts/lint.sh` - the markdown file list is hand-maintained (new docs are
  silently omitted) and `dub lint` runs without `--config=cli`.
- `dub.json:22-24` - the `preGenerateCommands` versions fallback works, but
  the POSIX `sed`/`mkdir` recipe fails under DUB's Windows cmd invocation;
  acceptable for POSIX packaging, worth a note in the packaging docs.
- `packaging/flatpak/org.dosierskanilo.DosierSkanilo.yml:25`, `:42`, `:59` -
  the source-archive `sha256` pins cannot be validated in-tree; confirm them
  against the published `v26.12.2` artifacts before the next release.

### Prior items resolved since 2026-10-24

All of the following were re-verified as fixed at `f67309d`:

- **C1** option injection via member names - all adapters pass member names
  after `--`, with regression tests for tar (`--to-command`), zip, rar, 7z.
- **C2** JSON rescan stale metadata - changed files now go through
  `clearJsonDerivedMetadata()` (`jsonoperations.d:260-270`), the multi-spec
  case splits into a fresh blob, test at `:362-394`.
- **M1** backslash filenames - `nativePathToStoragePath()` replaces `\`
  only under `version (Windows)` (`archive.d:97-105`); all three call sites
  converted, test in `scanner.d:520-538`.
- **M2** non-BMP archive members - all four SQLite range sites use the safe
  `prefix[0 .. $-1] ~ "0"` bound; regression test with `😀.txt` member at
  `transfer.d:1845-1884` and `scanner.d:291`.
- **M3** analysis cursor invalidation - `updated_at` is bumped inside the
  transaction gated by `analysisChanged()` (`analysis.d:204-206`,
  `:345-347`; test at `repository.d:1388-1392`).
- **M4** malformed torrents - every bencode key access guarded with typed
  exceptions, 64 MB size cap, `maxNestingDepth` 128 regression test
  (`torrentinfo.d:138-141`, `:664-676`).
- **M5** `mergeDataClassObjects()` - merges all fields from all inputs with
  conflict enforcement, tests at `:2693-2746` (residual: grammar flag from
  `objs[0]`, see Minor list).
- **M6** git-less archives build - `VERSION` file fallback in
  `preGenerateCommands` (`dub.json:22-24`).
- **M7** packaging recipes - all pinned to `26.12.2`; Flatpak manifest is a
  real `dub build` recipe; sha256 pins pending verification (Minor above).
- **M8** `!`-named containers - `virtualContainerPaths()` keys by the
  canonical escaped path (`scanner.d:425-433`); regression test at
  `scanner.d:278-309`.
- **prior Minors** - SQLite unknown-content-ID/invalid-cursor rejection now
  matches JSON (`sqlitecatalogbackend.d:272-287`, `:467-482`);
  `escapeLogValue` covers `\t` (other C0 controls remain, see Minor);
  member-cache collision key includes the member path (`:382-384`);
  password retry bounded at 3 attempts (`namedbinaryblob.d:2049-2069`,
  `:2147-2156`); `updateTorrentInfo` iterates all `.torrent` specs
  (`:2471-2491`); `deploy_staging` is manual (`main.yml:135`).

### New code sanity note (WP-13.6.1)

The virtual-archive-member skipping introduced in this cycle is correct:
`getFirstOpenableFileName()` (`namedbinaryblob.d:568-586`) only returns
existing physical paths, escaped `!!` container names round-trip correctly
(`:1664-1682`), pure-virtual blobs skip digests/file type/media info
(`:812-855` regression tests), repository metadata excludes all-virtual
blobs (`metadata.d:148-170`), and member digests are filled by the archive
index path (`persistArchives`, `metadata.d:1065-1219`). Blob-level digests
for pure-virtual blobs are intentionally provided only via the container's
`ArchiveSpec.checkSums`, so JSON duplicate analysis excludes them - consistent,
but worth documenting when the analysis contract is written down.

## Strengths

- **Security posture.** Option injection closed at every adapter with tests;
  path normalization rejects traversal, absolute paths, NUL, drive letters;
  passwords are at least bounded in retry count.
- **SQL safety.** No string interpolation of user data into SQL found in the
  re-audited paths; only internal enum fragments are concatenated, and the
  one `PRAGMA user_version = N` statement uses an internal integer.
- **Transaction hygiene.** Migrations, staged scans, metadata persistence,
  and analysis use atomic transactions with rollback and cancellation
  checkpoints; import keeps the whole replacement atomic.
- **Operation layer.** `operations.d` state transitions are closed and race
  free; `operationlease.d` flock semantics (catchable `OperationTargetBusyException`,
  idempotent `release`, fork-based cross-process test) remain solid.
- **Tests and process.** 180 unit tests plus full CLI integration green at
  89.46% coverage; every prior fix carries its regression test; backend
  parity is now explicitly tested for unknown IDs and cursor bounds.

## Recommended remediation order

**Wave 1 - error isolation and data availability.** M1 (JSON per-blob error
handling), M2 (cache close under lease), M3 (null media streams), with the
regression tests named in each item. M1 and M3 combine into the worst
reachable crash path (first finding in a review run aborts everything;
second turns a recoverable exception into an abort).

**Wave 2 - API correctness.** M4 (typed `limit` enforcement), M5
(`getExistingFiles` escape round-trip), M6 (JSON directory filter counts),
plus the `archiveindex.d` classification follow-up.

**Wave 3 - robustness and UX.** The Minor list: storage backup collisions,
cancellation checkpoints in JSON metadata batches, progress-thread safety,
JSON `--format`/`--pretty` validation, `duplicate-limit` usage error, query
memory usage, script portability items, packaging sha256 verification.

## Open follow-ups (updated)

- [ ] Add a JSON metadata regression test with one corrupt archive among
      good files; expected: failed item counted, run completes (M1).
- [ ] Add a member-cache test closing the cache while a lease on a removed
      member file is outstanding (M2).
- [ ] Add a malformed-media-file test where `parse*Stream` returns null and
      assert `toString`/`opEquals`/merge do not crash (M3).
- [ ] Add limit-0 cursor paging tests for every public `*FromDatabase`
      function using `options.limit - 1` (M4).
- [ ] Add a `!!` filename round-trip test through the legacy scanner path
      (M5).
- [ ] Add a JSON `listDirectories` filter-count parity test (M6).
- [ ] Verify all release checksums referenced by the Flatpak manifest
      against the published `v26.12.2` tag artifacts before the next
      release.
- [ ] Decide on the legacy `scanning.d` module: delete it or gate its
      fileSpecs write-back behind the M5 fix.
