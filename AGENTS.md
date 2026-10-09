# AGENTS

Minimal guidelines for coding AI working in this repository:

- Make focused changes that directly solve the requested task.
- Do not revert or reformat unrelated user changes.
- Follow the existing D style and module structure unless the task requires a different approach.
- Update `CHANGELOG.md` for user-visible behavior changes.
- The public D library API follows Semantic Versioning. Since it is distributed
  as a DUB package from this repository, release tags are the package/API version
  and must use the `vX.Y.Z` form. Bump major for incompatible public API changes,
  minor for backward-compatible API additions, and patch for backward-compatible
  fixes. CLI releases from this repository use the same release tag.
- Keep database schema/migration versions separate from the package/API version.
- Run the smallest relevant verification step after editing and report if verification could not be completed.
- Flag assumptions, risks, or follow-up work clearly when they affect correctness.
- Merge feature branches into `main` with `--no-ff` so the merge history stays explicit.
- For release commits, move the `## Unreleased` notes to `## Release X.Y.Z` and keep the summary in simple English.
- Prefix release tags with `v`, for example `v26.10.2`.

## D language guide

See [docs/development/d-language-guide.md](docs/development/d-language-guide.md) for the shared D style and documentation rules.
