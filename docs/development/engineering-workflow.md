---
title: Engineering Workflow
description: Change, verification, versioning, branch, and release rules for DosierSkanilo.
area: development
---

# Engineering Workflow

This document is the detailed companion to [`AGENTS.md`](../../AGENTS.md). It
applies to human contributors and coding agents.

## Change scope and user work

- Solve the requested problem with the smallest coherent change. Avoid drive-by
  refactors, renames, and formatting churn.
- Inspect the working tree before editing. Treat unfamiliar modified or
  untracked files as user work and leave them untouched unless the task
  explicitly requires changing them.
- Do not revert or reformat unrelated user changes.
- Follow the existing module boundaries, naming, and ownership patterns. The
  shared D style and Ddoc rules are in
  [`d-language-guide.md`](d-language-guide.md).
- When a task touches the backend and GUI together, keep the API and user-facing
  behavior consistent and verify both repositories.
- If ambiguity or an environment limitation could affect correctness, stop and
  state the assumption instead of guessing.

## Documentation gaps and approval

If a goal, rule, or procedure cannot be derived logically from `AGENTS.md` and
the linked documentation, do not invent a new workflow. Stop, explain the gap,
and ask for approval. After approval, update `AGENTS.md` or the appropriate
linked document in the same change so the rule is explicit for the next
contributor. Documentation is part of the implementation, not an optional
afterthought.

## Verification

The test layers and their exact commands are documented in
[`testing.md`](testing.md). Summary:

- Run the smallest relevant check after editing. Examples:

| Change | Minimum check |
| --- | --- |
| Library code | `dub test --compiler=ldc2` |
| CLI parser/output | targeted unit tests plus `./scripts/test-cli.sh` |
| Repository/schema/migration | repository and CLI integration tests |
| Markdown or repository metadata | `./scripts/lint.sh` |
| Broad or release-bound change | `DC=ldc2 ./scripts/test.sh` and `./scripts/lint.sh` |
| Ddoc/module headers | `./scripts/build-docs.sh` |

- Report any check that could not be run and why. Do not claim a pass without
  running the command.
- Prefer local verification during normal iteration. If remote CI is
  intentionally disabled, run the equivalent local checks and use `[skip ci]`
  only where it is appropriate.
- Add tests next to the code they verify and confirm from the test output that
  the new test actually ran. See the
  [D language guide](d-language-guide.md#tests).
- Before merging a feature branch into `main` or preparing a release, run the
  complete local gate (`DC=ldc2 ./scripts/test.sh` and `./scripts/lint.sh`),
  not only the targeted tests.

## Changelog, docs, and planning

- Update `CHANGELOG.md` for every user-visible behavior change. Keep entries
  under `## Unreleased` and write them in simple English.
- Internal refactors and test-only changes normally do not need a changelog
  entry; documentation-only changes may add one when they affect contributors.
- Update `TODO.md` when a work item, verification result, or known limitation
  changes. Do not leave completed work presented as open.
- Keep Ddoc and module headers complete. The requirements are part of the
  [D language guide](d-language-guide.md#ddoc).
- Keep README and docs links accurate when moving or adding documentation.

## Versioning

- The public D library API follows Semantic Versioning. The DUB package release
  version and tag are the API version.
- Release tags use `vX.Y.Z`. Bump major for incompatible public API changes,
  minor for backward-compatible API additions, and patch for backward-compatible
  fixes.
- The CLI in this repository uses the same release tag as the library package.
- Database schema and migration versions are independent of the package/API
  version. Increment and document them as a separate migration concern.
- The GUI is versioned independently. A paired release uses compatible versions
  of both repositories but does not force identical version numbers.

## Branches and merges

- `main` is the working and deployment branch. Create a short-lived branch from
  `main` for each problem.
- Name branches by intent using kebab-case. Examples:
  `feature/archive-search`, `fix/root-rebinding`, `docs/testing-guide`,
  `chore/dependency-metadata`, and `release/1.2.3`. Avoid generic names and
  mixed topics.
- Solve one problem per branch in one or more thematic commits. Keep unrelated
  fixes, refactors, and formatting changes out of the branch.
- Before merging, update `CHANGELOG.md` under `## Unreleased` with the
  user-visible or notable maintenance change.
- Merge the completed branch into `main` with `--no-ff` so the integration point
  stays explicit. Do not squash away the thematic commit history.
- After the merge, stay on `main`. `testing` is a deployment-free mirror of
  `main`, not an integration branch and never a place for direct commits.
  Fast-forward it without leaving `main` (`git branch -f testing main`) and push
  both branches to all mirrors.
- Push branches to all configured mirrors when publishing the result.

## Releases

Follow the full [release checklist](../RELEASE-CHECKLIST.md). Before creating a
release commit, review that checklist explicitly and confirm that documentation,
scripts, package metadata, changelog, and tests all describe the same intended
state. The non-negotiable points are:

- Create a `release/X.Y.Z` branch from `main`, move `## Unreleased` to
  `## Release X.Y.Z`, update `VERSION` and package metadata, and keep the
  summary in simple English.
- Merge the release branch to `main` first, then create the annotated tag
  `vX.Y.Z` on the `main` merge commit. Do not tag a branch-only commit. Stay on
  `main` and mirror the result to `testing` without deploying from `testing`.
- Source archives embed the tagged commit SHA. Moving or re-creating a tag
  changes the archive hash even when the tree is identical.
- Update Flatpak `sha256` pins in a follow-up commit on `main` after downloading
  the published tag archive. Do not tag the hash-update commit.
- Publish the paired GUI release and verify the tag metadata and archive hashes
  together.

## Reporting risks

State assumptions, unresolved questions, known risks, and follow-up work
explicitly. Say which checks passed, which were skipped, and what evidence is
still missing when a change is handed over.
