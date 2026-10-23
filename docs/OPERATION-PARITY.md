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
  JSON pause-before-replacement, and target-lease ownership. A forked process
  holds the lease lock while a second acquisition is rejected, proving the
  exclusion works across processes.
- `scripts/test-cli.sh` exercises JSON-target scan/analyze, SQLite scan with metadata,
  standalone metadata, analysis, import/export, mode isolation, and command output.
  It also sends SIGINT during a JSON analysis, a JSON scan, and SQLite
  metadata, checking the cooperative cancellation message, worker shutdown, an
  unpublished JSON catalog, and a still-usable repository.
- GUI `operationrequests.d` executes GUI-built requests against both modes and
  compares their scan, metadata, and analysis summaries. `operationtaskstate.d`
  tests acknowledged pause transitions, stale progress rejection, and refresh
  decisions from `OperationResult.changesCommitted`.
- The GTK startup self-test loads the Tools menu under
  `G_DEBUG=fatal-warnings`.

## Remaining verification

- Add process-level Ctrl-C tests for the remaining CLI operation families
  (SQLite scan, analyze, import, and export), including stream ownership and
  repository/catalog usability after cancellation.
- Add display-backed GTK interaction tests that start an operation from Tools,
  exercise Cancel/Pause/Resume, and verify progress and refresh in the owning tab.
- Basic cross-process contention is covered. Still open: cancellation/pause
  while another process is active, lease release after backend failure, and
  CIFS/SMB lock behavior.
