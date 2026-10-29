# TODO

Completed small maintenance items retained for context:

- [x] Align `changelogUrl` in `scripts/build.sh` and `scripts/build-docs.sh`.
- [x] Clarify the `analyze.d` API documentation module header.
- [x] Clean up `NamedBinaryBlob` hash/const diagnostics (`opEquals`, `toHash`,
  `toString`).
- [x] Add Markdown linting for the README, architecture, changelog, and TODO.

Prior review remediation is complete: every Critical and Major item of
`docs/reviews/2026-10-21-code-review.md` and
`docs/reviews/2026-10-24-code-review.md` is fixed with regression tests
(verified in `docs/reviews/2026-10-28-code-review.md`).

## P1 — WP-14: Remediate the 2026-10-28 review findings

Detailed findings are in `docs/reviews/2026-10-28-code-review.md`. Work
bottom-up in the order below; every subpackage lands its listed regression
tests before or with the code change.

### WP-14.1: JSON metadata error isolation (review M1, M3) — DONE

Currently one bad file aborts an entire JSON scan/analyze.

- Per-blob `try`/`catch` in `runJsonMetadataWork` /
  `runJsonMetadataBatch` (`service/jsonoperations.d`), counted into a
  metadata summary like the SQLite path; only cancellation exceptions pass
  through.
- Null-safe `MediaInfoSig`: stop appending null stream objects in
  `metadata/mediainfosig.d` parsing loops; keep `opEquals`/`dup`/`toString`
  null-safe on both sides.
- Acceptance: a corrupt archive or pathological media file yields a failed
  item and a completed run, including the duplicate-merge equality path.
  Regression tests: one corrupt archive among good files; a null-stream
  signature through `toString`/`opEquals`/`mergeDataClassObjects`.

- [x] Per-blob exception isolation with per-job failure messages and
  `summary.failed` counting, covering the threaded batch (structural
  pointer fix; the worker previously mutated a struct copy, so failures
  were silently discardable).
- [x] Parser-side null-skip plus defensive null filtering in
  `MediaInfoSig.toString` for catalogs written before the fix.
- [x] Regression tests "JSON metadata batch isolates per-item failures",
  "JSON metadata run survives corrupt archive alongside good files",
  "MediaInfoSig tolerates null stream references from old catalogs".

### WP-14.2: Member-content-cache lifecycle (review M2)

- Preserve lease accounting for disposed (`stale`) entries so `release()`
  and the `close()` guard observe them; track an outstanding-lease counter.
- Fix the `cleanupStaleSessions` visibility race on a freshly created
  session root (`membercontentcache.d:213-223`, `:318-332`).
- Document or serialize the `configureSharedMemberContentCache()` swap with
  active users.
- Acceptance: closing the cache under an outstanding lease on a removed
  member file either waits or keeps the file readable; no lease read reaches
  a deleted tree. Regression test at `close()` with a lease outstanding.

- [x] Outstanding-lease counter alongside per-entry counts; leases now
  identify their entry so release/update survive entry replacement.
  Closed paths stay intact while a lease on a vanished file remains, and
  `close()` refuses while any lease is outstanding.
- [x] Session lease acquired before the session directory becomes visible,
  closing the `cleanupStaleSessions` race window.
- [x] `configureSharedMemberContentCache()` documented as
  pre-usage-only swap.
- [x] Regression test "member cache keeps lease accounting for stale
  entries and close honours it".

### WP-14.3: Catalog API correctness (review M4, M5, M6)

- Typed `limit > 0` enforcement in the public
  `loadCatalogQueryPageWithIdsFromDatabase()` and every
  `repository/transfer.d` function touching `options.limit - 1`; limit-0
  unit tests (currently `RangeError` process abort).
- Keep the original spec for non-virtual paths in
  `getExistingFiles()` (`model/namedbinaryblob.d`) so canonical `!!` names
  round-trip; add the legacy-scanner `!!` round-trip test or delete the dead
  legacy `service/scanning.d` module (decide with the GUI repo first).
- Recompute JSON directory `fileCount`/`aggregateSize` per active filter in
  `matchingDirectories()` or relax the `catalogbackend.d` contract doc;
  restore JSON/SQLite parity with a `listDirectories` filter-count test.
- Follow-up: replace the textual `'!!' -> ''` classification in
  `repository/archiveindex.d` with a stored `is_virtual` column when the
  WP-13 schema is next touched (latent, no today-reachable defect).

- [x] Typed `RepositoryException` for zero limits in
  `loadCatalogQueryPageWithIdsFromDatabase()` (cursor crash site) and the
  `loadCatalogQueryPageWithIds`/`loadCatalogQueryCursorPage` wrappers;
  limit-0 test covering both wrappers and the free function.
- [x] `getExistingFiles()` deliberately keeps returning the openable
  (unescaped) physical name — callers open files with it. The corruption
  entered through the legacy write-back, which now re-escapes canonical
  `!!` names (`canonicalizeFileSpecs` in `service/scanning.d`, with a
  round-trip test); the `scanning.d` deletion question stays open for the
  GUI repo.
- [x] `matchingDirectories()` recomputes filtered counts and aggregate
  sizes (archive members included when requested), restoring JSON/SQLite
  parity; extended the non-BMP directory test with unfiltered/filtered
  count assertions.
- [ ] archiveindex `is_virtual` column follow-up (deferred to WP-13 schema).

### WP-14.4: Review-minor hardening and UX

Split churn from correctness; each item is independently landable.

- Operational robustness: backup name collisions within one second
  (`service/storageio.d`, `repository/repository.d` — append counter/UUID);
  metadata cleanup transaction outside `scope (exit)` at
  `repository/metadata.d:196-208`; progress/`makeProgressString` thread
  safety and `total == 0` NaN guard; JSON metadata batch cancellation
  checkpoints.
- CLI validation: reject bad `--format` for JSON `list`/`duplicates`;
  honor or reject `--pretty` for `info`/`list`/`duplicates`;
  `--duplicate-limit 0` becomes a usage error (exit 2) before backend open;
  document the exit-code contract (0/1/2) in help text.
- Performance: early-exit path-existence query instead of full-catalog
  `catalogHasPath`; inverse map for `contentTokenForBlobIndex()`.
- Documentation/scripts: derive `ROOT_DIR` from script location in
  `scripts/test-cli.sh`; dynamic markdown list and `--config=cli` in
  `scripts/lint.sh`; verify Flatpak sha256 pins against the published
  `v26.12.2` artifacts before the next release.

- [x] Backup names disambiguated with process id and per-process serial in
  `getBackupFileName()` and `backupDatabase()`; collision tests updated to
  glob by prefix.
- [x] `makeProgressString` NaN guard for a zero total (statics are already
  thread-local in D, so the suspected race was a non-issue).
- [x] CLI: bad `--format` rejected for JSON `list`/`duplicates`,
  `--duplicate-limit 0` is a usage error (exit 2) before backend open in
  both validation paths, `--pretty` documented as scan/analyze/export only,
  exit-code contract documented on `main()`.
- [x] `scripts/test-cli.sh` resolves `ROOT_DIR` from its own location and
  runs `dub` from the repository root; `scripts/lint.sh` lints
  `--config=cli` and discovers `docs/reviews/*.md` dynamically.
- [ ] Deferred: metadata cleanup transaction shape
  (`repository/metadata.d`), JSON metadata batch cancellation checkpoints,
  early-exit path-existence query, inverse content-token map, Flatpak
  sha256 verification against published artifacts.

## P1 — WP-09 closeout: shared CLI/GTK operations

The backend plan in `docs/SQLITE-IMPLEMENTATION-PLAN.md`, section WP-09, is
the source of truth. Implementation is complete (WP-09.1/09.1b contracts,
controlled SQLite and JSON operations, writer leases, CLI and GTK adapters
on the same typed requests); only verification remains:

- Process-level Ctrl-C checks for the remaining operation families.
- Lease races while a second process is active.
- Display-backed GTK operation start/progress/pause/cancel/refresh tests.

`test-cli.sh` already covers SIGINT for JSON analysis/scan, SQLite metadata/
scan, large duplicate merge, catalog import/export, and a forked-process
lease-exclusion test. Do not reintroduce an HMI-owned scan or analysis
implementation.

## P1 — WP-13.6.x: complete the storage-neutral catalog rollout

`docs/SQLITE-IMPLEMENTATION-PLAN.md`, sections WP-13 and WP-13.6, remain the
plan of record. WP-13.6.1 (CLI virtual archive references) is merged; next
steps in dependency order:

- [ ] WP-13.6.2: GTK backend and cache integration (`DosierSkanilo-Gui`),
      including the WP-11.2 deferred display work (`loadDocumentPage`,
      `loadAllRows`, blob virtual table).
- [ ] WP-13.6.3: cross-frontend parity checks for the new reference,
      duplicate, and export surfaces.
- [ ] Document in the WP-13 contract that blob-level digests for
      pure-virtual members are supplied only by the container's
      `ArchiveSpec.checkSums`, so JSON duplicate analysis excludes them by
      design (found correct-but-undocumented in the 2026-10-28 review).

## P2 — WP-14 follow-on: archiveindex virtual classification

Folded into WP-14.3; listed here only for priority ordering. It becomes its
own slice if the WP-13 schema work does not land first.

## P2 — Network-filesystem compatibility decision

- [x] Evaluate SQLite repository placement on CIFS/SMB and record the
  decision: network mounts are unsupported until they provide cross-host
  locks, WAL shared memory, atomic rename, durable sync, and working hard
  links (or the copy fallback). `docs/DATABASE.md` lists the requirements,
  observed failures, and supported deployment alternatives.

**Exit:** decision reviewed with evidence, constraints, and follow-up tasks;
this is a decision package, not an assumption that CIFS/SMB support must be
implemented.
