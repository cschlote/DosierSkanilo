#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TAG=${1:-}
if [ -z "${TAG}" ]; then
	printf 'usage: %s vX.Y.Z\n' "$0" >&2
	exit 2
fi
case "${TAG}" in
	v*) VERSION=${TAG#v} ;;
	*)
		printf 'release tag must start with v: %s\n' "${TAG}" >&2
		exit 1
		;;
esac

if [ "$(cat "${ROOT_DIR}/VERSION")" != "${VERSION}" ]; then
	printf 'VERSION (%s) does not match tag %s\n' \
		"$(cat "${ROOT_DIR}/VERSION")" "${TAG}" >&2
	exit 1
fi
if ! grep -q "^## Release ${VERSION} " "${ROOT_DIR}/CHANGELOG.md"; then
	printf 'CHANGELOG.md has no Release %s section\n' "${VERSION}" >&2
	exit 1
fi
printf 'release %s is consistent\n' "${TAG}"
