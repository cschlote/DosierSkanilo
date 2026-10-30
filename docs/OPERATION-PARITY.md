# CLI/GTK Operation Parity (WP-09.5)

The CLI and GTK frontends construct the public request types from
`dosierskanilo.operations` and call `runOperation()`. The operation implementation
and typed summaries are therefore shared; frontend-specific code is limited to
argument/dialog mapping, progress presentation, and source refresh.

## Supported operation matrix

| Operation | SQLite repository | JSON catalog | CLI mapping | GTK Tools mapping |
| --- | --- | --- | --- | --- |
| Scan | `ScanOperationRequest` with scan and optional metadata options | `ScanOperationRequest` with explicit catalog and filesystem root, optional metadata; rejects `dropMissing` | `scan --json` | Scan dialog; JSON asks for the filesystem root |
| Metadata | `MetadataOperationRequest`, one or more extractors required | Unsupported as a standalone request | `metadata` | Metadata dialog enabled for repository documents |
| Analyze | `AnalysisOperationRequest`, drop-missing and duplicate merge | `AnalysisOperationRequest`; optional metadata runs before analysis | `analyze --json` | Analyze dialog; JSON offers optional metadata first |

Targets are not inferred or converted. JSON operations do not create a SQLite
repository; repository operations do not write a JSON catalog implicitly.

## Automated evidence

- Backend `operationrunner.d` compares JSON and SQLite scan, checksum, and
  duplicate-analysis summaries plus the resulting shared-file relationships.
- Backend operation tests cover staged scan cancellation/resume, metadata batch
  commits and pause/resume, analysis rollback boundaries, JSON cancel-before-write,
  JSON partial-save cancellation, JSON pause-before-replacement, and target-lease
  ownership. A forked process
  holds the lease lock while a second acquisition is rejected, proving the
  exclusion works across processes.
- `scripts/test-cli.sh` exercises JSON-target scan/analyze, SQLite scan with
  metadata, standalone metadata, analysis, import/export, mode isolation, and
  command output. It checks that successful scans and analyses report their
  progress phases in lifecycle order (JSON adds its read/write phases), that
  per-phase work counts never move backwards, and that cancellation always
  exits with code 1 instead of 0 or the usage-error code.
- The same script sends SIGINT during a JSON analysis, a JSON scan, SQLite
  metadata, a SQLite scan, a large SQLite duplicate merge, a catalog import, a
  full catalog export, and a selected (`--path`) export. It checks the
  cooperative cancellation message, worker shutdown, a saved partial JSON
  catalog, a dry-run that writes nothing, a rolled-back merge, an unchanged
  repository, a still-usable repository, and that no export publishing path is
  left behind.
- Lease contention is checked at the process boundary: while one CLI process
  holds the repository write lease, a second mutating command fails fast with
  `Another mutating operation already owns target` and leaves stdout empty.
- GUI `operationrequests.d` executes GUI-built requests against both modes and
  compares their scan, metadata, and analysis summaries. `operationtaskstate.d`
  tests acknowledged pause transitions, stale progress rejection, and refresh
  decisions from `OperationResult.changesCommitted`.
- The GTK startup self-test loads the Tools menu under
  `G_DEBUG=fatal-warnings`.

## Catalog read/identity parity (WP-13.6.3)

The cross-adapter suites in `sqlitecatalogbackend.d` open the same fixture as a
JSON catalog and a SQLite repository and compare:

- Directory/reference resolution (`resolveDirectory`, `resolveReference`,
  `loadReference`) and opaque `uiHandle` values, including virtual members.
- Archive entry and member pages, nested archives, duplicate occurrences, and
  `acquireMemberContent` extraction leases.
- Deduplicated content rows (`listContents`), digest filters, and cursors.
- Filtered file/directory reads and root summaries.
- Archive-password storage and clearing by reference path.
- Subset exports for physical and virtual paths plus import round-trip checks.
- Duplicate groups and filtered reads on a controlled scan
  ("JSON and SQLite backends agree on duplicate groups and filtered reads").

Operation requests, cancellation, leases, and committed-state refresh stay
covered by the WP-09 evidence above; the GUI now consumes the same catalog
methods for trees, content rows, details, entries, and previews.

## Remaining verification

- Add display-backed GTK interaction tests that start an operation from Tools,
  exercise Cancel/Pause/Resume, and verify progress and refresh in the owning tab.
- Basic cross-process contention and lease release after a backend failure are
  covered, and the CLI process-boundary check above confirms the non-blocking
  `targetBusy` behaviour. Cancellation/pause while another process is active
  cannot occur as a wait state: the write lease is non-blocking, so a second
  writer fails at once. Pause/cancel is verified while the first writer
  holds the lease in-process, and forked-process tests verify the operating
  system lock excludes another process. CIFS/SMB placement is documented as
  unsupported in `docs/DATABASE.md`; there is no operation-level verification to
  add unless network support is revisited.
