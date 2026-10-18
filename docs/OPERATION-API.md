# Shared Operation API (WP-09.1)

This document freezes the frontend-neutral request and run-control contract for
long-running scan, metadata, and analysis operations. The public D types are in
`source/dosierskanilo/operations.d` and are re-exported by `import dosierskanilo`.
WP-09.1 and WP-09.1b define the request, cancellation, and pause/resume
contracts. `runOperation()` executes the repository and explicit JSON-backed
scan/analyze request families; synchronous `Repository` methods remain
convenience wrappers. The separate `CatalogBackend` layer provides the
storage-neutral read/query contract used by adapters, while CLI and GTK stay
on top of these shared requests.

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
  direct-JSON behavior.

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

The request types intentionally reuse repository option structs. Validation
rejects an analysis request that disables duplicate merging. Validation also
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
- JSON-backed scan may select metadata jobs supported by the explicit JSON
  target. JSON analysis may select metadata jobs before analysis. No separate
  JSON subcommand is implied by this API.

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
  after the final safe checkpoint. JSON analysis retains unavailable source paths
  by default; it removes missing records only when `dropMissing` is explicitly
  selected.

If cancellation arrives after the operation's last safe checkpoint, completion
wins and the terminal result is `completed`. If cancellation is observed before
that point, the terminal state is `cancelled`; rollback/partial commits follow
the policies above. Extractor failures that are represented in
`MetadataSummary.failed` do not by themselves make the whole metadata operation
`failed`; fatal orchestration/storage errors do.

## Pause/resume contract (WP-09.1b)

`OperationControl` supports thread-safe `requestPause()`, `requestResume()`,
`setPauseAvailable()`, and `pauseAtCheckpoint()` in addition to cancellation.
The executor advertises pause availability only when a safe checkpoint is
reachable. A request made while pause is unavailable is rejected. Repeating an
accepted pause request is idempotent; resume returns false if no pause is pending.

`pauseAtCheckpoint(progress)` may be called only after the operation has drained
child workers and released active SQLite statements/transactions or other
non-interruptible resources. A pending request first reports `pausing` as normal
progress arrives, then the executor reports `paused` only after acknowledging the
safe point. The worker waits without holding storage resources. Resume wakes the
worker, which reports `running` with its phase and work counters preserved.
Cancellation clears any pending pause, wakes a paused worker, and takes precedence
over resume. A request racing with an operation's last checkpoint may be rejected
or completion may win; a terminal operation never becomes paused.

`OperationProgress.pauseAvailable` reflects whether a pause request is
currently accepted. `pausing` and `paused` are distinct states; frontends must
show Pause as acknowledged only for the latter. Callback invocations remain
serialized and execute on the reporting worker. Frontends must marshal copied
progress values to their UI thread.

Storage-safe checkpoint decisions for the first controlled executors:

- **SQLite scan:** stage discovered references and missing-file candidates in
  temporary tables using completed statements, with no main-catalog transaction
  open. Traversal/staging may pause. Apply staged changes in the existing single
  atomic transaction; pause is unavailable during that short commit unit, and
  cancellation is checked before commit so the transaction can roll back.
- **SQLite metadata:** compute outside write transactions, drain the active
  worker batch, and persist each blob's requested metadata in one transaction.
  Pause between committed blob units, never while an extractor worker or write
  transaction is active.
- **SQLite analysis:** prepare the merge/drop plan before the atomic write
  transaction, with pause points only while staging. Apply all analysis changes
  in one transaction; pause is unavailable during that commit unit.
- **JSON scan/analyze:** pause during in-memory computation before serialization
  and file replacement. Disable pause and defer cancellation once the established
  backup/replacement sequence begins.

The target write lease remains held throughout a pause. Independent SQLite
readers may continue under WAL snapshot rules. Each executor must implement and
test its own staging/checkpoint strategy before reporting pause as available.

## Result and error contract

`OperationResult.state` is terminal. `operation` selects the summary field that
is meaningful: `scanSummary`, `metadataSummary`, or `analysisSummary`; unused
summary fields remain initialized. `errorCode` is `none` for completed and
cancelled results, `targetBusy` for an exclusive-target conflict,
`callbackFailure` for a progress callback exception, or `backendFailure` for an
operational error. `error` is an actionable diagnostic and may be empty for a
normal cancellation. `changesCommitted` is true when the operation committed any
source mutation before its terminal outcome; it lets a frontend refresh after a
cancelled/failed metadata run that committed completed blob units while avoiding
refreshes for rolled-back scans/analysis or JSON work cancelled before replacement.
Request-shape errors are returned by validation before an operation starts.

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
take a shared catalog-read lease, so they may parse the old catalog while an
operation computes. The backup/replacement phase takes a short exclusive catalog
lease, preventing readers from racing the rename/write sequence. The backend uses
advisory cross-process target leases; broader process-boundary contention and
crash-release tests remain in WP-09.2e.

## Current implementation boundary

`Repository.scan()`, `Repository.updateMetadata()`, and `Repository.analyze()`
remain synchronous convenience methods. `runOperation()` provides controlled
SQLite scan/metadata/analysis and explicit JSON scan/analyze execution. The GUI
and CLI use those controlled request overloads. Target write leases cover the
full operation lifetime, including acknowledged pauses; direct synchronous
repository wrappers acquire the same repository lease.
