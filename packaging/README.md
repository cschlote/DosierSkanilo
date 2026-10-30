# DosierSkanilo Packaging

This directory contains release scaffolding for Arch/AUR, Flatpak, Fedora and
Debian. The project is publicly mirrored at
`https://github.com/cschlote/DosierSkanilo`.

## Package names

- `dosierskanilo`: CLI scanner and backend library
- `dosierskanilo-git`: development snapshot of the CLI/backend

The GUI is packaged separately in `DosierSkanilo-Gui` as `dosierskanilo-gui`
and `dosierskanilo-gui-git`. There is intentionally no umbrella package.

The current stable release is `26.13.0` (`v26.13.0`). Versions before 26.12.1
predate the git-less `VERSION` fallback, so their source archives cannot be
packaged without `.git`. Replace `SKIP` and other placeholders in distribution
recipes before publishing packages. The project is licensed under
`GPL-3.0-only`; package recipes should install the repository's `LICENSE.md`.

The scanner depends on MediaInfo and archive tools at runtime. Debian/Fedora
recipes below are drafts and should be built in their native clean-build tools.

## Flatpak build

Install `flatpak` and `flatpak-builder`, then build the manifest from the
repository root. `--install-deps-from=flathub` installs the required 25.08 SDK,
LDC, and LLVM extensions if they are missing:

```sh
flatpak-builder --force-clean --install-deps-from=flathub \
    build/flatpak-build packaging/flatpak/org.dosierskanilo.DosierSkanilo.yml
```

The DUB dependency resolution runs inside the build sandbox with network access.
The Flatpak bundles MediaInfo for media metadata; 7z and RAR scanning remain
unavailable until their command-line tools are added to the manifest.

## Containerized Debian build

`packaging/debian/build-in-container.sh` builds a `.deb` in a clean Debian 13
container without installing build dependencies on the host. The repository is
mounted read-only at `/src`; the resulting package files are written to the
mounted output directory, which defaults to `build/packages/debian`.

```sh
./packaging/debian/build-in-container.sh
./packaging/debian/build-in-container.sh /tmp/dosierskanilo-debian
```

The script installs `build-essential`, `debhelper`, `dub`, `ldc`,
`libmediainfo-dev`, and `libsqlite3-dev` inside the container, copies the
working tree into the container, adds the `packaging/debian` metadata as
`debian/`, and runs `dpkg-buildpackage`. It auto-detects Docker or Podman.
Override the engine or image when needed:

```sh
CONTAINER_ENGINE=podman DEBIAN_IMAGE=debian:13-slim \
    ./packaging/debian/build-in-container.sh
```

The host repository is not modified. The first run needs network access to pull
the container image and download DUB dependencies. The script packages the
current working tree, so run it from a clean tag checkout for release artifacts.
Flatpak builds still require `flatpak-builder` on the host or a dedicated
Flatpak build container.

## Release checklist

1. Create and push an annotated `v<version>` tag. The tag archive must contain
   the tracked `VERSION` fallback used by git-less builds.
2. Verify the GitHub release archive and calculate its SHA256 checksum.
3. Replace checksum placeholders in the AUR, Flatpak, Fedora and Debian files.
4. Build and test each package in a clean environment, for example with
   `packaging/debian/build-in-container.sh` for Debian.
5. Publish AUR updates and attach Debian/Fedora/Flatpak artifacts to the release.

The `dosierskanilo-git` AUR package tracks `main` and intentionally uses a
non-reproducible source snapshot.
