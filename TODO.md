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

- [ ] Stop eagerly loading every `RepositoryFile` in the GUI's repository
  directory-source initialization just to build root summaries; expose the
  required counts/aggregates through bounded repository summary queries.
- [ ] Ensure concurrent background GUI queries use independent repository read
  connections rather than sharing one `RepositoryDirectorySource` connection.

## P2 — Shared query contract and integration

- [ ] Add cross-source tests proving JSON and SQLite return the same filtered,
  sorted logical sequence and `next`/`previous` behavior.
- [ ] Add filtered-export relationship-closure tests.
- [ ] Coordinate with `DosierSkanilo-Gui` on a fixture with more than 250 archive
  and torrent entries and verify continuation, stale-result rejection, and
  selection/path behavior across chunks.

## P3

- [ ] CIFS/SMB SQLite locking compatibility and safe repository placement
  decision
