/** Filesystem free-space helpers.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.diskspace;

/** Return the bytes available to unprivileged users on a filesystem.
 *
 * Params:
 *     path = Existing file or directory on the filesystem to inspect.
 * Returns: Available bytes, or `0` when the query fails or the platform does
 *     not expose `statvfs`.
 */
ulong availableBytes(string path) @trusted
{
    version (Posix)
    {
        import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
        import std.string : toStringz;

        statvfs_t info;
        if (statvfs(path.toStringz, &info) != 0)
            return 0;
        return cast(ulong) info.f_bavail * cast(ulong) info.f_frsize;
    }
    else
    {
        return 0;
    }
}

@("availableBytes reports free space for an existing directory")
unittest
{
    import std.file : tempDir;

    assert(availableBytes(tempDir()) > 0);
}
