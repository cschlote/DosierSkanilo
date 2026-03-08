#!/bin/sh
set -eu

MODE="${1:-build}"

if [ "$MODE" != "build" ] && [ "$MODE" != "runtime" ] && [ "$MODE" != "lint" ]; then
    echo "Usage: $0 [build|runtime|lint]" >&2
    exit 2
fi

if [ ! -r /etc/os-release ]; then
    echo "ERROR: Cannot detect distribution (/etc/os-release missing)." >&2
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

have_all_cmds() {
    for dep in "$@"; do
        if ! have_cmd "$dep"; then
            return 1
        fi
    done
    return 0
}

mode_already_satisfied() {
    case "$MODE" in
        lint)
            have_all_cmds dub ldc2 cc shellcheck hadolint
            ;;
        build)
            have_all_cmds dub ldc2 cc rsync
            ;;
        runtime)
            # Runtime features rely on these external CLIs.
            have_all_cmds file tar unzip 7z rsync
            ;;
        *)
            return 1
            ;;
    esac
}

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have_cmd sudo; then
        sudo "$@"
    else
        echo "ERROR: Need root privileges to install packages (run as root or install sudo)." >&2
        exit 1
    fi
}

install_hadolint_binary() {
    hadolint_version="${HADOLINT_VERSION:-v2.12.0}"
    case "$hadolint_version" in
        v*) ;;
        *) hadolint_version="v${hadolint_version}" ;;
    esac

    case "$(uname -m)" in
        x86_64) hadolint_arch="x86_64" ;;
        aarch64|arm64) hadolint_arch="arm64" ;;
        *)
            echo "ERROR: Unsupported architecture for hadolint binary: $(uname -m)" >&2
            return 1
            ;;
    esac

    hadolint_url="https://github.com/hadolint/hadolint/releases/download/${hadolint_version}/hadolint-Linux-${hadolint_arch}"
    hadolint_tmp="/tmp/hadolint.$$"

    if have_cmd curl; then
        run_as_root sh -c "curl -fsSL '$hadolint_url' -o '$hadolint_tmp'"
    elif have_cmd wget; then
        run_as_root sh -c "wget -qO '$hadolint_tmp' '$hadolint_url'"
    else
        echo "ERROR: Neither curl nor wget is available to download hadolint." >&2
        return 1
    fi

    run_as_root install -m 0755 "$hadolint_tmp" /usr/local/bin/hadolint
    run_as_root rm -f "$hadolint_tmp"
}

install_alpine() {
    runtime_pkgs="bash libmediainfo mediainfo file unzip zip tar p7zip rsync"
    build_pkgs="bash ldc dub build-base openssl-dev libmediainfo-dev rsync"
    lint_pkgs="shellcheck dub ldc build-base ca-certificates wget"

    if [ "$MODE" = "build" ]; then
        # shellcheck disable=SC2086
        run_as_root apk add --no-cache $build_pkgs
    elif [ "$MODE" = "runtime" ]; then
        # shellcheck disable=SC2086
        run_as_root apk add --no-cache $runtime_pkgs
        # unrar is not available in all Alpine repos/images; install best-effort.
        run_as_root apk add --no-cache unrar >/dev/null 2>&1 || true
    elif [ "$MODE" = "lint" ]; then
        # shellcheck disable=SC2086
        run_as_root apk add --no-cache $lint_pkgs
        if ! have_cmd hadolint; then
            if ! run_as_root apk add --no-cache hadolint >/dev/null 2>&1; then
                echo "hadolint package unavailable in apk, falling back to binary install." >&2
                install_hadolint_binary
            fi
        fi
    fi
}

install_debian_ubuntu() {
    distro="$1"
    version="$2"

    if [ "$distro" = "debian" ]; then
        case "$version" in
            12|13) ;;
            *)
                echo "ERROR: Unsupported Debian version '$version' (supported: 12, 13)." >&2
                exit 1
                ;;
        esac
    fi

    if [ "$distro" = "ubuntu" ]; then
        case "$version" in
            24.04|26.04) ;;
            *)
                echo "ERROR: Unsupported Ubuntu version '$version' (supported: 24.04, 26.04)." >&2
                exit 1
                ;;
        esac
    fi

    run_as_root apt-get update

    runtime_pkgs="bash libmediainfo0v5 libmediainfo-dev file unzip zip tar p7zip-full rsync"
    build_pkgs="bash ldc dub libssl-dev build-essential rsync"
    lint_pkgs="shellcheck hadolint dub ldc build-essential"

    if [ "$MODE" = "build" ]; then
        # shellcheck disable=SC2086
        run_as_root apt-get install -y --no-install-recommends $build_pkgs
    elif [ "$MODE" = "runtime" ]; then
        # shellcheck disable=SC2086
        run_as_root apt-get install -y --no-install-recommends $runtime_pkgs
        # unrar naming differs by distro/repo. Try preferred packages without failing hard.
        if run_as_root apt-get install -y --no-install-recommends unrar >/dev/null 2>&1; then
            :
        else
            run_as_root apt-get install -y --no-install-recommends unrar-free >/dev/null 2>&1 || true
        fi
    elif [ "$MODE" = "lint" ]; then
        # shellcheck disable=SC2086
        run_as_root apt-get install -y --no-install-recommends $lint_pkgs
    fi
}

install_manjaro() {
    runtime_pkgs="bash mediainfo file unzip zip tar p7zip rsync"
    build_pkgs="bash ldc dub openssl base-devel rsync"
    lint_pkgs="shellcheck hadolint dub ldc base-devel"

    run_as_root pacman -Sy --noconfirm --needed

    if [ "$MODE" = "build" ]; then
        # shellcheck disable=SC2086
        run_as_root pacman -S --noconfirm --needed $build_pkgs
    elif [ "$MODE" = "runtime" ]; then
        # shellcheck disable=SC2086
        run_as_root pacman -S --noconfirm --needed $runtime_pkgs
        # unrar may not be enabled in all mirrors/repo sets.
        run_as_root pacman -S --noconfirm --needed unrar >/dev/null 2>&1 || true
    elif [ "$MODE" = "lint" ]; then
        # shellcheck disable=SC2086
        run_as_root pacman -S --noconfirm --needed $lint_pkgs
    fi
}

if mode_already_satisfied; then
    echo "Dependencies already present for mode '$MODE'; skipping installation."
    exit 0
fi

case "${ID:-}" in
    alpine)
        install_alpine
        ;;
    debian)
        install_debian_ubuntu "debian" "${VERSION_ID:-}"
        ;;
    ubuntu)
        install_debian_ubuntu "ubuntu" "${VERSION_ID:-}"
        ;;
    manjaro)
        install_manjaro
        ;;
    *)
        if [ "${ID_LIKE:-}" = "manjaro" ] || [ "${ID_LIKE:-}" = "arch" ] || echo "${ID_LIKE:-}" | grep -Eq '(^| )arch( |$)'; then
            install_manjaro
        else
            echo "ERROR: Unsupported distribution '${ID:-unknown}' (ID_LIKE='${ID_LIKE:-}')." >&2
            echo "Supported: alpine, debian 12/13, ubuntu 24.04/26.04, manjaro/rolling." >&2
            exit 1
        fi
        ;;
esac

echo "Dependency installation completed for ${ID:-unknown} ${VERSION_ID:-unknown} (mode=$MODE)."
