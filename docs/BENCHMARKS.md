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

## Follow-Up Measurements

- Measure a 250-row unfiltered repository page.
- Measure a 250-row path-filtered page.
- Measure MediaInfo/archive/torrent detail loading for one selected row.
- Compare GUI peak memory before and after page loading.
- Measure repeated JSON filter/apply/clear and directory-tree filter changes,
  including allocation/GC behavior where tooling permits; compare reuse against
  rebuilding the filtered projection/tree.
- Repeat measurements with the production media-library distribution.
