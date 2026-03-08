#!/usr/bin/env bash
set -ex

DUB_COMPILER="${DUB_COMPILER:-ldc2}"

# Compile and run the programm in unittest mode
dub test --compiler="${DUB_COMPILER}" -b unittest-cov -- -v

# Now do a real run on data and collect some artifact here.
# In CI checkouts, ./docs may not be versioned; create it on demand.
mkdir -p ./docs/
dub run --compiler="${DUB_COMPILER}" -- -p ./docs/ -j dosierskanilo.json -f -r

# Redo, an calc checksums
dub run --compiler="${DUB_COMPILER}" -- -p ./docs/ -j dosierskanilo.json -f -r -c -m
