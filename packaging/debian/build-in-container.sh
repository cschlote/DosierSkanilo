#!/bin/sh
# Build the Debian package inside a clean Debian container.
#
# Host usage:
#   ./packaging/debian/build-in-container.sh [output-directory]
#
# Environment:
#   CONTAINER_ENGINE  docker or podman (auto-detected)
#   DEBIAN_IMAGE      container image (default: debian:13-slim)
set -eu

if [ "${1:-}" = "--inside" ]; then
    shift
    output=${1:-/artifacts}
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential ca-certificates debhelper dub ldc libmediainfo-dev \
        libsqlite3-dev

    rm -rf /build
    mkdir -p /build/source "$output"
    tar -C /src --exclude=./.git --exclude=./build -cf - . \
        | tar -C /build/source -xf -
    rm -rf /build/source/debian
    cp -a /build/source/packaging/debian /build/source/debian

    cd /build/source
    dpkg-buildpackage -us -uc -b -d
    ./build/bin/dosierskanilo --version

    for artifact in /build/*.deb /build/*.changes /build/*.buildinfo; do
        [ -e "$artifact" ] || continue
        cp "$artifact" "$output"/
    done
    if [ -n "${HOST_UID:-}" ]; then
        chown -R "${HOST_UID}:${HOST_GID:-$HOST_UID}" "$output"
    fi
    exit 0
fi

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
output=${1:-"$repo_root/build/packages/debian"}
case "$output" in
    /*) ;;
    *) output="$PWD/$output" ;;
esac
mkdir -p "$output"

if [ -z "${CONTAINER_ENGINE:-}" ]; then
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_ENGINE=docker
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_ENGINE=podman
    else
        echo "Install docker or podman, or set CONTAINER_ENGINE." >&2
        exit 1
    fi
fi

exec "$CONTAINER_ENGINE" run --rm \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "$repo_root:/src:ro" \
    -v "$output:/artifacts" \
    "${DEBIAN_IMAGE:-debian:13-slim}" \
    sh /src/packaging/debian/build-in-container.sh --inside /artifacts
