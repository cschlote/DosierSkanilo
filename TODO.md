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

## P1 — Repository-/GUI-Integration

- [x] Stop eagerly loading every `RepositoryFile` in the GUI's repository
  directory-source initialization; root counts and aggregate size now use a
  bounded repository summary query.
- [x] Give each repository directory-source query its own read connection so
  concurrent background operations do not share a `Repository` instance.
- [ ] WP-09.1: Define shared operation requests/results, progress events,
  cancellation semantics, and safe boundaries.
- [ ] WP-09.2: Adapt SQLite repository and explicit JSON scan/metadata/analysis
  services to the shared operation-control contract.
- [ ] WP-09.3: Make CLI handlers console/progress adapters over shared operations.
- [ ] WP-09.4: Add the GTK task manager, Tools actions, status feedback, and
  cooperative cancellation over those same operations.
- [ ] WP-09.5: Verify result, progress, cancellation, and state parity across
  CLI and GUI for repository and JSON modes; see the detailed phases in
  `docs/SQLITE-IMPLEMENTATION-PLAN.md`.

## P2 — Shared query contract and integration

- [x] Add cross-source tests proving JSON and SQLite return the same filtered,
  sorted logical sequence and `next`/`previous` behavior.
- [ ] Add filtered-export relationship-closure tests.
- [x] Add a GUI adapter fixture with more than 250 archive and torrent entries
  and verify continuation plus full nested paths on later pages.
- [x] Test the GTK TreeStore reply guard rejects a response after the selection
  token changes; continuation-marker activation and later-page leaf copying also
  have opt-in TreeView signal tests.

## P3

- [ ] CIFS/SMB SQLite locking compatibility and safe repository placement
  decision
