/** Repository archive passwords stored per blob or file path.
 *
 * Passwords are kept in the repository database and are looked up by
 * blob identity or escaped file name.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.passwords;

import d2sqlite3;
import std.conv : to;
import std.file : exists, mkdirRecurse, remove;
import std.path : baseName, buildNormalizedPath, buildPath, isAbsolute;
import std.string : empty, startsWith;
import std.stdio : File;
import dosierarkivo.archive : escapeArchiveVirtualPath, nativePathToStoragePath;
import dosierskanilo.operationlease : TargetWriteLease;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.types;
import dosierskanilo.repository.repository : Repository;

/** Members of `Repository` in the passwords area; mixed into the class. */
mixin template RepositoryPasswords()
{
    /** Set or remove the password associated with a blob identity.
     *
     * Params:
     *     blobId = Stable repository ID of the blob.
     *     password = Password to store, or an empty string to remove it.
     * Throws: `RepositoryException` when the blob ID is unknown.
     */
    void setArchivePasswordForBlob(long blobId, string password)
    {
        requireOpen();
        auto targetLease = TargetWriteLease.acquireRepositoryRoot(
            repositoryPaths.rootPath);
        scope (exit)
            targetLease.release();
        setArchivePasswordForBlobUnleased(blobId, password);
    }

    /** Set or remove a blob password without acquiring the write lease.
     *
     * The caller must already hold the repository write lease.
     *
     * Params:
     *     blobId = Stable repository ID of the blob.
     *     password = Password to store, or an empty string to remove it.
     * Throws: `RepositoryException` when the blob ID is unknown.
     */
    package void setArchivePasswordForBlobUnleased(long blobId, string password)
    {
        if (database.execute("SELECT 1 FROM blobs WHERE id = ?", blobId).empty)
            throw new RepositoryException("Unknown blob ID: " ~ blobId.to!string);
        database.execute("BEGIN IMMEDIATE");
        try
        {
            if (password.length == 0)
                database.execute("DELETE FROM archive_passwords WHERE blob_id = ?",
                    blobId);
            else
                database.execute("INSERT INTO archive_passwords (blob_id, password) "
                    ~ "VALUES (?, ?) ON CONFLICT(blob_id) DO UPDATE SET "
                    ~ "password = excluded.password", blobId, password);
            database.execute("UPDATE repository SET updated_at = ? WHERE id = 1",
                currentTimestamp());
            database.execute("COMMIT");
        }
        catch (Exception ex)
        {
            try
                database.execute("ROLLBACK");
            catch (Exception)
            {
            }
            throw ex;
        }
    }

    /** Resolve a repository filename to its blob and set or remove its password.
     *
     * Params:
     *     fileName = Absolute or repository-relative file name to resolve.
     *     password = Password to store, or an empty string to remove it.
     * Throws: `RepositoryException` when no matching file exists or the name
     *     matches more than one blob.
     */
    void setArchivePasswordForPath(string fileName, string password)
    {
        requireOpen();
        auto targetLease = TargetWriteLease.acquireRepositoryRoot(
            repositoryPaths.rootPath);
        scope (exit)
            targetLease.release();
        auto relativePath = passwordRelativePath(fileName, repositoryPaths.rootPath);
        long[] matches;
        foreach (row; database.execute("SELECT DISTINCT blob_id FROM file_refs "
            ~ "WHERE relative_path = ? ORDER BY blob_id", relativePath))
            matches ~= row.peek!long(0);
        if (matches.length == 0 && baseName(relativePath) == relativePath)
            foreach (row; database.execute("SELECT DISTINCT blob_id FROM file_refs "
                ~ "WHERE substr(relative_path, -length(?) - 1) = '/' || ? "
                ~ "ORDER BY blob_id", relativePath, relativePath))
                matches ~= row.peek!long(0);
        if (matches.length == 0)
            throw new RepositoryException("No repository file matches: " ~ fileName);
        if (matches.length > 1)
            throw new RepositoryException("Filename is ambiguous in this repository: "
                ~ fileName);
        setArchivePasswordForBlobUnleased(matches[0], password);
    }
}

/** Convert a repository filename to its stored, escaped relative path.
 *
 * Absolute paths must lie below `rootPath`. Relative paths are normalized
 * relative to the repository root.
 *
 * Params:
 *     fileName = File name to convert, absolute or repository-relative.
 *     rootPath = Canonical repository root.
 * Returns: Escaped storage path used by file references.
 * Throws: `RepositoryException` when the path escapes the repository root or
 *     is invalid.
 */
package string passwordRelativePath(string fileName, string rootPath)
{
    auto normalized = nativePathToStoragePath(buildNormalizedPath(fileName));
    auto normalizedRoot = nativePathToStoragePath(buildNormalizedPath(rootPath));
    if (isAbsolute(normalized))
    {
        auto prefix = normalizedRoot ~ "/";
        if (!normalized.startsWith(prefix))
            throw new RepositoryException("Archive path is outside repository root: "
                ~ fileName);
        normalized = normalized[prefix.length .. $];
    }
    if (normalized.length == 0 || normalized == ".."
        || normalized.startsWith("../"))
        throw new RepositoryException("Invalid repository file path: " ~ fileName);
    /* Stored references use the canonical escaped form. */
    return escapeArchiveVirtualPath(normalized);
}

@("archive passwords persist by blob identity and survive JSON export")
unittest
{
    import dosierskanilo.model.namedbinaryblob : deserializeDataClassJsonFile;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-archive-password-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto archivePath = buildPath(root, "private.zip");
    auto exported = buildPath(root, "catalog.json");
    write(archivePath, "archive placeholder");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();
    auto blobs = repository.loadCatalog();
    assert(blobs.length == 1);
    auto blobId = repository.loadCatalogQueryPageWithIds(
        RepositoryQueryOptions()).blobIds[0];

    repository.setArchivePasswordForPath(archivePath, "archive-secret");
    assert(repository.loadBlobDetails(blobId).archivePassword == "archive-secret");

    repository.exportJson(exported);
    auto roundTrip = deserializeDataClassJsonFile(exported);
    assert(roundTrip.length == 1);
    assert(roundTrip[0].archivePassword == "archive-secret");

    JsonImportOptions importOptions;
    importOptions.force = true;
    importOptions.backupExisting = false;
    repository.importJson(exported, importOptions);
    auto imported = repository.loadCatalog();
    assert(imported.length == 1);
    assert(imported[0].archivePassword == "archive-secret");

    repository.setArchivePasswordForPath("private.zip", "");
    assert(repository.loadCatalog()[0].archivePassword.length == 0);
}

@("archive password lookup resolves escaped file names")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-archive-password-escaped-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto archivePath = buildPath(root, "archive!.zip");
    write(archivePath, "archive placeholder");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();
    auto blobId = repository.loadCatalogQueryPageWithIds(
        RepositoryQueryOptions()).blobIds[0];

    repository.setArchivePasswordForPath(archivePath, "escaped-secret");
    assert(repository.loadBlobDetails(blobId).archivePassword
        == "escaped-secret");
    repository.setArchivePasswordForPath("archive!.zip", "");
    assert(repository.loadBlobDetails(blobId).archivePassword.length == 0);
}
