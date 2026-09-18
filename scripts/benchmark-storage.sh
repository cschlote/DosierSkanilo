#!/usr/bin/env bash
set -euo pipefail

# Compare direct JSON analysis with repository import/export timings.
# Usage: ./scripts/benchmark-storage.sh [json-file] [repetitions]

JSON_FILE="${1:-./test/json_file_v2.json}"
REPETITIONS="${2:-3}"
ROOT_DIR="$(pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dosierskanilo-benchmark.XXXXXX")"

cleanup() {
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

if [[ ! -f "${JSON_FILE}" ]]; then
    printf 'JSON file does not exist: %s\n' "${JSON_FILE}" >&2
    exit 1
fi

if ! [[ "${REPETITIONS}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Repetitions must be a positive integer: %s\n' "${REPETITIONS}" >&2
    exit 1
fi

if [[ ! -x "${ROOT_DIR}/build/bin/dosierskanilo" ]]; then
    printf 'Build the CLI first: %s\n' "${ROOT_DIR}/build/bin/dosierskanilo" >&2
    exit 1
fi

printf 'Benchmark input: %s\n' "${JSON_FILE}"
printf 'Repetitions: %s\n' "${REPETITIONS}"

for run in $(seq 1 "${REPETITIONS}"); do
    repository="${TMP_DIR}/repository-${run}"
    export_file="${repository}/export.json"
    json_file="${TMP_DIR}/catalog-${run}.json"
    mkdir -p "${repository}"
    cp "${JSON_FILE}" "${json_file}"

    /usr/bin/time -f "run=${run} json-load elapsed=%e memory=%MKB" \
        "${ROOT_DIR}/build/bin/dosierskanilo" \
        json analyze "${json_file}" \
        >/dev/null

    /usr/bin/time -f "run=${run} sqlite-init elapsed=%e memory=%MKB" \
        "${ROOT_DIR}/build/bin/dosierskanilo" \
        init "${repository}" \
        >/dev/null
    /usr/bin/time -f "run=${run} sqlite-import-data elapsed=%e memory=%MKB" \
        "${ROOT_DIR}/build/bin/dosierskanilo" \
        import "${repository}" "${JSON_FILE}" \
        >/dev/null

    /usr/bin/time -f "run=${run} sqlite-export elapsed=%e memory=%MKB" \
        "${ROOT_DIR}/build/bin/dosierskanilo" \
        export "${repository}" --output "${export_file}" \
        >/dev/null
done
