/** Filesystem safety checks for SQLite repositories.
 *
 * SQLite requires reliable POSIX locking, shared-memory WAL files, atomic
 * rename, and durable sync. Network and FUSE filesystems frequently provide
 * weaker semantics and can corrupt a catalog even when ordinary reads appear
 * to work.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.filesystem;

import std.algorithm.searching : startsWith;
import std.array : split;
import std.file : readText;
import std.path : buildNormalizedPath;
import std.string : replace, splitLines, toLower;

/** Return whether a kernel filesystem type is unsafe for SQLite repositories.
 *
 * FUSE variants (including sshfs and rclone), SMB/CIFS, NFS, 9p, WSL
 * `drvfs`, and other network/distributed filesystems are rejected because they
 * do not provide SQLite's required locking and durability guarantees.
 *
 * Params:
 *     fsType = Filesystem type as reported by the kernel, for example
 *         `ext4`, `overlay`, `fuse.sshfs`, or `nfs4`.
 * Returns: `true` when a SQLite repository must not be opened there.
 */
bool isUnsupportedRepositoryFilesystemType(string fsType) @safe pure
{
    const value = fsType.toLower;
    if (value.startsWith("fuse"))
        return true;
    foreach (unsupported; [
        "nfs", "nfs4", "cifs", "smb", "smb2", "smb3", "9p", "drvfs",
        "davfs", "ceph", "afs", "glusterfs", "lustre"
    ])
    {
        if (value == unsupported || value.startsWith(unsupported ~ "."))
            return true;
    }
    return false;
}

/** Resolve the filesystem type for a path from `mountinfo` contents.
 *
 * The longest matching mount point wins. This keeps bind mounts and nested
 * mounts from being classified by a parent filesystem.
 *
 * Params:
 *     path = Filesystem path to classify.
 *     mountInfo = Contents of `/proc/self/mountinfo`.
 * Returns: Kernel filesystem type, or an empty string when no mount matches.
 */
string filesystemTypeForPath(string path, string mountInfo) @safe
{
    const canonical = buildNormalizedPath(path);
    string bestMountPoint;
    string bestType;

    foreach (line; mountInfo.splitLines)
    {
        const parts = line.split(" - ");
        if (parts.length != 2)
            continue;
        const before = parts[0].split;
        const after = parts[1].split;
        if (before.length < 5 || after.length < 1)
            continue;

        const mountPoint = decodeMountInfoPath(before[4]);
        if (!isPathWithin(canonical, mountPoint))
            continue;
        if (mountPoint.length <= bestMountPoint.length)
            continue;
        bestMountPoint = mountPoint;
        bestType = after[0];
    }
    return bestType;
}

/** Query the kernel filesystem type for a path.
 *
 * Params:
 *     path = Filesystem path to classify.
 * Returns: Filesystem type, or an empty string when the platform or mount
 *     information does not expose it.
 */
string repositoryFilesystemType(string path) @safe
{
    version (linux)
    {
        try
            return filesystemTypeForPath(path, readText("/proc/self/mountinfo"));
        catch (Exception)
            return "";
    }
    else
        return "";
}

/** Decode the octal escapes used in `/proc/self/mountinfo` mount points.
 *
 * Params:
 *     value = Escaped mount-point field.
 * Returns: Mount point with spaces, tabs, newlines, and backslashes restored.
 */
private string decodeMountInfoPath(string value) @safe
{
    return value
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\");
}

/** Return whether `path` is the mount point or lies below it.
 *
 * Params:
 *     path = Canonical path to check.
 *     mountPoint = Mount point from the kernel mount table.
 * Returns: `true` for the mount point itself and every descendant.
 */
private bool isPathWithin(string path, string mountPoint) @safe
{
    if (path == mountPoint)
        return true;
    if (mountPoint == "/")
        return path.startsWith("/");
    return path.startsWith(mountPoint ~ "/");
}

@("mountinfo classification uses the longest matching mount")
unittest
{
    enum mountInfo = "1 0 0:1 / / rw - ext4 /dev/root rw\n"
        ~ "2 1 0:2 / /mnt/sshfs rw - fuse.sshfs host:/data rw\n"
        ~ "3 1 0:3 / /mnt/sshfs/local rw - tmpfs tmpfs rw\n";
    assert(filesystemTypeForPath("/mnt/sshfs/catalog", mountInfo)
        == "fuse.sshfs");
    assert(filesystemTypeForPath("/mnt/sshfs/local/catalog", mountInfo)
        == "tmpfs");
    assert(filesystemTypeForPath("/home/user/catalog", mountInfo) == "ext4");
    assert(filesystemTypeForPath("/elsewhere", "") == "");
}

@("unsupported repository filesystem types are rejected")
unittest
{
    assert(isUnsupportedRepositoryFilesystemType("fuse.sshfs"));
    assert(isUnsupportedRepositoryFilesystemType("fuse.rclone"));
    assert(isUnsupportedRepositoryFilesystemType("fuseblk"));
    assert(isUnsupportedRepositoryFilesystemType("nfs4"));
    assert(isUnsupportedRepositoryFilesystemType("cifs"));
    assert(isUnsupportedRepositoryFilesystemType("smb3"));
    assert(isUnsupportedRepositoryFilesystemType("9p"));
    assert(!isUnsupportedRepositoryFilesystemType("ext4"));
    assert(!isUnsupportedRepositoryFilesystemType("xfs"));
    assert(!isUnsupportedRepositoryFilesystemType("btrfs"));
    assert(!isUnsupportedRepositoryFilesystemType("overlay"));
    assert(!isUnsupportedRepositoryFilesystemType("tmpfs"));
}
