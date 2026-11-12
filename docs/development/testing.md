---
title: Testing
description: Internal and external test layers for DosierSkanilo.
area: development
---

# Testing

This document explains how the backend library, CLI, and integration tests are
built, executed, and interpreted. The verification policy is summarized in
[`AGENTS.md`](../../AGENTS.md) and
[`engineering-workflow.md`](engineering-workflow.md#verification).

## Test layers

### 1. D unit tests

Most backend behavior is covered by `unittest` blocks next to the code they
verify. DUB compiles all unittests from `source/` into one test binary.

- `dub test --compiler=ldc2` runs the unit suite without coverage.
- `DC=ldc2 ./scripts/test.sh` runs the unit suite with coverage, performs real
  JSON and SQLite scans, then runs the CLI integration suite.
- Coverage listings are written to `build/coverage/*.lst`; the script prints
  per-file and total coverage.
- Checked-in compatibility and metadata fixtures live under `test/`. The
  `synthetic-testdata` DUB configuration generates the deterministic corpus used
  by integration tests.

Some tests need an external archive writer or metadata tool. They return early
when the tool is unavailable, so a green minimal-container run does not prove
those external-tool paths. Run the suite on a workstation with the optional
tools installed when changing those adapters.

### 2. CLI integration tests

`scripts/test-cli.sh` builds the CLI and runs it as a real process against a
temporary synthetic corpus. It covers:

- JSON and SQLite scan, analyze, list, duplicates, import, export, backup,
  restore, and recovery
- progress-phase order, monotonic counters, and cancellation exit codes
- SIGINT handling during import, export, JSON scan/analyze, SQLite scan, and
  metadata, including partial-save and rollback behavior
- crash-safe catalog replacement and selected (`--path`) exports
- archive-member paths, occurrence suffixes, filtering, and export closure
- target-lease contention across processes
- JSON/SQLite result parity for representative operations

The script uses shell assertions, not a separate test framework. A failing
assertion stops the run with a non-zero exit code and a diagnostic on stderr.

### 3. Lint and static checks

`scripts/lint.sh` runs:

- `dub lint dosierskanilo --config=cli --report`
- `hadolint` when a `Dockerfile` exists
- `shellcheck` for every `scripts/*.sh`
- a Markdown linter over the maintained documentation list

The DUB lint report includes the undocumented-public-symbol count. A change
that adds public API must not add undocumented symbols.

### 4. Documentation build

`scripts/build-docs.sh` runs the configured documentation generator. Use it
after changing module headers, public Ddoc, navigation, or documentation
metadata. The build must complete without missing-symbol or broken-link errors.

### 5. External CI

- GitLab CI runs lint plus Debian 13, Ubuntu 24.04, and Alpine build/test jobs.
  Tag pipelines also publish release assets and API documentation.
- GitHub Actions runs lint, build, test, Pages, and tag-driven release jobs.
- The GUI repository's GitHub Actions jobs check out this backend for
  cross-repository coverage; the backend jobs do not build the GUI.
- When remote CI is intentionally disabled, run the same local checks and record
  that they were run locally.

## Commands

| Purpose | Command |
| --- | --- |
| Fast unit feedback | `dub test --compiler=ldc2` |
| Full local gate | `DC=ldc2 ./scripts/test.sh` |
| CLI integration only | `./scripts/test-cli.sh` |
| Lint/static checks | `./scripts/lint.sh` |
| Documentation build | `./scripts/build-docs.sh` |

## Policy

- After a change, run the smallest relevant test layer from the table above.
- Before merging a feature branch into `main` or preparing a release, run the
  complete local gate: `DC=ldc2 ./scripts/test.sh` and `./scripts/lint.sh`.
- Record the exact commands and results in the handover or release evidence.
  Never claim a test passed without running it.

## Current baseline

On 2026-11-10 the full suite reported 246 passing tests and 89.52 % coverage.

### 2026-11-10 review remediation

The P0 review remediation was verified with the complete local gate:
`243 passed`, `89.41 %` coverage, CLI integration checks, `scripts/lint.sh`,
and `scripts/build-docs.sh`. Focused regression coverage includes archive
symlink rejection, WAL-safe force/restore snapshots, staged restore rollback,
recovery dry-run and root discovery, missing optional `file`, null media
streams, document dry-run isolation, filtered directory counts, `dir!/file`
round-trips, partial archive indexes, ZIP wildcard members, archive page
pagination, progress/watcher lifetime, archive-only cancellation/resume, and
`--archive-limit` pending selection.
Treat these numbers as a recorded snapshot, not a permanent contract; update
them when the test set changes.
