# Release Checklist

Use this checklist for a backend + GUI release pair. Both repositories are
released from the same integration branch and each tag is prefixed with `v`.

## Preconditions

- [ ] Backend and GUI working trees are clean (`git status`).
- [ ] The integration branch is pushed to every mirror and `main` is merged.
- [ ] CI on `main` passed, including the GUI Xvfb display job.
- [ ] Untracked local review/scratch files are committed or removed.

## Automated verification

- [ ] Backend: `DC=ldc2 ./scripts/test.sh` (unit tests, CLI integration, coverage).
- [ ] Backend: `./scripts/lint.sh`.
- [ ] GUI: `DC=ldc2 ./scripts/test.sh` and `./scripts/build.sh`.
- [ ] GUI display suite: `./scripts/test-display.sh` (Xvfb) — unit suite with
      display-gated tests, JSON/repository self-tests, splitter/video-sink checks,
      and the 95,001-record JSON/SQLite smoke loads.
- [ ] GUI: `./scripts/benchmark-filters.sh 1000 10000 100000` reviewed for
      regressions.
- [ ] Backend: `./scripts/benchmark-storage.sh ./test/json_file_v2.json 3`
      reviewed for storage regressions.

## Manual verification

- [ ] Open a JSON catalog and a repository, run scan/metadata/analyze through
      Tools, and verify progress, pause/resume, cancel, and tab refresh.
- [ ] Modify a JSON tab, verify the `*` marker, Save (Ctrl+S), Reload prompt,
      Revert to Stored, and save-conflict handling.
- [ ] Preview archive members, including nested and encrypted archives.
- [ ] Verify video preview sink selection on X11 and on a Wayland session.
- [ ] Load the 95k-record JSON and SQLite catalogs and inspect table scrolling,
      filtering, and per-batch render times.
- [ ] Exercise `recover` listing/restore and the GUI recovery-copy dialog.
- [ ] Build and install the Debian, Arch, Fedora, and Flatpak packages; launch
      the installed GUI.

## Version and notes

- [ ] Pick versions (SemVer): backend minor/major for public API additions or
      breaks, GUI minor for features, patch for fixes only.
- [ ] Update backend `VERSION`, move `## Unreleased` to
      `## Release X.Y.Z` in both changelogs, and update package versions.
- [ ] After creating the backend tag, download the published source archive and
      update the Flatpak `sha256`; do the same for the GUI tag/archive.
- [ ] Refresh generated docs metadata (`public/meta.json`) when docs are built.

## Publish

- [ ] Commit `Release X.Y.Z` in each repository.
- [ ] Create annotated tags `vX.Y.Z` and push them to every mirror.
- [ ] Confirm the tag-driven release workflow validated metadata and tests and
      published the GitHub release (or published it manually if it already
      existed).
- [ ] Merge the release commits to `main` and push `main`.
