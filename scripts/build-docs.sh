#!/usr/bin/env bash
set -euo pipefail
set -x

DUB_COMPILER="${DUB_COMPILER:-ldc2}"
ADRDOX_COMPILER="${ADRDOX_COMPILER:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Fetch docs generator if needed.
dub fetch adrdox

# Prefer gdc for adrdox when available; fallback to project compiler.
if [ -z "${ADRDOX_COMPILER}" ]; then
	if command -v gdc >/dev/null 2>&1; then
		ADRDOX_COMPILER="gdc"
	else
		ADRDOX_COMPILER="${DUB_COMPILER}"
	fi
fi

echo "Generating docs with adrdox compiler: ${ADRDOX_COMPILER}"

mkdir -p "${ROOT_DIR}/public"
dub run adrdox --compiler="${ADRDOX_COMPILER}" -- source/dosierskanilo -o public -i --skeleton "${ROOT_DIR}/docs/skeleton.html"
cp -f "${ROOT_DIR}/docs/dosierskanilo-icon.svg" "${ROOT_DIR}/public/dosierskanilo-icon.svg"

RELEASE_TAG="$(git -C "${ROOT_DIR}" describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")"
RELEASE_BRANCH="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
RELEASE_COMMIT="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
BUILD_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "${ROOT_DIR}/public/meta.json" <<EOF
{
	"releaseTag": "${RELEASE_TAG}",
	"branch": "${RELEASE_BRANCH}",
	"commit": "${RELEASE_COMMIT}",
	"compiler": "${DUB_COMPILER}",
	"buildDateUtc": "${BUILD_ISO}",
	"changelogUrl": "https://github.com/cschlote/DosierSkanilo/blob/main/docs/CHANGELOG.md",
	"releaseUrl": "https://github.com/cschlote/DosierSkanilo/releases/tag/${RELEASE_TAG}"
}
EOF

echo "Successfully finished docs build script."
