# TODO

Current engineering plan for the backend library, CLI, JSON transfer, and
SQLite repository. Historical work-package records remain in
[`docs/SQLITE-IMPLEMENTATION-PLAN.md`](docs/SQLITE-IMPLEMENTATION-PLAN.md);
user-visible changes are listed in [`CHANGELOG.md`](CHANGELOG.md).

## Current status (2026-11-02)

- Version `26.13.0`; storage-neutral `CatalogBackend`, JSON v5, SQLite schema
  v5, explicit JSON `CatalogDocument` sessions, shared operation API, member
  cache, recovery writer, and tag-driven release validation are implemented.
- WP-09, WP-13, WP-14, and the persistence/document-session work are complete.
- Backend verification: 199 tests, coverage 89.65 %, CLI checks and
  `scripts/lint.sh` pass; CI is green on `testing` and `main`.
- Documentation and Ddoc headers were refreshed on 2026-11-02.

## P0 — Prepare the next backend release

Target: `26.14.0` (minor release for the public catalog/document API additions
and behavior fixes since `26.13.0`).

- [ ] Confirm that no open item requires an incompatible public API change; if
      it does, move it to the next major release instead of this one.
- [ ] Re-run the release checklist in
      [`docs/RELEASE-CHECKLIST.md`](docs/RELEASE-CHECKLIST.md), including the
      paired GUI release.
- [ ] Move `## Unreleased` to `## Release 26.14.0` in `CHANGELOG.md`, update
      `VERSION` and package metadata, and commit the release notes.
- [ ] Create the annotated `v26.14.0` tag after the paired GUI tag is ready;
      verify that the tag workflow validates tag/VERSION/CHANGELOG and publishes
      the GitHub release.
- [ ] Update packaging metadata (`packaging/debian/changelog`, Arch, Fedora,
      Flatpak) for `26.14.0`; download the published source archive, update the
      Flatpak `sha256` pins, and verify installation from the packaged
      artifacts.
- [ ] Regenerate and review the Ddoc site (`scripts/build-docs.sh`) as part of
      the release evidence.

## P1 — Catalog correctness and documentation follow-ups

- [ ] Fix `CatalogDocument.applyScan`/`applyAnalysis` for `request.dryRun`:
      currently the JSON adapter updates the in-memory buffer while leaving
      `modified()` false and the query index stale. Either reject dry-run on
      document sessions with `unsupportedFeature`, or apply it to a deep copy
      and leave the live buffer untouched.
- [ ] Decide the fate of the unused `verbose` parameter on
      `deserializeDataClassJsonFile`: keep it as a documented compatibility
      no-op until the next major release, or remove it with a deprecation note.
- [ ] Reduce the remaining `dub lint --report` undocumented-declaration
      warnings. Prioritize public DTO fields, archive-adapter classes, and CLI
      parser types; private helpers can be documented only when it improves
      maintenance. The maintained module list must keep
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
      TAR, RAR, and 7z by parsing their listing output. Shallow scans currently
      leave member sizes at zero, which makes the GUI show 0-byte archive
      entries until a deep scan extracts them.
- [ ] Decide whether direct JSON browsing needs a streaming reader/index for
      multi-million-record catalogs, or an explicit size guard that recommends
      repository import. Current direct JSON tabs hold the complete catalog and
      derived index in memory.
- [ ] Revisit network-filesystem SQLite placement only if a representative
      CIFS/SMB or NFS environment provides exclusive cross-host locks, working
      WAL shared memory, atomic rename, durable sync, and hard links (or the
      documented copy fallback). The current decision remains: unsupported.

## Completed work (compact record)

- **WP-14.1–14.4:** JSON metadata error isolation, member-cache lifecycle,
  catalog limit/identity/count correctness, hardening, CLI validation,
  performance, recovery, and release-script fixes. All regression tests pass.
- **WP-09:** Shared typed scan/metadata/analysis requests, progress,
  cancellation, pause/resume, target leases, CLI/GTK adapters, and
  cross-process/display-backed verification in
  [`docs/OPERATION-PARITY.md`](docs/OPERATION-PARITY.md).
- **WP-13.1–13.6:** Catalog domain/backend contract, JSON v5 virtual archive
  references, SQLite schema v5 with generated `is_virtual`, shared extraction
  cache, GUI integration, archive directory projection, and double-escaped
  member compatibility.
- **Persistence models:** `CatalogPersistence`, JSON `CatalogDocument` sessions,
  explicit save/discard/conflict handling, and SQLite transactional-store
  semantics.
- **Release automation:** tag-driven validation/publishing, streaming catalog
  writer with recovery chain, interactive recovery prompt, `recover` command,
  and paired backend/GUI release checklist.
- **Network filesystem decision:** CIFS/SMB/NFS/WSL/FUSE remain unsupported
  until they satisfy the recorded locking and durability requirements.
- **Documentation/DDoc:** current-state docs, historical plan banner, module
  attribution headers, and public API documentation refreshed.
