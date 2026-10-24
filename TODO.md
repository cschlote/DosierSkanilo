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
operation families, lease races while a second process is active, and
display-backed GTK operation start/progress/pause/cancel/refresh tests.
`test-cli.sh` covers SIGINT during JSON analysis, JSON scan, SQLite metadata,
SQLite scan, a large duplicate merge, catalog import, and catalog export; a
forked-process test covers basic cross-process lease exclusion. Do not
reintroduce an HMI-owned scan or analysis implementation.

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

- [x] WP-11.1: `Repository.open()` no longer rewrites `PRAGMA user_version` on
  every open, so steady-state opens leave the database file untouched (covered
  by a timestamp test). A 100,000-row repository serves 250-row pages in under
  10 ms and 1,000-row pages in about 40 ms wall time including process startup.
  No read-only open path was added: WAL still needs write access for `-shm` and
  `-wal`, so read-only mounts remain unsupported. Independent read connections
  are retained for concurrent queries.
- [x] WP-11.2: JSON archive-member pages now cache one per-directory member
  order and merge it with physical rows. The first page still materializes the
  member order. Backend/CLI work is complete; `loadDocumentPage`, `loadAllRows`,
  and the Blob virtual table are in the separate GTK frontend repository and are
  deferred until the GUI work starts.
- [x] WP-11.3: Keep the transitional Blob table coupled to the canonical JSON
  `NamedBinaryBlob` model for now. Source-neutral summary/detail DTOs are a
  WP-13 redesign prerequisite, not a local WP-11 API change.
- [x] WP-11.4: Reconcile the backend dependency diagram and close WP-00 baseline
  status; remaining large-path measurement is tracked under WP-11.2/WP-11.5.

WP-11 does not block WP-09 unless measurement or inspection reveals a correctness
issue.

## P2 — Network-filesystem compatibility decision

- [x] Evaluate SQLite repository placement on CIFS/SMB and record the decision:
  network mounts are unsupported until they provide cross-host locks, WAL shared
  memory, atomic rename, durable sync, and working hard links (or the copy
  fallback). `docs/DATABASE.md` lists the requirements, observed failures, and
  supported deployment alternatives. No representative CIFS/SMB environment is
  available for testing in this repository, so the restriction is documented
  rather than guessed at.

**Exit:** reviewed decision with evidence, constraints, and follow-up tasks; this
is a decision package, not an assumption that CIFS/SMB support must be implemented.
