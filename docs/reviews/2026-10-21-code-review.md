# Code Review Report - 2026-10-21

- Repository: `DosierSkanilo`
- Version reviewed: `26.11.3` (tag `v26.11.3`, commit `ca305be`)
- Branch: `testing`
- Scope: library, CLI, SQLite repository, JSON backend, archive adapters,
  CI scripts, documentation
- Method: manual reading plus targeted verification of the highest-impact
  findings

## Summary

The code base is well structured for its age and size. The domain model is
consistent, the SQLite layer uses parameterized statements, the migrations are
atomic, and the operation API cleanly separates the CLI and GTK frontends. The
documentation is unusually complete.

The main risks are not in the everyday query paths but in the failure and
recovery paths:

1. Two startup/write paths can destroy catalog data instead of preserving it
   (C1, C5).
2. A cancellation handle is bound to stack storage that outlives its owner
   (C2).
3. Duplicate merging silently discards metadata and archive passwords that
   belong to the dropped blob (C3).
4. Several runtime validations use `assert`, which disappears in `-release`
   builds and raises an `Error` - not an `Exception` - in debug builds, so the
   surrounding recovery code does not run (C4, M10, M13).

Beyond that, the JSON and SQLite backends diverge in backwards paging, which
contradicts the documented JSON/SQLite parity, and several SQL paths are
quadratic in the catalog size.

### Verification status

- Build: `DC=ldc2 dub build --config=cli` succeeds.
- Unit tests: **not executed** in this review session. The reviewed tree is
  clean and the last recorded CI run is green, but the findings below should be
  confirmed by `dub test` plus the specific regression tests suggested in each
  item.
- Findings C1, C2, C3, C4, C5 and M1 were re-read and confirmed directly in the
  source. Line numbers refer to commit `ca305be` and may drift after changes.

Severity scale: **Critical** = data loss, memory unsafety, or silent
corruption. **Major** = incorrect observable behavior, scalability failure, or
missing protection on a reachable path. **Minor** = limited impact, robustness,
or maintainability.

## Critical

### C1 - Restore path deletes the backup and loses the whole catalog

`source/dosierskanilo/service/storageio.d:215-227` (with `:175-203`)

`makeBackupFile()` prefers `rename()`. When the rename fails it falls back to
`copy(original, backup); remove(original);`. In that state the original no
longer exists. If serialization then fails, `restoreOriginalFile()` takes the
`mustCopy` branch and runs `remove(newname)` - it deletes the *only* remaining
copy.

Impact: the exact failure the backup is meant to protect against destroys the
catalog. Both the catalog and its backup are gone.

Fix: in the `mustCopy` branch restore the data (`copy(newname, jsonFile)` or
`rename` when possible) and remove the backup only after a successful restore.
Add a regression test that forces the copy path and a serialization failure.

### C2 - Cancellation mirror points to dead stack storage

`source/dosierskanilo/service/jsonoperations.d:439-441` and `:578-580`,
`source/dosierskanilo/operations.d:267-277`, `:290-298`

`updateJsonMetadata()` and `analyzeJsonRecords()` declare a function-local
`shared(bool) cancellationFlag` and call
`control.bindCancellationMirror(&cancellationFlag)`. `OperationControl` stores
the raw pointer and has no unbind API. After the function returns, a later
`requestCancellation()` executes `atomicStore(*cancellationMirror, true)`
through that dangling pointer.

Impact: silent memory corruption whenever cancellation arrives after the
metadata/analysis phase has returned, for example during the JSON commit
window. The `bindCancellationMirror` doc comment already requires the storage
to outlive the operation; the caller violates that contract.

Fix: let `OperationControl` own the mirror storage (an internal
`shared bool mirrorStorage` plus a `bindCancellationMirror()` that takes no
pointer), or add `unbindCancellationMirror()` and call it from a `scope(exit)`
in both functions.

### C3 - Duplicate merge drops metadata and archive passwords of the loser

`source/dosierskanilo/repository/analysis.d:185-187`, with the foreign keys in
`source/dosierskanilo/repository/schema.d:60-149`

The merge repoints `file_refs` from `dropId` to `keepId` and then runs
`DELETE FROM blobs WHERE id = ?`. Every dependent table
(`torrent_info`, `archive_passwords`, `metadata_status`, the four `media_*`
tables) uses `ON DELETE CASCADE`, so the dropped blob's metadata is deleted.

The scanner creates one blob per file and does not deduplicate, so two
identical files usually have two blob ids and only one of them may have been
scanned. After `analyze` (duplicate merging is on by default) the surviving
blob can therefore lose its torrent info, media info, or the archive password
the user stored for that archive - without any error.

Fix: migrate dependent rows to `keepId` before deleting `dropId`
(`INSERT OR REPLACE ... SELECT keepId, ... WHERE blob_id = dropId`), or delete
the dependents explicitly after the merge instead of relying on the cascade.

### C4 - `fileSpecs[0]` without length check in the serialization fixup

`source/dosierskanilo/model/namedbinaryblob.d:1019-1031`

```d
if (obj.fileSpecs.length > 1) { ... }
else {
    obj.fileName = obj.fileSpecs[0].fileName; // RangeError for length == 0
```

`fileSpecs` is empty for any blob that was invalidated
(`invalidateDataClassObjs`)
or that came from a record without `fileName`/`fileNames`. `RangeError` derives
from `Error`, so the `catch (Exception)` in `writeStorageJsonFile`
(`storageio.d:333`) does **not** catch it: the process aborts after the original
catalog has already been renamed away.

Fix: handle `fileSpecs.length == 0` explicitly (clear `fileName` and
`timeLastModified`), and replace the `assert` on the next line with a real
check.

### C5 - `--replace` turns any read error into an empty catalog

`source/dosierskanilo/service/jsonoperations.d:140-148`

```d
catch (Exception ex) {
    if (!forceOverwrite) throw ex;
    return NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, []);
}
```

`forceJsonOverwrite` is documented as "continue with an empty catalog if an
existing JSON input is malformed", but this branch catches *every* exception:
I/O errors, `OperationCallbackException` raised by a progress callback, and
out-of-memory situations. With `--replace`, any of those silently discards the
existing catalog.

Fix: rethrow `OperationCallbackException` and non-parse exceptions unchanged;
only treat JSON syntax errors as "malformed".

## Major

### M1 - JSON `previousFilesPage` returns the next page

`source/dosierskanilo/jsoncatalogbackend.d:227-231` versus
`source/dosierskanilo/sqlitecatalogbackend.d:210-237`

The JSON implementation of `previousFilesPage` is a literal copy of
`nextFilesPage`; the cursor index is treated as an absolute offset. The SQLite
implementation treats the cursor as a pivot and returns the rows *before* it.
For rows `f0,f1,f2` and `limit=1`, calling `previousFilesPage` with the cursor
of page 2 returns `f2` (JSON) but `f1` (SQLite).

Impact: the README and `docs/OPERATION-PARITY.md` promise forward/backward
paging parity; the JSON backend violates the documented
"Continue backward" contract of `catalogbackend.d:697-700`.

Fix: step the JSON offset back by the page size (or make the JSON cursor a
pivot like SQLite) and add a parity test that pages backwards through both
backends.

### M2 - Metadata persistence has non-transactional paths

`source/dosierskanilo/repository/metadata.d:172-297`, `:681-740`

The controlled path wraps persistence in `BEGIN`/`COMMIT`. The serial
`updateRepositoryMetadata()` and the parallel `processMetadataBatch()` do not.
`persistMediaInfo` deletes five tables and re-inserts, `persistArchives` deletes
stale member references, and `persistTorrentInfo` deletes and re-inserts - all
without a transaction. A failure leaves a half-written blob.

`processMetadataBatch` also lacks the `try/finally` that guards the task pool in
`runControlledMetadataBatch` (`:434-449`); an exception leaks worker threads.

Fix: wrap each blob's persistence exactly like the controlled path and put the
pool into `scope(exit)` / `try-finally`.

### M3 - Per-file full-table scans inside the scan transaction

`source/dosierskanilo/repository/scanner.d:170`, `:188-199`, `:214-233`, `:342`

`updateVirtualReferencesAvailability()` runs a non-sargable full scan of
`file_refs` and parses every row. It is called once per scanned file while the
write transaction is open. `deleteUnreachableBlobs()` and
`deleteVirtualDescendants()` add further table-wide statements per changed file.
With `F` files and `V` archive members this is `O(F * V)` with the write lock
held for the whole phase.

Fix: build the virtual-to-physical mapping once per scan (temp table or a
persisted `is_virtual` flag), and run orphan cleanup once after
`applyStagedFiles`/`applyStagedMissing` instead of per file.

### M4 - `COALESCE` disables the directory index

`source/dosierskanilo/repository/transfer.d:239-252`

`COALESCE(f.directory_id, 0) = :directory_id` prevents SQLite from using
`idx_file_refs_directory`; the query plan degrades to a covering-index scan of
all of `file_refs`. Every file listing scans the whole catalog.

Fix: use `f.directory_id IS :directory_id`, or split into an `IS NULL` and an
`= ?` branch.

### M5 - Archive listing and blob pages execute far too many statements

`source/dosierskanilo/repository/transfer.d:463-465`, `:565-594`, `:713-783`

`listArchiveEntriesFromDatabase` selects the entire catalog and filters in
memory for a per-archive UI call. Per catalog page, the code calls
`loadBlobDetailsFromDatabase` (about eleven statements) *and* `loadBlobFlags`
(nine single-row `SELECT 1` statements) for every blob, so a 250-row page
issues roughly 5000 statements.

Fix: restrict the archive query with a range predicate on `relative_path`, and
compute details and flags set-based for the whole page.

### M6 - Correlated `LIKE` aggregates per directory

`source/dosierskanilo/repository/transfer.d:144-147`, `:170-182`

Directory sizes are computed with `f.relative_path LIKE d.relative_path || '/%'`
per directory row. `LIKE` cannot use the index while `case_sensitive_like` is
off, so this is `O(dirs * refs)` per page. `loadRootSummaryFromDatabase` rescans
all references on every call.

Fix: pre-aggregate once, or use a range predicate
(`relative_path >= prefix AND relative_path < prefix || '\uffff'`).

### M7 - Import/export bypass the write lease; backup is not a snapshot

`source/dosierskanilo/repository/repository.d:201-210`, `:235-254`

Scan, metadata and analysis take a `TargetWriteLease`, but `importJson` and
`exportJson` do not. `importJson` deletes the whole catalog while another
process may be committing. `backupDatabase` runs
`PRAGMA wal_checkpoint(TRUNCATE)` and then copies the database file; a live
SQLite database (including `-wal`/`-shm`) is not copied consistently.

Fix: acquire the repository lease in both entry points and create the backup
with `VACUUM INTO` or the SQLite online backup API.

### M8 - Legacy fixup drops modification timestamps

`source/dosierskanilo/model/namedbinaryblob.d:927-940`

When a legacy record carries both `fileName` and `fileNames`, the code clears
`obj.timeLastModified` in the `fileName` branch and then reuses it (already
`null`) for every `fileNames` entry. The timestamp is the identity the scanner
uses to detect changes, so those references look modified on every scan.

Fix: capture the timestamp into a local before clearing the field and use it in
both branches.

### M9 - Backslash rewriting corrupts POSIX filenames

`source/dosierskanilo/model/namedbinaryblob.d:566-567`, `:1228-1233`

`replace('\\', '/')` is applied unconditionally. On POSIX a backslash is a legal
filename character, so `media\disc1.mkv` is stored as `media/disc1.mkv` - a path
that does not exist. The record is then treated as orphaned and is dropped by
`--drop-missing`.

Fix: translate separators only under `version (Windows)`.

### M10 - `assert` used as runtime validation for untrusted input

`source/dosierskanilo/model/namedbinaryblob.d:827-830`, `:1103`, `:1122`,
`:1137`, `:2366`; `source/dosierskanilo/service/analyze.d:102`;
`source/dosierskanilo_cli/main.d:100`

These asserts guard JSON format/version checks, sort preconditions, and checksum
lookups. With `-release` the checks vanish, so a malformed or wrong-version
catalog is silently accepted. Without `-release`, an `AssertError` is an
`Error` and escapes every `catch (Exception)` in the write path.

`analyze.d:102` is worse: a null SHA1 becomes an associative-array key, which is
invalid for `string`-keyed maps.

Fix: use `enforce` or explicit exceptions for anything protecting data
integrity, and remove the unreachable `assert(false, ...)` branches.

### M11 - Integer overflow in the bencode parser aborts the scan

`source/dosierskanilo/metadata/torrentinfo.d:182`, `:206`, `:243`, `:409-421`

`pos + len` overflows when `len` is huge, so the `enforce(pos + len <= ...)`
check passes and the following slice raises `RangeError`. Signed lengths are
also cast to `ulong`, turning `-1` into about `1.8e19`.

Impact: a malformed `.torrent` file aborts the whole scan because `RangeError`
is not caught by `catch (Exception e)` in `updateTorrentInfo`.

Fix: `enforce(len <= data.length - pos, ...)`, validate the length prefix, and
`enforce(length >= 0, ...)` before casting.

### M12 - Data race in the legacy threaded scan path

`source/dosierskanilo/service/scanning.d:229-231`, `:270-307`

Tasks share one stack slot for the progress callback (the value is constant, so
this is benign today but fragile), and more importantly the collector thread
assigns `obj.fileSpecs = existingFiles` at `:272-273` while tasks queued for the
same blob at `:230-258` may still be reading or sorting `obj.fileSpecs`.
`NamedBinaryBlob` is not `shared`, and `FileSpec.exists()` caches into a plain
field from several threads.

`myTaskPool.finish/stop` are also skipped if `workForce()` rethrows.

Impact: `service.scanning` is exported from the public package facade
(`source/dosierskanilo/package.d:29`), so library consumers are affected even
though the CLI no longer uses this path.

Fix: collect results only after `finish(true)`, never mutate a blob while its
tasks are in flight, and wrap the pool in `scope(exit) { pool.stop(); }`.

### M13 - Archive adapters abort the scan on tool failure

`source/dosierarkivo/ziparchive.d:114`, `tararchive.d:44`,
`sevenziparchive.d:68`, `rararchive.d:36`

`assert(rc.status == 0, rc.output)` is runtime control flow. In debug builds a
single failed extraction raises `AssertError` and aborts the whole scan; in
`-release` builds the check disappears and the function returns `true` after a
failed extraction.

Fix: throw a typed exception (or return `false`) on tool failure.

### M14 - Scan aborts on filenames containing `!` in v5 catalogs

`source/dosierskanilo/service/scanning.d:110-112`

v5 stores `a!b.txt` escaped as `a!!b.txt`, but the scan compares the stored name
with the raw directory entry name via
`enforce(fspec.fileName == dirEntry.name)`.
The comparison fails and aborts the scan.

Fix: compare decoded physical paths (`physicalPathForSpec(fspec)`) instead.

### M15 - Archive members are treated as missing in the legacy JSON path

`source/dosierskanilo/service/scanning.d:272-273`, `:322-323` and
`source/dosierskanilo/model/namedbinaryblob.d:467-501`

`physicalPathForSpec()` returns `""` for a virtual path, so `exists("")` is
false. `getExistingFiles()` then returns an empty array, the scanner replaces
`fileSpecs` with it, and `isBlobOrphaned()` reports the record as orphaned. A
`--drop-missing` analysis deletes every archive-member record.

Fix: treat a virtual member as existing when its container exists (or when
`archiveIndexKnown` is set), and never replace `fileSpecs` with the
physical-existence filter for virtual-grammar blobs.

### M16 - SQLite cursors are not invalidated by metadata mutations

`source/dosierskanilo/sqlitecatalogbackend.d:731-734`, `:1156-1175`

The cursor token is bound to `repository.updated_at`, which the scanner bumps
but
the metadata path does not, although metadata inserts and deletes `file_refs`
rows for archive members (`repository/metadata.d:536`, `:573`, `:606`, `:612`,
`:1033`). A stale cursor is silently accepted and pages skip or repeat rows.
The JSON backend already uses an index generation for this.

Fix: bump `updated_at` on every committed metadata mutation, or derive the
version from a monotonic counter.

### M17 - `listArchiveMembers` loads a directory and one full blob per member

`source/dosierskanilo/sqlitecatalogbackend.d:318-357`

`query.limit = size_t.max` makes the repository query unbounded, and
`loadBlobDetails` runs per member only to compute a fingerprint.

Fix: use a bounded keyset page and select only the checksum columns.

### M18 - Member content cache deletes leased files and ignores the member path

`source/dosierskanilo/membercontentcache.d:148-167`, `:307-321`

When a cached file has disappeared, the entry and its directory are removed
even if `leaseCount > 0`, so the lease holder's path is deleted underneath it.
Separately, the cache key is the content id plus the file extension, so two
different members with identical content and extension share an entry and the
second caller receives the first member's file name.

Fix: defer deletion of leased entries until the last lease is released, and
include the normalized member path in the key.

### M19 - JSON scan writes unescaped `!` paths

`source/dosierskanilo/service/jsonoperations.d:189-207`

In the changed-file branch the old spec is deleted and the replacement blob is
created with the raw name. In v5 mode `!` must be escaped; the next load calls
`parseArchiveVirtualPath` and throws, making the catalog unreadable (and, with
C5, replaceable by an empty one).

Fix: use the escaped stored name consistently and set
`fileSpecsUseArchiveVirtualGrammar` on the replacement.

### M20 - JSON backend throws untyped exceptions during open

`source/dosierskanilo/jsoncatalogbackend.d:117-126`, `:962-1018`

`rebuildIndex()` runs outside the constructor's `try/catch`.
`parseArchiveVirtualPath` throws a plain `Exception` for a malformed path,
which escapes the factory instead of becoming a
`CatalogBackendException`.

Fix: wrap the index build and translate failures to typed backend errors.

### M21 - `duplicates` loads the entire catalog into memory

`source/dosierskanilo_cli/main.d:403-408`

`lookupQuery.limit = size_t.max` followed by `queryBlobs()` materializes every
blob to build `pathByBlobId`, for a command that only needs the paths of the
reported groups.

Fix: resolve paths only for the reported blob ids.

### M22 - Stale-session cleanup can delete a live cache session

`source/dosierskanilo/membercontentcache.d:115-121`, `:340-359`

The session directory is created before the lease is acquired, so another
process's cleanup can remove a freshly created session in that window.

Fix: acquire the lease first, then create the directory.

### M23 - A new repository connection per query

`source/dosierskanilo/sqlitecatalogbackend.d:708-724`

Every read opens and closes a `Repository`, so paging across many pages repeats
connection setup and version queries.

Fix: keep one connection for the backend lifetime and close it in `close()`.

### M24 - One malformed member digest aborts the metadata run

`source/dosierskanilo/repository/metadata.d:1001-1006`, `:1092-1097`

`Base64.decode` throws on invalid input and the exception escapes the persist
phase, rolling back and skipping every remaining blob. `memberBlobIdFor` can
also return `0`, which is then written as `blob_id` and violates the foreign
key.

Fix: treat decode failures as "no digest", and fall back to a digest-less blob
row as the schema migration already does (`schema.d:438-446`).

## Minor

### Model and metadata

- `model/checksums.d:88` - FNV-1a offset basis is `1469598103934665603`
  (missing a digit); the 64-bit value is `14695981039346656037`. Only affects
  hash distribution.
- `model/namedbinaryblob.d:311-332`, `:413` - the copy constructor copies the
  `fileSpecs` slice, so two blobs share one backing array; `~=` or `sort` on
  one mutates the other. Use `.dup`.
- `model/namedbinaryblob.d:2382` - `uniq` only removes adjacent duplicates, but
  the merged array is a concatenation of two sorted lists. Sort first.
- `model/namedbinaryblob.d:866-879` - `uniqDataClassArrayByFileName` depends on
  the current Phobos return value of `copy()`; older toolchains silently drop a
  record per duplicate group.
- `model/namedbinaryblob.d:2420-2426` - `cleanupInvalidatedDataClassObjs`
  removes *any* record without file specs instead of an explicitly invalidated
  one.
- `model/namedbinaryblob.d:1889-1905`, `:1952-1997` - the password retry loop
  has no bound and can spin forever.
- `model/namedbinaryblob.d:2302-2326` - `updateTorrentInfo` computes the
  `.torrent` file list and then iterates all specs, breaking on the first one.
- `metadata/digests.d:51-52` - the `File` handle is only released by the GC;
  a large scan can exhaust descriptors. A missing file throws.
- `metadata/digests.d:64`, `service/scanning.d:261`, `:300`, `:357` - plain
  reads of a `shared(bool)` instead of `atomicLoad`.
- `metadata/torrentinfo.d:151-154` - the info hash is computed from a re-encoded
  dictionary, not the original bencoded `info` bytes, which yields wrong hashes
  for non-canonical torrents.
- `metadata/torrentinfo.d:138` - the whole `.torrent` file is read into memory
  with no size cap.
- `service/scanning.d:272-273` - assignment of `fileSpecs` from the
  existence filter discards legitimately non-physical references (see M15).
- `metadata/digests.d:17` - leftover `FIXME`.

### Repository

- `repository/analysis.d:55-79` - the non-controlled merge takes
  `group_concat(id)` without `ORDER BY`, so the survivor is unspecified; the
  controlled path uses `min(id)`.
- `repository/analysis.d:143-147`, `:190-198` - counters are computed before the
  commit and still report rolled-back work.
- `repository/transfer.d:236-376` - `RepositoryFileQuery.offset` is silently
  ignored.
- `repository/transfer.d:484-485` versus `:532` - `entryIndex` has two
  different meanings (listing position versus `file_refs.id`).
- `repository/transfer.d:1036-1038` - the `LIKE` prefix does not escape `%` and
  `_`, so `pathPrefix` can over-match.
- `repository/transfer.d:277`, `:344`, `:700-703` - `cast(long) limit + 1`
  overflows for `limit == long.max`; `size_t.max` is special-cased but
  `long.max` is not.
- `repository/repository.d:67-71` - `db.close()` in the error path can replace
  the real exception with a `SqliteException`.
- `repository/repository.d:78-92` - WAL enablement failure is ignored.
- `repository/repository.d:344-353` - password write and `updated_at` update are
  two autocommitted statements.
- `repository/repository.d:364-376`, `:589-605` - archive password lookup does
  not escape `!` in the stored path and scans the whole table in D code.
- `repository/schema.d:170-316` - the schema version is tracked in two places
  and `PRAGMA user_version` is never set.
- `repository/*.d` - `enforce()` raises `EnforceException`, not the documented
  `RepositoryException`.
- `repository/scanner.d:314-320`, `:377-402` - the directory chain is ensured
  twice.
- `repository/metadata.d:308-313` - cleanup runs outside a transaction in
  `scope(exit)`, also while an exception is propagating.
- `repository/metadata.d:759-770` - the `empty` archive state is overwritten by
  the generic `completed` state.
- `repository/archiveindex.d:71-81` - `resolveArchiveMemberBlobLinks` is
  `O(V * B)` and runs after every archive metadata run and every import.

### Backends and operation layer

- `jsoncatalogbackend.d:1861-1866` versus `sqlitecatalogbackend.d:1340-1345` -
  the "filter is empty" predicates differ for `includeArchiveMembers`.
- `jsoncatalogbackend.d:244-274`, `:1121-1183` versus
  `sqlitecatalogbackend.d:821-871` - `fingerprint.size`,
  `archiveSummary.entryCount`, `torrentSummary.fileListAvailable` and the
  `extractors` list differ between backends.
- `jsoncatalogbackend.d:276-284` versus `sqlitecatalogbackend.d:263-301` -
  `listArchiveEntries` throws `invalidIdentifier` on one backend and returns an
  empty page on the other.
- `jsoncatalogbackend.d:802`, `sqlitecatalogbackend.d:477`, `:638` -
  `enforce` produces untyped exceptions instead of
  `CatalogBackendException`.
- `jsoncatalogbackend.d:1654-1657` - availability is a snapshot from index-build
  time and never refreshed.
- `jsoncatalogbackend.d:212-219`, `:1687-1717` - every page materializes and
  sorts the whole matching set.
- `jsoncatalogbackend.d:367`, `:1814` - `archiveMemberReferenceByToken` grows
  from a read path and is only cleared by `rebuildIndex`.
- `jsoncatalogbackend.d:593`, `:647`, `:656`, `:771-782` - AA `opIndex`
  silently inserts defaults on a miss.
- `operations.d:40-63` - `validOperationStateTransition` is only used by tests;
  no runtime validation of state transitions.
- `operations.d:401-409` - the progress callback runs while the callback mutex
  is held, so a callback that reports recursively self-deadlocks.
- `membercontentcache.d:84-122` - no destructor, so the session directory and
  its lease leak if `close()` is not called.
- `membercontentcache.d:69-75` - `MemberContentLease.release()` uses a plain
  `bool` and is not thread-safe.
- `membercontentcache.d:137-210` - raises untyped `Exception`s for
  cancellation, closed-cache and limit violations.

### CLI, packaging, CI, docs

- `dosierskanilo_cli/main.d:57`, `:496`, `:525-548` - a global `shared bool`
  is written from a signal handler without atomics; `exit()` and `printf()` are
  not async-signal-safe.
- `dosierskanilo_cli/main.d:442-446` - `jsonQuote` does not escape control
  characters, so a path containing a tab yields invalid JSON.
- `dosierskanilo_cli/main.d:186`, `:192` - `repository.rootPath` is read in the
  JSON branch where `repository` is null. Currently unreachable because the
  parser rejects the option combinations, but it is a latent
  `NullReferenceException`.
- `dosierskanilo_cli/parser.d:203-232` - scope keys are embedded in the
  user-visible option descriptions (documented in help, but couples help text
  to getopt strings).
- `dosierskanilo/operationlease.d` - hardcoded flock constants; the lock helper
  uses `__errno_location`, which is Linux-specific (macOS uses `__error`); lock
  files live in world-writable `tempDir()`.
- `dosierskanilo/service/storageio.d:154-161`, `:312-342` - backups are written
  relative to the process CWD, not next to the catalog, so catalogs with the
  same base name collide. Writes are not atomic (rename-away, then write in
  place).
- `dub.json:19-22` - version flags `useJSONStorage` and
  `SqliteEnableUnlockNotify` are not referenced anywhere in `source/`.
- `.gitlab-ci.yml:7` versus `:63` - base image is Alpine 3.20 while the build
  job uses 3.23.
- `.gitlab-ci.yml:100` - regex `^(v+)\d+\.\d+\.\d+$` accepts `vv26.11.3`.
- `.gitlab-ci.yml:74-87` - `deploy_staging` runs on every push to `main` and
  `testing`, but `scripts/deploy.sh` only prints "Nothing yet to deploy."
- `scripts/test.sh:28-34` - writes `dosierskanilo.json` into the repository root
  during the test run.
- `scripts/lint.sh:37-42` - the markdown lint list is hard-coded and does not
  include new documents such as this report.

## Strengths

- **Domain model.** The blob-centric model (one payload, many references) is
  clean, and equality/hash are based on size plus digests only.
- **JSON v5 grammar.** The `!/`, `!!`, `!~N` virtual path grammar is
  unambiguous, depth-limited during migration, and covered by round-trip tests
  including literal `!` in physical names.
- **Path-traversal hardening.** `normalizeArchiveEntryPath` rejects absolute
  paths, `..`, NUL bytes and drive letters.
- **SQL safety.** All user data is passed as bound parameters; no string
  interpolation into SQL was found.
- **Transactions and migrations.** Migrations are atomic, idempotent, and guard
  against a newer schema. Long operations (hashing, MediaInfo, archive parsing)
  correctly run outside the write transaction.
- **Keyset pagination.** The cursor predicate and `ORDER BY` agree for every
  sort order, including the `(size, path, id)` tiebreaker.
- **Cancellation and pause.** The controlled executors re-check cancellation
  immediately before commit, and the JSON path never replaces the catalog after
  a cancel.
- **Operation contract.** `CatalogBackend` is genuinely storage-neutral, with
  opaque ids, locators, capabilities and typed errors; JSON and SQLite adapters
  share DTOs.
- **Tests.** About 180 inline unittests, contract tests with fake backends,
  JSON/SQLite parity suites against the synthetic corpus, and a shell
  integration test that compares both modes byte for byte.
- **Documentation.** Architecture, JSON format, database schema, operation API,
  parity matrix, benchmarks and a detailed work-package plan.

## Recommended remediation order

**Wave 1 - data safety (Critical).** C1, C2, C3, C4, C5, M8, M19, M24. Add
regression tests for each: copy-fallback restore, cancel after phase end,
duplicate merge with asymmetric metadata, empty `fileSpecs` serialization,
`--replace` on an unreadable file, legacy record with both name fields, and a
filename containing `!`.

**Wave 2 - correctness of the shared contract.** M1, M14, M15, M16, M20, M10,
M13, M11, M12. Replace runtime `assert`s and add the missing backward-paging
parity test.

**Wave 3 - scalability.** M3, M4, M5, M6, M7, M17, M21, M23, plus the
`transfer.d` index and statement-count items. Benchmark before and after, in
line with the existing `scripts/benchmark-storage.sh` and the open WP-11 tasks.

**Wave 4 - cleanup.** Minor items, CI/version-flag cleanups,
`RepositoryException`
consistency, signal-handler hardening, and Markdown lint coverage.

## Open measurements and follow-ups

- Add a regression test for the JSON replacement crash window (write a large
  catalog and kill the process during the write).
- The `TODO.md` items for process-level Ctrl-C, multi-process lease races and
  CIFS/SMB behavior remain the right home for the remaining verification work;
  the findings above do not duplicate them.
- The legacy `service.scanning` / `service.analyze` modules are still part of
the
  public package facade. Either fix the threading issues (M12, M15) or mark the
  modules deprecated and remove them in the next major release.

## Remediation status

### Wave 1 - data safety

- [x] C1 - backup falls back to `copy` and `restoreOriginalFile()` restores the
      data (plus a copy-fallback unittest); the write also stages into a
      temporary file before renaming.
- [x] C2 - `OperationControl.unbindCancellationMirror()` releases the mirror,
      and both JSON metadata paths unbind on exit.
- [x] C3 - `mergeBlobMetadata()` copies metadata status, media signatures and
      streams, torrent data, archive passwords, and the file type before the
      duplicate blob is deleted; the survivor is always the lowest id.
- [x] C4 - empty `fileSpecs` and malformed catalogs raise
      `CatalogFormatException` instead of asserting.
- [x] C5 - `--force` only recovers from format errors; I/O failures propagate.
- [x] M8 - legacy fixups keep the modification timestamp.
- [x] M19 - JSON rescans escape virtual paths and update the existing spec.
- [x] M24 - malformed base64 digests are ignored and `blob_id = 0` is never
      written.

### Wave 2 - shared contract correctness

- [x] M1 - JSON `previousFilesPage` steps behind the cursor and a backward
      paging check was added to the adapter test.
- [x] M2 - every metadata persistence path is transactional per blob and the
      parallel pool stops in `finally`.
- [x] M10 - null SHA1 digests are skipped and the CLI signal-handler failure is
      logged instead of asserted.
- [x] M11 - bencode string lengths are validated without overflow.
- [x] M12 - the legacy threaded scan joins jobs before replacing specs and
      always stops the pool.
- [x] M13 - archive tool failures raise `ArchiveToolException`.
- [x] M14 - scans compare decoded physical paths.
- [x] M15 - virtual members count as present while their container exists.
- [x] M16 - metadata runs bump `repository.updated_at`.
- [x] M20 - index-build failures degrade the JSON backend instead of escaping.

### Wave 3 - scalability (partial)

- [x] M4 - directory filtering no longer wraps the column in `COALESCE`.
- [x] M7 - import/export take the write lease; backups use `VACUUM INTO`.
- [x] M17 - archive member pages use bounded keyset pages and a fingerprint-only
      blob lookup.
- [x] M21 - duplicate listings restrict the blob query to the reported ids via
      `RepositoryQueryOptions.blobIds`.
- [x] M23 - the SQLite backend keeps one read connection until `close()`.
- [ ] M3, M5, M6 - open; these need benchmarks and larger query rewrites before
      changing them.

Verification: `DC=ldc2 dub test --config=library` - 151 passed, 0 failed;
`./scripts/test-cli.sh` - passed.
