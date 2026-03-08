# TODO

Project review date: 2026-03-08

## P0 - Critical

- [x] Fix shell command injection risks in archive handling
  - Impact: Archive paths and entry names are interpolated into shell command strings and executed via `executeShell`, which is unsafe with crafted filenames.
  - Code pointers: `source/dosierarkivo/baseclass.d:212`, `source/dosierarkivo/baseclass.d:236`, `source/dosierarkivo/baseclass.d:357`, `source/dosierarkivo/baseclass.d:430`.
  - Required change:
    - Replace `executeShell("...")` command construction with argument-array process execution (`execute`/`spawnProcess` with `string[] args`).
    - Avoid `cd ... && ...`; use process working-directory options instead.
    - Add tests using spaces, quotes, and shell metacharacters in archive filenames and entry names.
  - Status:
    - Completed in `source/dosierarkivo/baseclass.d` by switching archive adapters to argument-array execution.
    - Added unittest `archive extraction with special filenames` covering quoted/metacharacter filenames.

## P1 - High

- [x] Remove archive scan limiter left from debugging
  - Impact: Archive analysis silently returns early when an archive has more than 10 entries, causing incomplete metadata in production scans.
  - Code pointer: `source/dosierskanilo/namedbinaryblob.d:1373`.
  - Required change:
    - Remove the `DEBUG HACK` condition and return.
    - Add/adjust a unittest with archive >10 entries to prevent regression.
  - Status:
    - Removed the limiter in `updateArchives` so all archive entries are processed.
    - Extended `updateArchives` unittest to generate and scan an archive with 11 entries.

- [x] Fix multithreaded scanner behavior mismatch for archive jobs
  - Impact: In multithread mode archive scanning is only queued when `obj.fileType` is already set before task submission, while single-thread path does not require this; archives may be skipped unexpectedly.
  - Code pointer: `source/appmain.d:451`.
  - Required change:
    - Remove dependency on pre-existing `obj.fileType` for queueing archive tasks, or enforce explicit job ordering/dependency.
    - Add a regression test covering single-thread vs multi-thread parity for `--scanArchives`.
  - Status:
    - Unified archive queueing condition via `shouldQueueArchiveScanJob` and reused it in both scanner paths.
    - Added unittest `archive scan queueing parity` for the scheduling predicate.

- [x] Harden archive adapter parsing against external tool output drift
  - Impact: `assert`-based parsing for tool output (`unzip -l`, etc.) can abort the whole run when utility output changes by locale/version.
  - Code pointers: `source/dosierarkivo/baseclass.d:220`, `source/dosierarkivo/baseclass.d:225`.
  - Required change:
    - Replace hard `assert` checks with recoverable parse/validation logic.
    - Log and skip unsupported output formats instead of terminating the process.
  - Status:
    - Reworked ZIP entry listing to prefer machine-readable `unzip -Z1` output and use tolerant fallback parsing for `unzip -l`.
    - Replaced aborting assumptions with warning logs and graceful skip (`[]`) on unsupported output.
    - Added unittest `zip list parser tolerates output drift` for malformed external tool output.

## P2 - Medium

- [ ] Improve digest progress accounting
  - Impact: Digest progress increments with `buffSize` instead of actual chunk length, so progress can overshoot or become inaccurate for the final chunk.
  - Code pointer: `source/dosierskanilo/digests.d:71`.
  - Required change:
    - Update progress with `buffer.length`.
    - Add unit coverage for small files and non-multiple-of-buffer-size files.

- [ ] Add explicit handling for missing JSON storage file on first run
  - Impact: Startup behavior depends on `deserializeDataClassJsonFile` implementation details; first-run UX/error semantics should be explicit and documented.
  - Code pointer: `source/appmain.d:217`.
  - Required change:
    - If JSON file is absent, initialize empty database intentionally.
    - Keep failure only for malformed/incompatible JSON unless `--force` is provided.

- [ ] Add CI coverage reporting and make linter gating stricter
  - Impact: Lint stage currently allows failure, reducing early feedback quality.
  - Code pointer: `.gitlab-ci.yml:35`.
  - Required change:
    - Remove `allow_failure: true` for D lint job once baseline is clean.
    - Export unittest coverage artifact from `dub test -b unittest-cov` and publish in CI artifacts/reporting.

## P3 - Low

- [ ] Clean up outdated comments/typos and naming consistency
  - Impact: Minor maintainability friction (typos and stale comments) across docs and code.
  - Examples:
    - `source/appmain.d:10` (`ToDo` section stale)
    - `source/commandline.d` spelling (`Recursivly`, `darabase`, etc.)
  - Required change:
    - Sweep comments/help text for clarity and consistency.

- [ ] Consolidate build/test compiler strategy
  - Impact: Local task defaults use `ldc2` for build while tests in scripts may use default compiler (`dub test`), causing drift between CI/local behaviors.
  - Code pointers: `scripts/test.sh:9`, workspace task `test-host`.
  - Required change:
    - Standardize test compiler selection (`--compiler=ldc2` or explicit matrix).
    - Document expected compiler support in `README.md`.

## Validation snapshot

- `dub test -b unittest-cov -- -v`: passed (`39 passed, 0 failed`).
- `dub build --compiler=ldc2`: passed.
