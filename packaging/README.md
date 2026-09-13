# DosierSkanilo Packaging

This directory contains release scaffolding for Arch/AUR, Flatpak, Fedora and
Debian. The project is publicly mirrored at
`https://github.com/cschlote/DosierSkanilo`.

The current stable release is `26.9.2` (`v26.9.2`). Replace `SKIP` and other
placeholders in distribution recipes before publishing packages. The project
license is `CC-BY-NC-SA 4.0`; package recipes must install the repository's
license file is not currently present, so maintainers must add and install the
canonical license text before publishing binary packages.

The scanner depends on MediaInfo and archive tools at runtime. Debian/Fedora
recipes below are drafts and should be built in their native clean-build tools.

## Release checklist

1. Create and push an annotated `v<version>` tag.
2. Verify the GitHub release archive and calculate its SHA256 checksum.
3. Replace checksum placeholders in the AUR, Flatpak, Fedora and Debian files.
4. Build and test each package in a clean environment.
5. Publish AUR updates and attach Debian/Fedora/Flatpak artifacts to the release.

The `dosierskanilo-git` AUR package tracks `main` and intentionally uses a
non-reproducible source snapshot.
