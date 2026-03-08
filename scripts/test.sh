#!/usr/bin/env bash
set -ex

# Compile and run the programm in unittest mode
dub test

# Now do a real run on data and collect some artifact here.
dub run -- -p ./docs/ -j dosierskanilo.json -f -r

# Redo, an calc checksums
dub run -- -p ./docs/ -j dosierskanilo.json -f -r -c -m
