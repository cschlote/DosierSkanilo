#!/bin/sh
set -eu

echo "Running D lint"
if ! command -v ldc2 >/dev/null 2>&1; then
	echo "ERROR: ldc2 is not installed." >&2
	exit 1
fi
if ! command -v dub >/dev/null 2>&1; then
	echo "ERROR: dub is not installed." >&2
	exit 1
fi
dub lint dosierskanilo --report

echo "Running hadolint"
if ! command -v hadolint >/dev/null 2>&1; then
	echo "ERROR: hadolint is not installed." >&2
	exit 1
fi
if [ -f Dockerfile ]; then
	hadolint Dockerfile
else
	echo "No Dockerfile found, skipping hadolint."
fi

echo "Running shellcheck"
if ! command -v shellcheck >/dev/null 2>&1; then
	echo "ERROR: shellcheck is not installed." >&2
	exit 1
fi

find scripts -type f -name '*.sh' | while IFS= read -r script_file; do
	shellcheck "$script_file"
done

echo "Running markdown lint"
# Keep the maintained documentation list in one place. Glob patterns expand
# when the linters run.
markdown_files="README.md docs/ARCHITECTURE.md docs/BENCHMARKS.md docs/JSON-FORMAT.md docs/DATABASE.md docs/OPERATION-API.md docs/CATALOG-DOMAIN.md docs/SQLITE-IMPLEMENTATION-PLAN.md docs/reviews/*.md CHANGELOG.md TODO.md"
if command -v markdownlint-cli2 >/dev/null 2>&1; then
	# shellcheck disable=SC2086 # the glob and word splitting are intentional
	markdownlint-cli2 $markdown_files
elif command -v markdownlint >/dev/null 2>&1; then
	# shellcheck disable=SC2086
	markdownlint $markdown_files
elif command -v mdl >/dev/null 2>&1; then
	# shellcheck disable=SC2086
	mdl $markdown_files
else
	echo "ERROR: markdownlint-cli2, markdownlint, or mdl is not installed." >&2
	exit 1
fi

echo "Linting finished successfully."
