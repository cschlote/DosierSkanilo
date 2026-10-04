# TODO

## P1

- [x] `changelogUrl` in `scripts/build.sh` und `scripts/build-docs.sh`
  auf den kanonischen Pfad angleichen
- [x] `analyze.d`-Modulheader in der API-Doku präziser benennen

## P2

- [x] `NamedBinaryBlob`-Hash- und Const-Diagnostik bereinigen
  (`opEquals`, `toHash`, `toString`)
- [x] Markdown-Linting für `README.md`, `docs/ARCHITECTURE.md`,
  `CHANGELOG.md` und `TODO.md` ergänzen

## P1 — Close remaining WP-08 verification gaps

These are three independent, test-focused tasks. Their complete scope and exit
criteria are in `docs/SQLITE-IMPLEMENTATION-PLAN.md`, section WP-08.

- [ ] WP-08.1: Complete parser contract tests for valid/invalid SQLite and JSON
  commands, option boundaries, help/version behavior, and parser state isolation.
- [ ] WP-08.2: Add a genuine `dataVersion: 2` JSON wrapper fixture; import it via
  the public transfer API and verify migration/export semantics.
- [ ] WP-08.3: Verify filtered export is relationship-closed, preserves selected
  shared-blob references, and excludes references outside the requested scope.

Recommended order: finish these small tests before implementation of the shared
operation-control work. They do not block design of WP-09.1.

## P1 — Shared CLI/GTK operations (WP-09)

The detailed request inventory, package checklists, deliverables, and acceptance
criteria live in `docs/SQLITE-IMPLEMENTATION-PLAN.md`, section WP-09. Keep the
backend plan authoritative so the two repositories do not drift.

- [ ] WP-09.1: Freeze frontend-neutral requests/results, progress and
  cancellation semantics, threading/ownership, storage-mode mapping, and safe
  partial-result boundaries. Add contract-level tests and API documentation.
- [ ] WP-09.2: Implement the contract for SQLite scan/metadata/analysis and
  existing JSON scan/analyze services; test cancellation at deterministic safe
  boundaries and preserve valid storage state.
- [ ] WP-09.3: Convert CLI handlers to request/result adapters; map Ctrl-C to
  cooperative cancellation and preserve command, stream, and exit contracts.
- [ ] WP-09.4: Add GTK Tools actions and a background task manager with main-loop
  progress, real backend cancellation, per-target write serialization, and
  source refresh.
- [ ] WP-09.5: Compare CLI/GTK results and storage changes; cover progress,
  cancellation, errors, refresh, and explicit JSON/SQLite mode isolation.

Dependencies: WP-09.1 -> WP-09.2; after WP-09.2, WP-09.3 and WP-09.4 may
proceed in parallel; WP-09.5 requires both. WP-09.4 also depends on the existing
GUI source integration (WP-07).

## P2 — Network filesystem compatibility decision

- [ ] Evaluate SQLite repository placement on CIFS/SMB: document the locking,
  WAL, atomic-rename, and failure assumptions that the current repository makes;
  identify supported and unsupported mount configurations; test only where a
  representative environment is available.
- [ ] Record a decision on supported network filesystems and safe placement.
  If reliable locking/transactions cannot be established, document a clear
  restriction and actionable diagnostic rather than implying support.

**Exit:** a reviewed support decision with its evidence, constraints, and any
follow-up implementation/testing tasks; this item is a decision package, not an
assumption that CIFS/SMB support must be implemented.
