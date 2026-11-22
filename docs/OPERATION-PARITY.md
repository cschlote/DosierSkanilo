# CLI/GTK Operation Parity (WP-09.5)

The CLI and GTK frontends construct the public request types from
`dosierskanilo.operations` and call `runOperation()`. The operation implementation
and typed summaries are therefore shared; frontend-specific code is limited to
argument/dialog mapping, progress presentation, and source refresh.

## Supported operation matrix

| Operation | SQLite repository | JSON catalog | CLI mapping | GTK Tools mapping |
| --- | --- | --- | --- | --- |
| Scan | `ScanOperationRequest` with scan and optional metadata options | `ScanOperationRequest` with explicit catalog and filesystem root, optional metadata; rejects `dropMissing` | `scan` | Scan dialog; JSON asks for the filesystem root |
| Metadata | `MetadataOperationRequest`, one or more extractors required | Unsupported as a standalone request | `metadata` | Metadata dialog enabled for repository documents |
| Analyze | `AnalysisOperationRequest`; optional metadata runs before drop-missing and duplicate merge | `AnalysisOperationRequest`; optional metadata runs before analysis | `analyze` / `analyze --json` | Analyze dialog; JSON offers optional metadata first |

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

## Manual GUI verification checklist

The items below cannot be exercised by the automated backend suites and must
be confirmed in the GTK self-test or by hand before a release. Record the
result and date in the verification stamp section.

| Item | Storage mode | Expected behaviour | Status |
| --- | --- | --- | --- |
| Save/Discard/Cancel on a modified JSON tab | JSON | Dialog offers all three choices; Cancel keeps the tab open | Not yet verified |
| Large-JSON open guard (>= 32 MiB) | JSON | "Cancel"/"Open Anyway" dialog appears; Cancel aborts load | Not yet verified |
| Pause/resume during scan | Both | Operation pauses at a checkpoint, resumes without data loss | Not yet verified |
| Pause/resume during metadata | Both | Acknowledged pause transition, no partial blob commit | Not yet verified |
| Pause/resume during analyze | Both | Transaction stays atomic across pause | Not yet verified |
| Single-file metadata rescan (`--only` / dialog) | SQLite | Only the selected repository file is processed | Not yet verified |
| Post-operation reload in owning tab | Both | Tab reloads after the operation within 10 s | Not yet verified |
| Archive deep-scan resume | Both | Completed archives are skipped on the next run | Not yet verified |

## Known gaps and not yet covered

The following parity areas are tracked but not yet verified end to end. Each
links to the backend plan or the GUI TODO.

- Archive deep-scan resume through the GUI Tools path (backend CLI path is
  covered by `test-cli.sh`).
- Metadata single-file rescan through the GUI dialog (backend `--only` path
  is covered).
- Operation pause while an archive scan is in progress.
- Cancellation of an in-progress archive member extraction lease.
- GUI-side comparison of metadata result counts (checksums, file types,
  media info) between JSON and SQLite on the synthetic corpus; the backend
  compares scan and analysis summaries only.
- Concurrent read queries while a write operation is active (no measurement
  or test exists yet).

## Verification stamp

Recorded against the backend repository state at the time of verification.

| Field | Value |
| --- | --- |
| Backend branch | `testing` |
| Backend commit | `a37b054` |
| Backend version | `26.18.0` |
| Verification date | 2026-11-22 |
| Backend unit tests | 280 (reported) |
| GUI unit tests | 80 (reported) |
| GUI coverage | 36.66 % (reported) |
| Manual GUI checklist | Not yet executed |

Update this stamp whenever the parity evidence is re-verified. The manual
checklist above must be completed before the next release tag is created.

## Verification evidence

- The GUI CI now runs an Xvfb-backed display job (`scripts/test-display.sh`):
  the unit suite with the display-gated virtual-table scroll test plus GUI
  startup/self-test smoke runs for JSON and repository documents. The self-test
  can also start scan, metadata, and analyze through the Tools path
  (`--self-test-operation`), which verifies progress/status handling and the
  post-operation refresh trigger, plus synthetic pause/resume and cancellation
  runs that honor operation checkpoints; the self-test also waits for the
  post-operation reload to complete in the owning tab (10s timeout).
- Basic cross-process contention and lease release after a backend failure are
  covered, and the CLI process-boundary check above confirms the non-blocking
  `targetBusy` behaviour. Cancellation/pause while another process is active
  cannot occur as a wait state: the write lease is non-blocking, so a second
  writer fails at once. Pause/cancel is verified while the first writer
  holds the lease in-process, and forked-process tests verify the operating
  system lock excludes another process. CIFS/SMB placement is documented as
  unsupported in `docs/DATABASE.md`; there is no operation-level verification to
  add unless network support is revisited.
