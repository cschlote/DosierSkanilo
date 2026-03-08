#!/usr/bin/env bash
set -euo pipefail
set -x

# We cache the DUB builds, so allow upgrades
dub upgrade

# Verbosely build the dub package
# shellcheck disable=SC2086
dub build ${CI_DUBARGS:=} -v

# Also build the ddox documentation
dub fetch ddox
dub build --build=ddox

echo "Successfully finished build script."
