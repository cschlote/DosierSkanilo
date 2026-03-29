#!/usr/bin/env bash
set -ex

DC="${DC:-ldc2}"
LST_DIR="./build/coverage"

# Keep coverage listing files in one place.
mkdir -p "${LST_DIR}"
find "${LST_DIR}" -maxdepth 1 -type f -name '*.lst' -delete
find . -maxdepth 1 -type f -name '*.lst' -delete

# Compile and run the programm in unittest mode
dub test -b unittest-cov -- -v
find . -maxdepth 1 -type f -name '*.lst' -exec mv -f {} "${LST_DIR}"/ \;

# VS Code coverage overlays often look for *.lst files at workspace root.
# Keep canonical files in build/coverage and provide root symlinks for editor tooling.
find . -maxdepth 1 -type l -name '*.lst' -delete
find "${LST_DIR}" -maxdepth 1 -type f -name '*.lst' -exec ln -sfn {} ./ \;

# Now do a real run on data using documentation sources as sample input.
# Keep ./docs available in CI/local checkouts.
mkdir -p ./docs/
dub run -- -p ./docs/ -j dosierskanilo.json -f -r

# Redo, an calc checksums
dub run -- -p ./docs/ -j dosierskanilo.json -f -r -c -m
