# TODO

Project review date: 2026-03-08

## Current focus

- Keep archive, scanner, and storage behavior stable while simplifying maintenance.
- Keep CI and local workflows compiler-consistent (`ldc2` default, explicit overrides).

## Open items

### P1 - High

- [ ] Address hash/const diagnostics in `NamedBinaryBlob` model
  - Impact: Static analysis reports `opEquals`/`toHash` and constness mismatches, which can become correctness or API-friction issues when using these types in hashed or const-heavy contexts.
  - Code pointers: `source/dosierskanilo/namedbinaryblob.d:93`, `source/dosierskanilo/namedbinaryblob.d:435`, `source/dosierskanilo/namedbinaryblob.d:579`.
  - Required change:
    - Define consistent `toHash` where `opEquals` is provided and align method constness (`toString`/related operators) with D expectations.
    - Add/adjust unittests for equality/hash behavior.

### P3 - Low

- [ ] Add markdown lint gate for project docs
  - Impact: Doc formatting regressions (tabs/list indentation drift) can accumulate unnoticed.
  - Required change:
    - Add a markdown lint step in CI or local lint script and enforce it for `README.md`, `CHANGELOG.md`, and `TODO.md`.

## Recently completed (summary)

- Release 26.5.0 wave completed: scanner/storage/CI fixes, compiler consistency, changelog update, and release tag/push.
- Build artifact ignore patterns refreshed in `.gitignore` (`dosierskanilo`, `dosierskanilo-test-*`).
- Changelog indentation normalized to spaces for markdown-lint compatibility.

## Validation snapshot

- `dub test --compiler=ldc2 -b unittest-cov -- -v`: passed (`45 passed, 0 failed`).
- `dub build --compiler=ldc2`: passed.
