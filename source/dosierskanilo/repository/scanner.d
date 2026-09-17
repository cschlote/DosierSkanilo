/** Filesystem scanning against the normalized repository schema. */
module dosierskanilo.repository.scanner;

import d2sqlite3;

import std.algorithm.searching : startsWith;
import std.file : DirEntry, SpanMode, dirEntries, isFile;
import std.path : buildNormalizedPath, buildPath, dirName, dirSeparator;
import std.string : empty, replace, split;

import dosierskanilo.repository.errors;
import dosierskanilo.repository.types;

/** Scan the repository root and update current file references. */
ScanSummary scanRepository(ref Database db, string rootPath,
    RepositoryScanOptions options)
{
    ScanSummary summary;
    auto now = currentTimestamp();

    try
    {
        db.begin();
        foreach (entry; dirEntries(rootPath,
            options.recursive ? SpanMode.depth : SpanMode.shallow))
        {
            auto relative = repositoryRelativePath(rootPath, entry.name);
            if (!options.pickHidden && hasHiddenComponent(relative))
                continue;

            if (isFile(entry.name))
            {
                summary.filesFound++;
                upsertFileReference(db, relative, entry, now, summary);
            }
            else
            {
                summary.directoriesFound++;
                ensureDirectory(db, relative);
            }
        }

        markMissing(db, rootPath, options.pickHidden, summary);
        if (options.dropMissing)
        {
            summary.filesDropped = cast(size_t) db.execute(
                "SELECT count(*) FROM file_refs WHERE exists_on_disk = 0")
                .oneValue!long;
            db.execute("DELETE FROM file_refs WHERE exists_on_disk = 0");
            db.execute("DELETE FROM blobs WHERE id NOT IN "
                ~ "(SELECT DISTINCT blob_id FROM file_refs)");
        }
        db.execute("UPDATE repository SET updated_at = ? WHERE id = 1", now);
        db.commit();
    }
    catch (Exception ex)
    {
        try
            db.rollback();
        catch (Exception)
        {
        }
        throw ex;
    }
    return summary;
}

private void upsertFileReference(ref Database db, string relativePath,
    DirEntry entry, string now, ref ScanSummary summary)
{
    auto result = db.execute("SELECT file_refs.id, file_refs.blob_id, "
        ~ "blobs.file_size, file_refs.time_last_modified FROM file_refs "
        ~ "JOIN blobs ON blobs.id = file_refs.blob_id "
        ~ "WHERE file_refs.relative_path = ?", relativePath);
    auto modified = entry.timeLastModified.toISOExtString;

    if (result.empty)
    {
        db.execute("INSERT INTO blobs (file_size) VALUES (?)",
            cast(long) entry.size);
        auto blobId = db.lastInsertRowid;
        auto directoryId = ensureDirectory(db, dirName(relativePath));
        if (directoryId == 0)
        {
            db.execute("INSERT INTO file_refs "
                ~ "(blob_id, relative_path, time_last_modified, "
                ~ "exists_on_disk, last_seen_at) VALUES (?, ?, ?, 1, ?)",
                blobId, relativePath, modified, now);
        }
        else
        {
            db.execute("INSERT INTO file_refs "
                ~ "(blob_id, directory_id, relative_path, "
                ~ "time_last_modified, exists_on_disk, last_seen_at) "
                ~ "VALUES (?, ?, ?, ?, 1, ?)", blobId, directoryId,
                relativePath, modified, now);
        }
        summary.filesAdded++;
        return;
    }

    auto row = result.front;
    auto fileId = row.peek!long(0);
    auto oldSize = cast(ulong) row.peek!long(2);
    auto oldModified = row.peek!string(3);
    if (oldSize != entry.size || oldModified != modified)
    {
        db.execute("INSERT INTO blobs (file_size) VALUES (?)",
            cast(long) entry.size);
        auto newBlobId = db.lastInsertRowid;
        db.execute("UPDATE file_refs SET blob_id = ?, "
            ~ "time_last_modified = ?, exists_on_disk = 1, last_seen_at = ? "
            ~ "WHERE id = ?", newBlobId, modified, now, fileId);
        summary.filesChanged++;
    }
    else
    {
        db.execute("UPDATE file_refs SET exists_on_disk = 1, "
            ~ "last_seen_at = ? WHERE id = ?", now, fileId);
    }
}

private void markMissing(ref Database db, string rootPath, bool pickHidden,
    ref ScanSummary summary)
{
    auto result = db.execute("SELECT id, relative_path FROM file_refs "
        ~ "WHERE exists_on_disk = 1");
    foreach (row; result)
    {
        auto path = row.peek!string(1);
        if (!pickHidden && hasHiddenComponent(path))
            continue;
        if (!existsOnDisk(rootPath, path))
        {
            db.execute("UPDATE file_refs SET exists_on_disk = 0 "
                ~ "WHERE id = ?", row.peek!long(0));
            summary.filesMissing++;
        }
    }
}

private bool existsOnDisk(string rootPath, string relativePath)
{
    import std.file : exists;
    import std.path : buildPath;
    return exists(buildPath(rootPath, relativePath));
}

private long ensureDirectory(ref Database db, string relativeDirectory)
{
    if (relativeDirectory.empty || relativeDirectory == ".")
        return 0;

    auto normalized = relativeDirectory.replace('\\', '/');
    long parentId;
    string current;
    foreach (part; normalized.split("/"))
    {
        if (part.empty || part == ".")
            continue;
        current = current.empty ? part : current ~ "/" ~ part;
        if (parentId == 0)
            db.execute("INSERT OR IGNORE INTO directories "
                ~ "(parent_id, relative_path, name) VALUES (NULL, ?, ?)",
                current, part);
        else
            db.execute("INSERT OR IGNORE INTO directories "
                ~ "(parent_id, relative_path, name) VALUES (?, ?, ?)",
                parentId, current, part);
        parentId = db.execute("SELECT id FROM directories "
            ~ "WHERE relative_path = ?", current).oneValue!long;
    }
    return parentId;
}

private string repositoryRelativePath(string rootPath, string path)
{
    auto normalizedRoot = buildNormalizedPath(rootPath);
    auto normalized = buildNormalizedPath(path);
    if (normalized == normalizedRoot)
        return "";
    auto prefix = normalizedRoot ~ dirSeparator;
    if (!normalized.startsWith(prefix))
        throw new RepositoryException("Scanned path is outside repository root: "
            ~ path);
    return normalized[prefix.length .. $].replace('\\', '/');
}

private bool hasHiddenComponent(string relativePath)
{
    foreach (part; relativePath.split("/"))
        if (part.startsWith("."))
            return true;
    return false;
}

private string currentTimestamp()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toISOExtString;
}
