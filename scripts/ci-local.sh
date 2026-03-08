#!/bin/sh
set -eu

echo "[ci-local] Running lint stage"
./scripts/lint.sh

echo "[ci-local] Running build stage"
./scripts/build.sh

echo "[ci-local] Running test stage"
./scripts/test.sh

echo "[ci-local] All stages finished successfully."
