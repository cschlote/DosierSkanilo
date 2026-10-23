# Storage Benchmarks

These measurements are a baseline for the JSON-to-SQLite migration. They are
not a hardware-independent performance claim. Re-run
`scripts/benchmark-storage.sh` on the target machine before making design or
release decisions.

## Method

Synthetic wrapper catalogs were generated with 1,000, 10,000 and 100,000
records. Each record contained a unique relative filename, file size and
modification timestamp. The measurements used `/usr/bin/time` and the CLI
binary built with LDC.

The measured operations were:

- JSON load without writing output
- SQLite import into a new `.dosierskanilo` repository
- Full SQLite-to-JSON export

The SQLite import and full export deliberately exercise the compatibility
boundary. They are not representative of a paginated GUI query.

## Baseline

- 1,000 records: JSON `0.01 s`/`7 MB`; SQLite import `0.03 s`/`9 MB`;
  export `0.03 s`/`16 MB`.
- 10,000 records: JSON `0.14 s`/`25 MB`; SQLite import `0.27 s`/`30 MB`;
  export `0.28 s`/`30 MB`.
- 100,000 records: JSON `1.76 s`/`219 MB`; SQLite import `2.93 s`/`240 MB`;
  export `2.43 s`/`240 MB`.

The full JSON and full export paths still materialize the complete domain model.
SQLite becomes advantageous for the intended GUI path because repository page
queries apply filters and `LIMIT/OFFSET` before domain objects are created.

## Reproduction

```bash
./scripts/benchmark-storage.sh ./test/json_file_v2.json 3
```

For large synthetic catalogs, generate wrapper JSON with the required
`dataArray`, `dataVersion`, and file reference fields, then pass its path to
the script. Benchmark files should remain outside the Git repository.

## Repository Page Queries

The catalog page path used to load details and flags per blob. `list` on a
synthetic repository with 30,000 one-line files, `--limit 1000 --format json`,
issued about `4 * N + 2` statements for a page without media or archive data
(`4,002` for 1,000 rows). It now issues 14 statements for the page regardless
of row count; pages with media and torrent rows add only a fixed number of
stream and file queries.

Wall-clock time was unchanged in this measurement: 20 CLI invocations took
`0.73 s` before and `0.74 s` after (`~37 ms` each). Process startup and
in-process SQLite statement dispatch dominate at this size, so the statement
bound matters mainly for embedded/GUI refresh paths and larger metadata rows.
Measure the GUI page refresh on production data before drawing conclusions.

## Repository Open Behavior

`Repository.open()` used to execute `PRAGMA user_version` unconditionally after
migration, which rewrote the database header and updated its mtime on every
open. The version is now written only when it differs. Twenty `info` invocations
against a 100,000-row repository left the database mtime unchanged; a unit test
reopens an initialized repository after a short delay and asserts the same.

Read-only mounts are still unsupported: the repository uses WAL, and SQLite
needs write access to create or recover `-shm`/`-wal`. Opening a read-only copy
fails with `SQLITE_READONLY` (error 8). This is a filesystem-support decision,
not a read-path performance limit.

On the same 100,000-row synthetic repository (checksums only, no media or
archive details), `list --limit 250 --format json` completed in under 10 ms and
`--limit 1000` in about 40 ms per invocation, including process startup.

## Repository Rescan

A repository with 10,000 files in 100 directories was scanned, then rescanned
with no changes. Rescanning used to take about `1.9 s`; it now takes about
`0.2 s` (first scan about `0.39 s`). The temporary missing-reference candidate
table had no index on `relative_path`, so removing each still-present file from
the candidate set scanned the whole table, making the walk quadratic in the
number of present files. The temporary table now declares `relative_path UNIQUE`.
Staging and unchanged-file updates also reuse prepared statements instead of
preparing the same SQL for every file.

The scan also checks the virtual-container set once instead of issuing a
virtual-reference range query for every ordinary file. Peak RSS stayed around
10 MB on this fixture.

Reproduce with a local directory tree; the CLI scans the repository root:

```bash
mkdir -p /tmp/scanbench/data
# populate /tmp/scanbench/data
dosierskanilo init /tmp/scanbench
dosierskanilo scan /tmp/scanbench --recursive
dosierskanilo scan /tmp/scanbench --recursive
```

## JSON Archive Member Pages

`includeArchiveMembers` pages used to count duplicate member paths with a nested
scan and regenerate and sort the full member set for every page. A synthetic
catalog with one archive container and unique member paths showed the
quadratic path counting clearly: with 50,000 members the first 250-row page took
`6.5 s`. Replacing the nested count with one path-count pass reduced that to
`0.24 s`.

Member rows are now ordered once per directory and cached. The row array reserves
the known direct entry count before appending, which avoids repeated growth and
copying of the full member array. Physical rows and member rows are merged lazily
for path and size order, so later pages do not regenerate or sort the member set.
On the 100,000-member catalog the first 250-row page now takes about `86 ms` and
allocates about `46 MB`; the second page takes about `6 ms` and allocates about
`0.05 MB`. Measured with `GC.stats.allocatedInCurrentThread` in the benchmark.
The first page still builds the full member order, so peak memory remains
proportional to the number of members in the queried directory. The benchmark
process used about `680 MB` in total for that catalog, including JSON indexing and
content snapshots.

Reproduce with:

```bash
dub run --single scripts/benchmark-json-members.d --build=release -- 100000
```

## Follow-Up Measurements

- Measure a 250-row unfiltered repository page.
- Measure a 250-row path-filtered page.
- Measure MediaInfo/archive/torrent detail loading for one selected row.
- Compare GUI peak memory before and after page loading.
- Measure repeated JSON filter/apply/clear and directory-tree filter changes,
  including allocation/GC behavior where tooling permits; compare reuse against
  rebuilding the filtered projection/tree.
- Repeat measurements with the production media-library distribution.
