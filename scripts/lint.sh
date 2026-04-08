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
if command -v markdownlint-cli2 >/dev/null 2>&1; then
	markdownlint-cli2 README.md docs/ARCHITECTURE.md CHANGELOG.md TODO.md
elif command -v markdownlint >/dev/null 2>&1; then
	markdownlint README.md docs/ARCHITECTURE.md CHANGELOG.md TODO.md
else
	echo "ERROR: markdownlint-cli2 or markdownlint is not installed." >&2
	exit 1
fi

echo "Linting finished successfully."
