#!/usr/bin/env bash
set -euo pipefail
#set -x

# We cache the DUB builds, so allow upgrades
dub upgrade

DC="${DC:-ldc2}"
export DC
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Verbosely build the dub package
# shellcheck disable=SC2086
dub build ${CI_DUBARGS:=}

# Also build API documentation with adrdox.
"${ROOT_DIR}/scripts/build-docs.sh"

echo "Successfully finished build script."
