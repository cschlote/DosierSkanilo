# Release Checklist

Use this checklist for a backend + GUI release pair. Both repositories are
released from the same integration branch and each tag is prefixed with `v`.

## Preconditions

- [ ] Backend and GUI working trees are clean (`git status`).
- [ ] README, AGENTS, workflow/testing docs, TODO, CHANGELOG, and package
      metadata describe the same intended release state.
- [ ] The documented test commands match the current scripts and CI jobs.
- [ ] The integration branch is pushed to every mirror and `main` is merged.
- [ ] CI on `main` passed, including the GUI Xvfb display job, or the same
      checks were run locally when remote CI is intentionally disabled.
- [ ] Untracked local review/scratch files are committed or removed.

## Automated verification

- [ ] Backend: `DC=ldc2 ./scripts/test.sh` (unit tests, CLI integration, coverage).
- [ ] Backend: `./scripts/lint.sh`.
- [ ] GUI: `DC=ldc2 ./scripts/test.sh` and `./scripts/build.sh`.
- [ ] GUI display suite: `./scripts/test-display.sh` (Xvfb) — unit suite with
      display-gated tests, JSON/repository self-tests, splitter/video-sink checks,
      and the 95,001-record JSON/SQLite smoke loads.
- [ ] Backend docs and Ddoc: `./scripts/build-docs.sh` completes, and
      `dub lint dosierskanilo --config=cli --report` shows no new undocumented
      public API symbols.
- [ ] Backend and GUI `TODO.md` status/roadmap reviewed; no stale open item is
      presented as current release work.
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
- [ ] Refresh generated docs metadata (`public/meta.json`) when docs are built.

## Tag placement and Flatpak hashes

- Create release tags on the `main` merge commit after the release commit has
  been merged, never on a branch-only release commit.
- Source archives from GitHub and GitLab include the tagged commit SHA in their
  archive metadata (`pax_global_header`). Re-pointing or re-creating a tag
  changes the archive `sha256` even when the source tree is identical. Never
  reuse a Flatpak hash after moving a tag.
- The source archive cannot contain the final hash of itself. Tag first,
  download the published archive, compute its `sha256`, then update the Flatpak
  manifest in a follow-up commit on `main`.
- Do not tag that hash-update commit: the resulting archive would change again
  and invalidate its own pinned hash.
- If a tag or release must be corrected, download the archive again, update the
  Flatpak pin, and verify that the manifest on `main` points at the archive of
  the tag that is actually published.

## Publish

- [ ] Commit `Release X.Y.Z` in each repository.
- [ ] Merge the release commits to `main` and push `main`.
- [ ] Create annotated tags `vX.Y.Z` on the `main` merge commits and push them
      to every mirror.
- [ ] Update the Flatpak `sha256` pins from the published tag archives in a
      follow-up commit on `main`.
- [ ] Confirm the tag-driven release workflow validated metadata and tests and
      published the GitHub release, or publish the release manually when remote
      CI is disabled.
