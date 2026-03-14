#!/bin/sh
set -eu

echo "[build-all] Running clean stage"
./scripts/clean.sh

echo "[build-all] Running lint stage"
./scripts/lint.sh

echo "[build-all] Running build stage"
./scripts/build.sh

echo "[build-all] Running test stage"
./scripts/test.sh

echo "[build-all] Running build docs stage"
./scripts/build-docs.sh

echo "[build-all] All stages finished successfully."
