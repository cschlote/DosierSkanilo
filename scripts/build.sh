#!/usr/bin/env bash
set -euo pipefail
set -x

# We cache the DUB builds, so allow upgrades
dub upgrade

DUB_COMPILER="${DUB_COMPILER:-ldc2}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Verbosely build the dub package
# shellcheck disable=SC2086
dub build --compiler="${DUB_COMPILER}" ${CI_DUBARGS:=} -v

# Also build API documentation with adrdox
dub fetch adrdox
dub run adrdox -- . "${ROOT_DIR}/source/dosierskanilo" -o docs -i --skeleton "${ROOT_DIR}/skeleton.html"
cp -f "${ROOT_DIR}/dosierskanilo-icon.svg" "${ROOT_DIR}/docs/dosierskanilo-icon.svg"

RELEASE_TAG="$(git -C "${ROOT_DIR}" describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")"
RELEASE_BRANCH="$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
RELEASE_COMMIT="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
BUILD_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "${ROOT_DIR}/docs/meta.json" <<EOF
{
	"releaseTag": "${RELEASE_TAG}",
	"branch": "${RELEASE_BRANCH}",
	"commit": "${RELEASE_COMMIT}",
	"compiler": "${DUB_COMPILER}",
	"buildDateUtc": "${BUILD_ISO}",
	"changelogUrl": "https://github.com/cschlote/DosierSkanilo/blob/main/CHANGELOG.md",
	"releaseUrl": "https://github.com/cschlote/DosierSkanilo/releases/tag/${RELEASE_TAG}"
}
EOF

echo "Successfully finished build script."
