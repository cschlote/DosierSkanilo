#!/usr/bin/env bash
set -euo pipefail

# Resolve the repository root from this script's location, not from the
# caller's working directory.
ROOT_DIR="$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)"
DC="${DC:-ldc2}"
export DC
BIN="${ROOT_DIR}/build/bin/dosierskanilo"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dosierskanilo-cli.XXXXXX")"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# Render captured progress output (carriage-return frames with ANSI clears)
# as one line per update and require the phases to appear in this order.
assert_progress_order() {
    local label=$1
    local output
    output=$(printf '%s' "$2" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        | tr '\r' '\n')
    local previous=0 phase position
    shift 2
    for phase in "$@"; do
        position=$(awk -v needle="${label} ${phase} " \
            '{ if (index($0, needle) > 0) { print NR; exit } }' \
            <<<"${output}")
        if [[ -z "${position}" ]]; then
            printf '%s\n' "Missing progress phase '${label} ${phase}'." >&2
            exit 1
        fi
        if (( position <= previous )); then
            printf '%s\n' \
                "Progress phase '${label} ${phase}' is out of order." >&2
            exit 1
        fi
        previous=${position}
    done
}

# Work counts within one phase must never move backwards.
assert_monotonic_progress() {
    local label=$1 phase=$2 output=$3
    local previous=-1 current
    while read -r current; do
        [[ -z "${current}" ]] && continue
        if (( current < previous )); then
            printf '%s\n' \
                "Progress count regressed in '${label} ${phase}'." >&2
            exit 1
        fi
        previous=${current}
    done < <(printf '%s' "${output}" \
        | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | tr '\r' '\n' \
        | grep -F "${label} ${phase} " \
        | grep -oE '[0-9]+/[0-9]+' | cut -d/ -f1)
}

(cd "${ROOT_DIR}" && dub build --config=cli --compiler="${DC}" >/dev/null)

# Generate one D-owned corpus and exercise both explicit storage modes against it.
fixture_bundle="${TMP_DIR}/synthetic-catalog"
(cd "${ROOT_DIR}" && dub run --config=synthetic-testdata --compiler="${DC}" -- \
    --output "${fixture_bundle}")
fixture_root="${fixture_bundle}/catalog"
synthetic_catalog="${TMP_DIR}/synthetic-catalog.json"

synthetic_sqlite_root="${TMP_DIR}/synthetic-sqlite-catalog"
cp -a "${fixture_root}" "${synthetic_sqlite_root}"
"${BIN}" init "${synthetic_sqlite_root}" >/dev/null
sqlite_scan_output=$("${BIN}" scan "${synthetic_sqlite_root}" \
    --recursive --checksums)
[[ "${sqlite_scan_output}" == *"Catalog scan: 12 files, 12 added"* ]]
assert_progress_order "Catalog scan" "${sqlite_scan_output}" \
    validating discovering checksums
assert_monotonic_progress "Catalog scan" checksums "${sqlite_scan_output}"
sqlite_analysis_output=$("${BIN}" analyze "${synthetic_sqlite_root}")
[[ "${sqlite_analysis_output}" == *"Catalog analysis: 0 missing, 0 dropped, 1 duplicate groups, 1 merged blobs, 0 orphaned blobs."* ]]
assert_progress_order "Catalog analysis" "${sqlite_analysis_output}" \
    validating "missing files" duplicates "analysis cleanup"

pushd "${TMP_DIR}" >/dev/null
synthetic_json_output=$("${BIN}" scan "${fixture_root}" \
    --json "${synthetic_catalog}" --recursive --checksums)
[[ "${synthetic_json_output}" == *"Catalog scan: 12 files, 12 added"* ]]
assert_progress_order "Catalog scan" "${synthetic_json_output}" \
    "reading JSON" discovering checksums "writing JSON"
assert_monotonic_progress "Catalog scan" checksums "${synthetic_json_output}"
[[ ! -d "${fixture_root}/.dosierskanilo" ]]
json_rescan_output=$("${BIN}" scan "${fixture_root}" \
    --json "${synthetic_catalog}" --recursive --checksums)
[[ "$(grep -c "Read serialized data from JSON file" <<<"${json_rescan_output}" || true)" -eq 1 ]]
json_analysis_output=$("${BIN}" analyze --json "${synthetic_catalog}")
[[ "${json_analysis_output}" == *"Catalog analysis: 0 missing, 0 dropped, 1 duplicate groups, 1 merged blobs, 0 orphaned blobs."* ]]
assert_progress_order "Catalog analysis" "${json_analysis_output}" \
    "reading JSON" "missing files" duplicates "analysis cleanup" \
    "writing JSON"
[[ "$(wc -l < "${synthetic_catalog}")" -eq 0 ]]

pretty_catalog="${TMP_DIR}/pretty-catalog.json"
"${BIN}" scan "${fixture_root}" --json "${pretty_catalog}" \
    --recursive --checksums --pretty >/dev/null
[[ "$(wc -l < "${pretty_catalog}")" -gt 1 ]]
"${BIN}" analyze --json "${pretty_catalog}" --pretty >/dev/null
[[ "$(wc -l < "${pretty_catalog}")" -gt 1 ]]
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

# Indexed archive members are ordinary list references: canonical virtual
# paths are searchable and the display name omits any occurrence suffix.
archive_catalog="${TMP_DIR}/archive-catalog.json"
archive_sqlite_root="${TMP_DIR}/archive-sqlite-catalog"
archive_cache="${TMP_DIR}/archive-cache"
cp -a "${fixture_root}" "${archive_sqlite_root}"
"${BIN}" init "${archive_sqlite_root}" >/dev/null
"${BIN}" scan "${archive_sqlite_root}" --recursive --checksums \
    --scan-archives --scan-archives --archive-cache-dir "${archive_cache}" \
    --archive-cache-size 64 >/dev/null
[[ -d "${archive_cache}" ]]
if compgen -G "${archive_cache}/session-*" >/dev/null; then
    printf '%s\n' "Archive cache session was not cleaned up." >&2
    exit 1
fi
"${BIN}" scan "${fixture_root}" --json "${archive_catalog}" \
    --recursive --checksums --scan-archives --scan-archives >/dev/null
"${BIN}" analyze "${archive_sqlite_root}" >/dev/null
"${BIN}" analyze --json "${archive_catalog}" >/dev/null

archive_json_list=$("${BIN}" list --json "${archive_catalog}" \
    --base-dir "${fixture_root}" --limit 200 --format=json \
    | sed -n '/^{/p' | sed -E 's/"id":[0-9]+,//g')
archive_sqlite_list=$("${BIN}" list "${archive_sqlite_root}" \
    --limit 200 --format=json | sed -E 's/"id":[0-9]+,//g')
[[ "${archive_json_list}" == "${archive_sqlite_list}" ]]
[[ "${archive_json_list}" == *'"path":"archives/sample.zip!/payload/copy.txt"'* ]]
[[ "${archive_json_list}" == *'"name":"copy.txt"'* ]]
archive_list_total=$(grep -o '"total":[0-9]*' <<<"${archive_sqlite_list}" \
    | cut -d: -f2)
archive_info=$("${BIN}" info "${archive_sqlite_root}" --format=json)
archive_info_references=$(grep -o '"references":[0-9]*' <<<"${archive_info}" \
    | cut -d: -f2)
[[ -n "${archive_info_references}" ]]
[[ "${archive_info_references}" == "${archive_list_total}" ]]

# Duplicate member names keep canonical occurrence suffixes in paths but not
# in the user-facing display name.
archive_occurrence_catalog="${TMP_DIR}/archive-occurrence.json"
cat >"${archive_occurrence_catalog}" <<'EOF'
{"dataVersion":5,"dataArray":[{"fileSize":1070,"fileSpecs":[{"fileName":"archives/sample.zip"}]},{"fileSize":28,"fileSpecs":[{"fileName":"archives/sample.zip!/payload/copy.txt"}]},{"fileSize":28,"fileSpecs":[{"fileName":"archives/sample.zip!/payload/copy.txt!~1"}]}]}
EOF
archive_occurrences=$("${BIN}" list --json "${archive_occurrence_catalog}" \
    --base-dir "${fixture_root}" --format=json)
[[ "${archive_occurrences}" == *'"path":"archives/sample.zip!/payload/copy.txt!~0"'* ]]
[[ "${archive_occurrences}" == *'"path":"archives/sample.zip!/payload/copy.txt!~1"'* ]]
[[ "${archive_occurrences}" != *'"name":"copy.txt!~'* ]]

archive_filtered=$("${BIN}" list --json "${archive_catalog}" \
    --base-dir "${fixture_root}" \
    --text "archives/sample.zip!/payload/copy.txt" --format=json \
    | sed -n '/^{/p' | sed -E 's/"id":[0-9]+,//g')
[[ "${archive_filtered}" == *'"total":1'* ]]
[[ "${archive_filtered}" == *'"path":"archives/sample.zip!/payload/copy.txt"'* ]]
[[ "${archive_filtered}" == *'"name":"copy.txt"'* ]]

archive_json_duplicates=$("${BIN}" duplicates --json "${archive_catalog}" \
    --base-dir "${fixture_root}" --format=json \
    | sed -n '/^{/p' | sed -E 's/"id":[0-9]+,//g')
archive_sqlite_duplicates=$("${BIN}" duplicates "${archive_sqlite_root}" \
    --format=json | sed -E 's/"id":[0-9]+,//g')
[[ "${archive_json_duplicates}" == "${archive_sqlite_duplicates}" ]]
[[ "${archive_json_duplicates}" == *'"path":"archives/sample.zip!/payload/copy.txt"'* ]]
[[ "${archive_json_duplicates}" == *'"name":"copy.txt"'* ]]

archive_export="${TMP_DIR}/archive-export.json"
"${BIN}" export "${archive_sqlite_root}" --output "${archive_export}" >/dev/null
[[ "$(wc -l < "${archive_export}")" -eq 0 ]]
grep -qF 'archives\/sample.zip!\/payload\/copy.txt' "${archive_export}"

archive_pretty_export="${TMP_DIR}/archive-pretty-export.json"
"${BIN}" export "${archive_sqlite_root}" --output "${archive_pretty_export}" \
    --pretty >/dev/null
[[ "$(wc -l < "${archive_pretty_export}")" -gt 1 ]]

archive_member_export="${TMP_DIR}/archive-member-export.json"
"${BIN}" export "${archive_sqlite_root}" --output "${archive_member_export}" \
    --path "archives/sample.zip!/payload/copy.txt" >/dev/null
grep -qF 'archives\/sample.zip!\/payload\/copy.txt' "${archive_member_export}"
if grep -qF 'alpha\/original.txt' "${archive_member_export}"; then
    printf '%s\n' "Selected export included an unrelated reference." >&2
    exit 1
fi
if grep -qF 'copies\/copy.txt' "${archive_member_export}"; then
    printf '%s\n' "Selected export included an unrelated reference." >&2
    exit 1
fi

archive_missing_export="${TMP_DIR}/archive-missing-export.json"
if "${BIN}" export "${archive_sqlite_root}" \
    --output "${archive_missing_export}" \
    --path "archives/sample.zip!/missing.txt" \
    2>"${TMP_DIR}/archive-missing-export.err"; then
    printf '%s\n' "Selected export accepted a missing virtual path." >&2
    exit 1
fi
grep -qF 'archives/sample.zip!/missing.txt' \
    "${TMP_DIR}/archive-missing-export.err"
[[ ! -e "${archive_missing_export}" ]]
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
        printf "{\"checkSums\":{\"md5sum_b64\":\"AAAAAAAAAAAAAAAAAAAAAA==\",\"sha1sum_b64\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAA=\",\"xxh64sum_b64\":\"AAAAAAAAAAA=\"},\"fileSize\":1,\"fileSpecs\":[{\"fileName\":\"bulk/f%06d\",\"timeLastModified\":\"2020-01-02T04:04:06\"}]}", i
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

# SIGINT during repository import or export cancels without publishing.
cancel_import_repo="${TMP_DIR}/cancel-import-repo"
mkdir -p "${cancel_import_repo}"
"${BIN}" init "${cancel_import_repo}" >/dev/null
"${BIN}" import "${cancel_import_repo}" "${crash_source}" \
    >"${TMP_DIR}/cancel-import-stdout" 2>"${TMP_DIR}/cancel-import-stderr" &
cancel_import_pid=$!
sleep 0.2
kill -INT "${cancel_import_pid}" 2>/dev/null || true
if wait "${cancel_import_pid}"; then
    printf '%s\n' "Expected interrupted import to fail." >&2
    exit 1
fi
grep -q "Catalog import cancelled" "${TMP_DIR}/cancel-import-stderr"
cancel_import_info=$("${BIN}" info "${cancel_import_repo}" --format=json)
[[ "${cancel_import_info}" == *'"blobs":0'* ]]

cancel_export_path="${TMP_DIR}/cancel-export.json"
"${BIN}" export "${crash_repo}" --output "${cancel_export_path}" \
    >"${TMP_DIR}/cancel-export-stdout" 2>"${TMP_DIR}/cancel-export-stderr" &
cancel_export_pid=$!
sleep 0.2
kill -INT "${cancel_export_pid}" 2>/dev/null || true
if wait "${cancel_export_pid}"; then
    printf '%s\n' "Expected interrupted export to fail." >&2
    exit 1
fi
grep -q "Catalog export cancelled" "${TMP_DIR}/cancel-export-stderr"
[[ ! -e "${cancel_export_path}" ]]
"${BIN}" info "${crash_repo}" >/dev/null

# A selected (--path) export cancels the same way and publishes nothing.
cancel_subset_path="${TMP_DIR}/cancel-subset-export.json"
"${BIN}" export "${crash_repo}" --output "${cancel_subset_path}" \
    --path "bulk" \
    >"${TMP_DIR}/cancel-subset-stdout" 2>"${TMP_DIR}/cancel-subset-stderr" &
cancel_subset_pid=$!
for _ in $(seq 1 500); do
    [[ -s "${TMP_DIR}/cancel-subset-stdout" ]] && break
    sleep 0.01
done
kill -INT "${cancel_subset_pid}" 2>/dev/null || true
cancel_subset_rc=0
wait "${cancel_subset_pid}" || cancel_subset_rc=$?
[[ "${cancel_subset_rc}" -eq 1 ]]
grep -q "Catalog export cancelled" "${TMP_DIR}/cancel-subset-stderr"
[[ ! -e "${cancel_subset_path}" ]]
rm -f "${cancel_subset_path}".tmp-*

# SIGINT during a JSON scan stops the workers and saves collected records.
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
[[ "${scan_rc}" -eq 1 ]]
# Cancellation is an operation failure: exit code 1, never 0 or a usage error.
grep -q "Waiting for the application to finish" "${TMP_DIR}/cancel-scan-stdout"
grep -q "collected data was saved" "${TMP_DIR}/cancel-scan-stdout"
[[ -s "${TMP_DIR}/cancel-scan.json" ]]
"${BIN}" list --json "${TMP_DIR}/cancel-scan.json" --format=json >/dev/null

# --dry-run keeps cancellation from writing the catalog.
"${BIN}" scan "${cancel_scan_tree}" --json "${TMP_DIR}/cancel-dry.json" \
    --recursive --checksums --dry-run >"${TMP_DIR}/cancel-dry-stdout" 2>&1 &
scan_pid=$!
sleep 0.2
kill -INT "${scan_pid}" 2>/dev/null || true
scan_rc=0
wait "${scan_pid}" || scan_rc=$?
[[ "${scan_rc}" -eq 1 ]]
grep -q "no changes were written" "${TMP_DIR}/cancel-dry-stdout"
[[ ! -e "${TMP_DIR}/cancel-dry.json" ]]

# The same corpus through SQLite: cancellation during metadata leaves the
# repository readable, whether or not discovery was already committed.
"${BIN}" init "${cancel_scan_tree}" >/dev/null
"${BIN}" scan "${cancel_scan_tree}" --recursive --checksums \
    >"${TMP_DIR}/cancel-sqlite-scan-stdout" 2>&1 &
sqlite_scan_pid=$!
sleep 0.2
kill -INT "${sqlite_scan_pid}" 2>/dev/null || true
sqlite_scan_rc=0
wait "${sqlite_scan_pid}" || sqlite_scan_rc=$?
[[ "${sqlite_scan_rc}" -eq 1 ]]
grep -q "cancelled" "${TMP_DIR}/cancel-sqlite-scan-stdout"
"${BIN}" info "${cancel_scan_tree}" >/dev/null
"${BIN}" list "${cancel_scan_tree}" --format=json >/dev/null

# SIGINT during SQLite metadata cancels and leaves the repository usable.
"${BIN}" metadata "${crash_repo}" --checksums \
    >"${TMP_DIR}/metadata-cancel-stdout" 2>&1 &
metadata_pid=$!
sleep 0.5
kill -INT "${metadata_pid}" 2>/dev/null || true
metadata_rc=0
wait "${metadata_pid}" || metadata_rc=$?
[[ "${metadata_rc}" -eq 1 ]]
grep -q "cancelled" "${TMP_DIR}/metadata-cancel-stdout"
"${BIN}" info "${crash_repo}" >/dev/null

# SIGINT during a large SQLite duplicate merge rolls the transaction back.
"${BIN}" analyze "${crash_repo}" >"${TMP_DIR}/analyze-cancel-stdout" 2>&1 &
analyze_pid=$!
sleep 0.5
kill -INT "${analyze_pid}" 2>/dev/null || true
analyze_rc=0
wait "${analyze_pid}" || analyze_rc=$?
[[ "${analyze_rc}" -eq 1 ]]
grep -q "cancelled" "${TMP_DIR}/analyze-cancel-stdout"
"${BIN}" info "${crash_repo}" >/dev/null
[[ "$("${BIN}" list "${crash_repo}" --format=json)" == *'"total":100000'* ]]

# While one process owns the target write lease, a second mutating command
# fails fast instead of racing the first one.
"${BIN}" metadata "${crash_repo}" --checksums \
    >"${TMP_DIR}/lease-first-stdout" 2>"${TMP_DIR}/lease-first-stderr" &
lease_first_pid=$!
for _ in $(seq 1 500); do
    if [[ -s "${TMP_DIR}/lease-first-stdout" \
        || -s "${TMP_DIR}/lease-first-stderr" ]]; then
        break
    fi
    sleep 0.01
done
lease_second_rc=0
"${BIN}" analyze "${crash_repo}" \
    >"${TMP_DIR}/lease-second-stdout" 2>"${TMP_DIR}/lease-second-stderr" \
    || lease_second_rc=$?
[[ "${lease_second_rc}" -eq 1 ]]
grep -q "Another mutating operation already owns target" \
    "${TMP_DIR}/lease-second-stderr"
[[ ! -s "${TMP_DIR}/lease-second-stdout" ]]
kill -INT "${lease_first_pid}" 2>/dev/null || true
wait "${lease_first_pid}" 2>/dev/null || true
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
[[ "${cancel_rc}" -eq 1 ]]
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

# Help/version are successful. Normal commands announce the app on stderr.
"${BIN}" --help >/dev/null
"${BIN}" --version >/dev/null
startup_banner=$("${BIN}" info "${sqlite_root}" 2>&1 >/dev/null)
[[ "${startup_banner}" == *"DosierSkanilo v"* ]]
if "${BIN}" info "${TMP_DIR}" > "${TMP_DIR}/stdout" 2> "${TMP_DIR}/stderr"; then
    printf '%s\n' "Expected info without a repository to fail." >&2
    exit 1
fi
[[ ! -s "${TMP_DIR}/stdout" ]]
[[ -s "${TMP_DIR}/stderr" ]]

printf '%s\n' "CLI integration checks passed."
