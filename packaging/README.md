# DosierSkanilo Packaging

This directory contains release scaffolding for Arch/AUR, Flatpak, Fedora and
Debian. The project is publicly mirrored at
`https://github.com/cschlote/DosierSkanilo`.

## Package names

- `dosierskanilo`: CLI scanner and backend library
- `dosierskanilo-git`: development snapshot of the CLI/backend

The GUI is packaged separately in `DosierSkanilo-Gui` as `dosierskanilo-gui`
and `dosierskanilo-gui-git`. There is intentionally no umbrella package.

The current stable release is `26.16.0` (`v26.16.0`). Versions before 26.12.1
predate the git-less `VERSION` fallback, so their source archives cannot be
packaged without `.git`. Replace `SKIP` and other placeholders in distribution
recipes before publishing packages. The project is licensed under
`GPL-3.0-only`; package recipes should install the repository's `LICENSE.md`.

## Dependencies

### Build dependencies

- D compiler and DUB: `ldc2` is the tested compiler; DUB resolves
  `d2sqlite3`, `silly`, `jsonizer`, `mediainfo-d`, and `xxhash3`.
- C toolchain and linker (`gcc`/`cc`), `pkg-config`, and `git` for the build
  version stamp.
- SQLite development headers: `libsqlite3-dev` (Debian/Ubuntu), `sqlite`
  (Arch), `sqlite-devel` (Fedora).
- MediaInfo development headers when building the binding:
  `libmediainfo-dev` (Debian/Ubuntu), `mediainfo-devel` (Fedora). The runtime
  library is loaded dynamically.
- Documentation: `adrdox` is fetched by DUB; GDC is the preferred host
  compiler. Lint jobs also need `shellcheck`, `hadolint`, and a Markdown
  linter.

The helper script used by CI is
[`../scripts/install-dependencies.sh`](../scripts/install-dependencies.sh);
the package recipes below are the authoritative distribution metadata.

### Mandatory runtime dependencies

- SQLite runtime library (`libsqlite3.so.0`); the executable links it directly.
- MediaInfo shared library (`libmediainfo.so.0`); the D binding loads it at
  runtime. The `mediainfo` command-line frontend is not required.
- The platform C runtime and `libgcc_s`.

### Optional runtime dependencies

| Command | Enables |
| --- | --- |
| `file` | file-type signatures (`--file-types`, `--all`) |
| `unzip` | ZIP listing and member extraction |
| `tar` | TAR listing and member extraction |
| `unrar` | RAR listing and member extraction |
| `p7zip` / `7z` | 7z listing and member extraction |
| `python3` | exact extraction of duplicate-name ZIP members |

Without these commands the corresponding metadata or archive feature is
unavailable or degrades gracefully; they are not required to start the scanner
or work with files and SQLite repositories.

### Package mapping

- **Debian/Ubuntu:** `Depends: libmediainfo0v5`; `${shlibs:Depends}` adds
  SQLite. `Recommends: file, unzip, tar, unrar, p7zip-full | 7zip`;
  `Suggests: python3`.
- **Arch:** `depends=('libmediainfo' 'sqlite')`; the archive and file tools are
  listed in `optdepends`.
- **Fedora:** `Requires: mediainfo, sqlite-libs`; `Recommends` lists the
  optional tools and `Suggests` adds Python.
- **Flatpak:** bundles `libzen` and `libmediainfo` but does not bundle `file`,
  `unzip`, `tar`, `unrar`, `p7zip`, or `python3`. Archive and file-type
  features therefore remain unavailable in the Flatpak build until those
  tools are added to the manifest or supplied by the runtime.

Debian and Fedora recipes are drafts and should be built in their native
clean-build tools.

## Flatpak build

Install `flatpak` and `flatpak-builder`, then build the manifest from the
repository root. `--install-deps-from=flathub` installs the required 25.08 SDK,
LDC, and LLVM extensions if they are missing:

```sh
flatpak-builder --force-clean --install-deps-from=flathub \
    build/flatpak-build packaging/flatpak/org.dosierskanilo.DosierSkanilo.yml
```

The DUB dependency resolution runs inside the build sandbox with network access.
The Flatpak bundles libmediainfo for media metadata. It does not bundle `file`,
`unzip`, `tar`, `unrar`, `p7zip`, or `python3`, so archive and file-type
features remain unavailable until those tools are added to the manifest.

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

1. Merge the release commit to `main` and create the annotated `v<version>` tag
   on that `main` merge commit. The tag archive must contain the tracked
   `VERSION` fallback used by git-less builds.
2. Verify the published source archive and calculate its SHA256 checksum.
3. Update the Flatpak `sha256` in a follow-up commit on `main`. Never reuse a
   hash after moving a tag: GitHub and GitLab archives embed the tagged commit
   SHA, so an identical tree can still produce a different archive hash.
4. Replace checksum placeholders in the AUR, Flatpak, Fedora and Debian files.
5. Build and test each package in a clean environment, for example with
   `packaging/debian/build-in-container.sh` for Debian.
6. Publish AUR updates and attach Debian/Fedora/Flatpak artifacts to the release.

Do not tag the Flatpak hash-update commit. The source archive cannot contain a
stable hash of itself; the manifest on `main` is the authoritative package
input after the tag is published.

The `dosierskanilo-git` AUR package tracks `main` and intentionally uses a
non-reproducible source snapshot.
