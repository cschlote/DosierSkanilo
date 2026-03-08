#!/usr/bin/env bash
set -euo pipefail
set -x

# We cache the DUB builds, so allow upgrades
dub upgrade

DUB_COMPILER="${DUB_COMPILER:-ldc2}"

# Verbosely build the dub package
# shellcheck disable=SC2086
dub build --compiler="${DUB_COMPILER}" ${CI_DUBARGS:=} -v

# Also build API documentation with adrdox
dub fetch adrdox
dub run adrdox -- . -o docs -i

echo "Successfully finished build script."
