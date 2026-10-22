# TODO

Completed small maintenance items retained for context:

- [x] Align `changelogUrl` in `scripts/build.sh` and `scripts/build-docs.sh`.
- [x] Clarify the `analyze.d` API documentation module header.
- [x] Clean up `NamedBinaryBlob` hash/const diagnostics (`opEquals`, `toHash`,
  `toString`).
- [x] Add Markdown linting for the README, architecture, changelog, and TODO.

## P1 — Close WP-08 verification gaps

Detailed scope and acceptance criteria are in
`docs/SQLITE-IMPLEMENTATION-PLAN.md`, section WP-08.

- [x] WP-08.1: Test valid and invalid SQLite/JSON parser inputs, option
  boundaries, help/version behavior, and parser state isolation.
- [x] WP-08.2: Add a genuine `dataVersion: 2` fixture and verify import,
  migration, and version-3 export; correct the broad existing test name that
  currently implies version-2 coverage.
- [x] WP-08.3: Verify filtered export is relationship-closed, preserves selected
  shared-blob references, and excludes references outside the requested scope.

These are independent test-closeout tasks. They do not block WP-09.1 contract
design, but should be complete before WP-09 parity closeout.

## P1 — Review-discovered correctness work (WP-10)

Detailed regression requirements are in `docs/SQLITE-IMPLEMENTATION-PLAN.md`,
section WP-10. Confirm each suspected issue with a test before changing code.

- [x] WP-10.1: Restore case-sensitive path matching parity in blob/catalog
  queries and the GUI Blob table; keep exact SHA1 matching independent of path
  case and document the accepted digest representation.
- [x] WP-10.2: Verify `markMissing` reconciles 40 simultaneous missing rows
  with present/hidden controls; the configured SQLite/D2-SQLite test showed no
  skipped rows, so no iteration rewrite was needed.
- [x] WP-10.3: Define changed-file orphan cleanup and per-run
  `filesMissing`/`filesDropped` summary semantics; test shared blobs and repeated
  file changes.

WP-10.1 depends on the GUI source/query integration (WP-07); WP-10.2 and WP-10.3
depend on the repository scanner (WP-04). These correctness fixes should land
before the affected operation slices, especially WP-09.2a.

The multi-row `markMissing` regression passed for 40 vanished references on the
configured SQLite/D2-SQLite target; no skipped-row defect was reproduced, so no
scanner iteration rewrite was made. Changed-file scans now remove an old blob
only after its final reference moves away.

## P1 — Shared CLI/GTK operations (WP-09)

The backend plan in `docs/SQLITE-IMPLEMENTATION-PLAN.md`, section WP-09, is the
source of truth for the request contract, safe cancellation semantics, and
acceptance criteria.

Implemented: WP-09.1/09.1b contracts, controlled SQLite and JSON operations,
repository/catalog writer leases, initial SQLite/JSON CLI adapters, and GTK Tools
actions using the same typed requests. Backend and GUI tests compare source modes,
request construction, task-state reduction, and refresh decisions.

Remaining verification is enumerated in WP-09 and
`docs/OPERATION-PARITY.md`: process-level Ctrl-C checks for the remaining
operation families, multi-process lease races, and display-backed GTK
operation start/progress/pause/cancel/refresh tests. `test-cli.sh` now covers
SIGINT during a JSON analysis. Do not reintroduce an HMI-owned scan or analysis
implementation.

## P1 — Storage-neutral catalog and archive-content model (WP-13)

The domain/API redesign is recorded in
`docs/SQLITE-IMPLEMENTATION-PLAN.md`, section WP-13. Work bottom-up: freeze
content/reference identities and virtual archive locators, then define the
polymorphic JSON/SQL catalog interface, port the existing adapters, and finally
make archive members first-class content references. Keep SQLite as the only
implemented SQL engine until adapter portability requirements are tested.

## P2 — Read-path and API-boundary audit (WP-11)

Investigation first: the review raised possible performance costs and an
intentional transitional type coupling, not all confirmed defects.

- [ ] WP-11.1: Benchmark steady-state repository opens/tree queries and inspect
  which `Repository.open()` steps write after initialization. Add a read-only
  open path only if measurements or write behavior justify it; retain
  independent connections for concurrent queries.
- [ ] WP-11.2: Trace production JSON paging/materialization call paths and
  measure representative JSON and virtual-table memory/latency before caching or
  changing load behavior.
- [ ] WP-11.3: Decide whether the transitional Blob table remains coupled to
  `NamedBinaryBlob` or migrates to source-neutral summary/detail DTOs.
- [x] WP-11.4: Reconcile the backend dependency diagram and close WP-00 baseline
  status; remaining large-path measurement is tracked under WP-11.2/WP-11.5.

WP-11 does not block WP-09 unless measurement or inspection reveals a correctness
issue.

## P2 — Network-filesystem compatibility decision

- [ ] Evaluate SQLite repository placement on CIFS/SMB: document locking, WAL,
  atomic-rename, backup, and failure assumptions; identify supported and
  unsupported mount configurations; test only where a representative
  environment is available.
- [ ] Record a support decision. If reliable locking/transactions cannot be
  established, document a clear restriction and actionable diagnostic rather
  than implying support.

**Exit:** reviewed decision with evidence, constraints, and follow-up tasks; this
is a decision package, not an assumption that CIFS/SMB support must be implemented.
