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

# Generate one D-owned corpus and exercise both explicit storage modes against it.
fixture_bundle="${TMP_DIR}/synthetic-catalog"
dub run --config=synthetic-testdata --compiler="${DC}" -- \
    --output "${fixture_bundle}"
fixture_root="${fixture_bundle}/catalog"
synthetic_catalog="${TMP_DIR}/synthetic-catalog.json"

synthetic_sqlite_root="${TMP_DIR}/synthetic-sqlite-catalog"
cp -a "${fixture_root}" "${synthetic_sqlite_root}"
"${BIN}" init "${synthetic_sqlite_root}" >/dev/null
sqlite_scan_output=$("${BIN}" scan "${synthetic_sqlite_root}" \
    --recursive --checksums)
[[ "${sqlite_scan_output}" == *"Catalog scan: 12 files, 12 added"* ]]
sqlite_analysis_output=$("${BIN}" analyze "${synthetic_sqlite_root}")
[[ "${sqlite_analysis_output}" == *"Catalog analysis: 0 missing, 0 dropped, 1 duplicate groups, 1 merged blobs, 0 orphaned blobs."* ]]

pushd "${TMP_DIR}" >/dev/null
synthetic_json_output=$("${BIN}" scan "${fixture_root}" \
    --json "${synthetic_catalog}" --recursive --checksums)
[[ "${synthetic_json_output}" == *"Catalog scan: 12 files, 12 added"* ]]
[[ ! -d "${fixture_root}/.dosierskanilo" ]]
json_analysis_output=$("${BIN}" analyze --json "${synthetic_catalog}")
[[ "${json_analysis_output}" == *"Catalog analysis: 0 missing, 0 dropped, 1 duplicate groups, 1 merged blobs, 0 orphaned blobs."* ]]
json_list_output=$("${BIN}" list --json "${synthetic_catalog}" \
    --base-dir "${fixture_root}" --format=json \
    | sed -n '/^{/p' | sed -E 's/"id":[0-9]+,//g')
sqlite_list_output=$("${BIN}" list "${TMP_DIR}/synthetic-sqlite-catalog" \
    --format=json | sed -E 's/"id":[0-9]+,//g')
[[ "${json_list_output}" == "${sqlite_list_output}" ]]
json_duplicates_output=$("${BIN}" duplicates --json "${synthetic_catalog}" \
    --base-dir "${fixture_root}" --format=json \
    | sed -n '/^{/p' | sed -E 's/"id":[0-9]+,//g')
sqlite_duplicates_output=$("${BIN}" duplicates \
    "${TMP_DIR}/synthetic-sqlite-catalog" --format=json \
    | sed -E 's/"id":[0-9]+,//g')
[[ "${json_duplicates_output}" == "${sqlite_duplicates_output}" ]]
popd >/dev/null

# A killed JSON export never leaves a truncated or missing catalog at the
# canonical path: the writer serializes into a staging file and renames it.
crash_source="${TMP_DIR}/crash-source.json"
crash_repo="${TMP_DIR}/crash-repo"
crash_output="${TMP_DIR}/crash-output.json"
crash_pristine="${TMP_DIR}/crash-pristine.json"
mkdir -p "${crash_repo}"
awk 'BEGIN {
    print "{\"dataVersion\":5,\"dataArray\":["
    for (i = 0; i < 100000; i++) {
        if (i)
            print ","
        printf "{\"fileSize\":1,\"fileSpecs\":[{\"fileName\":\"f%06d\",\"timeLastModified\":\"2020-01-02T04:04:06\"}]}", i
    }
    print "]}"
}' > "${crash_source}"
"${BIN}" init "${crash_repo}" >/dev/null
"${BIN}" import "${crash_repo}" "${crash_source}" >/dev/null
printf '%s\n' '{"dataVersion":5,"dataArray":[]}' > "${crash_pristine}"
cp "${crash_pristine}" "${crash_output}"
"${BIN}" export "${crash_repo}" --output "${crash_output}" >/dev/null &
export_pid=$!
crash_staged=false
for _ in $(seq 1 60000); do
    if compgen -G "${crash_output}.tmp-*" >/dev/null; then
        crash_staged=true
        kill -STOP "${export_pid}" 2>/dev/null || true
        kill -KILL "${export_pid}" 2>/dev/null || true
        break
    fi
    if ! kill -0 "${export_pid}" 2>/dev/null; then
        break
    fi
    sleep 0.001
done
wait "${export_pid}" 2>/dev/null || true
[[ "${crash_staged}" == true ]]
cmp "${crash_pristine}" "${crash_output}"
rm -f "${crash_output}".tmp-*
"${BIN}" analyze --json "${crash_output}" >/dev/null

# SIGINT during a JSON scan stops the workers and never publishes a catalog.
cancel_scan_tree="${TMP_DIR}/cancel-scan-tree"
mkdir -p "${cancel_scan_tree}"
for index in $(seq 1 200); do
    ln "${crash_source}" "${cancel_scan_tree}/f${index}.json"
done
"${BIN}" scan "${cancel_scan_tree}" --json "${TMP_DIR}/cancel-scan.json" \
    --recursive --checksums >"${TMP_DIR}/cancel-scan-stdout" 2>&1 &
scan_pid=$!
sleep 0.2
kill -INT "${scan_pid}" 2>/dev/null || true
scan_rc=0
wait "${scan_pid}" || scan_rc=$?
[[ "${scan_rc}" -ne 0 ]]
grep -q "cancelled" "${TMP_DIR}/cancel-scan-stdout"
[[ ! -e "${TMP_DIR}/cancel-scan.json" ]]

# SIGINT during SQLite metadata cancels and leaves the repository usable.
"${BIN}" metadata "${crash_repo}" --checksums \
    >"${TMP_DIR}/metadata-cancel-stdout" 2>&1 &
metadata_pid=$!
sleep 0.5
kill -INT "${metadata_pid}" 2>/dev/null || true
metadata_rc=0
wait "${metadata_pid}" || metadata_rc=$?
[[ "${metadata_rc}" -ne 0 ]]
grep -q "cancelled" "${TMP_DIR}/metadata-cancel-stdout"
"${BIN}" info "${crash_repo}" >/dev/null

# SIGINT during a JSON analysis cancels cooperatively: the process fails, the
# original catalog is left in place, and no staging file is published.
cancel_catalog="${TMP_DIR}/cancel-catalog.json"
cancel_pristine="${TMP_DIR}/cancel-pristine.json"
cp "${crash_source}" "${cancel_catalog}"
cp "${cancel_catalog}" "${cancel_pristine}"
"${BIN}" analyze --json "${cancel_catalog}" >"${TMP_DIR}/cancel-stdout" 2>&1 &
analyze_pid=$!
sleep 0.5
kill -INT "${analyze_pid}" 2>/dev/null || true
cancel_rc=0
wait "${analyze_pid}" || cancel_rc=$?
[[ "${cancel_rc}" -ne 0 ]]
cmp "${cancel_pristine}" "${cancel_catalog}"
grep -q "cancelled" "${TMP_DIR}/cancel-stdout"

library="${TMP_DIR}/library"
catalog="${TMP_DIR}/library.json"
sqlite_root="${TMP_DIR}/sqlite-library"
mkdir -p "${library}" "${sqlite_root}/nested"
cp "${ROOT_DIR}/test/dummy-text-file.txt" "${library}/sample.txt"
cp "${ROOT_DIR}/test/dummy-text-file.txt" "${sqlite_root}/nested/sample.txt"

# Direct JSON mode must not create repository metadata.
"${BIN}" scan "${library}" --json "${catalog}" --recursive --checksums
[[ -f "${catalog}" ]]
[[ ! -d "${library}/.dosierskanilo" ]]
pushd "${TMP_DIR}" >/dev/null
"${BIN}" analyze --json "${catalog}"
popd >/dev/null

# Top-level commands use SQLite and discover the root from a nested directory.
init_output=$("${BIN}" init "${sqlite_root}")
[[ "${init_output}" == *"Initialized new repository at"* ]]
mkdir -p "${TMP_DIR}/second-sqlite-library"
init_output=$("${BIN}" init "${TMP_DIR}/second-sqlite-library")
[[ "${init_output}" == *"Initialized new repository at"* ]]
existing_init_output=$("${BIN}" init "${sqlite_root}")
[[ "${existing_init_output}" == *"Opened existing repository at"* ]]
scan_output=$("${BIN}" scan "${sqlite_root}" --recursive --checksums)
[[ "${scan_output}" == *"Catalog scan:"* ]]
[[ "${scan_output}" == *"Catalog metadata:"* ]]
analysis_output=$("${BIN}" analyze "${sqlite_root}")
[[ "${analysis_output}" == *"Catalog analysis:"* ]]
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

# Missing command arguments and command errors do not pollute stdout.
if "${BIN}" import > "${TMP_DIR}/import-stdout" 2> "${TMP_DIR}/import-stderr"; then
    printf '%s\n' "Expected import without a catalog to fail." >&2
    exit 1
fi
[[ ! -s "${TMP_DIR}/import-stdout" ]]
[[ "$(<"${TMP_DIR}/import-stderr")" == *"Import requires a JSON catalog filename."* ]]
if "${BIN}" export "${sqlite_root}" > "${TMP_DIR}/export-stdout" 2> "${TMP_DIR}/export-stderr"; then
    printf '%s\n' "Expected export without an output file to fail." >&2
    exit 1
fi
[[ ! -s "${TMP_DIR}/export-stdout" ]]
[[ "$(<"${TMP_DIR}/export-stderr")" == *"Export requires an output JSON filename."* ]]

# Help/version are successful.
"${BIN}" --help >/dev/null
"${BIN}" --version >/dev/null
if "${BIN}" info "${TMP_DIR}" > "${TMP_DIR}/stdout" 2> "${TMP_DIR}/stderr"; then
    printf '%s\n' "Expected info without a repository to fail." >&2
    exit 1
fi
[[ ! -s "${TMP_DIR}/stdout" ]]
[[ -s "${TMP_DIR}/stderr" ]]

printf '%s\n' "CLI integration checks passed."
