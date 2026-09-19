#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(pwd)"
DC="${DC:-ldc2}"
export DC
BIN="${ROOT_DIR}/build/bin/dosierskanilo"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dosierskanilo-cli.XXXXXX")"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

if [[ ! -x "${BIN}" ]]; then
    dub build --config=cli
fi

library="${TMP_DIR}/library"
catalog="${TMP_DIR}/library.json"
sqlite_root="${TMP_DIR}/sqlite-library"
mkdir -p "${library}" "${sqlite_root}/nested"
cp "${ROOT_DIR}/test/dummy-text-file.txt" "${library}/sample.txt"
cp "${ROOT_DIR}/test/dummy-text-file.txt" "${sqlite_root}/nested/sample.txt"

# Direct JSON mode must not create repository metadata.
"${BIN}" json scan "${library}" "${catalog}" --recursive --checksums
[[ -f "${catalog}" ]]
[[ ! -d "${library}/.dosierskanilo" ]]
pushd "${TMP_DIR}" >/dev/null
"${BIN}" json analyze "${catalog}"
popd >/dev/null

# Top-level commands use SQLite and discover the root from a nested directory.
init_output=$("${BIN}" init "${sqlite_root}")
[[ "${init_output}" == *"Initialized new repository at"* ]]
mkdir -p "${TMP_DIR}/second-sqlite-library"
init_output=$("${BIN}" init "${TMP_DIR}/second-sqlite-library")
[[ "${init_output}" == *"Initialized new repository at"* ]]
existing_init_output=$("${BIN}" init "${sqlite_root}")
[[ "${existing_init_output}" == *"Opened existing repository at"* ]]
scan_output=$("${BIN}" scan "${sqlite_root}" --recursive)
[[ "${scan_output}" == *"Repository scan:"* ]]
analysis_output=$("${BIN}" analyze "${sqlite_root}")
[[ "${analysis_output}" == *"Repository analysis:"* ]]
metadata_output=$("${BIN}" metadata "${sqlite_root}" --file-types)
[[ "${metadata_output}" == *"Metadata update:"* ]]
duplicates_output=$("${BIN}" duplicates "${sqlite_root}")
[[ "${duplicates_output}" == *"Found "*" duplicate groups."* ]]
"${BIN}" import "${sqlite_root}" "${ROOT_DIR}/test/json_file_v2.json" --replace
exported_catalog="${TMP_DIR}/sqlite-export.json"
"${BIN}" export "${sqlite_root}" --output "${exported_catalog}"
[[ -s "${exported_catalog}" ]]
pushd "${sqlite_root}/nested" >/dev/null
"${BIN}" info --format=json > "${TMP_DIR}/info.json"
popd >/dev/null
[[ -s "${TMP_DIR}/info.json" ]]
"${BIN}" list "${sqlite_root}" --format=json > "${TMP_DIR}/list.json"
[[ -s "${TMP_DIR}/list.json" ]]

# Help/version are successful and command errors do not pollute stdout.
"${BIN}" --help >/dev/null
"${BIN}" --version >/dev/null
if "${BIN}" info "${TMP_DIR}" > "${TMP_DIR}/stdout" 2> "${TMP_DIR}/stderr"; then
    printf '%s\n' "Expected info without a repository to fail." >&2
    exit 1
fi
[[ ! -s "${TMP_DIR}/stdout" ]]
[[ -s "${TMP_DIR}/stderr" ]]

printf '%s\n' "CLI integration checks passed."
