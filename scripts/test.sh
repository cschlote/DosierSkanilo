#!/usr/bin/env bash
set -euo pipefail
#set -x

DC="${DC:-ldc2}"
# The DC environment variable can be set to specify the D compiler to use (e.g., ldc2, dmd, gdc).
# It is used by dub to determine which compiler to use.
export DC
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

# Calculate coverage percentage for all files. Output the stats for each file.
# Finally output the total coverage percentage.
print_coverage() {
    local total_covered=0
    local total_executable=0
    local coverage_files=()
    local lst_file

    is_own_coverage_file() {
        case "$(basename "$1")" in
            source-dosierarkivo-*.lst|source-dosierskanilo-*.lst|source-dosierskanilo_cli-*.lst)
                return 0
                ;;
            *)
                return 1
                ;;
        esac
    }

    shopt -s nullglob
    coverage_files=("${LST_DIR}"/*.lst)
    shopt -u nullglob

    if [ "${#coverage_files[@]}" -eq 0 ]; then
        echo "No coverage listings found."
        return 0
    fi

    for lst_file in "${coverage_files[@]}"; do
        if ! is_own_coverage_file "${lst_file}"; then
            continue
        fi

        local stats
        local covered
        local executable

        stats=$(awk '
            BEGIN {
                FS = "|"
            }
            {
                marker = $1
                gsub(/[ \t]/, "", marker)
                if (marker ~ /^[0-9]+$/) {
                    executable++
                    if ((marker + 0) > 0)
                        covered++
                }
            }
            END {
                printf "%d %d\n", covered + 0, executable + 0
            }
        ' "${lst_file}")
        read -r covered executable <<<"${stats}"

        local percent
        percent=$(awk -v c="${covered}" -v e="${executable}" 'BEGIN { if (e == 0) printf "100.00"; else printf "%.2f", (100.0 * c / e) }')
        printf "%s: %s/%s (%s%%)\n" "$(basename "${lst_file}" .lst)" "${covered}" "${executable}" "${percent}"
        total_covered=$((total_covered + covered))
        total_executable=$((total_executable + executable))
    done

    if [ "${total_executable}" -eq 0 ]; then
        echo "No project coverage listings found."
        return 0
    fi

    local total_percent
    total_percent=$(awk -v c="${total_covered}" -v e="${total_executable}" 'BEGIN { if (e == 0) printf "100.00"; else printf "%.2f", (100.0 * c / e) }')
    printf "Total coverage: %s%%\n" "${total_percent}"
}

print_coverage
