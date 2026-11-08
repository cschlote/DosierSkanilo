/** Filesystem scanning against the normalized repository schema.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.scanner;

import d2sqlite3;

import std.algorithm.searching : startsWith;
import std.file : SpanMode, dirEntries, isFile, readText;
import std.path : buildNormalizedPath, buildPath, dirName, dirSeparator;
import std.string : empty, replace, split;

import dosierarkivo.archive : archivePathSeparator, escapeArchiveVirtualPath,
    nativePathToStoragePath, parseArchiveVirtualPath;
import dosierskanilo.repository.archiveindex : deleteUnreachableBlobs,
    isVirtualFileReferenceSql;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.filesystem : isWithinUnsupportedMount,
    unsupportedMountPoints;
import dosierskanilo.repository.types;
import dosierskanilo.operations : OperationControl, OperationKind,
    OperationPhase, OperationProgress, OperationState;

/** Scan the repository root and update current file references.
 *
 * Params:
 *     db = Open repository database to update.
 *     rootPath = Absolute repository root directory.
 *     options = Scan scope and missing-file handling options.
 * Returns: Summary counters for the completed scan.
 * Throws: `RepositoryException` or database errors propagated from the
 *     controlled scan.
 */
ScanSummary scanRepository(ref Database db, string rootPath,
    RepositoryScanOptions options)
{
    return scanRepositoryControlled(db, rootPath, options, null, 0).summary;
}

/**
 * Stage filesystem observations outside a catalog transaction, then apply them
 * atomically. Pause checkpoints occur only while staging and after each
 * temporary-table statement has completed.
 *
 * Params:
 *     db = Open repository database to update.
 *     rootPath = Absolute repository root directory.
 *     options = Scan scope and missing-file handling options.
 *     control = Optional operation control for progress, pause, and
 *         cancellation; may be `null`.
 *     operationId = Operation id reported in progress events.
 * Returns: Execution result containing scan counters and commit/cancellation
 *     state.
 * Throws: `RepositoryException` or database errors when scanning or applying
 *     the staged changes fails.
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
        const virtualContainers = virtualContainerPaths(db);
        auto statements = ScanStatements(db);
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
                statements.stageFile.inject(canonicalRelative,
                    cast(long) entry.size, modified);
                statements.removeMissingCandidate.inject(canonicalRelative);
            }
            else
            {
                execution.summary.directoriesFound++;
                statements.stageDirectory.inject(relative);
            }

            if (!reportScanProgress(control, operationId, OperationPhase.scanning,
                execution.summary.filesFound + execution.summary.directoriesFound,
                relative))
            {
                execution.cancelled = true;
                return execution;
            }
        }

        if (!stageMissingReferences(db, rootPath, options.recursive,
            options.pickHidden, control, operationId,
            execution.summary.filesFound + execution.summary.directoriesFound,
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
        applyStagedFiles(db, now, execution.summary, virtualContainers,
            statements);
        applyStagedMissing(db, virtualContainers);
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

/** Precompiled statements reused throughout one scan run.
 *
 * Preparing these statements once avoids per-row preparation overhead while
 * walking large repositories.
 */
private struct ScanStatements
{
    /// Looks up an existing file reference by relative path.
    Statement selectFile;
    /// Marks an unchanged file reference as seen now.
    Statement markFileSeen;
    /// Stages one observed file row for later application.
    Statement stageFile;
    /// Stages one observed directory row for later application.
    Statement stageDirectory;
    /// Removes a discovered path from the missing-candidate set.
    Statement removeMissingCandidate;

    /** Prepare all scan statements against the given database handle.
     *
     * Params:
     *     db = Open database used for the scan; the prepared statements remain
     *         bound to it.
     */
    this(ref Database db)
    {
        stageFile = db.prepare("INSERT OR REPLACE INTO temp.scan_stage_files "
            ~ "(relative_path, file_size, time_last_modified) "
            ~ "VALUES (?, ?, ?)");
        stageDirectory = db.prepare("INSERT OR IGNORE INTO "
            ~ "temp.scan_stage_directories (relative_path) VALUES (?)");
        removeMissingCandidate = db.prepare("DELETE FROM "
            ~ "temp.scan_missing_candidates WHERE relative_path = ?");
        selectFile = db.prepare("SELECT file_refs.id, file_refs.blob_id, "
            ~ "blobs.file_size, file_refs.time_last_modified FROM file_refs "
            ~ "JOIN blobs ON blobs.id = file_refs.blob_id "
            ~ "WHERE file_refs.relative_path = ?");
        markFileSeen = db.prepare("UPDATE file_refs SET exists_on_disk = 1, "
            ~ "last_seen_at = ? WHERE id = ?");
    }
}

/** Insert or update the catalog row for one scanned file.
 *
 * New files are added to the current scan stage with a fresh blob. Changed
 * files receive a fresh blob, drop any virtual descendants that no longer
 * apply, and are counted as changed. Unchanged files are only marked as seen.
 *
 * Params:
 *     db = Open database used for the scan.
 *     relativePath = Canonical (escaped) repository-relative path of the file.
 *     fileSize = Size of the file in bytes.
 *     modified = Last-modified timestamp in ISO extended format.
 *     now = Timestamp recorded as the last-seen time.
 *     summary = Scan counters updated in place.
 *     virtualContainers = Set of canonical paths known to contain virtual
 *         members; matching paths get their members' availability refreshed.
 *     statements = Precompiled statements reused for this scan.
 */
private void upsertFileReference(ref Database db, string relativePath,
    ulong fileSize, string modified, string now, ref ScanSummary summary,
    in bool[string] virtualContainers, ref ScanStatements statements)
{
    statements.selectFile.bindAll(relativePath);
    auto result = statements.selectFile.execute();
    const bool exists = !result.empty;
    long fileId;
    long oldBlobId;
    ulong oldSize;
    string oldModified;
    if (exists)
    {
        auto row = result.front;
        fileId = row.peek!long(0);
        oldBlobId = row.peek!long(1);
        oldSize = cast(ulong) row.peek!long(2);
        oldModified = row.peek!string(3);
    }
    result = ResultRange.init;
    statements.selectFile.reset();
    if (!exists)
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
        if (relativePath in virtualContainers)
            updateVirtualReferencesAvailability(db, relativePath, true, now);
        return;
    }

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
        statements.markFileSeen.bindAll(now, fileId);
        statements.markFileSeen.execute();
        statements.markFileSeen.reset();
    }
    if (relativePath in virtualContainers)
        updateVirtualReferencesAvailability(db, relativePath, true, now);
}

/** Delete all stored virtual member references below a container path.
 *
 * Params:
 *     db = Open database used for the scan.
 *     containerPath = Canonical (escaped) path of the container whose members
 *         should be removed.
 */
private void deleteVirtualDescendants(ref Database db, string containerPath)
{
    /* The caller passes the canonical (escaped) stored path. */
    const auto prefix = containerPath ~ archivePathSeparator();
    long[] staleIds;
    foreach (row; db.execute("SELECT id FROM file_refs WHERE "
        ~ "relative_path >= ? AND relative_path < ?",
        prefix, prefix[0 .. $ - 1] ~ "0"))
        staleIds ~= row.peek!long(0);
    foreach (id; staleIds)
        db.execute("DELETE FROM file_refs WHERE id = ?", id);
}

/** Refresh availability of all virtual members belonging to a physical file.
 *
 * Only references whose escaped path falls in the container's prefix range are
 * parsed, which keeps the update from walking every virtual member in the
 * repository.
 *
 * Params:
 *     db = Open database used for the scan.
 *     physicalRelativePath = Stored path of the physical container (escaped or
 *         raw; the physical part is extracted).
 *     available = New `exists_on_disk` value for matching members.
 *     now = Timestamp recorded as the last-seen time; an empty string leaves
 *         `last_seen_at` unchanged.
 */
private void updateVirtualReferencesAvailability(ref Database db,
    string physicalRelativePath, bool available, string now)
{
    const auto physical = parseArchiveVirtualPath(physicalRelativePath).physicalPath;
    const auto prefix = escapeArchiveVirtualPath(physical)
        ~ archivePathSeparator();
    long[] memberIds;
    /* Restrict the scan to the escaped container path range before parsing so
     * a scan does not walk every virtual member in the repository. */
    foreach (row; db.execute("SELECT id, relative_path FROM file_refs WHERE "
        ~ "relative_path >= ? AND relative_path < ? AND "
        ~ isVirtualFileReferenceSql("relative_path"),
        prefix, prefix[0 .. $ - 1] ~ "0"))
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

@("virtual reference availability uses the escaped container path")
unittest
{
    import dosierskanilo.repository.schema : migrate;

    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, 10), (2, 20), (3, 30), (4, 40)");
    db.execute("INSERT INTO file_refs (id, blob_id, relative_path, "
        ~ "exists_on_disk, last_seen_at) VALUES "
        ~ "(1, 1, 'sample!!.zip', 1, ?), "
        ~ "(2, 2, 'sample!!.zip!/inner!!.txt', 1, ?), "
        ~ "(3, 3, 'other!!.zip!/inner!!.txt', 1, ?), "
        ~ "(4, 4, 'sample!!.zip!/😀.txt', 1, ?)",
        "2026-01-01T00:00:00", "2026-01-01T00:00:00", "2026-01-01T00:00:00",
        "2026-01-01T00:00:00");
    auto containers = virtualContainerPaths(db);
    assert("sample!!.zip" in containers);
    assert("other!!.zip" in containers);

    updateVirtualReferencesAvailability(db,
        escapeArchiveVirtualPath("sample!.zip"), false, "");

    assert(db.execute("SELECT exists_on_disk FROM file_refs WHERE id = 1")
        .oneValue!long == 1);
    assert(db.execute("SELECT exists_on_disk FROM file_refs WHERE id = 2")
        .oneValue!long == 0);
    assert(db.execute("SELECT exists_on_disk FROM file_refs WHERE id = 3")
        .oneValue!long == 1);
    assert(db.execute("SELECT exists_on_disk FROM file_refs WHERE id = 4")
        .oneValue!long == 0);
}

@("scans escape directory paths like file references")
unittest
{
    import dosierskanilo : Repository;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "scanner-directory-escape-"
        ~ randomUUID().toString());
    mkdirRecurse(buildPath(root, "d!e"));
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "d!e", "f.txt"), "payload");

    auto repository = Repository.initialize(root);
    scope (exit)
        if (repository !is null)
            repository.close();
    repository.scan(RepositoryScanOptions(true, false, false));

    assert(repository.directoryIdByRelativePath("d!!e") > 0,
        "directory identities must use the escaped namespace");
    assert(repository.directoryIdByRelativePath("d!e") == 0,
        "raw directory names must not leak into the catalog");

    bool found;
    foreach (directory; repository.listDirectories(
        RepositoryDirectoryQuery(0, 0, 10)))
    {
        if (directory.relativePath != "d!!e")
            continue;
        found = true;
        assert(directory.name == "d!e");
        assert(directory.fileCount == 1);
        assert(directory.aggregateSize == "payload".length);
    }
    assert(found, "escaped directory row is missing");
    assert(repository.fileReferenceByRelativePath("d!!e/f.txt").name == "f.txt");

    /* Filters accept the user-visible name as well as the stored spelling. */
    const directoryId = repository.directoryIdByRelativePath("d!!e");
    assert(repository.listFiles(RepositoryFileQuery(directoryId, 0, 10,
        "d!e")).length == 1);
    assert(repository.listFiles(RepositoryFileQuery(directoryId, 0, 10,
        "d!!e")).length == 1);
    assert(repository.listDirectories(RepositoryDirectoryQuery(0, 0, 10,
        "d!e")).length == 1);
    assert(repository.loadCatalogQueryPage(RepositoryQueryOptions(0, 10,
        "d!e")).length == 1);
}

@("non-recursive scans leave nested references untouched")
unittest
{
    import dosierskanilo : Repository;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "scanner-nonrecursive-"
        ~ randomUUID().toString());
    mkdirRecurse(buildPath(root, "sub"));
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "root.txt"), "root");
    write(buildPath(root, "sub", "nested.txt"), "nested");

    auto repository = Repository.initialize(root);
    repository.scan(RepositoryScanOptions(true, false, false));
    repository.close();

    remove(buildPath(root, "sub", "nested.txt"));
    rmdirRecurse(buildPath(root, "sub"));

    repository = Repository.open(root);
    const summary = repository.scan(RepositoryScanOptions(false, false, false));
    assert(summary.filesMissing == 0);
    assert(repository.fileReferenceByRelativePath("sub/nested.txt").present,
        "a non-recursive scan must not probe or mark nested references");
    repository.close();
}

/** Drop and recreate the temporary staging tables used by a scan.
 *
 * Params:
 *     db = Open database whose temporary schema is reset.
 */
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
        ~ "(id INTEGER PRIMARY KEY, relative_path TEXT NOT NULL UNIQUE)");
    db.execute("CREATE TEMP TABLE scan_stage_missing (id INTEGER PRIMARY KEY)");
}

/** Drop the scan staging tables, ignoring any cleanup errors.
 *
 * Params:
 *     db = Open database whose temporary schema is cleared.
 */
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

/** One previously known reference that may have disappeared from disk. */
private struct MissingCandidate
{
    /// Catalog row id of the reference.
    long id;
    /// Stored relative path of the reference.
    string relativePath;
    /// Whether a candidate row was actually returned.
    bool found;
}

/** Fetch the next missing-file candidate with an id greater than `afterId`.
 *
 * Params:
 *     db = Open database holding the temporary candidate table.
 *     afterId = Cursor value; pass zero to start at the beginning.
 * Returns: The next candidate, or a default-initialized value with
 *     `found == false` when no candidate remains.
 */
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

/** Probe candidate references and stage the ones missing from disk.
 *
 * Candidates outside a non-recursive scan's scope, hidden paths, and paths
 * below unsupported network/FUSE mounts are left untouched. The latter avoids
 * blocking indefinitely on a stale mount. Progress is reported before each
 * filesystem probe so a pause names the path currently blocking.
 *
 * Params:
 *     db = Open database holding the temporary candidate table.
 *     rootPath = Repository root against which paths are resolved.
 *     recursive = Whether references below subdirectories are in scope.
 *     pickHidden = Whether hidden path components are considered.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Operation id reported in progress events.
 *     completed = Number of observations already completed before this call.
 *     observedMissing = Running count of missing references, updated in place.
 * Returns: `true` when staging completed, or `false` when the operation was
 *     cancelled.
 */
private bool stageMissingReferences(ref Database db, string rootPath,
    bool recursive, bool pickHidden, OperationControl control, ulong operationId,
    size_t completed, ref size_t observedMissing)
{
    /* Iterate one ordered cursor instead of preparing and executing a new
     * query for every candidate. At millions of references the per-row query
     * overhead dominates the phase and makes progress look stalled. */
    import std.string : indexOf;

    string[string] unsafeMounts;
    version (linux)
    {
        try
            unsafeMounts = unsupportedMountPoints(readText("/proc/self/mountinfo"));
        catch (Exception)
        {
        }
    }

    long[] missingIds;
    {
        auto candidates = db.execute("SELECT id, relative_path FROM "
            ~ "temp.scan_missing_candidates ORDER BY id");
        foreach (row; candidates)
        {
            const auto id = row.peek!long(0);
            const auto relativePath = row.peek!string(1);
            /* A non-recursive scan only owns the root level. References below
             * a subdirectory are outside its scope and must not be probed or
             * marked missing; probing them can stall on unrelated mounts. */
            const bool inScope = recursive
                || relativePath.indexOf('/') == -1;
            if (inScope && (pickHidden || !hasHiddenComponent(relativePath)))
            {
                const auto physicalRelative = parseArchiveVirtualPath(
                    relativePath).physicalPath;
                const auto absolutePath = buildPath(rootPath, physicalRelative);
                /* A stale or hanging network/FUSE mount must not block the
                 * whole scan. Leave those references unchanged; the mount is
                 * outside the supported repository filesystem contract. */
                if (isWithinUnsupportedMount(absolutePath, unsafeMounts))
                {
                    completed++;
                    continue;
                }
                /* Report before the filesystem probe so a heartbeat names
                 * the path that is currently blocking, not the previous one. */
                if (!reportScanProgress(control, operationId,
                    OperationPhase.reconcilingMissingFiles, completed + 1,
                    relativePath))
                    return false;
                if (!existsOnDisk(rootPath, physicalRelative))
                    missingIds ~= id;
            }
            completed++;
        }
    }
    foreach (id; missingIds)
        db.execute("INSERT INTO temp.scan_stage_missing (id) VALUES (?)", id);
    observedMissing += missingIds.length;
    return true;
}

/** Create catalog rows for all staged directories in parent-first order.
 *
 * Params:
 *     db = Open database used for the scan.
 */
private void applyStagedDirectories(ref Database db)
{
    auto directories = db.execute("SELECT relative_path FROM "
        ~ "temp.scan_stage_directories ORDER BY length(relative_path), relative_path");
    foreach (row; directories)
        ensureDirectory(db, row.peek!string(0));
}

/** Apply all staged file observations to the catalog.
 *
 * Params:
 *     db = Open database used for the scan.
 *     now = Timestamp recorded as the last-seen time.
 *     summary = Scan counters updated in place.
 *     virtualContainers = Set of canonical paths known to contain virtual
 *         members.
 *     statements = Precompiled statements reused for this scan.
 */
private void applyStagedFiles(ref Database db, string now,
    ref ScanSummary summary, in bool[string] virtualContainers,
    ref ScanStatements statements)
{
    auto files = db.execute("SELECT relative_path, file_size, "
        ~ "time_last_modified FROM temp.scan_stage_files ORDER BY relative_path");
    foreach (row; files)
        upsertFileReference(db, row.peek!string(0),
            cast(ulong) row.peek!long(1), row.peek!string(2), now, summary,
            virtualContainers, statements);
}

/** Mark staged references as missing and refresh their virtual members.
 *
 * Params:
 *     db = Open database used for the scan.
 *     virtualContainers = Set of canonical paths known to contain virtual
 *         members.
 */
private void applyStagedMissing(ref Database db, in bool[string] virtualContainers)
{
    auto missing = db.execute("SELECT id FROM temp.scan_stage_missing ORDER BY id");
    foreach (row; missing)
    {
        const auto id = row.peek!long(0);
        const auto path = db.execute("SELECT relative_path FROM file_refs "
            ~ "WHERE id = ?", id).oneValue!string;
        db.execute("UPDATE file_refs SET exists_on_disk = 0 WHERE id = ?",
            id);
        if (path in virtualContainers)
            updateVirtualReferencesAvailability(db, path, false, "");
    }
}

/** Collect the canonical paths of file references that act as containers.
 *
 * A container is any physical file that has virtual member references stored
 * below it.
 *
 * Params:
 *     db = Open database to query.
 * Returns: Set of escaped container paths.
 */
private bool[string] virtualContainerPaths(ref Database db)
{
    bool[string] result;
    foreach (row; db.execute("SELECT relative_path FROM file_refs WHERE "
        ~ isVirtualFileReferenceSql("relative_path")))
        result[escapeArchiveVirtualPath(
            parseArchiveVirtualPath(row.peek!string(0)).physicalPath)] = true;
    return result;
}

/** Report one scan progress checkpoint when a control object is present.
 *
 * Params:
 *     control = Optional operation control; when `null`, no report is sent.
 *     operationId = Operation id reported in progress events.
 *     phase = Current scan phase.
 *     completed = Number of observations completed so far.
 *     path = Path currently being processed.
 * Returns: `true` when the scan may continue, or `false` when cancellation or
 *     a pause checkpoint requested a stop.
 */
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

/** Check whether a repository-relative path currently exists on disk.
 *
 * Params:
 *     rootPath = Repository root directory.
 *     relativePath = Native relative path below the root.
 * Returns: `true` when the path exists.
 */
private bool existsOnDisk(string rootPath, string relativePath)
{
    import std.file : exists;
    import std.path : buildPath;
    return exists(buildPath(rootPath, relativePath));
}

/** Ensure catalog rows exist for a directory and all of its parents.
 *
 * Directory identities share the escaped namespace with file references.
 *
 * Params:
 *     db = Open database used for the scan.
 *     relativeDirectory = Native repository-relative directory path.
 * Returns: The catalog id of the deepest directory, or `0` for the repository
 *     root or an empty path.
 */
private long ensureDirectory(ref Database db, string relativeDirectory)
{
    if (relativeDirectory.empty || relativeDirectory == ".")
        return 0;

    auto normalized = nativePathToStoragePath(relativeDirectory);
    long parentId;
    string current;
    string canonical;
    foreach (part; normalized.split("/"))
    {
        if (part.empty || part == ".")
            continue;
        current = current.empty ? part : current ~ "/" ~ part;
        /* Directory identities share the escaped namespace with file
         * references. Keeping the raw path here would break prefix queries
         * below a directory whose name contains an exclamation mark. */
        canonical = escapeArchiveVirtualPath(current);
        if (parentId == 0)
            db.execute("INSERT OR IGNORE INTO directories "
                ~ "(parent_id, relative_path, name) VALUES (NULL, ?, ?)",
                canonical, part);
        else
            db.execute("INSERT OR IGNORE INTO directories "
                ~ "(parent_id, relative_path, name) VALUES (?, ?, ?)",
                parentId, canonical, part);
        parentId = db.execute("SELECT id FROM directories "
            ~ "WHERE relative_path = ?", canonical).oneValue!long;
    }
    return parentId;
}

/** Convert an absolute scanned path into a storage-relative path.
 *
 * Params:
 *     rootPath = Repository root directory.
 *     path = Absolute path below the root.
 * Returns: The path relative to the root in storage form, or an empty string
 *     when `path` is the root itself.
 * Throws: `RepositoryException` when `path` is outside the repository root.
 */
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
    return nativePathToStoragePath(normalized[prefix.length .. $]);
}

/** Report whether any path component starts with a dot.
 *
 * Params:
 *     relativePath = Slash-separated repository-relative path.
 * Returns: `true` when at least one component is hidden.
 */
private bool hasHiddenComponent(string relativePath)
{
    foreach (part; relativePath.split("/"))
        if (part.startsWith("."))
            return true;
    return false;
}

/** Return the current local time as an ISO extended-format timestamp.
 *
 * Returns: Timestamp string used for catalog bookkeeping.
 */
private string currentTimestamp()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toISOExtString;
}

version (Windows) {} else
@("repository paths preserve POSIX backslashes")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "scanner-backslash-"
        ~ randomUUID().toString());
    const auto filePath = buildPath(root, "a\\b.txt");
    mkdirRecurse(root);
    write(filePath, "data");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    assert(repositoryRelativePath(root, filePath) == "a\\b.txt");
}

@("virtual descendant cleanup removes non-BMP members")
unittest
{
    import dosierskanilo.repository.schema : migrate;
    import d2sqlite3 : Database;

    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, 100), (2, 1), "
        ~ "(3, 2), (4, 3)");
    db.execute("INSERT INTO file_refs (id, blob_id, relative_path, "
        ~ "exists_on_disk) VALUES "
        ~ "(1, 1, 'sample.zip', 1), "
        ~ "(2, 2, 'sample.zip!/😀.txt', 1), "
        ~ "(3, 3, 'sample.zip!/z.txt', 1), "
        ~ "(4, 4, 'other.zip!/keep.txt', 1)");
    deleteVirtualDescendants(db, "sample.zip");
    assert(db.execute("SELECT count(*) FROM file_refs WHERE "
        ~ "relative_path >= 'sample.zip!/'").oneValue!long == 0);
    assert(db.execute("SELECT count(*) FROM file_refs WHERE "
        ~ "relative_path = 'other.zip!/keep.txt'").oneValue!long == 1);
}
