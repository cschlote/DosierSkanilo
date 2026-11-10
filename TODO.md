# TODO

Current engineering plan for the backend library, CLI, JSON transfer, and
SQLite repository. Historical work-package records remain in
[`docs/SQLITE-IMPLEMENTATION-PLAN.md`](docs/SQLITE-IMPLEMENTATION-PLAN.md);
user-visible changes are listed in [`CHANGELOG.md`](CHANGELOG.md).

## Current status (2026-11-10)

- Version `26.15.1`; storage-neutral `CatalogBackend`, JSON v5, SQLite schema
  v6, explicit JSON `CatalogDocument` sessions, shared operation API, member
  cache, recovery writer, and tag-driven release validation are implemented.
- WP-09, WP-13, WP-14, and the persistence/document-session work are complete.
- Backend verification: 222 tests, coverage 89.10 %, CLI checks and
  `scripts/lint.sh` pass; CI is green on `main`, and `testing` mirrors the same
  commit without deployments.
- Documentation and Ddoc headers are complete: every documentable public,
  package, and private declaration has Ddoc (verified 2026-11-08).
- The 2026-11-10 review is complete; its remediation is planned below and is
  the release blocker for the next version.

## P0 — Review remediation for the next release

Source: [`docs/reviews/2026-11-10-code-review.md`](docs/reviews/2026-11-10-code-review.md).

Target: the next release after `26.15.1`. This is a backward-compatible
bug-fix and robustness cycle; no public API is removed. Use `26.15.2` when the
cycle contains only fixes, or `26.16.0` when a new option or observable
behavior is added. Keep `27.0.0` separate.

Rules:

- One intent-named branch per item (`fix/...`, `feature/...`, `docs/...`).
- Every item lands with a regression test and a `CHANGELOG.md` entry.
- Run `DC=ldc2 ./scripts/test.sh` and `DC=ldc2 ./scripts/lint.sh` at each wave
  gate. Run the targeted probes from the review again before the release.
- Do not change the SQLite schema in this cycle. The `is_virtual` storage
  change is deferred to Major 27.

### Wave 1 — Security, data safety, destructive commands

- [ ] **R1.1 (C1) - Reject archive link members.**
      Reject symlink and hardlink entries in the tar, zip, rar, and 7z
      adapters, and add a central `MemberContentCache` guard that rejects
      `isSymlink(path)` and paths whose `realPath()` escapes the entry
      directory. Acceptance: tar and zip archives containing a symlink to an
      external file are indexed without following the target; preview returns
      an unextractable-member error, and the catalog contains no digest of the
      target.
- [ ] **R1.2 (C2) - Make force/restore safety backups WAL-safe.**
      Replace the raw rename in `backupExistingCatalog()` with a `VACUUM INTO`
      snapshot of the live connection (or move sidecars next to the renamed
      database under `<backupDb>-wal`/`<backupDb>-shm` and move the main file
      last). Acceptance: with a second connection holding uncheckpointed
      committed WAL frames, `init --force` and `restore --force` produce a
      safety backup that reopens with the expected row count.
- [ ] **R1.3 (C3) - Close the document-save conflict race.**
      Capture the catalog fingerprint when the backend loads the file, acquire
      the replacement lease before comparing, then re-read the fingerprint
      under the lease. Acceptance: two document sessions on the same path
      cannot both save; the second receives `writeConflict`, and an external
      rewrite between load and save is detected.
- [ ] **R1.4 (M1) - Make `restore()` staged and rollback-safe.**
      Copy the source next to the target, run `migrate()` and the schema
      assertions on the staged file, then swap old-to-backup and
      staging-to-target. Restore the old database if any step fails. Validate
      `schema_migrations`, `file_refs.is_virtual`, and the required tables.
      Acceptance: an invalid foreign database and an injected rename failure
      leave the live catalog usable. Depends on R1.2 for the safety snapshot.
- [ ] **R1.5 (M7) - Route archive-password writes through the staged writer.**
      Wrap the read in `setArchivePassword()` and use
      `commitJsonCatalog()`/`writeCatalogJsonFile()` instead of the
      truncate-in-place writer. Acceptance: a parse failure raises
      `CatalogBackendException`; a simulated write failure leaves the previous
      catalog readable.
- [ ] **R1.6 (M14) - Tolerate a missing optional `file` utility.**
      Catch process errors in `getFileUtilityVersion()` and `getFileType()` and
      return `"unknown"`/`null`. Acceptance: `scan --json` succeeds with a
      `PATH` that contains no `file` executable.
- [ ] **R1.7 (M15) - Validate `recover` and honor `--dry-run`.**
      Add a dedicated validator that rejects options other than
      `--restore-from` and `--no-input`, or implement `--dry-run` as a
      listing-only operation. Acceptance: `recover --dry-run --restore-from`
      does not change the catalog or create a backup; unsupported options exit
      with usage status 2.
- [ ] **R1.8 (M16) - Discover the repository root in `restore`.**
      Resolve `findRoot()` before choosing the target and require an explicit
      root when the user wants a new repository. Acceptance: `restore` from a
      repository subdirectory restores the discovered parent and does not
      create a nested `.dosierskanilo`.

### Wave 2 — Guard correctness and document/archive integrity

- [ ] **R2.1 (M2) - Close the filesystem-guard bypasses.**
      Classify `realPath()` of the database file and its parent, and process
      mountinfo in order so a later overmount wins. Treat an unclassifiable
      filesystem as an explicit warning or opt-in. Acceptance: unit tests
      cover a symlinked root/database and an overmount on an existing mount
      point; local ext4/xfs/btrfs/tmpfs/overlay/zfs remain accepted.
- [ ] **R2.2 (M3) - Prune unsupported mounts during the scan walk.**
      Build the unsupported-mount table before `dirEntries` and skip recursion
      into those directories. Acceptance: a stale FUSE/autofs subtree is not
      entered during discovering; existing references below it stay unchanged.
- [ ] **R2.3 (M4) - Always exclude the repository metadata directory.**
      Exclude the resolved `.dosierskanilo` path from repository scans even
      with `--pick-hidden`. Acceptance: `catalog.sqlite3`, `-wal`, `-shm`, and
      `logs/operations.jsonl` never appear as file references.
- [ ] **R2.4 (M8) - Skip null MediaInfo streams in the JSON adapter.**
      Make `mediaStreamsFor()`, snapshot flags, and content-row flags tolerate
      null entries and compute media state from non-null streams. Acceptance: a
      catalog with a null stream opens, lists, and exports without a
      `NullReferenceError`, and does not report phantom media.
- [ ] **R2.5 (M9) - Isolate document dry-run and failures.**
      Reject `dryRun` on document sessions with `unsupportedFeature`, or run
      the helper against a deep copy and swap only on success. Acceptance:
      dry-run and failed operations leave `modified()`, the buffer, and the
      query index unchanged.
- [ ] **R2.6 (M10) - Correct filtered JSON directory counts.**
      Count only rows whose `directoryId` equals the directory, plus matching
      members when `includeArchiveMembers`. Acceptance: filtered JSON counts
      equal unfiltered counts and SQLite counts for the same query.
- [ ] **R2.7 (M11) - Fix the `dir!/file` round-trip.**
      Keep the original canonical spec for non-virtual paths in
      `getExistingFiles()` or re-escape based on parsed identity instead of
      `canFind("!/")`. Acceptance: a `dir!/sample!.zip` record survives a
      legacy scan, metadata run, and JSON export/import without changing
      identity.
- [ ] **R2.8 (M12) - Do not promote partial archive indexes.**
      Build `archiveSpecs` locally and assign it only after the archive
      succeeds; catch digest/stat/nested failures and keep an index-only entry.
      Acceptance: a member that disappears during hashing leaves the previous
      complete index or a failed item, never a truncated index marked
      complete.
- [ ] **R2.9 (M13) - Extract ZIP members by index.**
      Use the Python `zipfile` path for all ZIP entries, or reject glob
      metacharacters. Acceptance: an archive with `foo*` and `foo1` extracts
      only the requested member and never restores symlinks.

### Wave 3 — Scalability, robustness, and UX

- [ ] **R3.1 (M5) - Clean unreachable blobs once per scan.**
      Remove the per-changed-file `deleteUnreachableBlobs()` call and run one
      cleanup after the staged files and missing references are applied.
      Acceptance: a rescan of many changed files executes one orphan query;
      record before/after timing in `docs/BENCHMARKS.md`.
- [ ] **R3.2 (M6) - Bound archive-member listing.**
      Batch container paths through a temporary table or bounded variable
      chunks, and apply identity deduplication and pagination in SQL.
      Acceptance: a container with more than the SQLite variable limit and an
      archive with one million synthetic members list a page without loading
      the full member set.
- [ ] **R3.3 - Harden backup and force-init edge cases.**
      Move or remove stale `-wal`/`-shm` on `init --force` even when the main
      database is absent; delete a partial `backupTo` target on failure and
      validate the destination filesystem; give force/restore backups a
      collision-free name. Acceptance: tests cover the missing-main-file case,
      an injected `VACUUM INTO` failure, and two backups in one second.
- [ ] **R3.4 - Unify repository errors and page validation.**
      Use `enforce!RepositoryException` in the public repository methods and
      validate `limit`/cursor before empty-detail early returns in the JSON
      backend. Acceptance: no public repository method throws
      `EnforceException`; JSON and SQLite reject `limit == 0` identically.
- [ ] **R3.5 - Fix the remaining CLI UX gaps.**
      Add `.before-restore-` to the recovery candidates; reject
      `--restore-from` outside `recover`; reject `--pretty` for `info`/`list`/
      `duplicates`; send verbose query diagnostics to stderr. Acceptance:
      `recover` lists its own safety copy, JSON query output stays valid with
      `--verbose`, and unsupported options exit 2.
- [ ] **R3.6 - Repair progress state and watcher lifetime.**
      Let the heartbeat use the shared line-state and header helpers, route
      verbose heartbeats to newline records, guard all heartbeat fields with
      `operationStateMutex`, and stop the cancellation watcher when the
      operation finishes. Acceptance: a heartbeat-only operation is erased
      before the summary, and a completed command leaves no polling thread.
- [ ] **R3.7 - Close the model/archive minors.**
      Handle v3 `!` names in `physicalPathForSpec()`; reject negative torrent
      `piece length` and use checked size addition; pass archive paths after
      `--` in listing commands; preserve leading/trailing whitespace in
      zip/7z listings; isolate per-item exceptions in the legacy scanner;
      clear digest outputs on cancellation; and remove archive test temp
      directories with `scope (exit)`. Acceptance: each item has a focused
      regression test, and the legacy scanner decision from P1 is applied
      first.
- [ ] **R3.8 - Update documentation for the repaired boundaries.**
      Document WAL-safe force/restore backups, the real filesystem-guard
      scope, exit codes in help/README, `--duplicate-limit` and `--format`,
      and the new test baseline. Acceptance: `DATABASE.md`, `README.md`, and
      `docs/development/testing.md` match the implemented behavior and pass
      Markdown lint.
- [ ] **R3.9 - Defer the `is_virtual` storage change.**
      Keep the generated `VIRTUAL` column for schema v6 and move the
      `STORED`/indexed form into the Major 27 baseline. Acceptance: no schema
      migration is added in this cycle and Major 27 lists the change.

### Release gate

- [ ] Re-run every targeted probe from the review and record the result in
      `docs/development/testing.md`.
- [ ] Full suite, CLI integration, lint, and the Ddoc build are green.
- [ ] `CHANGELOG.md` under `## Unreleased` covers every user-visible fix.
- [ ] `VERSION` and all packaging metadata use the chosen patch/minor version.
- [ ] Re-run [`docs/RELEASE-CHECKLIST.md`](docs/RELEASE-CHECKLIST.md), including
      the paired GUI release.
- [ ] Confirm the paired GUI release consumes the document-save/dry-run fixes,
      rejects symlink archive members in preview, and uses the corrected
      restore/recover messages.
- [ ] Verify installation from packaged artifacts and refresh the Flatpak
      source hash after tagging.

Definition of done: no Critical or Major finding from the 2026-11-10 review is
open, all regression tests are present, the schema is still v6, and the next
release passes the full verification gate.

## Major 27 — Collapse legacy formats and migrations

Target: `27.0.0` (deliberate major break; existing catalogs are rebuilt with a
fresh scan). The single-user operating model makes dropping historical formats
acceptable, but the cut must still be explicit and well tested.

Goal: keep exactly one persisted baseline:

- **JSON v5** is the only supported interchange format.
- The current SQLite baseline (v6, plus the one-time `is_virtual` storage bump,
  expected v7) is the only supported repository schema.
- If the cleanup changes the database shape, bump the schema once and make that
  new version the new baseline; do not carry old migrations forward.

Work items:

- [ ] Freeze JSON v5 and the 27 SQLite baseline (v6 plus the one-time
      `is_virtual` storage bump, expected v7).
- [ ] Include the deferred `is_virtual` storage change: make the column
      materialized/`STORED`, index it for physical/virtual filtering, and fold
      the one-time schema bump into the new baseline.
- [ ] Remove JSON readers, writers, and normalization for legacy root arrays and
      versions 0–4.
- [ ] Make v0–v4 JSON inputs fail with a clear, actionable error that tells the
      user to rescan or recreate the catalog.
- [ ] Remove schema migrations 1–5. New repositories are created directly at
      the 27 baseline; older repositories are rejected with a clear error.
- [ ] Remove now-dead compatibility DTOs, fixup helpers, archive-spec legacy
      conversion, fixtures, and tests.
- [ ] Keep the current v5 export/import path and the `backup`/`restore`
      commands. Backup remains the safety net for the migration.
- [ ] Remove or justify the remaining legacy public surface:
      `service/scanning.d`, the unused `verbose` argument on
      `deserializeDataClassJsonFile`, and other compatibility-only wrappers.
- [ ] Reduce JSON-format tests to the v5 contract and add explicit rejection
      tests for every removed input version.
- [ ] Reduce SQLite migration tests to fresh 27-baseline creation and add
      explicit rejection tests for every older schema version.
- [ ] Update `README.md`, `DATABASE.md`, `JSON-FORMAT.md`, `ARCHITECTURE.md`,
      `CATALOG-DOMAIN.md`, the testing guide, and release notes for the hard
      cut.
- [ ] Verify a fresh large-repository scan, metadata extraction, analysis,
      v5 export/import round-trip, backup, and restore.
- [ ] Release as `27.0.0` with a clear note that 26.x catalogs must be recreated
      or rebuilt from a current v5 export.

Definition of done: no production code path accepts a legacy JSON or SQLite
schema, a fresh repository works end to end, backup/restore works on the new
baseline, and the documentation no longer implies that old formats are readable.

## P1 — Catalog correctness and documentation follow-ups

- [ ] Decide the fate of the unused `verbose` parameter on
      `deserializeDataClassJsonFile`: keep it as a documented compatibility
      no-op until the next major release, or remove it with a deprecation note.
- [x] Document every documentable public, package, and private declaration,
      including fields, enum members, aliases, manifest constants, constructors,
      and functions with parameter/return contracts. All maintained modules keep
      `Authors`/`Copyright`/`License` headers.
- [ ] Decide whether the legacy public `service/scanning.d` scanner should be
      deprecated in favor of the shared JSON operation path, or retained as a
      compatibility API. Document the decision before changing the export.

## P2 — Deferred format and delivery work

- [ ] Design a later JSON catalog version that can round-trip complete torrent
      file lists and the remaining `TorrentInfo` fields. Do not extend v5
      silently; existing readers must keep their guarantees.
- [ ] Add distribution smoke checks for the supported package formats
      (Debian/Ubuntu/Alpine, Arch, Fedora, Flatpak) to the release evidence.
- [ ] Populate archive-member sizes and timestamps during shallow scans for ZIP,
      TAR, and 7z by parsing their listing output. RAR already supplies these
      fields from its shallow listing. The remaining formats leave member sizes
      at zero, so the GUI shows 0-byte entries until a deep scan extracts them.
- [ ] Decide whether direct JSON browsing needs a streaming reader/index for
      multi-million-record catalogs, or an explicit size guard that recommends
      repository import. Current direct JSON tabs hold the complete catalog and
      derived index in memory.
- [ ] Revisit network-filesystem SQLite placement only if a representative
      CIFS/SMB or NFS environment provides exclusive cross-host locks, working
      WAL shared memory, atomic rename, durable sync, and hard links (or the
      documented copy fallback). The current decision remains: unsupported;
      `Repository` now rejects these mount types before opening SQLite.

## Completed work (compact record)

- **WP-14.1–14.4:** JSON metadata error isolation, member-cache lifecycle,
  catalog limit/identity/count correctness, hardening, CLI validation,
  performance, recovery, and release-script fixes. All regression tests pass.
- **WP-09:** Shared typed scan/metadata/analysis requests, progress,
  cancellation, pause/resume, target leases, CLI/GTK adapters, and
  cross-process/display-backed verification in
  [`docs/OPERATION-PARITY.md`](docs/OPERATION-PARITY.md).
- **WP-13.1–13.6:** Catalog domain/backend contract, JSON v5 virtual archive
  references, SQLite schema v6 with escaped directory paths and generated
  `is_virtual`, shared extraction cache, GUI integration, archive directory
  projection, and double-escaped member compatibility.
- **Persistence models:** `CatalogPersistence`, JSON `CatalogDocument` sessions,
  explicit save/discard/conflict handling, and SQLite transactional-store
  semantics.
- **Release automation:** tag-driven validation/publishing, streaming catalog
  writer with recovery chain, interactive recovery prompt, `recover` command,
  and paired backend/GUI release checklist.
- **Network filesystem decision:** CIFS/SMB/NFS/WSL/FUSE remain unsupported
  until they satisfy the recorded locking and durability requirements.
- **Documentation/DDoc:** current-state docs, historical plan banner, complete
  module attribution headers, and Ddoc for every documentable declaration
  including private and package symbols.
