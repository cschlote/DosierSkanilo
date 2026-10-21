/** Filesystem scanning against the normalized repository schema. */
module dosierskanilo.repository.scanner;

import d2sqlite3;

import std.algorithm.searching : startsWith;
import std.file : SpanMode, dirEntries, isFile;
import std.path : buildNormalizedPath, buildPath, dirName, dirSeparator;
import std.string : empty, replace, split;

import dosierarkivo.archive : escapeArchiveVirtualPath,
    parseArchiveVirtualPath;
import dosierskanilo.repository.archiveindex : deleteUnreachableBlobs,
    isVirtualFileReferenceSql;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.types;
import dosierskanilo.operations : OperationControl, OperationKind,
    OperationPhase, OperationProgress, OperationState;

/** Scan the repository root and update current file references. */
ScanSummary scanRepository(ref Database db, string rootPath,
    RepositoryScanOptions options)
{
    return scanRepositoryControlled(db, rootPath, options, null, 0).summary;
}

/**
 * Stage filesystem observations outside a catalog transaction, then apply them
 * atomically. Pause checkpoints occur only while staging and after each
 * temporary-table statement has completed.
 */
ScanExecutionResult scanRepositoryControlled(ref Database db, string rootPath,
    RepositoryScanOptions options, OperationControl control, ulong operationId)
{
    ScanExecutionResult execution;
    resetScanStage(db);
    scope (exit)
        clearScanStage(db);
    db.execute("INSERT INTO temp.scan_missing_candidates (id, relative_path) "
        ~ "SELECT id, relative_path FROM file_refs WHERE exists_on_disk = 1 "
        ~ "AND NOT (" ~ isVirtualFileReferenceSql("relative_path") ~ ")");

    if (!reportScanProgress(control, operationId, OperationPhase.discovering,
        0, "Scanning filesystem."))
    {
        execution.cancelled = true;
        return execution;
    }

    try
    {
        foreach (entry; dirEntries(rootPath,
            options.recursive ? SpanMode.depth : SpanMode.shallow))
        {
            auto relative = repositoryRelativePath(rootPath, entry.name);
            if (!options.pickHidden && hasHiddenComponent(relative))
                continue;

            if (isFile(entry.name))
            {
                execution.summary.filesFound++;
                auto modified = entry.timeLastModified.toISOExtString;
                const auto canonicalRelative = escapeArchiveVirtualPath(relative);
                db.execute("INSERT OR REPLACE INTO temp.scan_stage_files "
                    ~ "(relative_path, file_size, time_last_modified) "
                    ~ "VALUES (?, ?, ?)", canonicalRelative, cast(long) entry.size,
                    modified);
                db.execute("DELETE FROM temp.scan_missing_candidates "
                    ~ "WHERE relative_path = ?", canonicalRelative);
            }
            else
            {
                execution.summary.directoriesFound++;
                db.execute("INSERT OR IGNORE INTO temp.scan_stage_directories "
                    ~ "(relative_path) VALUES (?)", relative);
            }

            if (!reportScanProgress(control, operationId, OperationPhase.scanning,
                execution.summary.filesFound + execution.summary.directoriesFound,
                relative))
            {
                execution.cancelled = true;
                return execution;
            }
        }

        if (!stageMissingReferences(db, rootPath, options.pickHidden, control,
            operationId, execution.summary.filesFound + execution.summary.directoriesFound,
            execution.summary.filesMissing))
        {
            execution.cancelled = true;
            return execution;
        }

        // No pause is advertised while the atomic catalog transaction is active.
        if (control !is null)
            control.setPauseAvailable(false);
        if (control !is null && control.cancellationRequested)
        {
            execution.cancelled = true;
            return execution;
        }

        auto now = currentTimestamp();
        db.begin();
        applyStagedDirectories(db);
        applyStagedFiles(db, now, execution.summary);
        applyStagedMissing(db);
        if (options.dropMissing)
        {
            execution.summary.filesDropped = cast(size_t) db.execute(
                "SELECT count(*) FROM file_refs WHERE exists_on_disk = 0")
                .oneValue!long;
            db.execute("DELETE FROM file_refs WHERE exists_on_disk = 0");
            deleteUnreachableBlobs(db);
        }
        db.execute("UPDATE repository SET updated_at = ? WHERE id = 1", now);
        if (control !is null && control.cancellationRequested)
        {
            db.rollback();
            execution.cancelled = true;
            return execution;
        }
        db.commit();
        execution.committed = true;
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
    return execution;
}

private void upsertFileReference(ref Database db, string relativePath,
    ulong fileSize, string modified, string now, ref ScanSummary summary)
{
    auto result = db.execute("SELECT file_refs.id, file_refs.blob_id, "
        ~ "blobs.file_size, file_refs.time_last_modified FROM file_refs "
        ~ "JOIN blobs ON blobs.id = file_refs.blob_id "
        ~ "WHERE file_refs.relative_path = ?", relativePath);
    if (result.empty)
    {
        db.execute("INSERT INTO blobs (file_size) VALUES (?)",
            cast(long) fileSize);
        auto blobId = db.lastInsertRowid;
        const auto physicalRelative = parseArchiveVirtualPath(
            relativePath).physicalPath;
        auto directoryId = ensureDirectory(db, dirName(physicalRelative));
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
        updateVirtualReferencesAvailability(db, relativePath, true, now);
        return;
    }

    auto row = result.front;
    auto fileId = row.peek!long(0);
    auto oldBlobId = row.peek!long(1);
    auto oldSize = cast(ulong) row.peek!long(2);
    auto oldModified = row.peek!string(3);
    if (oldSize != fileSize || oldModified != modified)
    {
        db.execute("INSERT INTO blobs (file_size) VALUES (?)",
            cast(long) fileSize);
        auto newBlobId = db.lastInsertRowid;
        deleteVirtualDescendants(db, relativePath);
        db.execute("UPDATE file_refs SET blob_id = ?, "
            ~ "time_last_modified = ?, exists_on_disk = 1, last_seen_at = ? "
            ~ "WHERE id = ?", newBlobId, modified, now, fileId);
        db.execute("DELETE FROM blobs WHERE id = ? AND NOT EXISTS "
            ~ "(SELECT 1 FROM file_refs WHERE blob_id = ?)",
            oldBlobId, oldBlobId);
        deleteUnreachableBlobs(db);
        summary.filesChanged++;
    }
    else
    {
        db.execute("UPDATE file_refs SET exists_on_disk = 1, "
            ~ "last_seen_at = ? WHERE id = ?", now, fileId);
    }
    updateVirtualReferencesAvailability(db, relativePath, true, now);
}

private void deleteVirtualDescendants(ref Database db, string containerPath)
{
    const auto prefix = containerPath ~ "!/";
    long[] staleIds;
    foreach (row; db.execute("SELECT id FROM file_refs WHERE "
        ~ "substr(relative_path, 1, ?) = ?",
        cast(long) prefix.length, prefix))
        staleIds ~= row.peek!long(0);
    foreach (id; staleIds)
        db.execute("DELETE FROM file_refs WHERE id = ?", id);
}

private void updateVirtualReferencesAvailability(ref Database db,
    string physicalRelativePath, bool available, string now)
{
    const auto physical = parseArchiveVirtualPath(physicalRelativePath).physicalPath;
    long[] memberIds;
    foreach (row; db.execute("SELECT id, relative_path FROM file_refs WHERE "
        ~ isVirtualFileReferenceSql("relative_path")))
    {
        const auto parsed = parseArchiveVirtualPath(row.peek!string(1));
        if (parsed.physicalPath == physical)
            memberIds ~= row.peek!long(0);
    }
    foreach (memberId; memberIds)
        if (now.length == 0)
            db.execute("UPDATE file_refs SET exists_on_disk = ? WHERE id = ?",
                available ? 1 : 0, memberId);
        else
            db.execute("UPDATE file_refs SET exists_on_disk = ?, last_seen_at = ? "
                ~ "WHERE id = ?", available ? 1 : 0, now, memberId);
}

private void resetScanStage(ref Database db)
{
    db.execute("DROP TABLE IF EXISTS temp.scan_stage_directories");
    db.execute("DROP TABLE IF EXISTS temp.scan_stage_files");
    db.execute("DROP TABLE IF EXISTS temp.scan_missing_candidates");
    db.execute("DROP TABLE IF EXISTS temp.scan_stage_missing");
    db.execute("CREATE TEMP TABLE scan_stage_directories "
        ~ "(relative_path TEXT PRIMARY KEY)");
    db.execute("CREATE TEMP TABLE scan_stage_files "
        ~ "(relative_path TEXT PRIMARY KEY, file_size INTEGER NOT NULL, "
        ~ "time_last_modified TEXT NOT NULL)");
    db.execute("CREATE TEMP TABLE scan_missing_candidates "
        ~ "(id INTEGER PRIMARY KEY, relative_path TEXT NOT NULL)");
    db.execute("CREATE TEMP TABLE scan_stage_missing (id INTEGER PRIMARY KEY)");
}

private void clearScanStage(ref Database db)
{
    try
    {
        db.execute("DROP TABLE IF EXISTS temp.scan_stage_directories");
        db.execute("DROP TABLE IF EXISTS temp.scan_stage_files");
        db.execute("DROP TABLE IF EXISTS temp.scan_missing_candidates");
        db.execute("DROP TABLE IF EXISTS temp.scan_stage_missing");
    }
    catch (Exception)
    {
    }
}

private struct MissingCandidate
{
    long id;
    string relativePath;
    bool found;
}

private MissingCandidate nextMissingCandidate(ref Database db, long afterId)
{
    auto result = db.execute("SELECT id, relative_path FROM "
        ~ "temp.scan_missing_candidates WHERE id > ? ORDER BY id LIMIT 1",
        afterId);
    if (result.empty)
        return MissingCandidate.init;
    auto row = result.front;
    return MissingCandidate(row.peek!long(0), row.peek!string(1), true);
}

private bool stageMissingReferences(ref Database db, string rootPath,
    bool pickHidden, OperationControl control, ulong operationId, size_t completed,
    ref size_t observedMissing)
{
    long afterId;
    while (true)
    {
        auto candidate = nextMissingCandidate(db, afterId);
        if (!candidate.found)
            break;
        afterId = candidate.id;
        if (pickHidden || !hasHiddenComponent(candidate.relativePath))
        {
            const auto physicalRelative = parseArchiveVirtualPath(
                candidate.relativePath).physicalPath;
            if (!existsOnDisk(rootPath, physicalRelative))
            {
                db.execute("INSERT INTO temp.scan_stage_missing (id) VALUES (?)",
                    candidate.id);
                observedMissing++;
            }
        }
        completed++;
        if (!reportScanProgress(control, operationId,
            OperationPhase.reconcilingMissingFiles, completed,
            candidate.relativePath))
            return false;
    }
    return true;
}

private void applyStagedDirectories(ref Database db)
{
    auto directories = db.execute("SELECT relative_path FROM "
        ~ "temp.scan_stage_directories ORDER BY length(relative_path), relative_path");
    foreach (row; directories)
        ensureDirectory(db, row.peek!string(0));
}

private void applyStagedFiles(ref Database db, string now,
    ref ScanSummary summary)
{
    auto files = db.execute("SELECT relative_path, file_size, "
        ~ "time_last_modified FROM temp.scan_stage_files ORDER BY relative_path");
    foreach (row; files)
        upsertFileReference(db, row.peek!string(0),
            cast(ulong) row.peek!long(1), row.peek!string(2), now, summary);
}

private void applyStagedMissing(ref Database db)
{
    auto missing = db.execute("SELECT id FROM temp.scan_stage_missing ORDER BY id");
    foreach (row; missing)
    {
        const auto id = row.peek!long(0);
        const auto path = db.execute("SELECT relative_path FROM file_refs "
            ~ "WHERE id = ?", id).oneValue!string;
        db.execute("UPDATE file_refs SET exists_on_disk = 0 WHERE id = ?",
            id);
        updateVirtualReferencesAvailability(db, path, false, "");
    }
}

private bool reportScanProgress(OperationControl control, ulong operationId,
    OperationPhase phase, size_t completed, string path)
{
    if (control is null)
        return true;
    if (control.cancellationRequested)
        return false;
    control.setPauseAvailable(true);
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = OperationKind.scan;
    progress.state = OperationState.running;
    progress.phase = phase;
    progress.completed = completed;
    progress.totalKnown = false;
    progress.path = path;
    progress.message = phase == OperationPhase.discovering
        ? "Scanning filesystem." : "Checking stored file references.";
    control.report(progress);
    if (!control.pauseAtCheckpoint(progress))
        return false;
    return !control.cancellationRequested;
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
