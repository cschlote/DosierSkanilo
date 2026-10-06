# Shared Operation API (WP-09.1)

This document freezes the frontend-neutral request and run-control contract for
long-running scan, metadata, and analysis operations. The public D types are in
`source/dosierskanilo/operations.d` and are re-exported by `import dosierskanilo`.
WP-09.1 defines the contract only; it does not make the synchronous repository
or JSON services cancellable. Controlled executors are added in WP-09.2.
Pause/resume is not part of the frozen WP-09.1 API; a planned WP-09.1b contract
extension will define it before operation executors are implemented.

## Storage-mode and operation matrix

- **Scan request:** repository mode requires an explicit repository root and
  accepts scan options plus optional metadata options. JSON mode requires both an
  explicit filesystem root and catalog path; it accepts scan/metadata options
  but rejects `dropMissing`.
- **Metadata request:** supported only for an explicit repository root and at
  least one selected extractor. JSON has no standalone metadata command.
- **Analysis request:** repository mode requires an explicit repository root
  and accepts analysis options, but no metadata options. JSON mode requires an
  explicit catalog path; optional metadata jobs run first to match existing
  `json analyze` behavior.

Targets are not inferred or converted. The caller resolves a repository root
before constructing a request. JSON scan must not initialize or discover a
SQLite repository; JSON analyze reads and writes only its explicit catalog.
Request validation checks the target shape and option combinations without
opening the paths; the executing operation performs filesystem/repository
validation and returns operational errors through its result.

`OperationTarget.jsonTarget(catalogPath, filesystemRoot)` requires both paths for
scan. `filesystemRoot` may be empty for JSON analysis, whose current CLI accepts
only a catalog argument. Repository targets must not also specify JSON paths.

## Existing CLI option mapping

The frontend adapters preserve current parser defaults and command validation.
Map these flags to typed request fields:

- `--recursive`, `--pick-hidden` map to scan options for SQLite/JSON scan.
- `--drop-missing` maps to repository scan or analysis options and JSON analysis;
  JSON scan rejects it.
- `--checksums`, `--file-types`, `--media-info`, `--rescan-media-info`,
  `--scan-torrents`, and `--threads` map to metadata options. They are available
  on SQLite scan/metadata and JSON scan/analyze as currently supported.
- `--scan-archives` maps to `metadataOptions.scanArchives = true` and
  `metadataOptions.deepArchiveScan = false`, matching current CLI behavior.
- `--rescan-media-info` is a modifier, not an extractor by itself; standalone
  metadata requests still require at least one selected extractor.

The current CLI exposes archive scanning as a flag, not a depth value. The
request retains the library's `deepArchiveScan` field for API compatibility, but
WP-09 frontend adapters must not present an unimplemented depth option as if it
were a CLI capability.

`--verbose` and terminal formatting remain frontend presentation settings, not
operation request fields. `--text`, `--limit`, `--offset`, media/presence query
filters and `--format` belong to read-only repository queries; `--replace` and
`--output` belong to import/export. They are not scan/metadata/analyze request
settings. Import/export are outside the first WP-09 operation set.

The request types intentionally reuse repository option structs.
`json analyze` keeps duplicate merging enabled, matching the current JSON
service; validation rejects an analysis request that disables it. Validation also
rejects an empty standalone metadata request and JSON scan `dropMissing`, as the
current CLI does.

## Request ownership

- Requests are value types. The operation runner takes a copy at dispatch and
  must not mutate the caller's copy.
- The caller assigns a nonzero `operationId`, unique among its currently active
  tasks. Progress and result values echo it; the backend does not allocate a
  process-global ID.
- Repository requests carry the existing `RepositoryScanOptions`,
  `MetadataScanOptions`, or `RepositoryAnalysisOptions`, not CLI `ArgsArray`.
- JSON scan may select metadata jobs supported by the existing `json scan`
  command. JSON analysis may select metadata jobs before analysis. No new JSON
  subcommand is implied by this API.

Validation returns `OperationRequestValidation`. An invalid request does not
start backend work and has a stable `OperationRequestError` code and diagnostic.
Filesystem existence, schema checks, permissions, and content errors are
operation-time failures, not request-shape errors.

## Lifecycle and progress

`OperationState` has these meanings:

- `queued`: the frontend has accepted the user request but has not dispatched it;
- `running`: the backend has begun processing;
- `cancelling`: cancellation was requested and the executor is stopping at a safe
  point or draining workers;
- `completed`, `cancelled`, `failed`: terminal outcomes.

Allowed transitions are `queued -> running|cancelled|failed`,
`running -> cancelling|completed|cancelled|failed`, and
`cancelling -> completed|cancelled|failed`. Terminal states never transition
again. A task may complete from `cancelling` if it passed its last safe
cancellation checkpoint before the request was observed.

Only the frontend/task manager owns queueing. Backend `OperationProgress` events
describe dispatched work and include the request ID, operation kind, state,
phase, optional current/total counts, current path, and human-readable status.
When `totalKnown` is false, `total` is ignored and clients display the message or
phase rather than inventing a percentage. The operation coordinator emits work
counts in order; they are monotonic within a phase and may restart when the phase
changes.

Progress callbacks are optional. `OperationControl.report()` invokes the
callback synchronously on the reporting worker thread and serializes concurrent
reports for one control object. The callback must copy/consume the value during
the call; it must not retain references to a worker's database objects or stack
data. GTK callbacks must enqueue a value copy to the main loop. CLI callbacks
write to the appropriate output stream and must not interleave progress lines.
Callback exceptions propagate to the operation executor and turn the operation
into a failed result; they must never bypass worker joining or transaction cleanup.

## Cancellation and storage semantics

`OperationControl.requestCancellation()` sets a thread-safe, sticky cancellation
flag. It is cooperative: a request is observed only at safe checkpoints. It does
not interrupt a filesystem syscall, an external metadata tool, or an active
SQLite statement. The executor must stop scheduling new work, drain/join started
workers, finish or roll back the current commit unit, and only then return.

The commit-unit policy is operation-specific and is fixed as follows:

- **SQLite scan:** one scan is atomic. Cancellation before commit rolls back all
  file-reference, missing-file, and `dropMissing` changes from that scan.
- **SQLite metadata:** one blob is the persistence unit. After cancellation, do
  not schedule another batch; drain the current batch and persist only complete
  blob results. A blob's requested metadata updates are committed together.
  Unfinished/pending jobs remain retryable on a later metadata run. Completed
  blobs from earlier batches remain committed and appear in the partial summary.
- **SQLite analysis:** analysis is atomic as it is today. Cancellation before
  commit rolls back missing-file changes, duplicate merges, and orphan cleanup
  together; a result never reports a half-merged catalog.
- **JSON scan/analyze:** mutate an in-memory catalog and do not replace the JSON
  file if cancellation is observed before the write phase. Once serialization and
  the established backup/replacement sequence starts, cancellation is deferred
  until that commit sequence finishes; return completed or failed, not cancelled,
  after the final safe checkpoint.

If cancellation arrives after the operation's last safe checkpoint, completion
wins and the terminal result is `completed`. If cancellation is observed before
that point, the terminal state is `cancelled`; rollback/partial commits follow
the policies above. Extractor failures that are represented in
`MetadataSummary.failed` do not by themselves make the whole metadata operation
`failed`; fatal orchestration/storage errors do.

## Planned pause/resume extension (WP-09.1b)

Pause and resume are a planned extension; the current `OperationControl` exposes
cancellation only. Before backend executors or GUI controls claim pause support,
WP-09.1b must extend the public run-control and lifecycle contract and add
deterministic tests for its races and state transitions.

The extension is expected to provide cooperative pause and resume requests. A
pause request is not an immediate suspension: the operation acknowledges
`paused` only at an operation-defined safe checkpoint, after the current
uninterruptible call or atomic persistence unit has finished and its workers have
been drained. Resume wakes the operation and continues from the acknowledged
checkpoint with its phase and progress state intact. Cancellation while paused
wakes the operation and takes precedence over waiting for resume.

The contract must also tell clients whether pausing is supported/available at
the current phase, so a GUI does not enable Pause when the next safe checkpoint
cannot be reached before completion. A pending request may still report
`pausing` while the operation finishes an uninterruptible unit.

An operation must not wait in the paused state while holding an active SQLite
transaction or statement, or while partway through the JSON backup/replacement
sequence. The exclusive per-target write lease remains held while paused, so a
second process cannot mutate the same repository/catalog before the operation
resumes or is cancelled. Independent SQLite readers may continue under the
existing WAL/snapshot rules. Progress must distinguish `pausing` from
`paused`; clients must not display the operation as paused until the backend has
acknowledged a safe point.

The WP-09.2 operation slices must define checkpoints individually. In particular,
SQLite scan and analysis currently promise operation-wide atomic transactions:
their pause design must not break that guarantee or wait indefinitely inside an
open transaction. If that requires staging or a revised commit-unit design, it
must be designed and tested before pause is advertised for those operations.
JSON pause points must remain outside its non-interruptible replacement sequence.

## Result and error contract

`OperationResult.state` is terminal. `operation` selects the summary field that
is meaningful: `scanSummary`, `metadataSummary`, or `analysisSummary`; unused
summary fields remain initialized. `errorCode` is `none` for completed and
cancelled results, `targetBusy` for an exclusive-target conflict,
`callbackFailure` for a progress callback exception, or `backendFailure` for an
operational error. `error` is an actionable diagnostic and may be empty for a
normal cancellation. Request-shape errors are returned by validation before an
operation starts.

## Mutation serialization decision

The backend operation coordinator is the authority for write serialization;
frontends must not implement competing lock policies. It uses the canonical
repository root or JSON catalog path as the target key and allows only one
mutating operation per target at a time across CLI and GUI processes. A direct
library caller that cannot acquire the target lease gets a `failed` result with
`targetBusy`; a GUI task manager may queue a task before dispatching it. Different
targets may run concurrently.

SQLite readers keep independent read connections and observe committed snapshots
under SQLite/WAL rules while the target lease blocks another mutator. JSON readers
may read the old catalog while an operation computes, but must not race the
catalog replacement step. The backend coordinator/lease implementation and its
cross-process tests are delivered in WP-09.2e; this policy is the contract that
implementation must satisfy.

## Current implementation boundary

The current public APIs remain synchronous:
`Repository.scan()`, `Repository.updateMetadata()`, `Repository.analyze()`, and
the direct JSON CLI services do not yet accept `OperationControl`. The request,
event, validation, result, and cancellation types introduced by WP-09.1 are a
stable contract for later slices, not an indication that operations can already
be cancelled. The first executable slice is SQLite scan followed by its CLI
adapter (WP-09.2a and WP-09.3a). Pause/resume types and behavior are not yet
implemented and remain planned in WP-09.1b.
