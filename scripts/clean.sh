#!/usr/bin/env bash
set -eu

DUB_COMPILER="${DUB_COMPILER:-ldc2}"

echo "[clean] Running dub clean"
dub clean --compiler="${DUB_COMPILER}" -v

echo "[clean] Removing generated binaries and coverage"
rm -rf ./build/bin ./build/coverage

echo "[clean] Removing generated docs output and archives"
rm -rf ./public
rm -f ./public.tar.gz ./docs.tar.gz

echo "[clean] Removing generated JSON/runtime artifacts"
rm -f ./dosierskanilo.json ./.filescanner.json ./.crash_save.json

echo "[clean] Removing generated coverage listing files and symlinks"
find . -maxdepth 1 -type f -name '*.lst' -delete
find . -maxdepth 1 -type l -name '*.lst' -delete

echo "[clean] Done"
