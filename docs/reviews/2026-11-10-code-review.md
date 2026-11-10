# Code Review Report - 2026-11-10

- Repository: `DosierSkanilo`
- Version reviewed: unreleased `main` head, commit `a3a28dd`
  (`v26.15.1` plus 13 commits: filesystem guard, missing-probe protection,
  `init --force`, `backup`/`restore`, cancellation progress)
- Branch: `main`
- Scope: library, domain model, JSON and SQLite backends, repository layer,
  CLI, archive adapters, metadata extraction, member content cache, operation
  layer, scripts, CI, packaging, documentation
- Method: manual reading, source-side verification of every Critical and Major
  finding, and four parallel read-only audits of the repository, backend,
  CLI/package, and model/archive layers. Behavioural findings were reproduced
  with the built `a3a28dd` binary or with the real archive tools.

## Summary

The tree remains in good overall condition. The new work since `26.12.2` is
substantial and mostly sound: the filesystem guard, `VACUUM INTO` backups,
`init --force`, root rebinding, the missing-probe guard, and the cancellation
progress watcher all work in the normal paths. All 222 unit tests and the CLI
integration checks pass.

The highest-impact problems are again in failure and trust boundaries:

1. A crafted archive containing a symlink member makes the scanner read and
   hash the link target, exposing arbitrary local files (C1). This is a direct
   extension of the archive sandbox that option injection hardened.
2. The `init --force` and `restore` safety backup renames the SQLite `-wal`
   sidecar to a name SQLite will never associate with the backup database, so
   a backup can silently miss committed WAL transactions (C2).
3. `CatalogDocument.save()` checks the on-disk fingerprint before acquiring the
   replacement lease, so two document sessions can both pass the conflict test
   and the second silently overwrites the first (C3).

The prior reviews' Critical items remain fixed. Four 2026-10-28 items are only
partially fixed after the intervening refactors (null media streams, zero-limit
paging, `!!` round-trip, and JSON directory counts); the status sections of the
old reviews are updated accordingly.

### Verification status

- Build: `DC=ldc2 ./scripts/test.sh` - `222 passed`, `0 failed`, CLI
  integration checks passed, `89.10 %` line coverage.
- Lint: `DC=ldc2 ./scripts/lint.sh` passed (shellcheck and Markdown lint).
- Binary: `build/bin/dosierskanilo --version` reports
  `DosierSkanilo v26.15.1-13-ga3a28dd`.
- Targeted probes were executed from `/tmp/opencode` and did not modify the
  repository:
  - a tar member that is a symlink to an external file was followed; its
    target content was hashed and exported as the member digest;
  - `recover cat.json --restore-from other.json --dry-run` overwrote the
    catalog and created `cat.json.before-restore-...`;
  - `recover cat.json` immediately afterwards reported
    `No backups or recovery files found.`;
  - from `<repo>/sub`, `restore --input backup.sqlite3` created a new nested
    repository instead of restoring the discovered parent;
  - a catalog written with `PATH` lacking `file` failed every write attempt;
  - `scan --pick-hidden` cataloged `.dosierskanilo/catalog.sqlite3`,
    `-wal`, `-shm`, and the operation log;
  - `list --json --format json --verbose` printed verbose log lines to stdout
    before the JSON document and made the stream invalid JSON.
- Line numbers refer to commit `a3a28dd` and may drift after changes.

Severity scale: **Critical** = data loss, security compromise, memory unsafety,
or silent corruption. **Major** = incorrect observable behavior, scalability
failure, release failure, or missing protection on a reachable path.
**Minor** = limited impact, robustness, maintainability, or documentation.

## Critical

### C1 - Symlink archive members expose arbitrary local files

`source/dosierarkivo/archive.d:117-131` (descriptor has no link kind),
`source/dosierarkivo/tararchive.d:65-71`,
`source/dosierarkivo/ziparchive.d:143-151`,
`source/dosierskanilo/membercontentcache.d:321-327`, `:374-377`,
`source/dosierskanilo/model/namedbinaryblob.d:2471-2487`

Archive descriptors classify entries only as file or directory. `tar` and
`unzip` preserve symlink entries, and the member cache accepts the extracted
path with `exists`/`isFile`, both of which follow links. The deep archive scan
then calls `calculatesDigests`, `getSize`, `file`, and MediaInfo on the link
target.

The probe created a tar with a member `link.txt -> /tmp/.../secret.txt`, scanned
it with a deep archive scan, exported the catalog, and observed that
`evil.tar!/link.txt` carried the SHA-1 of `secret.txt`. Member preview returns
the same path, so the contents are readable through the catalog as well.

Impact: scanning an untrusted archive lets the scanner read any local file the
user can read, store its size, digest, type, and media metadata, and expose its
contents through preview. This defeats the archive sandbox that the `--`
end-of-options hardening was meant to establish.

Fix: reject symlink and hardlink entries in every adapter (tar type `l`/`h`,
ZIP external attributes, RAR/7z attributes), and add a central post-extraction
guard in `MemberContentCache.acquire`: reject `isSymlink(path)` and require
`realPath(path)` to remain below `entry.directory`. Add tar and ZIP regression
tests with a symlink to a temporary target.

### C2 - Force/restore safety backup loses committed WAL transactions

`source/dosierskanilo/repository/repository.d:210-228` (`backupExistingCatalog`),
`:254-276` (`initialize`), `:356-396` (`restore`)

`backupExistingCatalog()` renames the main database to
`catalog.sqlite3.before-<reason>-<stamp>`, but renames the sidecars to
`catalog.sqlite3-wal.before-...` and `catalog.sqlite3-shm.before-...`. SQLite
only looks for `<database>-wal` and `<database>-shm`; the renamed WAL can never
be replayed against the renamed database. If the WAL contains committed frames
that were not checkpointed, the backup opens without those transactions.

The window is real when another reader keeps the WAL alive, or when a previous
writer crashed. The main database is also moved before its sidecars, so an
interruption between the two renames leaves the backup in an invalid state.

The existing regression test (`repository.d:1334-1371`) closes the repository
and only asserts that a `.before-reinit-` file exists; it never opens the
backup or checks its row count.

Impact: the safety net advertised for `init --force` and `restore --force` can
silently omit the most recent committed catalog changes.

Fix: take the exclusive lease, checkpoint the live connection, and create the
safety copy with `VACUUM INTO` (the same mechanism as `backupTo`). If a raw file
copy is required, move the sidecars next to the backup database under
`<backupDb>-wal`/`<backupDb>-shm` and move the main file last. Add a test that
opens a second reader, keeps committed WAL frames, runs `init --force`, and
asserts that the backup reopens with the full row count.

### C3 - `CatalogDocument.save` conflict detection is a check-then-write race

`source/dosierskanilo/jsoncatalogbackend.d:3908-3912`, `:4179-4199`;
`source/dosierskanilo/service/jsonoperations.d:278-292`

The document session captures `loadedFingerprint` when `document()` is first
called, which is after the backend has already loaded the catalog
(`jsoncatalogbackend.d:246-252`). A file changed in that window is loaded from
the old bytes and then accepted as the new baseline.

`save()` also compares the fingerprint before `commitJsonCatalog()` acquires
the replacement lease. Two document sessions can both observe the same
fingerprint, then serialize their writes one after the other; the second
overwrites the first without a `writeConflict`. `save()` does not take the
repository write lease either, so it does not exclude mutating CLI/GUI
operations.

Impact: silent loss of another writer's catalog updates despite the advertised
`writeConflict` contract. The fingerprint is also `size:mtime`, so a rewrite
within the timestamp resolution with the same size is invisible.

Fix: capture the fingerprint at backend load time; in `save()`, acquire the
replacement lease first, re-read the fingerprint under the lock, then stage and
rename. Use a content hash or a monotonic version in addition to size/mtime if
the format allows it. Add a two-writer regression test.

## Major

### M1 - `restore()` has no rollback and accepts weak validation

`source/dosierskanilo/repository/repository.d:285-340`
(`validateRestoreSource`), `:371-395` (replacement)

Validation checks `PRAGMA integrity_check`, the presence of `repository`,
`blobs`, and `file_refs`, and the `repository.schema_version` value. It does
not check `schema_migrations`, required columns, or the archive/index tables.

After validation, `restore()` moves the current database into `backups/`,
copies the source to a staging file, renames it into place, and calls
`openRoot()`, which runs `migrate()`. If the copy, rename, migration, or reopen
fails, the target is left without a database; the only recovery is the manual
`backups/` file, which may itself be incomplete (C2). A foreign database with
the three table names and `schema_version = 6` passes validation but can fail
after the live database has already been moved.

Impact: a failed restore can remove a usable catalog instead of leaving it in
place.

Fix: stage the copy next to the target, run `migrate()` and schema assertions
on the staged file, then swap old→backup and staging→target. On any failure,
rename the backup back. Validate `max(schema_migrations.version) ==
repository.schema_version` and the required generated columns.

### M2 - Filesystem rejection is bypassable through symlinks and overmounts

`source/dosierskanilo/repository/filesystem.d:57-82`
(`filesystemTypeForPath`), `source/dosierskanilo/repository/repository.d:1272-1280`
(`canonicalDirectory`), `:192-200`

`canonicalDirectory()` uses `absolutePath`/`buildNormalizedPath`, which are
lexical and do not resolve symlinks. `filesystemTypeForPath()` then matches the
lexical path against `/proc/self/mountinfo`. A repository root, `.dosierskanilo`
directory, or database file that is a symlink into `/mnt/sshfs/...` is
classified as the local parent filesystem and accepted, even though SQLite and
its WAL live on FUSE/NFS.

The mount tie-break also keeps the first entry for equal mount-point lengths
(`filesystem.d:76`), while the visible mount is the later one in mountinfo. A
FUSE overmount on a path that was first mounted as ext4 is therefore classified
as ext4.

Impact: the documented "SQLite repositories are rejected on FUSE/sshfs/SMB/NFS"
boundary can be bypassed, reintroducing the locking and durability risks that
motivated the guard. The bypass requires a symlinked path or an overmount, but
both are ordinary user actions.

Fix: resolve `realPath()` of the actual database file and its parent (or of the
repository root) before classification; iterate mountinfo in order with
"later wins" on equal mount points; and treat "filesystem could not be
classified" as an explicit opt-in or warning instead of silent acceptance.

### M3 - The missing-probe guard does not protect the scan walk

`source/dosierskanilo/repository/scanner.d:82-111` (walk),
`:569-630` (`stageMissingReferences`)

`isWithinUnsupportedMount()` is applied only while probing already stored
references. The `dirEntries(rootPath, SpanMode.depth)` traversal runs first and
still descends into every FUSE/NFS/autofs mount below the repository root,
reading entry metadata there. A stale mount blocks the scan in the discovering
phase before the guarded reconciliation is reached.

The CHANGELOG claim is scoped to "missing-file reconciliation", so the wording
is accurate, but the user-visible hang class is not fully closed and the
documentation should say so or the walk should be guarded too.

Fix: build the unsupported-mount table before the walk and prune traversal at
those mount points (a shallow `dirEntries` recursion that skips matching
directories), and resolve symlinks before the probe guard.

### M4 - `--pick-hidden` catalogs the repository's own live database

`source/dosierskanilo_cli/main.d:869`;
`source/dosierskanilo/repository/scanner.d:86-87`

Repository scans pass `--pick-hidden` straight into the scanner. The scanner
skips hidden components only when `pickHidden` is false, so `.dosierskanilo`
itself is cataloged. The probe produced file references for
`.dosierskanilo/catalog.sqlite3`, `catalog.sqlite3-wal`,
`catalog.sqlite3-shm`, and `logs/operations.jsonl`.

Impact: the catalog references its own database and journal. Every scan sees a
changed DB/WAL, metadata extraction may hash the live database while it is
being written, and backups now add more self-references. This creates permanent
churn and can make the catalog non-reproducible.

Fix: always exclude the resolved metadata directory (`paths.metadataPath`) from
repository scans, independently of `--pick-hidden`, and add a regression test.

### M5 - Per-changed-file orphan cleanup makes rescans quadratic

`source/dosierskanilo/repository/scanner.d:276-289`;
`source/dosierskanilo/repository/archiveindex.d:110-115`

`upsertFileReference()` calls `deleteUnreachableBlobs(db)` for every changed
file, although the immediately preceding statements already delete the old blob
when it has no remaining references. `deleteUnreachableBlobs()` is a full
`DELETE ... WHERE NOT EXISTS` over `blobs`, executed inside the write
transaction.

With `F` changed files and `B` blobs this is `O(F × B)` with the write lock
held for the whole apply phase. On a large rescan after a mount change this is
the dominant cost.

Fix: remove the per-file call and run one cleanup after `applyStagedFiles()` /
`applyStagedMissing()`, as the `--drop-missing` branch already does.

### M6 - `listArchiveEntries` exceeds the bind limit and scans the archive

`source/dosierskanilo/repository/transfer.d:930-1007`

The query emits two named parameters per file reference of the container blob.
After duplicate analysis merges identical archives, one blob can own many
references; older SQLite builds cap at 999 variables, newer at 32766, so the
query throws instead of listing entries.

The function also collects every matching entry into `allEntries`, deduplicates
in memory, and only then applies `offset`/`limit`. A page of 100 entries on a
million-member archive performs all the work and allocates all rows.

Fix: insert the container paths into a temp table and join, or batch by the
SQLite variable limit; apply deduplication and pagination in SQL (keyset or
`GROUP BY` over a normalized identity) instead of materializing the archive.

### M7 - `setArchivePassword` writes in place and leaks untyped read errors

`source/dosierskanilo/jsoncatalogbackend.d:903-951`;
`source/dosierskanilo/model/namedbinaryblob.d:1682-1737`

The read at `:910` is outside the `try`, so a parse failure escapes as a plain
`Exception` although the Ddoc promises `CatalogBackendException`. The write at
`:946` calls `serializeDataClassWrapperFile()` directly, which opens the
canonical path with `"wb"` and streams into it. A crash or disk-full condition
truncates the catalog. The normal scan/analyze path uses the staged writer with
backup and recovery files; this path bypasses it.

Impact: a failed password update can destroy a large catalog, and callers may
receive an undocumented exception type.

Fix: wrap the read, and route the write through `commitJsonCatalog()` /
`writeCatalogJsonFile()` under the same replacement and write leases used by
other mutations.

### M8 - JSON indexing still dereferences null MediaInfo stream entries

`source/dosierskanilo/jsoncatalogbackend.d:2454-2508` (`mediaStreamsFor`),
`:2574-2577`, `:3226-3234`;
`source/dosierskanilo/metadata/mediainfosig.d:370-401`

The parsers now skip null streams and `MediaInfoSig.toString`/`opEquals` are
null-safe, but `mediaStreamsFor()` iterates the stream arrays and reads
`stream.index`, `stream.format`, and the other fields without an `is null`
check. `snapshotFor()` calls it during `rebuildIndex()`, so opening a legacy
catalog that contains a null stream reference can throw
`NullReferenceError`/crash instead of producing a typed error. The flag
computation at `:3226-3234` also treats an all-null array as non-empty.

Impact: the prior M3 hardening is bypassed by the JSON adapter for exactly the
legacy catalogs it was meant to tolerate, and media flags can be phantom-true.

Fix: skip null entries in every adapter loop and compute media flags from
non-null entries only. Add a JSON-backend test loading a catalog with a null
stream.

### M9 - Document dry-run mutates the live buffer and leaves the index stale

`source/dosierskanilo/jsoncatalogbackend.d:4088-4101`, `:4143-4154`;
`source/dosierskanilo/service/jsonoperations.d:101-169`

`applyScan`/`applyAnalysis` pass `backend.catalog` directly to the helpers,
which mutate it unconditionally. Only when `!request.dryRun` is `dirty` set and
`rebuildIndex()` called. A dry-run therefore changes the in-memory catalog
without marking it modified or refreshing the query index; references dropped
by `absolutizeJsonStoredPaths()` are lost. If the helper throws, the partial
mutation remains and the exception is converted into a failed result.

Impact: a preview or a failed operation silently corrupts the live document;
subsequent reads can be inconsistent with the buffer. This is the open P1 item
in `TODO.md`, now confirmed in the current code.

Fix: reject `dryRun` on document sessions with `unsupportedFeature`, or run
against a deep copy and swap only on success; restore the previous buffer on
failure.

### M10 - Filtered JSON directory counts count descendants, not immediate files

`source/dosierskanilo/jsoncatalogbackend.d:3482-3511`;
compare unfiltered counts at `:3240-3244` and the contract at
`source/dosierskanilo/catalogbackend.d:615-616`

`applyDirectoryFilterCounts()` counts every file below
`directory.relativePath ~ "/"`, while the unfiltered index increments
`fileCount` only for the immediate parent, and SQLite uses
`f.directory_id = d.id`. It also adds archive member bytes to
`aggregateSize` but never adds member counts.

Impact: a filtered JSON `listDirectories` reports a different `fileCount` from
both the unfiltered JSON row and SQLite, contradicting the documented
"Immediate matching file references" contract. The recent parity fix replaced
one inconsistency with another.

Fix: count only rows whose `directoryId` equals the directory (plus matching
member rows when `includeArchiveMembers`) and keep `aggregateSize` as the
descendant sum. Add a filtered `listDirectories` parity test.

### M11 - `dir!/file` physical names are still misclassified as virtual

`source/dosierskanilo/model/namedbinaryblob.d:516-550`
(`getExistingFiles`), `source/dosierskanilo/service/scanning.d:209-231`
(`canonicalizeFileSpecs`)

For a physical file whose canonical stored name is `dir!!/sample!!.zip`,
`getExistingFiles()` returns the openable disk name `dir!/sample!!.zip`.
`canonicalizeFileSpecs()` then decides "already virtual" with
`spec.fileName.canFind("!/")`, which matches the decoded literal, so it skips
re-escaping. The next load parses `dir!/sample!!.zip` as archive `dir` member
`sample!!.zip`.

Impact: a record for a file in a directory whose name ends in `!` changes
identity on the next legacy scan: it is no longer openable, metadata is
skipped, and a duplicate blob is created. The test at `scanning.d:556-584` only
covers `sample!.zip` without a preceding `!`-named directory.

Fix: in `getExistingFiles()`, keep the original canonical spec for every
non-virtual path and re-escape only in the write-back using the parsed identity,
not a substring test. Add a `dir!/sample!.zip` round-trip test.

### M12 - A failed archive member scan leaves a partial index marked complete

`source/dosierskanilo/model/namedbinaryblob.d:2317`, `:2471-2487`,
`:2523-2529`; promotion at `:1548-1554`

`updateArchives()` assigns `obj.archiveSpecs = []` before iterating. Digest and
stat calls after a successful extraction, and the recursive `updateArchives()`
call for nested archives, are outside the per-member catch. If one throws, the
exception escapes with a partial `archiveSpecs` array on the blob. The JSON
metadata path records the item as failed, but on save `normalizeV5Catalog()`
treats any non-null archive list as authoritative and sets
`archiveIndexKnown = true`.

Impact: one corrupt or disappearing member permanently truncates the outer
archive's member list until `--rescan` is used.

Fix: build a local array and assign it only after the complete archive succeeds;
wrap the whole per-member block (extraction, digest, stat, nested scan) and
append an index-only entry on failure. Do not promote partial indexes; restore
the previous `archiveSpecs` on item failure.

### M13 - ZIP extraction treats member names as wildcard patterns

`source/dosierarkivo/ziparchive.d:143-152`

`extractEntry()` passes the raw member name to `unzip`. Info-ZIP expands
filename operands; a member literally named `foo*` extracts every matching
member, not only the requested one. The cache accounts only the literal target,
so extra files remain on disk outside the cache byte limit until session
eviction.

Impact: a deep scan of a crafted ZIP can extract unrelated members, exhaust
disk space, and (combined with C1) write through extracted links.

Fix: use the existing Python `zipfile` index-based extraction
(`ziparchive.d:181-207`) for all ZIP entries, not only duplicate names.
`ZipInfo` writes exactly one member and does not restore symlinks. Add a
`foo*`/`foo1` regression test.

### M14 - A missing optional `file` utility breaks every JSON save

`source/dosierskanilo/metadata/fileutilsig.d:49-61`;
`source/dosierskanilo/model/namedbinaryblob.d:142-154`, `:1666`

`getFileUtilityVersion()` calls `execute(["file", "--version"])` without a
catch. `refreshRuntimeMetadata()` catches only MediaInfo failures, and every
JSON serialization calls it. With `PATH` lacking `file`, a plain scan without
`--file-types` failed all three write attempts and left no catalog.

Impact: a documented optional runtime tool becomes mandatory for all JSON
writes, and the failure is reported as a catalog write failure rather than a
missing optional tool.

Fix: catch `Exception` in `getFileUtilityVersion()` and return `"unknown"`,
matching `getMediaInfoVersion()`; add a test with a `PATH` that lacks `file`.

### M15 - `recover` bypasses validation and ignores `--dry-run`

`source/dosierskanilo_cli/parser.d:390-400`;
`source/dosierskanilo_cli/main.d:518-567`

The `recover` branch returns before `setVerboseOutputs()`, the `--all` check,
and both validators. `--dry-run` is accepted and displayed in the `Settings:`
line, but `executeCatalogRecovery()` copies the replacement over the catalog
unconditionally when `--restore-from` is set. The probe changed the catalog MD5
and created a `.before-restore-` copy under `--dry-run`.

Impact: a user asking for a non-writing run gets a destructive restore with
only an undiscoverable safety copy.

Fix: add a dedicated `recover` validator that rejects every option except
`--restore-from`/`--no-input`, or honor `--dry-run` as a listing-only
operation. Route verbose setup through the normal path as well.

### M16 - `restore` does not discover the repository root

`source/dosierskanilo_cli/main.d:739-748`;
`source/dosierskanilo/repository/repository.d:356-359`

`executeRepositoryRestore()` calls `Repository.restore()` with the default
`"."` from `repositoryvalidation.d:76-79`. `restore()` only canonicalizes that
path and does not call `findRoot()`, unlike `open()`. Running the command in a
subdirectory of an existing repository creates a new nested
`.dosierskanilo/catalog.sqlite3` instead of restoring the discovered repository.

Impact: silent wrong restore target and later commands in the subtree bind to
the new nearest repository.

Fix: resolve `findRoot()` first and require an explicit root that differs from
the discovered root if the user really wants a new repository. Add a CLI test
running `restore` from a subdirectory.

## Minor

- **Force init with a missing database leaves stale sidecars.**
  `repository.d:265-269` only acquires the lease and moves files when
  `catalog.sqlite3` exists. If the main file is absent but `-wal`/`-shm` are
  present, `openRoot()` creates a fresh database beside them and SQLite can
  replay stale frames. Always move or remove both sidecars on `force`.
- **`backupTo` leaves a partial file on failure.** `repository.d:649-662`
  writes the target with `VACUUM INTO` and only then checks integrity; a failed
  vacuum or check leaves a file that makes the next retry fail with
  "already exists". Remove the target on failure and validate the destination
  directory's filesystem.
- **Force/restore backup names can overwrite earlier backups.**
  `repository.d:215-226` uses a second-resolution timestamp only, unlike
  `backupDatabase()`, which adds PID and a serial. POSIX `rename` overwrites an
  existing file. Add a PID/serial or fail when the target exists.
- **`is_virtual` is a VIRTUAL generated column.** `schema.d:249-262` cannot
  be indexed, yet `countPhysicalFileReferences()` and
  `loadRootSummaryFromDatabase()` (`transfer.d:500-525`) evaluate `replace()`
  for every row. Prefer `STORED` plus a partial index on large catalogs.
- **Inconsistent repository error typing.** `repository.d:701`, `:717`,
  `:900`, `:935`, `:949`, `:1039`, `:1080`, `:1217` use untyped `enforce`,
  throwing `EnforceException` while sibling methods use `RepositoryException`.
- **JSON page validation is bypassed on empty detail pages.**
  `jsoncatalogbackend.d:1073-1089` and `:1215-1231` return an empty page for a
  known content before `pageSlice()` validates `limit == 0`, unlike SQLite.
- **`recover` cannot list its own pre-restore backup.**
  `main.d:487-490` accepts `stem-` and `.json.tmp-` candidates, while the
  safety copy is named `catalog ~ ".before-restore-"` at `:539-542`. The probe
  confirmed the immediately following `recover` reports no backups.
- **`--restore-from` leaks to every command.** Registered globally at
  `parser.d:287`, it is only consumed by `recover`; there is no guard beside
  the `--input` check at `:378-382`.
- **`--pretty` is still silently accepted by query commands.**
  `parser.d:289` documents it for scan/analyze/export only, but `info`, `list`,
  and `duplicates` accept it and emit compact JSON.
- **`--verbose` corrupts JSON stdout.** `main.d:1397`, `:1513` use
  `logLineVerbose()` for query diagnostics; `list --format json --verbose`
  printed plain-text lines before the JSON document, contradicting
  `README.md:206-208`.
- **Heartbeat output bypasses the single-line state machine.**
  `parser.d:1195-1247` writes `\r\x1b[K` but never sets
  `operationProgressLineOpen` or prints the header; `clearOperationProgress()`
  (`:1502-1513`) then cannot erase a heartbeat-only line. Verbose mode also
  receives the compact heartbeat instead of newline records.
- **Cross-thread progress state is not fully synchronized.**
  `activeOperationControl`, `operationStartedAt`, `operationProgressLineOpen`,
  and `lastOperationProgress` are written outside `operationStateMutex`
  (`parser.d:1143-1160`, `:1444-1446`, `:1502-1513`) while the heartbeat reads
  them (`:1202-1225`). `SysTime` is 16 bytes, so torn reads are possible.
- **Cancellation watcher threads never stop on success.**
  `main.d:1710-1723` loops until cancellation and is never joined. A one-shot
  CLI leaks one daemon thread per controlled operation; reused library-style
  callers leak more. Add a finished flag or one process-wide watcher.
- **`physicalPathForSpec()` cannot resolve v3 `!` names.**
  `namedbinaryblob.d:559-570` always parses the v5 grammar. A v3 raw name with
  `!`, or an extracted archive path containing `!`, returns `""`, so
  `updateDigests`/`updateFileType`/`updateMediaInfo` silently skip it.
- **Torrent integer edge cases remain.** `torrentinfo.d:199-204` casts a
  signed `piece length` without a negative check, and `:271` accumulates
  `totalSize` without overflow checking.
- **Listing commands pass archive paths before `--`.**
  `tararchive.d:49`, `ziparchive.d:99`, `:114`, `rararchive.d:68`, `:160`,
  and `sevenziparchive.d:52` are normally safe because scans pass absolute
  paths, but a catalog-supplied relative path beginning with `-` can still be
  interpreted as an option.
- **ZIP/7z listing parsers damage names with surrounding whitespace.**
  `ziparchive.d:104` and `sevenziparchive.d:71` call `.strip`; the formats
  preserve leading/trailing spaces, so the stored name no longer matches the
  archive and extraction fails. Line-based parsing also cannot represent
  member names containing newlines.
- **The legacy scanner still aborts on one extractor exception.**
  `scanning.d:329-345` calls `workForce()` without per-item isolation, unlike
  the JSON and repository paths. The module remains publicly exported.
- **Cancellation leaves digest outputs unchanged.**
  `digests.d:73-74` returns before `finish()`; callers that reuse buffers can
  observe old digests. Clear outputs or document that they are valid only on
  non-cancelled completion.
- **Test temp directories leak on failure.**
  `dosierarkivo/testsupport.d:59-61` removes them with `scope (success)` only.

### Prior items resolved or still partial

All Critical and Major findings of the 2026-10-21 and 2026-10-24 reviews remain
fixed in the re-read code. The distribution recipes are pinned to `26.15.1`,
and the Flatpak `sha256` matches the published `v26.15.1` archive.

The 2026-10-28 items now have this status:

- **M1 JSON per-blob metadata isolation - fixed.**
  `service/jsonoperations.d:1004-1069` catches per-job exceptions and records
  failures; cancellation exceptions still abort intentionally.
- **M2 member-cache stale lease accounting - fixed.**
  `membercontentcache.d:219-225`, `:329-340`, `:442-461` keep stale entries
  while leased and refuse `close()` under an outstanding lease; regression test
  at `:877-928`.
- **M3 null MediaInfo streams - partial.** `mediainfosig.d` is hardened, but the
  JSON adapter still dereferences null entries (M8).
- **M4 zero-limit cursor paging - partial.** `pageSlice()` validates, but two
  empty-detail early returns bypass it (Minor).
- **M5 `!!` round-trip through `getExistingFiles` - partial.** The simple
  `sample!.zip` case works; `dir!/file` is still misclassified (M11).
- **M6 JSON directory filter counts - partial.** Counts are recomputed, but
  with descendant semantics instead of immediate files (M10).
- **Flatpak `sha256` pins - verified.** The manifest hash equals the published
  `v26.15.1` tarball.
- **Legacy `scanning.d` decision - still open** in `TODO.md` P1.

## Strengths

- **Security posture.** Archive member operands are passed after `--` in every
  adapter, path normalization rejects absolute/traversal/NUL/drive-letter
  names, and the new filesystem guard correctly rejects FUSE, sshfs, SMB/CIFS,
  NFS, 9p, and WSL `drvfs` in the normal path.
- **Backup mechanism.** `backup` and import backups use `VACUUM INTO`, which
  includes WAL rows and produces a compact snapshot; `restore` validates before
  touching the target and requires `--force`.
- **SQL safety.** No string interpolation of user data into SQL was found in
  the re-audited paths; only internal enum fragments and generated-column
  expressions are concatenated.
- **Transaction hygiene.** Migrations, staged scans, metadata persistence,
  analysis, and import replacement are transactional with rollback and
  cancellation checkpoints.
- **Operation layer.** The state machine is closed and race-free, bound
  cancellation mirrors are unbound on exit, and the new CLI watcher surfaces
  `cancelling` even between progress events.
- **Tests and documentation.** 222 unit tests, synthetic corpus, JSON/SQLite
  parity suites, CLI integration checks, and unusually complete architecture
  documents; every prior fix still carries its regression test.

## Recommended remediation order

**Wave 1 - security and data safety.** C1 (symlink members), C2 (WAL backup),
C3 (document save race), M1 (restore rollback), M7 (password write), M14
(optional `file` dependency). Add the probes named in each item as regression
tests before changing behavior.

**Wave 2 - correctness of the new surfaces.** M2, M3, M4, M8, M9, M10, M11,
M12, M13, M15, M16. These include the partial regressions from the
2026-10-28 review.

**Wave 3 - scalability and robustness.** M5, M6, the `is_virtual` column, the
remaining Minors, script/CI portability, and documentation gaps.

## Open follow-ups

- [ ] Reject symlink/hardlink archive members and add tar/ZIP tests (C1).
- [ ] Create force/restore safety backups with `VACUUM INTO` and verify the
      backup row count after keeping WAL frames (C2).
- [ ] Add a two-writer document-save conflict test (C3).
- [ ] Stage and validate a restore before swapping the live database, with
      rollback on failure (M1).
- [ ] Classify `realPath()` of the database and handle equal-mount-point
      overmounts (M2).
- [ ] Prune unsupported mounts during the scan walk, not only during missing
      probes (M3).
- [ ] Always exclude `.dosierskanilo` from repository scans (M4).
- [ ] Replace the per-changed-file `deleteUnreachableBlobs()` call with one
      post-scan cleanup (M5).
- [ ] Rework archive member listing to batch container paths and paginate in
      SQL (M6).
- [ ] Route `setArchivePassword` through the staged writer (M7).
- [ ] Add null-stream tolerance to every JSON adapter loop (M8).
- [ ] Reject or isolate document dry-run (M9).
- [ ] Recompute filtered directory counts with immediate-file semantics (M10).
- [ ] Fix the `dir!/file` round-trip and add a legacy-scanner test (M11).
- [ ] Do not promote partial archive indexes (M12).
- [ ] Extract ZIP members by index or reject glob metacharacters (M13).
- [ ] Make `getFileUtilityVersion()` tolerate a missing `file` (M14).
- [ ] Validate `recover` options and honor `--dry-run` (M15).
- [ ] Use `findRoot()` in `restore` (M16).
- [ ] Fix heartbeat line state, verbose heartbeat routing, and progress-state
      synchronization (Minor).
- [ ] Run the full suite again after the fixes; this review did run
      `scripts/test.sh`, `scripts/lint.sh`, and the probes listed above.
