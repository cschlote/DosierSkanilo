#!/usr/bin/env bash
set -euo pipefail

DC="${DC:-ldc2}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Fetch docs generator if needed.
dub fetch adrdox

DOCS_COMPILERS=()

add_docs_compiler() {
	local candidate="$1"
	local resolved

	[ -n "${candidate}" ] || return 0
	resolved="$(command -v "${candidate}" 2>/dev/null || true)"
	[ -n "${resolved}" ] || return 0

	local existing
	for existing in "${DOCS_COMPILERS[@]}"; do
		if [ "${existing}" = "${resolved}" ]; then
			return 0
		fi
	done
	DOCS_COMPILERS+=("${resolved}")
}

# GDC is the known-good adrdox host compiler. ldc2 is only used when GDC is
# unavailable, because adrdox can fail or produce excessive output with it.
if [ -n "${ADRDOX_COMPILER:-}" ]; then
	add_docs_compiler "${ADRDOX_COMPILER}"
fi
if command -v gdc >/dev/null 2>&1; then
	add_docs_compiler gdc
else
	add_docs_compiler "${DC}"
fi

attempt_docs() {
	local compiler="$1"
	local attempt="$2"

	echo "Generating docs with adrdox compiler: ${compiler} (attempt ${attempt})"
	rm -rf "${ROOT_DIR}/public"
	mkdir -p "${ROOT_DIR}/public"
	# Cap runtime and keep only the tail of the output so a misbehaving adrdox
	# build cannot flood CI logs.
	if timeout "${ADRDOX_TIMEOUT:-900}" dub run adrdox --compiler="${compiler}" \
		-- source/dosierskanilo -o public -i --jobs="${ADRDOX_JOBS:-1}" \
		--skeleton "${ROOT_DIR}/docs/skeleton.html" 2>&1 | tail -n 200; then
		return 0
	fi
	echo "WARNING: adrdox failed with compiler ${compiler} on attempt ${attempt}." >&2
	return 1
}

docs_generated=false
docs_compiler_used=""
for compiler in "${DOCS_COMPILERS[@]}"; do
	for attempt in 1 2; do
		if attempt_docs "${compiler}" "${attempt}"; then
			docs_generated=true
			docs_compiler_used="${compiler}"
			break 2
		fi
	done
done

if [ "${docs_generated}" != true ]; then
	echo "ERROR: adrdox documentation generation failed with every available compiler." >&2
	exit 1
fi
echo "Documentation generated with adrdox compiler: ${docs_compiler_used}"

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
	"compiler": "${DC}",
	"buildDateUtc": "${BUILD_ISO}",
	"changelogUrl": "https://github.com/cschlote/DosierSkanilo/blob/main/CHANGELOG.md",
	"releaseUrl": "https://github.com/cschlote/DosierSkanilo/releases/tag/${RELEASE_TAG}"
}
EOF

echo "Successfully finished docs build script."
