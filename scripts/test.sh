#!/usr/bin/env bash
set -ex

# Compile and run the programm in unittest mode
dub test -b unittest-cov -- -v

# Now do a real run on data and collect some artifact here.
# In CI checkouts, ./docs may not be versioned; create it on demand.
mkdir -p ./docs/
dub run -- -p ./docs/ -j dosierskanilo.json -f -r

# Redo, an calc checksums
dub run -- -p ./docs/ -j dosierskanilo.json -f -r -c -m
