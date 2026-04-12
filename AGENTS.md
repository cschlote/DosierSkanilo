# AGENTS

Minimal guidelines for coding AI working in this repository:

- Make focused changes that directly solve the requested task.
- Do not revert or reformat unrelated user changes.
- Follow the existing D style and module structure unless the task requires a different approach.
- Update `CHANGELOG.md` for user-visible behavior changes.
- Run the smallest relevant verification step after editing and report if verification could not be completed.
- Flag assumptions, risks, or follow-up work clearly when they affect correctness.
- Merge feature branches into `main` with `--no-ff` so the merge history stays explicit.
- For release commits, move the `## Unreleased` notes to `## Release X.Y.Z` and keep the summary in simple English.
- Prefix release tags with `v`, for example `v26.9.2`.
