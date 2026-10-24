# Code Review Report - 2026-10-24

- Repository: `DosierSkanilo`
- Version reviewed: `26.12.0` (tag `v26.12.0`, commit `ad0a802`)
- Branch: `main`
- Scope: library, CLI, SQLite repository, JSON backend, archive adapters,
  operation layer, scripts, CI, packaging, documentation
- Method: manual reading, targeted verification of the highest-impact findings,
  and four parallel read-only audits of the operation, backend, CLI/package,
  and archive/metadata layers

## Summary

The 26.12.0 tree keeps the strengths of the previous release: the domain model
is clear, SQL is parameterized, migrations and long metadata phases are
transactional, and the backend/operation abstraction remains coherent. The
prior Critical findings C1-C5 are addressed in the areas re-read for this
review.

The new risks are concentrated in untrusted input handling and backend
consistency:

1. Deep archive scanning passes archive member names as bare command-line
   operands. A crafted tar member can execute a shell command (C1).
2. A JSON rescan updates only size and modification time for a changed file,
   leaving old checksums and metadata in place (C2).
3. POSIX filenames containing backslashes are still rewritten as directory
   separators in both storage paths.
4. SQLite range queries silently omit archive members whose names start with a
   non-BMP character.
5. Analysis changes rows without bumping `repository.updated_at`, so SQLite
   cursors survive a duplicate merge or missing-file deletion.

The release packaging recipes also lag the `26.12.0` tag, and every recipe that
builds from a tag archive currently fails at the `git describe` pre-generation
step.

### Verification status

- Build: `DC=ldc2 dub build --config=cli` succeeded for the reviewed tree.
- Binary: `build/bin/dosierskanilo --version` reports
  `DosierSkanilo v26.12.0-0-gad0a802`.
- Unit tests: the release test run was green (`151 passed`, `89.10%` coverage).
  The full suite was not rerun after this review's source reading.
- Targeted probes were executed from `/tmp/opencode` and did not modify the
  repository:
  - crafted tar member `--to-command=touch ...` executed `touch`;
  - JSON rescan kept the old MD5 after `AAAA` was replaced with `BBBB`;
  - JSON scan stored `a\b.txt` as `a/b.txt`;
  - SQLite archive range omitted `emoji.zip!/😀.txt`;
  - analysis merged duplicate blobs without changing `updated_at`;
  - a malformed `.torrent` aborted the CLI with `RangeError`;
  - a `git archive HEAD` source tree failed `dub build` at `git describe`;
  - deleting `sample!.zip` left its member reference marked available.
- Line numbers refer to commit `ad0a802` and may drift after changes.

Severity scale: **Critical** = data loss, security compromise, memory unsafety,
or silent corruption. **Major** = incorrect observable behavior, scalability
failure, release failure, or missing protection on a reachable path.
**Minor** = limited impact, robustness, maintainability, or documentation.

## Critical

### C1 - Archive extraction permits command injection through member names

`source/dosierarkivo/tararchive.d:44`, `:65-66`; `ziparchive.d:111`;
`rararchive.d:45`; `sevenziparchive.d:64-65`; with
`source/dosierarkivo/archive.d:343`

`FileArchiveTar.extractEntry()` calls:

```d
execute(["tar", "-xf", tarPath, "-C", destDir, filename]);
```

and the duplicate-occurrence path calls:

```d
execute(["tar", "--extract", "--file=" ~ tarPath,
    "--directory=" ~ destDir, occurrenceOption, descriptor.name]);
```

`filename` is the archive's original member name. `normalizeArchiveEntryPath()`
accepts names beginning with `-`, so a tar member named
`--to-command=touch /tmp/pwned` reaches `tar` as an option, not as a member
filter. The targeted probe created that member, listed it with `tar -tf`, and
the exact adapter argument vector executed `touch`.

ZIP, RAR, and 7z pass the same raw name as an operand (`unzip`, `unrar`, `7z`),
so the same class of option injection exists there; the tar variant is the
demonstrated command-execution path.

Impact: scanning a malicious archive with deep extraction enabled runs an
arbitrary command as the scanner user. `MetadataScanOptions.deepArchiveScan`
defaults to `true`, so library callers that do not override it are exposed. The
CLI currently sets it to `false` and cannot enable it: `--scan-archives` only
sets a boolean, so `argScanArchives` never exceeds `1` (see the Minor section).

Fix: insert an explicit end-of-options marker where the tool supports it, or
prefix the member operand with `./` after validating the normalized path.
Reject extraction of member names beginning with `-` as a second layer. Add a
regression test with a `--to-command` member for tar and analogous operands for
the other adapters.

### C2 - JSON rescan keeps stale checksums and metadata for changed files

`source/dosierskanilo/service/jsonoperations.d:203-216`, with the metadata
gating at `:383-391`

When a scanned file's size or modification time changes, the single-spec branch
updates only `existing.fileSize` and `fileSpec.timeLastModified`. It does not
clear `checkSums`, `fileType`, `mediaInfoSig`, `torrentInfo`,
`archiveSpecs`, `archiveIndexKnown`, or `archiveIndexDeep`.

The metadata phase then skips work that appears complete:
`doChecksums` requires `!blob.checkSums.hasDigests`, file type requires an empty
`fileType`, media requires a null signature, archives require an absent index,
and torrents require a null `torrentInfo`. The old values therefore survive the
rescan.

The targeted probe scanned `AAAA` with `--checksums`, replaced the bytes with
`BBBB`, and scanned again with `--checksums`. The second run reported
`0 checksum` updates and left the old MD5
`CYiQ3eBp6autY/GaDZ4fMg==`; the actual MD5 was
`9QiBztNMfZ5rzhAL8z3sYA==`.

Impact: duplicate detection, archive membership, torrent metadata, media
classification, and digests can all describe the previous contents of a changed
file. A later `analyze` can merge or drop records based on stale SHA1 values.

Fix: when a changed file is detected, clear every content-derived field before
metadata work, or replace the blob with a fresh record and let the configured
extractors repopulate it. Add a regression test that changes file bytes while
keeping the same size and checks that the digest and all extractor state are
refreshed.

## Major

### M1 - POSIX backslash filenames are rewritten as directory separators

`source/dosierskanilo/service/jsonoperations.d:176`;
`source/dosierskanilo/repository/scanner.d:495`;
`source/dosierskanilo/model/namedbinaryblob.d:616`, `:1282`

All three paths apply `.replace('\\', '/')` unconditionally. On POSIX a
backslash is a legal filename character, so a file named `a\b.txt` is stored as
`a/b.txt`, which is a different path and normally does not exist. The JSON probe
stored `/tmp/.../a/b.txt` for the source file `a\b.txt`; the repository probe
stored `a/b.txt` and then reported a metadata failure because the rewritten
path could not be opened.

Impact: silent reference corruption, failed metadata extraction, duplicate
entries, and loss of the record under `--drop-missing` or a later analysis. This
is the unresolved prior M9, now confirmed in both the JSON and SQLite scan
paths.

Fix: translate separators only under `version (Windows)`, and keep the original
POSIX bytes otherwise. Add a POSIX regression test that round-trips a backslash
filename through scan, metadata, and JSON export/import.

### M2 - SQLite range bounds omit non-BMP archive members

`source/dosierskanilo/repository/scanner.d:246`, `:263`;
`source/dosierskanilo/repository/transfer.d:256`, `:607`

The upper bound `prefix ~ "\uFFFF"` is encoded as UTF-8 `EF BF BF`. UTF-8
sequences for non-BMP characters start with `F0`-`F4` and compare greater than
that bound under SQLite's binary collation. Archive members whose first
character after `!/` is non-BMP are therefore outside every range query.

The probe created `emoji.zip` with `😀.txt` and `z.txt`. SQLite stored both
virtual references, but the `prefix >= ... AND prefix < prefix || U+FFFF` query
returned only `z.txt`. The JSON backend already uses the safer `directory ~ "0"`
bound at `jsoncatalogbackend.d:2154-2155`.

Impact: `listArchiveEntries()` omits those members; directory aggregates
undercount them; a changed or deleted container does not mark them unavailable;
and stale descendants are not deleted. The catalog silently presents an
incomplete archive.

Fix: use a bound that covers all UTF-8, such as `prefix ~ "\U0010FFFF"`, or use
the same `prefix ~ "0"` shape as the JSON backend. Apply the fix to all four
range sites and add a non-BMP member test.

### M3 - Analyze does not invalidate SQLite cursors

`source/dosierskanilo/repository/analysis.d:288-344`;
compare `source/dosierskanilo/repository/metadata.d:202-206`, `:355-359`

The SQLite cursor token is derived from `repository.updated_at`
(`sqlitecatalogbackend.d:832-835`). The scan and metadata paths update that
column, but the analysis transaction merges blobs, repoints `file_refs`, deletes
orphans, and commits without touching it.

The probe scanned two identical files, recorded `updated_at`, ran `analyze`,
and observed the same timestamp after the duplicate merge had reduced two blobs
to one.

Impact: a cursor issued before analysis remains valid after the row set and
content identities change. Detail and directory pages can skip or repeat rows,
or return a cursor that no longer identifies the same rows. This is the same
class of bug as the fixed prior M16, but on the analysis path.

Fix: update `repository.updated_at` in the analysis transaction immediately
before commit, including the no-op and rollback paths only when rows actually
changed. Add a cursor test that merges duplicates between two page requests.

### M4 - Malformed torrent metadata aborts the whole process

`source/dosierskanilo/metadata/torrentinfo.d:150`, `:233`, `:238`,
`:388-475`; `source/dosierskanilo/model/namedbinaryblob.d:2367`;
`source/dosierskanilo/repository/metadata.d:143`

`infoDict["length"]` and `dict["path"]` use associative-array indexing without a
presence check. A missing key raises `RangeError`, which derives from `Error`,
so the surrounding `catch (Exception)` in `updateTorrentInfo()` does not catch
it. The bencode parser also recurses without a depth or size guard.

The probe created a syntactically valid torrent whose multi-file entry had a
`path` but no `length`. `metadata --scan-torrents` aborted with
`core.exception.RangeError@...torrentinfo.d(233): Range violation` and exit code
1 instead of recording a per-blob failure.

Impact: one malformed or malicious `.torrent` file can crash the CLI or a
worker thread and abort an otherwise valid metadata run. Deeply nested bencode
can additionally exhaust the stack or memory.

Fix: use `key in dict` before indexing, convert parser failures to a typed
exception such as `TorrentFormatException`, and enforce a nesting-depth and
input-size limit. Add a malformed-torrent regression test that expects a failed
metadata item, not a process abort.

### M5 - JSON duplicate analysis can discard media metadata

`source/dosierskanilo/model/namedbinaryblob.d:2413-2428`;
`source/dosierskanilo/service/jsonoperations.d:621`

`mergeDataClassObjects()` starts with `objs[0].dup` but computes
`newobj.mediaInfoSig` from `objs[1 .. $]` only:

```d
MediaInfoSig mis = null;
foreach (obj; objs[1 .. $])
{
    if (!mis)
        mis = obj.mediaInfoSig;
    ...
}
auto newobj = (objs[0]).dup;
newobj.mediaInfoSig = mis;
```

If only the first blob has a media signature, `mis` stays null and the merged
record loses it. Conversely, metadata attached to later blobs (file type,
torrent info, archive specs, archive password) is never merged. The SQLite
analysis path has an explicit `mergeBlobMetadata()` fix; the JSON path still
uses this helper.

Impact: JSON analysis, including `scan --merge-duplicates`, can silently drop
media metadata from a surviving duplicate. This is a data-loss bug, although it
is limited to the JSON backend and metadata rather than the blob itself.

Fix: merge metadata from every member, not only `objs[1 .. $]`, and reject
conflicting values explicitly. Use the SQLite merge helper's field list as the
contract. Add a JSON test with metadata on the first duplicate and on a later
duplicate.

### M6 - Git-less release archives fail to build

`dub.json:22-24`; `source/dosierskanilo_cli/main.d:62`

`preGenerateCommands` runs:

```sh
git describe --long --always > build/bin/build-version.txt
```

A GitHub/GitLab source archive or a package recipe using
`archive/refs/tags/vX.Y.Z.tar.gz` has no `.git` directory. `git describe` exits
128, DUB aborts, and `build/bin/build-version.txt` is never created for the
compile-time import in `main.d`.

The probe exported `HEAD` with `git archive`, then ran
`DC=ldc2 dub build --config=cli`; it failed with
`Error Command failed with exit code 128: git describe --long --always ...`.

Impact: the published tag archives cannot be built by the supplied AUR,
Debian, Fedora, or Flatpak recipes. The release is only buildable from a Git
checkout.

Fix: make the pre-generation command tolerant, for example:

```sh
git describe --long --always > build/bin/build-version.txt 2>/dev/null \
    || echo "v26.12.0" > build/bin/build-version.txt
```

Alternatively, generate the version file only when `.git` exists and provide a
tracked fallback. Add a packaged-source build test.

### M7 - Distribution recipes are stale or incomplete

`packaging/arch/aur/dossierskanilo/PKGBUILD:2`, `:10`;
`packaging/fedora/dossierskanilo.spec:2`; `packaging/debian/changelog:1`;
`packaging/flatpak/org.dosierskanilo.DosierSkanilo.yml:11-17`

The packaging files still target `26.9.2` while `packaging/README.md:15` says
the current stable release is `26.12.0`. The Flatpak manifest downloads the
`v26.9.2` archive and only runs `install -Dm755 build/bin/dosierskanilo`; it
never runs `dub build`, so even after the version is updated the build will fail
unless a prebuilt binary is supplied. The AUR and Fedora recipes use the same
Git-less tag archive and inherit M6.

Impact: the release cannot be reproduced by the documented distribution
recipes, and the Flatpak manifest is not a build recipe at all.

Fix: update the version in every recipe, add a real build command to the
Flatpak manifest (or a source module that produces the binary), and test each
recipe against the actual release archive with network dependencies available.

### M8 - `!` in an archive container name breaks member availability

`source/dosierskanilo/repository/scanner.d:65-68`, `:209-210`, `:235-236`,
`:413-414`, `:418-424`

Staged physical paths are stored in canonical escaped form
(`escapeArchiveVirtualPath(relative)`), so `sample!.zip` becomes
`sample!!.zip`. `virtualContainerPaths()` instead keys containers by the
unescaped physical path returned by `parseArchiveVirtualPath().physicalPath`.
The membership checks in `upsertFileReference()` and `applyStagedMissing()`
therefore never match a container whose name contains `!`.

The probe created `sample!.zip` with `a.txt`, scanned it, deleted the archive,
and ran `scan --drop-missing`. The container reference became unavailable, but
`sample!!.zip!/a.txt` remained marked available.

Impact: archive members of `!`-named containers keep stale availability, survive
missing-file cleanup, and can remain as unreferenced catalog rows. This is a
data-consistency bug distinct from the fixed M14/M19 path handling.

Fix: key `virtualContainerPaths` by the canonical stored path, or escape the
physical path at every membership check. Add a test with `!` in the container
name and a deleted container.

## Minor

- `source/dosierskanilo/sqlitecatalogbackend.d:272-279`, `:459-466` - SQLite
  `listArchiveEntries()` and `listTorrentEntries()` do not validate unknown
  content IDs; they return an empty page. JSON throws `invalidIdentifier` at
  `jsoncatalogbackend.d:455-458`, `:570-573`. The prior Wave 5 claim that both
  backends reject unknown IDs is only true for JSON.
- `source/dosierskanilo/sqlitecatalogbackend.d:1315-1326` versus
  `jsoncatalogbackend.d:2350-2352` - SQLite accepts a cursor offset past the end
  of the result sequence and returns an empty page; JSON throws `invalidCursor`.
- `source/dosierskanilo/repository/transfer.d:248-257` - directory
  `fileCount` and `aggregateSize` subqueries ignore the active `CatalogFilter`,
  although `catalogbackend.d:448-450` documents "matching" counts. The JSON
  index has the same precomputed-count behavior at
  `jsoncatalogbackend.d:1979-1986`.
- `source/dosierskanilo/model/namedbinaryblob.d:2350-2374` -
  `updateTorrentInfo()` computes `torrentFiles` but then sorts all
  `obj.fileSpecs` and tries only the first one. If the first reference is not
  the `.torrent`, the exception is caught, the loop breaks, and valid torrent
  metadata is never extracted.
- `source/dosierskanilo/membercontentcache.d:365-378` - the cache key still
  uses only the content identity plus the member extension, so two members with
  different paths and the same extension collide. `:216-218` still removes a
  cached entry and its directory when the file disappeared, even if
  `leaseCount > 0`. Prior M18 is only partially addressed.
- `source/dosierskanilo/model/namedbinaryblob.d:1937-1953` - archive password
  retries loop until the callback eventually returns a correct password; a
  callback that keeps returning a wrong value can spin forever. Add a bound or
  a cancellation check.
- `source/dosierskanilo_cli/jsonvalidation.d:65-70`, `:73-107` - the existence
  check is only applied to `analyze`. `list --json missing.json` and
  `duplicates --json missing.json` exit 0 and print an empty result. The probe
  confirmed both commands succeed.
- `source/dosierskanilo_cli/parser.d:211`, `:274-275` with
  `source/dosierskanilo_cli/main.d:517-518`, `:622-623` - the CLI cannot enable
  deep archive scanning. `--scan-archives` is bound to a boolean, and the
  post-processing only assigns `argScanArchives = 1`; repeating the flag cannot
  make `argScanArchives > 1`, so `deepArchiveScan` is always `false` for CLI
  scans. This currently limits C1's CLI exposure but leaves the CLI feature
  inconsistent with the library default.
- `source/dosierskanilo/repository/repository.d:672-677` - `escapeLogValue()`
  escapes backslash, quote, newline, and carriage return but not tab or other
  control characters. A path containing a tab produces an invalid JSON line in
  the repository log.
- `.github/workflows/main.yml:126` - `deploy_staging` still runs on every push
  to `main`, while `CHANGELOG.md:122-123` says staging is manual. GitLab uses a
  manual rule at `.gitlab-ci.yml:84-85`; the GitHub workflow is inconsistent.
  `scripts/deploy.sh` is currently a no-op, so this is not urgent.
- `scripts/clean.sh:10-21` - all removals are relative to the caller's current
  directory. Running `/path/to/scripts/clean.sh` from another directory removes
  that directory's `build`, `public`, and JSON artifacts instead of the
  repository's.
- `scripts/install-dependencies.sh:86-92` - `HADOLINT_VERSION` is interpolated
  into `run_as_root sh -c "curl ... '$hadolint_url' ..."`. A value containing a
  single quote can break out and run commands as root. The variable is normally
  trusted, but the helper should not construct a shell string from it.
- `source/dosierskanilo/service/scanning.d:332-334` - the legacy single-threaded
  scan replaces `fileSpecs` with the existence-filtered array before checking
  its length, unlike the threaded path at `:283-285`. It can leave a blob with
  no references even when `--drop-missing` was not requested. The module is
  still exported from the public package facade.

## Strengths

- **Archive path normalization.** `normalizeArchiveEntryPath()` rejects
  absolute paths, traversal components, NUL bytes, and drive letters; the
  remaining `-`-prefix gap is the basis of C1 and should be closed without
  weakening those protections.
- **SQL safety.** User data continues to use bound parameters; no string
  interpolation into SQL was found in the reviewed paths.
- **Transactions.** Migrations, scan application, metadata persistence, and
  analysis use atomic transactions with rollback and cancellation checkpoints.
- **Prior remediation.** C1-C5 and most Wave 2-4 items remain fixed in the
  re-read code, including typed JSON backend errors, metadata timestamp bumps,
  archive member paging, and the backend lease paths.
- **Tests and documentation.** The inline unit tests, synthetic corpus,
  JSON/SQLite parity tests, CLI integration script, and architecture documents
  remain unusually strong for a project of this size.

## Recommended remediation order

**Wave 1 - security and data integrity.** C1, C2, M1, M3, M5, M8. Add the
targeted regression tests listed in each item before changing behavior.

**Wave 2 - correctness and release.** M2, M4, M6, M7. Fix the UTF-8 range
bounds, make torrent parsing fail cleanly, and verify every distribution recipe
against a real tag archive.

**Wave 3 - minor robustness.** The SQLite/JSON parity gaps, directory count
semantics, member cache residual, packaging/logging/script items, and the
legacy scanner.

## Open measurements and follow-ups

- [ ] Add a CLI or library regression test for C1 using a tar member named
      `--to-command=...` and assert that no command runs.
- [ ] Add a JSON scan test that changes file bytes with the same size and mtime
      granularity, then verifies that every digest and extractor field changes.
- [ ] Add POSIX tests for backslash filenames in both JSON and SQLite paths.
- [ ] Add a non-BMP archive member to the SQLite parity corpus and assert that
      it appears in `listArchiveEntries()`.
- [ ] Add an analysis cursor test that merges duplicates between page requests.
- [ ] Add malformed-torrent tests for missing keys, deep nesting, and a missing
      `info` dictionary; expected result is a failed item, not a process abort.
- [ ] Build each release archive from `git archive` and from the actual tag
      tarball before publishing.
- [ ] Re-run `DC=ldc2 ./scripts/test.sh` after the fixes; this review itself did
      not rerun the full suite.
