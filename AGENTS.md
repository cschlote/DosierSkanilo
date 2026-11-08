# AGENTS

Guidance for coding agents in this repository. The detailed rules are in
[docs/development/engineering-workflow.md](docs/development/engineering-workflow.md).

## Working principles

- Make focused changes that directly solve the requested task.
- Inspect the working tree first and leave unrelated user changes untouched.
  Never revert or reformat them.
- Follow the existing D style, module boundaries, and ownership patterns.
- Flag assumptions, risks, and follow-up work clearly when they affect
  correctness.
- See [change scope](docs/development/engineering-workflow.md#change-scope-and-user-work).

## Changelog and documentation

- Update `CHANGELOG.md` for user-visible behavior changes, under
  `## Unreleased`, in simple English.
- Keep `TODO.md` and documentation links current.
- Keep Ddoc and module headers complete, including private and package
  declarations.
- See [changelog and docs](docs/development/engineering-workflow.md#changelog-docs-and-planning)
  and the [D language guide](docs/development/d-language-guide.md).

## Verification

- Run the smallest relevant verification step after editing and report any
  check that could not be completed.
- Prefer local checks; do not claim a pass without running the command.
- See the [verification matrix](docs/development/engineering-workflow.md#verification).

## Versioning

- The public D library API follows Semantic Versioning. DUB package and CLI
  releases use the same `vX.Y.Z` tag.
- Bump major for incompatible public API changes, minor for backward-compatible
  additions, and patch for fixes.
- Keep database schema/migration versions separate from package/API versions.
- The GUI is versioned independently but released in a compatible pair.
- See [versioning](docs/development/engineering-workflow.md#versioning).

## Branches and releases

- Merge completed work into `main` with `--no-ff`, then fast-forward `testing`.
- Release commits move `## Unreleased` to `## Release X.Y.Z`.
- Create annotated tags on the `main` merge commit, never on a branch-only
  commit. Source archives embed the commit SHA, so moving a tag changes the
  archive hash.
- Update Flatpak `sha256` pins in a follow-up commit on `main`; do not tag the
  hash-update commit.
- See [branches and merges](docs/development/engineering-workflow.md#branches-and-merges),
  [releases](docs/development/engineering-workflow.md#releases), and the
  [release checklist](docs/RELEASE-CHECKLIST.md).
