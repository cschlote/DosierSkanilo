/** Metadata extraction against repository-managed file references. */
module dosierskanilo.repository.metadata;

import d2sqlite3;

import std.array : join;
import std.base64 : Base64;
import std.conv : to;
import std.exception : enforce;
import std.path : buildPath;
import std.parallelism : Task, TaskPool, task;
import std.string : empty, endsWith, replace, startsWith;
import std.typecons : Nullable;

import dosierarkivo.archive : archiveIndexVersion,
    appendArchiveVirtualPath, escapeArchiveVirtualPath,
    nativePathToStoragePath, normalizeArchiveEntryPath,
    parseArchiveVirtualPath;
import dosierskanilo.metadata.mediainfosig : MediaInfoSig;
import dosierskanilo.metadata.torrentinfo : TorrentInfo;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.operations : OperationControl, OperationKind,
    OperationCallbackException, OperationPhase, OperationProgress,
    OperationState;
import dosierskanilo.progress : ProgressCallBack;
import dosierskanilo.repository.archiveindex : deleteUnreachableBlobs,
    ensureArchiveMemberBlob, isVirtualFileReferenceSql,
    resolveArchiveMemberBlobLinks;
import dosierskanilo.repository.schema : migrate;
import dosierskanilo.repository.types;

private struct VirtualContainerReference
{
    Nullable!long directoryId;
    string relativePath;
    bool existsOnDisk;
    string lastSeenAt;
}

private class MetadataWorkItem
{
    long blobId;
    NamedBinaryBlob blob;
    MetadataScanOptions options;
    OperationControl control;
    ulong operationId;
    ulong progressCompleted;
    ulong progressTotal;
    bool doChecksums;
    bool doFileType;
    bool doMediaInfo;
    bool doArchives;
    bool doTorrents;
    string[string] errors;
}

private void reportMetadataWorkProgress(MetadataWorkItem item,
    OperationPhase phase, ulong subtaskCompleted = 0,
    ulong subtaskTotal = 0, bool subtaskTotalKnown = false,
    string subtaskUnit = "")
{
    if (item.control is null)
        return;
    OperationProgress progress;
    progress.operationId = item.operationId;
    progress.operation = OperationKind.metadata;
    progress.state = OperationState.running;
    progress.phase = phase;
    progress.completed = item.progressCompleted;
    progress.total = item.progressTotal;
    progress.totalKnown = true;
    progress.subtaskCompleted = subtaskCompleted;
    progress.subtaskTotal = subtaskTotal;
    progress.subtaskTotalKnown = subtaskTotalKnown;
    progress.subtaskUnit = subtaskUnit;
    progress.path = item.blob.getFirstFileName();
    progress.message = "Processing metadata.";
    item.control.report(progress);
}

private void runMetadataWork(MetadataWorkItem item)
{
    void attempt(string kind, void delegate() action)
    {
        try
            action();
        catch (OperationCallbackException ex)
            throw ex;
        catch (Exception ex)
            item.errors[kind] = ex.msg;
    }

    if (item.doChecksums)
    {
        reportMetadataWorkProgress(item, OperationPhase.checksums);
        ProgressCallBack checksumProgress;
        if (item.control !is null)
        {
            checksumProgress.contextual = (size_t completed, size_t total) {
                reportMetadataWorkProgress(item, OperationPhase.checksums,
                    completed, total, true, "bytes");
            };
        }
        attempt("checksums", {
            if (item.control is null)
                updateDigests(item.blob);
            else
                updateDigests(item.blob, null, &checksumProgress);
        });
    }
    if (item.doFileType)
    {
        reportMetadataWorkProgress(item, OperationPhase.fileTypes);
        attempt("file_type", { updateFileType(item.blob); });
    }
    if (item.doMediaInfo)
    {
        reportMetadataWorkProgress(item, OperationPhase.mediaInfo);
        attempt("media_info", { updateMediaInfo(item.blob, item.options.rescan); });
    }
    if (item.doArchives)
    {
        reportMetadataWorkProgress(item, OperationPhase.archives);
        ProgressCallBack archiveProgress;
        if (item.control !is null)
        {
            archiveProgress.contextual = (size_t completed, size_t total) {
                reportMetadataWorkProgress(item, OperationPhase.archives,
                    completed, total, true, "entries");
            };
        }
        attempt("archives", {
            updateArchives(item.blob, item.options.rescan,
                item.options.deepArchiveScan, null,
                item.control is null ? null : &archiveProgress,
                item.options.archivePasswordCallback, 0, 8, "", null,
                item.options.detectFileTypes, item.options.extractMediaInfo);
        });
    }
    if (item.doTorrents)
    {
        reportMetadataWorkProgress(item, OperationPhase.torrents);
        attempt("torrents", { updateTorrentInfo(item.blob, item.options.rescan); });
    }
}

private long[] metadataBlobIds(ref Database db, string filePath)
{
    long[] blobIds;
    if (filePath.empty)
    {
        foreach (row; db.execute("SELECT DISTINCT b.id FROM blobs b "
            ~ "JOIN file_refs f ON f.blob_id = b.id WHERE "
            ~ "NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ") "
            ~ "ORDER BY b.id"))
            blobIds ~= row.peek!long(0);
    }
    else
    {
        const auto canonical = escapeArchiveVirtualPath(nativePathToStoragePath(filePath));
        foreach (row; db.execute("SELECT DISTINCT b.id FROM blobs b "
            ~ "JOIN file_refs f ON f.blob_id = b.id "
            ~ "WHERE f.relative_path = ? AND "
            ~ "NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ") "
            ~ "ORDER BY b.id", canonical))
            blobIds ~= row.peek!long(0);
    }
    return blobIds;
}

/** Persist one metadata result atomically, rolling back partial writes. */
private void commitMetadataWork(ref Database db, scope void delegate() work)
{
    db.begin();
    try
    {
        work();
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
}

/** Run the selected metadata jobs one blob at a time. */
MetadataSummary updateRepositoryMetadata(ref Database db, string rootPath,
    MetadataScanOptions options)
{
    scope (exit)
    {
        if (options.scanArchives)
        {
            resolveArchiveMemberBlobLinks(db);
            deleteUnreachableBlobs(db);
        }
        /* Metadata rewrites file_refs for archive members, so cursors issued
         * before this run must become invalid even though sourceVersion only
         * reads repository.updated_at. */
        db.execute("UPDATE repository SET updated_at = ? WHERE id = 1",
            currentTimestamp());
    }
    if (options.threads > 1)
        return updateRepositoryMetadataParallel(db, rootPath, options);

    MetadataSummary summary;
    foreach (blobId; metadataBlobIds(db, options.filePath))
    {
        auto blob = loadBlob(db, rootPath, blobId);
        if (blob is null)
            continue;
        summary.blobsVisited++;

        if (options.calculateChecksums && !blob.checkSums.hasDigests)
        {
            setMetadataStatus(db, blobId, "checksums", "pending", "");
            try
            {
                updateDigests(blob);
                commitMetadataWork(db, {
                    persistChecksums(db, blobId, blob);
                    setMetadataStatus(db, blobId, "checksums",
                        metadataState(blob.checkSums.hasDigests), "");
                });
                summary.checksumsUpdated++;
            }
            catch (Exception ex)
            {
                setMetadataStatus(db, blobId, "checksums", "failed", ex.msg);
                summary.failed++;
            }
        }

        if (options.detectFileTypes && blob.fileType.length == 0
            && !metadataCompleted(db, blobId, "file_type"))
        {
            setMetadataStatus(db, blobId, "file_type", "pending", "");
            try
            {
                updateFileType(blob);
                commitMetadataWork(db, {
                    db.execute("UPDATE blobs SET file_type = ? WHERE id = ?",
                        blob.fileType, blobId);
                    setMetadataStatus(db, blobId, "file_type",
                        metadataState(blob.fileType.length > 0), "");
                });
                summary.fileTypesUpdated++;
            }
            catch (Exception ex)
            {
                setMetadataStatus(db, blobId, "file_type", "failed", ex.msg);
                summary.failed++;
            }
        }

        if (options.extractMediaInfo && (options.rescan
            || !metadataCompleted(db, blobId, "media_info")))
        {
            setMetadataStatus(db, blobId, "media_info", "pending", "");
            try
            {
                updateMediaInfo(blob, options.rescan);
                commitMetadataWork(db, {
                    persistMediaInfo(db, blobId, blob.mediaInfoSig);
                    setMetadataStatus(db, blobId, "media_info", metadataState(
                        blob.mediaInfoSig !is null && !blob.mediaInfoSig.empty),
                        "");
                });
                if (blob.mediaInfoSig !is null && !blob.mediaInfoSig.empty)
                    summary.mediaInfoUpdated++;
            }
            catch (Exception ex)
            {
                setMetadataStatus(db, blobId, "media_info", "failed", ex.msg);
                summary.failed++;
            }
        }

        if (options.scanArchives && (options.rescan
            || !metadataCompleted(db, blobId, "archives")
            || !archiveIndexCurrent(db, blobId, options.deepArchiveScan)))
        {
            setMetadataStatus(db, blobId, "archives", "pending", "");
            try
            {
                updateArchives(blob, options.rescan, options.deepArchiveScan,
                    null, null, options.archivePasswordCallback, 0, 8, "", null,
                    options.detectFileTypes, options.extractMediaInfo);
                commitMetadataWork(db, {
                    persistArchives(db, blobId, blob.archiveSpecs,
                        options.deepArchiveScan, summary);
                    persistArchivePassword(db, blobId, blob.archivePassword);
                    /* persistArchives already stores "empty"/"completed". */
                    if (blob.archiveSpecs is null)
                        setMetadataStatus(db, blobId, "archives",
                            "not_archive", "");
                });
                if (blob.archiveSpecs !is null)
                    summary.archivesUpdated++;
            }
            catch (Exception ex)
            {
                persistArchivePassword(db, blobId, blob.archivePassword);
                setMetadataStatus(db, blobId, "archives", "failed", ex.msg);
                summary.failed++;
            }
        }

        if (options.scanTorrents && (options.rescan
            || !metadataCompleted(db, blobId, "torrents")))
        {
            setMetadataStatus(db, blobId, "torrents", "pending", "");
            try
            {
                updateTorrentInfo(blob, options.rescan);
                commitMetadataWork(db, {
                    persistTorrentInfo(db, blobId, blob.torrentInfo);
                    setMetadataStatus(db, blobId, "torrents",
                        metadataState(blob.torrentInfo !is null), "");
                });
                if (blob.torrentInfo !is null)
                    summary.torrentsUpdated++;
            }
            catch (Exception ex)
            {
                setMetadataStatus(db, blobId, "torrents", "failed", ex.msg);
                summary.failed++;
            }
        }
    }
    return summary;
}

/**
 * Run metadata extraction in bounded worker batches with one atomic persistence
 * transaction per blob. Pause is acknowledged only after every worker in the
 * active batch has finished and all complete blob results have been committed.
 */
MetadataExecutionResult updateRepositoryMetadataControlled(ref Database db,
    string rootPath, MetadataScanOptions options, OperationControl control,
    ulong operationId)
{
    scope (exit)
    {
        if (options.scanArchives)
        {
            resolveArchiveMemberBlobLinks(db);
            deleteUnreachableBlobs(db);
        }
        /* Metadata rewrites file_refs for archive members, so cursors issued
         * before this run must become invalid even though sourceVersion only
         * reads repository.updated_at. */
        db.execute("UPDATE repository SET updated_at = ? WHERE id = 1",
            currentTimestamp());
    }
    MetadataExecutionResult execution;
    auto blobIds = metadataBlobIds(db, options.filePath);
    auto batchSize = options.threads > 0 ? options.threads * 4 : 1;
    if (batchSize == 0)
        batchSize = 1;
    auto phases = metadataPhases(options);
    size_t nextIndex;

    while (nextIndex < blobIds.length)
    {
        if (!reportMetadataProgress(control, operationId,
            OperationPhase.discovering, execution.summary.blobsVisited,
            blobIds.length, "Preparing metadata work."))
        {
            execution.cancelled = true;
            return execution;
        }

        MetadataWorkItem[] items;
        while (nextIndex < blobIds.length && items.length < batchSize)
        {
            if (control !is null && control.cancellationRequested)
                break;
            auto blobId = blobIds[nextIndex++];
            auto blob = loadBlob(db, rootPath, blobId);
            if (blob is null)
                continue;

            auto item = new MetadataWorkItem();
            item.blobId = blobId;
            item.blob = blob;
            item.options = options;
            item.control = control;
            item.operationId = operationId;
            item.progressCompleted = cast(ulong) nextIndex;
            item.progressTotal = cast(ulong) blobIds.length;
            item.doChecksums = options.calculateChecksums
                && !blob.checkSums.hasDigests;
            item.doFileType = options.detectFileTypes
                && blob.fileType.length == 0
                && !metadataCompleted(db, blobId, "file_type");
            item.doMediaInfo = options.extractMediaInfo
                && (options.rescan || !metadataCompleted(db, blobId, "media_info"));
            item.doArchives = options.scanArchives
                && (options.rescan || !metadataCompleted(db, blobId, "archives")
                    || !archiveIndexCurrent(db, blobId,
                        options.deepArchiveScan));
            item.doTorrents = options.scanTorrents
                && (options.rescan || !metadataCompleted(db, blobId, "torrents"));
            items ~= item;
        }

        if (control !is null && control.cancellationRequested)
        {
            execution.cancelled = true;
            return execution;
        }
        if (items.length == 0)
        {
            continue;
        }

        runControlledMetadataBatch(items, options.threads);
        // All worker calls are joined before any result is persisted or pause is
        // acknowledged. One transaction covers the batch; a persistence failure
        // rolls the batch back as a unit.
        bool transactionOpen;
        bool persistedWork;
        try
        {
            db.begin();
            transactionOpen = true;
            foreach (item; items)
            {
                if (hasMetadataWork(item))
                {
                    persistMetadataWork(db, item, execution.summary);
                    persistedWork = true;
                }
                execution.summary.blobsVisited++;
            }
            db.commit();
            transactionOpen = false;
        }
        catch (Exception ex)
        {
            if (transactionOpen)
            {
                try
                    db.rollback();
                catch (Exception)
                {
                }
            }
            throw ex;
        }
        if (persistedWork)
            execution.committed = true;

        const auto checkpointPhase = phases.length > 0
            ? phases[$ - 1] : OperationPhase.discovering;
        const auto checkpointPath = items.length > 0
            ? items[$ - 1].blob.getFirstFileName() : "";
        if (!checkpointMetadataProgress(control, operationId, checkpointPhase,
            execution.summary.blobsVisited, blobIds.length, checkpointPath))
        {
            execution.cancelled = true;
            return execution;
        }
    }
    return execution;
}

private bool hasMetadataWork(MetadataWorkItem item)
{
    return item.doChecksums || item.doFileType || item.doMediaInfo
        || item.doArchives || item.doTorrents;
}

private void runControlledMetadataBatch(MetadataWorkItem[] items, size_t threads)
{
    if (threads <= 1)
    {
        foreach (item; items)
            runMetadataWork(item);
        return;
    }

    TaskPool pool = new TaskPool(threads);
    Task!(runMetadataWork, MetadataWorkItem)*[] tasks;
    try
    {
        foreach (item; items)
        {
            auto worker = task!runMetadataWork(item);
            tasks ~= worker;
            pool.put(worker);
        }
        foreach (worker; tasks)
            worker.workForce();
    }
    finally
    {
        pool.finish(true);
        pool.stop();
    }
}

private OperationPhase[] metadataPhases(MetadataScanOptions options)
{
    OperationPhase[] phases;
    if (options.calculateChecksums) phases ~= OperationPhase.checksums;
    if (options.detectFileTypes) phases ~= OperationPhase.fileTypes;
    if (options.extractMediaInfo) phases ~= OperationPhase.mediaInfo;
    if (options.scanArchives) phases ~= OperationPhase.archives;
    if (options.scanTorrents) phases ~= OperationPhase.torrents;
    return phases;
}

private bool reportMetadataProgress(OperationControl control, ulong operationId,
    OperationPhase phase, size_t completed, size_t total, string path)
{
    if (control is null)
        return true;
    if (control.cancellationRequested)
        return false;
    control.setPauseAvailable(true);
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = OperationKind.metadata;
    progress.state = OperationState.running;
    progress.phase = phase;
    progress.completed = completed;
    progress.total = total;
    progress.totalKnown = true;
    progress.path = path;
    progress.message = phase == OperationPhase.discovering
        ? "Preparing metadata work." : "Metadata results committed for completed blobs.";
    control.report(progress);
    if (control.cancellationRequested)
        return false;
    if (!control.pauseAtCheckpoint(progress))
        return false;
    return !control.cancellationRequested;
}

@("metadataCompleted and archiveIndexCurrent")
unittest
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE metadata_status (blob_id INTEGER NOT NULL, "
        ~ "metadata_kind TEXT NOT NULL, state TEXT NOT NULL, "
        ~ "extractor_version TEXT, scanned_at TEXT, error_message TEXT, "
        ~ "PRIMARY KEY (blob_id, metadata_kind))");

    assert(!metadataCompleted(db, 1, "file_type"));
    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
        ~ "scanned_at, error_message) VALUES (1, 'file_type', 'completed', ?, '')",
        "2026-01-01T00:00:00");
    assert(metadataCompleted(db, 1, "file_type"));

    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
        ~ "extractor_version, scanned_at, error_message) VALUES "
        ~ "(1, 'archives', 'completed', ?, ?, '')",
        archiveIndexVersion ~ ":123:deep", "2026-01-01T00:00:00");
    assert(archiveIndexCurrent(db, 1, true));
    assert(archiveIndexCurrent(db, 1, false));

    db.execute("UPDATE metadata_status SET extractor_version = ? WHERE blob_id = 1 "
        ~ "AND metadata_kind = 'archives'", archiveIndexVersion ~ ":123:shallow");
    assert(!archiveIndexCurrent(db, 1, true));

    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
        ~ "scanned_at, error_message) VALUES (2, 'archives', 'not_archive', ?, '')",
        "2026-01-01T00:00:00");
    assert(archiveIndexCurrent(db, 2, true));
}

@("updateRepositoryMetadata")
unittest
{
    import std.file : getSize;
    import dosierskanilo.testdata : ensureSyntheticTestCatalog;

    auto fixture = ensureSyntheticTestCatalog();
    const auto rootPath = fixture.catalogRoot;
    const auto filePath = buildPath(rootPath, "media", "tone.wav");

    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, ?)",
        cast(long) getSize(filePath));
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(1, 1, NULL, 'media/tone.wav', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00");

    auto summary = updateRepositoryMetadata(db, rootPath,
        MetadataScanOptions(1, true, true, false, false, true, false, false));

    assert(summary.blobsVisited == 1);
    assert(summary.checksumsUpdated == 1);
    assert(summary.fileTypesUpdated == 1);
    assert(summary.mediaInfoUpdated == 0);
    assert(summary.archivesUpdated == 0);
    assert(summary.torrentsUpdated == 0);
    assert(summary.failed == 0);
    assert(db.execute("SELECT md5, sha1, xxh64 FROM blobs WHERE id = 1")
        .oneValue!Blob.length > 0);
    assert(db.execute("SELECT file_type FROM blobs WHERE id = 1")
        .oneValue!string.length > 0);
    assert(metadataCompleted(db, 1, "checksums"));
    assert(metadataCompleted(db, 1, "file_type"));
}

@("updateRepositoryMetadataControlled")
unittest
{
    import std.file : getSize;
    import dosierskanilo.testdata : ensureSyntheticTestCatalog;

    auto fixture = ensureSyntheticTestCatalog();
    const auto rootPath = fixture.catalogRoot;
    const auto filePath = buildPath(rootPath, "media", "tone.wav");

    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, ?)",
        cast(long) getSize(filePath));
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(1, 1, NULL, 'media/tone.wav', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00");

    auto execution = updateRepositoryMetadataControlled(db, rootPath,
        MetadataScanOptions(1, true, true, false, false, true, false, false),
        new OperationControl(), 77);

    assert(!execution.cancelled);
    assert(execution.committed);
    assert(execution.summary.blobsVisited == 1);
    assert(execution.summary.checksumsUpdated == 1);
    assert(execution.summary.fileTypesUpdated == 1);
    assert(execution.summary.mediaInfoUpdated == 0);
    assert(execution.summary.archivesUpdated == 0);
    assert(execution.summary.torrentsUpdated == 0);
}

@("updateRepositoryMetadata archives and torrents")
unittest
{
    import std.file : getSize;
    import dosierskanilo.testdata : ensureSyntheticTestCatalog;

    auto fixture = ensureSyntheticTestCatalog();
    const auto archivePath = buildPath(fixture.catalogRoot, "archives", "sample.zip");
    const auto torrentPath = buildPath(fixture.catalogRoot, "torrent", "single-file.torrent");

    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, ?)",
        cast(long) getSize(archivePath));
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(1, 1, NULL, 'archives/sample.zip', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (2, ?)",
        cast(long) getSize(torrentPath));
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(2, 2, NULL, 'torrent/single-file.torrent', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00");

    auto summary = updateRepositoryMetadata(db, fixture.catalogRoot,
        MetadataScanOptions(1, false, false, false, true, false, true, false));

    assert(summary.blobsVisited == 2);
    assert(summary.archivesUpdated == 1);
    assert(summary.torrentsUpdated == 1);
    assert(summary.failed == 0);
    assert(metadataCompleted(db, 1, "archives"));
    assert(metadataCompleted(db, 2, "torrents"));
    assert(archiveIndexCurrent(db, 1, false));
    assert(db.execute("SELECT COUNT(*) FROM file_refs WHERE relative_path LIKE ?",
        "archives/sample.zip!/%").oneValue!long > 0);
    assert(db.execute("SELECT COUNT(*) FROM torrent_info WHERE blob_id = 2")
        .oneValue!long == 1);
    assert(db.execute("SELECT COUNT(*) FROM torrent_files WHERE torrent_blob_id = 2")
        .oneValue!long > 0);
}

/** Honor pause/cancel requests after workers and metadata transactions have drained. */
private bool checkpointMetadataProgress(OperationControl control,
    ulong operationId, OperationPhase phase, size_t completed, size_t total,
    string path)
{
    if (control is null)
        return true;
    if (control.cancellationRequested)
        return false;
    control.setPauseAvailable(true);
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = OperationKind.metadata;
    progress.state = OperationState.running;
    progress.phase = phase;
    progress.completed = completed;
    progress.total = total;
    progress.totalKnown = true;
    progress.path = path;
    progress.message = "Metadata results committed for completed blobs.";
    return control.pauseAtCheckpoint(progress) && !control.cancellationRequested;
}

private MetadataSummary updateRepositoryMetadataParallel(ref Database db,
    string rootPath, MetadataScanOptions options)
{
    MetadataSummary summary;
    long[] batchIds;
    auto batchSize = options.threads * 4;
    if (batchSize == 0)
        batchSize = 1;

    foreach (blobId; metadataBlobIds(db, options.filePath))
    {
        batchIds ~= blobId;
        if (batchIds.length >= batchSize)
        {
            processMetadataBatch(db, rootPath, options, batchIds, summary);
            batchIds.length = 0;
        }
    }
    if (batchIds.length > 0)
        processMetadataBatch(db, rootPath, options, batchIds, summary);
    return summary;
}

private void processMetadataBatch(ref Database db, string rootPath,
    MetadataScanOptions options, long[] blobIds, ref MetadataSummary summary)
{
    MetadataWorkItem[] items;
    foreach (blobId; blobIds)
    {
        auto blob = loadBlob(db, rootPath, blobId);
        if (blob is null)
            continue;

        auto item = new MetadataWorkItem();
        item.blobId = blobId;
        item.blob = blob;
        item.options = options;
        item.doChecksums = options.calculateChecksums && !blob.checkSums.hasDigests;
        item.doFileType = options.detectFileTypes && blob.fileType.length == 0
            && !metadataCompleted(db, blobId, "file_type");
        item.doMediaInfo = options.extractMediaInfo
            && (options.rescan || !metadataCompleted(db, blobId, "media_info"));
        item.doArchives = options.scanArchives
            && (options.rescan || !metadataCompleted(db, blobId, "archives")
                || !archiveIndexCurrent(db, blobId,
                    options.deepArchiveScan));
        item.doTorrents = options.scanTorrents
            && (options.rescan || !metadataCompleted(db, blobId, "torrents"));
        if (!(item.doChecksums || item.doFileType || item.doMediaInfo
            || item.doArchives || item.doTorrents))
            continue;

        if (item.doChecksums)
            setMetadataStatus(db, blobId, "checksums", "pending", "");
        if (item.doFileType)
            setMetadataStatus(db, blobId, "file_type", "pending", "");
        if (item.doMediaInfo)
            setMetadataStatus(db, blobId, "media_info", "pending", "");
        if (item.doArchives)
            setMetadataStatus(db, blobId, "archives", "pending", "");
        if (item.doTorrents)
            setMetadataStatus(db, blobId, "torrents", "pending", "");
        items ~= item;
    }

    TaskPool pool = new TaskPool(options.threads);
    Task!(runMetadataWork, MetadataWorkItem)*[] tasks;
    try
    {
        foreach (item; items)
        {
            auto worker = task!runMetadataWork(item);
            tasks ~= worker;
            pool.put(worker);
        }

        summary.blobsVisited += items.length;
        foreach (index, item; items)
        {
            tasks[index].workForce();
            commitMetadataWork(db, { persistMetadataWork(db, item, summary); });
        }
    }
    finally
    {
        pool.finish(true);
        pool.stop();
    }
}

private void persistMetadataWork(ref Database db, MetadataWorkItem item,
    ref MetadataSummary summary)
{
    void finish(string kind, bool requested, bool hasData, void delegate() persist)
    {
        if (!requested)
            return;
        if (kind in item.errors)
        {
            if (kind == "archives")
                persistArchivePassword(db, item.blobId,
                    item.blob.archivePassword);
            setMetadataStatus(db, item.blobId, kind, "failed", item.errors[kind]);
            summary.failed++;
            return;
        }
        persist();
        /* persistArchives records the authoritative "empty"/"completed" state;
         * only a non-archive needs a status row here. */
        if (kind == "archives")
        {
            if (!hasData)
                setMetadataStatus(db, item.blobId, kind, "not_archive", "");
        }
        else
            setMetadataStatus(db, item.blobId, kind, metadataState(hasData), "");
        if (hasData)
        {
            if (kind == "checksums") summary.checksumsUpdated++;
            else if (kind == "file_type") summary.fileTypesUpdated++;
            else if (kind == "media_info") summary.mediaInfoUpdated++;
            else if (kind == "archives") summary.archivesUpdated++;
            else if (kind == "torrents") summary.torrentsUpdated++;
        }
    }

    finish("checksums", item.doChecksums, item.blob.checkSums.hasDigests,
        { persistChecksums(db, item.blobId, item.blob); });
    finish("file_type", item.doFileType, item.blob.fileType.length > 0,
        { db.execute("UPDATE blobs SET file_type = ? WHERE id = ?",
            item.blob.fileType, item.blobId); });
    finish("media_info", item.doMediaInfo,
        item.blob.mediaInfoSig !is null && !item.blob.mediaInfoSig.empty,
        { persistMediaInfo(db, item.blobId, item.blob.mediaInfoSig); });
    finish("archives", item.doArchives, item.blob.archiveSpecs !is null,
        {
            persistArchives(db, item.blobId, item.blob.archiveSpecs,
                item.options.deepArchiveScan, summary);
            persistArchivePassword(db, item.blobId, item.blob.archivePassword);
        });
    finish("torrents", item.doTorrents, item.blob.torrentInfo !is null,
        { persistTorrentInfo(db, item.blobId, item.blob.torrentInfo); });
}

private NamedBinaryBlob loadBlob(ref Database db, string rootPath, long blobId)
{
    auto blobResult = db.execute("SELECT b.file_size, b.file_type, b.md5, "
        ~ "b.sha1, b.xxh64, p.password "
        ~ "FROM blobs b LEFT JOIN archive_passwords p ON p.blob_id = b.id "
        ~ "WHERE b.id = ?", blobId);
    if (blobResult.empty)
        return null;

    auto blobRow = blobResult.front;
    auto blob = new NamedBinaryBlob();
    blob.fileSize = cast(size_t) blobRow.peek!long(0);
    blob.fileType = blobRow.peek!(Nullable!string)(1).isNull
        ? "" : blobRow.peek!(Nullable!string)(1).get;
    auto md5 = blobRow.peek!(Nullable!Blob)(2);
    if (!md5.isNull && md5.get.length > 0)
        blob.checkSums.md5sum_b64 = Base64.encode(md5.get);
    auto sha1 = blobRow.peek!(Nullable!Blob)(3);
    if (!sha1.isNull && sha1.get.length > 0)
        blob.checkSums.sha1sum_b64 = Base64.encode(sha1.get);
    auto xxh64 = blobRow.peek!(Nullable!Blob)(4);
    if (!xxh64.isNull && xxh64.get.length > 0)
        blob.checkSums.xxh64sum_b64 = Base64.encode(xxh64.get);
    blob.archivePassword = blobRow.peek!(Nullable!string)(5).isNull
        ? "" : blobRow.peek!(Nullable!string)(5).get;

    auto refs = db.execute("SELECT relative_path, time_last_modified "
        ~ "FROM file_refs WHERE blob_id = ? AND exists_on_disk = 1 "
        ~ "ORDER BY relative_path", blobId);
    foreach (row; refs)
    {
        auto modified = row.peek!(Nullable!string)(1);
        const auto storedPath = row.peek!string(0);
        const auto parsed = parseArchiveVirtualPath(storedPath);
        auto fileName = escapeArchiveVirtualPath(buildPath(rootPath,
            parsed.physicalPath));
        foreach (entry; parsed.entries)
            fileName = appendArchiveVirtualPath(fileName, entry.relativePath,
                entry.hasOccurrence ? entry.occurrence : size_t.max);
        blob.fileSpecs ~= new FileSpec(
            fileName,
            modified.isNull ? "" : modified.get);
    }
    blob.fileSpecsUseArchiveVirtualGrammar = true;
    auto archiveStatus = db.execute("SELECT state, extractor_version "
        ~ "FROM metadata_status WHERE blob_id = ? AND metadata_kind = 'archives'",
        blobId);
    if (!archiveStatus.empty)
    {
        auto statusRow = archiveStatus.front;
        const auto state = statusRow.peek!string(0);
        if (state == "completed" || state == "empty")
        {
            blob.archiveIndexKnown = true;
            const auto extractor = statusRow.peek!(Nullable!string)(1);
            blob.archiveIndexDeep = !extractor.isNull
                && extractor.get.endsWith(":deep");
        }
    }
    return blob.fileSpecs.length == 0 ? null : blob;
}

private void persistChecksums(ref Database db, long blobId, NamedBinaryBlob blob)
{
    Nullable!Blob md5;
    Nullable!Blob sha1;
    Nullable!Blob xxh64;
    md5 = cast(Blob) blob.checkSums.get_md5sum;
    sha1 = cast(Blob) blob.checkSums.get_sha1sum;
    xxh64 = cast(Blob) blob.checkSums.get_xxh64;
    db.execute("UPDATE blobs SET md5 = ?, sha1 = ?, xxh64 = ? WHERE id = ?",
        md5, sha1, xxh64, blobId);
}

private void setMetadataStatus(ref Database db, long blobId, string kind,
    string state, string errorMessage)
{
    db.execute("INSERT INTO metadata_status "
        ~ "(blob_id, metadata_kind, state, scanned_at, error_message) "
        ~ "VALUES (?, ?, ?, ?, ?) ON CONFLICT(blob_id, metadata_kind) DO UPDATE "
        ~ "SET state = excluded.state, scanned_at = excluded.scanned_at, "
        ~ "error_message = excluded.error_message", blobId, kind, state,
        currentTimestamp(), errorMessage);
}

private bool metadataCompleted(ref Database db, long blobId, string kind)
{
    auto result = db.execute("SELECT state FROM metadata_status "
        ~ "WHERE blob_id = ? AND metadata_kind = ?", blobId, kind);
    if (result.empty)
        return false;
    auto state = result.front.peek!string(0);
    return state == "completed" || state == "empty"
        || (kind == "archives" && state == "not_archive");
}

private bool archiveIndexCurrent(ref Database db, long blobId, bool requireDeep)
{
    auto result = db.execute("SELECT state, extractor_version FROM metadata_status "
        ~ "WHERE blob_id = ? AND metadata_kind = 'archives'", blobId);
    if (result.empty)
        return false;
    auto row = result.front;
    const auto state = row.peek!string(0);
    if (state == "not_archive")
        return true;
    if (state != "completed" && state != "empty")
        return false;
    const auto extractor = row.peek!(Nullable!string)(1);
    if (extractor.isNull
        || !extractor.get.startsWith(archiveIndexVersion ~ ":"))
        return false;
    return !requireDeep || extractor.get.endsWith(":deep");
}

private string metadataState(bool hasData)
{
    return hasData ? "completed" : "empty";
}

private void persistMediaInfo(ref Database db, long blobId, MediaInfoSig info)
{
    db.execute("DELETE FROM media_image_streams WHERE blob_id = ?", blobId);
    db.execute("DELETE FROM media_video_streams WHERE blob_id = ?", blobId);
    db.execute("DELETE FROM media_audio_streams WHERE blob_id = ?", blobId);
    db.execute("DELETE FROM media_text_streams WHERE blob_id = ?", blobId);
    db.execute("DELETE FROM media_signatures WHERE blob_id = ?", blobId);
    if (info is null || info.empty)
        return;

    db.execute("INSERT INTO media_signatures (blob_id, scanned_at) "
        ~ "VALUES (?, ?)", blobId, currentTimestamp());
    foreach (stream; info.imageStreams)
        db.execute("INSERT INTO media_image_streams "
            ~ "(blob_id, stream_index, format, width, height) "
            ~ "VALUES (?, ?, ?, ?, ?)", blobId, stream.index, stream.format,
            cast(long) stream.width, cast(long) stream.height);
    foreach (stream; info.videoStreams)
        db.execute("INSERT INTO media_video_streams "
            ~ "(blob_id, stream_index, language, format, width, height, "
            ~ "frame_rate, bit_rate, duration) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            blobId, stream.index, stream.language, stream.format,
            cast(long) stream.width, cast(long) stream.height, stream.frameRate,
            cast(long) stream.bitRate, stream.duration);
    foreach (stream; info.audioStreams)
        db.execute("INSERT INTO media_audio_streams "
            ~ "(blob_id, stream_index, language, format, channels, bit_rate, "
            ~ "duration) VALUES (?, ?, ?, ?, ?, ?, ?)", blobId, stream.index,
            stream.language, stream.format, cast(long) stream.channels,
            cast(long) stream.bitRate, stream.duration);
    foreach (stream; info.textStreams)
        db.execute("INSERT INTO media_text_streams "
            ~ "(blob_id, stream_index, language, format, frame_rate, bit_rate, "
            ~ "duration) VALUES (?, ?, ?, ?, ?, ?, ?)", blobId, stream.index,
            stream.language, stream.format, stream.frameRate,
            cast(long) stream.bitRate, stream.duration);
}

private void persistArchives(ref Database db, long blobId, ArchiveSpec[] entries,
    bool deepScanned, ref MetadataSummary summary)
{
    if (entries is null)
    {
        string[] containerPaths;
        foreach (row; db.execute("SELECT relative_path FROM file_refs "
            ~ "WHERE blob_id = ?", blobId))
            containerPaths ~= row.peek!string(0).idup;
        foreach (path; containerPaths)
        {
            const auto prefix = path ~ "!/";
            long[] staleIds;
            foreach (row; db.execute("SELECT id FROM file_refs WHERE "
                ~ "substr(relative_path, 1, ?) = ?",
                cast(long) prefix.length, prefix))
                staleIds ~= row.peek!long(0);
            foreach (staleId; staleIds)
                db.execute("DELETE FROM file_refs WHERE id = ?", staleId);
        }
        db.execute("DELETE FROM metadata_status WHERE blob_id = ? "
            ~ "AND metadata_kind = 'archives'", blobId);
        return;
    }

    VirtualContainerReference[] containers;
    foreach (row; db.execute("SELECT directory_id, relative_path, exists_on_disk, "
        ~ "last_seen_at FROM file_refs WHERE blob_id = ? ORDER BY relative_path",
        blobId))
    {
        VirtualContainerReference container;
        container.directoryId = row.peek!(Nullable!long)(0);
        container.relativePath = row.peek!string(1).idup;
        container.existsOnDisk = row.peek!long(2) != 0;
        const auto lastSeen = row.peek!(Nullable!string)(3);
        container.lastSeenAt = lastSeen.isNull ? "" : lastSeen.get.idup;
        containers ~= container;
    }
    if (containers.length == 0)
        return;

    const bool preserveDeep = !deepScanned
        && archiveIndexCurrent(db, blobId, true);
    bool[string] desiredPaths;
    bool[long] persistedMemberFileTypes;
    bool[long] persistedMemberMedia;

    long memberBlobIdFor(ArchiveSpec entry, string memberPath,
        bool preserveMember)
    {
        auto existing = db.execute("SELECT f.blob_id, b.file_size, b.md5, "
            ~ "b.sha1, b.xxh64 FROM file_refs f JOIN blobs b ON b.id = f.blob_id "
            ~ "WHERE f.relative_path = ?", memberPath);
        auto md5 = checksumBlob(entry.checkSums.md5sum_b64);
        auto sha1 = checksumBlob(entry.checkSums.sha1sum_b64);
        auto xxh64 = checksumBlob(entry.checkSums.xxh64sum_b64);
        /* Corrupt or truncated digests must not be trusted, otherwise the
         * content row lookup fails and a blob_id of 0 would be written. */
        if (hasValidDigests(md5, sha1, xxh64))
        {
            const auto existingId = ensureArchiveMemberBlob(db,
                cast(long) entry.fileSize, md5, sha1, xxh64);
            if (existingId != 0)
                return existingId;
        }
        if (!existing.empty)
        {
            auto row = existing.front;
            const auto oldMd5 = row.peek!(Nullable!Blob)(2);
            const auto oldSha1 = row.peek!(Nullable!Blob)(3);
            const auto oldXxh64 = row.peek!(Nullable!Blob)(4);
            if (row.peek!long(1) == cast(long) entry.fileSize
                && (preserveMember || (!oldMd5.isNull && !oldSha1.isNull
                    && !oldXxh64.isNull)))
                return row.peek!long(0);
        }
        db.execute("INSERT INTO blobs (file_size, md5, sha1, xxh64) "
            ~ "VALUES (?, ?, ?, ?)", cast(long) entry.fileSize,
            md5, sha1, xxh64);
        return db.lastInsertRowid;
    }

    void writeMember(string memberPath, long memberBlobId,
        VirtualContainerReference container, string modifiedAt)
    {
        Nullable!string modified;
        if (modifiedAt.length > 0)
            modified = Nullable!string(modifiedAt);
        Nullable!string lastSeen;
        if (container.lastSeenAt.length > 0)
            lastSeen = Nullable!string(container.lastSeenAt);
        db.execute("INSERT INTO file_refs (blob_id, directory_id, relative_path, "
            ~ "time_last_modified, exists_on_disk, last_seen_at) "
            ~ "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(relative_path) DO UPDATE SET "
            ~ "blob_id = excluded.blob_id, directory_id = excluded.directory_id, "
            ~ "time_last_modified = excluded.time_last_modified, "
            ~ "exists_on_disk = excluded.exists_on_disk, "
            ~ "last_seen_at = excluded.last_seen_at", memberBlobId,
            container.directoryId, memberPath, modified,
            container.existsOnDisk ? 1 : 0, lastSeen);
        desiredPaths[memberPath] = true;
    }

    void writeEntries(VirtualContainerReference parent, ArchiveSpec[] children,
        size_t depth, bool preserveContainerDeep)
    {
        enforce(depth < 32, "Nested archive indexing exceeds the maximum depth.");
        size_t[string] pathCounts;
        foreach (entry; children)
        {
            if (entry is null)
                continue;
            bool safe;
            bool isDirectory;
            const auto path = normalizeArchiveEntryPath(entry.fileName, safe,
                isDirectory);
            if (safe && !isDirectory)
                pathCounts[path] = pathCounts.get(path, 0) + 1;
        }

        size_t[string] occurrences;
        foreach (entryIndex, entry; children)
        {
            if (entry is null)
                continue;
            bool safe;
            bool isDirectory;
            const auto path = normalizeArchiveEntryPath(entry.fileName, safe,
                isDirectory);
            if (!safe || isDirectory)
                continue;
            auto occurrence = entry.hasIndexIdentity ? entry.occurrence
                : occurrences.get(path, 0);
            occurrences[path] = occurrence + 1;
            entry.entryIndex = entryIndex;
            entry.occurrence = occurrence;
            entry.hasIndexIdentity = true;
            const auto memberPath = appendArchiveVirtualPath(parent.relativePath,
                path, pathCounts.get(path, 0) > 1 || occurrence > 0
                    ? occurrence : size_t.max);
            entry.fileName = path;
            bool preserveMemberDeep;
            if (!deepScanned)
            {
                auto existingMember = db.execute("SELECT blob_id FROM file_refs "
                    ~ "WHERE relative_path = ?", memberPath);
                if (!existingMember.empty)
                    preserveMemberDeep = archiveIndexCurrent(db,
                        existingMember.front.peek!long(0), true);
            }
            auto memberBlobId = memberBlobIdFor(entry, memberPath,
                preserveContainerDeep || preserveMemberDeep);
            entry.contentBlobId = memberBlobId;
            entry.contentIdentity = "";
            writeMember(memberPath, memberBlobId, parent,
                entry.timeLastModified);
            if (entry.fileType.length > 0)
            {
                db.execute("UPDATE blobs SET file_type = ? WHERE id = ?",
                    entry.fileType, memberBlobId);
                setMetadataStatus(db, memberBlobId, "file_type", "completed", "");
                if (memberBlobId !in persistedMemberFileTypes)
                {
                    persistedMemberFileTypes[memberBlobId] = true;
                    ++summary.fileTypesUpdated;
                }
            }
            if (entry.mediaInfoSig !is null)
            {
                persistMediaInfo(db, memberBlobId, entry.mediaInfoSig);
                setMetadataStatus(db, memberBlobId, "media_info",
                    metadataState(!entry.mediaInfoSig.empty), "");
                if (!entry.mediaInfoSig.empty && memberBlobId !in persistedMemberMedia)
                {
                    persistedMemberMedia[memberBlobId] = true;
                    ++summary.mediaInfoUpdated;
                }
            }
            if (entry.archivePassword.length > 0)
                persistArchivePassword(db, memberBlobId, entry.archivePassword);

            if (entry.nestedEntries !is null)
            {
                VirtualContainerReference nested;
                nested.directoryId = parent.directoryId;
                nested.relativePath = memberPath;
                nested.existsOnDisk = parent.existsOnDisk;
                nested.lastSeenAt = parent.lastSeenAt;
                writeEntries(nested, entry.nestedEntries,
                    depth + 1, !deepScanned
                        && archiveIndexCurrent(db, memberBlobId, true));
            }
            else if (preserveContainerDeep || preserveMemberDeep)
            {
                const auto descendantPrefix = memberPath ~ "!/";
                foreach (row; db.execute("SELECT relative_path FROM file_refs "
                    ~ "WHERE substr(relative_path, 1, ?) = ?",
                    cast(long) descendantPrefix.length, descendantPrefix))
                    desiredPaths[row.peek!string(0)] = true;
            }
        }
    }

    foreach (container; containers)
        writeEntries(container, entries, 0, preserveDeep);

    foreach (container; containers)
    {
        const auto descendantPrefix = container.relativePath ~ "!/";
        long[] staleIds;
        foreach (row; db.execute("SELECT id, relative_path FROM file_refs "
            ~ "WHERE substr(relative_path, 1, ?) = ?",
            cast(long) descendantPrefix.length, descendantPrefix))
            if (row.peek!string(1) !in desiredPaths)
                staleIds ~= row.peek!long(0);
        foreach (staleId; staleIds)
            db.execute("DELETE FROM file_refs WHERE id = ?", staleId);
    }

    const auto extractorVersion = archiveIndexVersion
        ~ (deepScanned || preserveDeep ? ":deep" : ":shallow");
    const auto state = entries.length == 0 ? "empty" : "completed";
    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
        ~ "extractor_version, scanned_at, error_message) VALUES (?, 'archives', "
        ~ "?, ?, ?, NULL) ON CONFLICT(blob_id, metadata_kind) DO UPDATE SET "
        ~ "state = excluded.state, extractor_version = excluded.extractor_version, "
        ~ "scanned_at = excluded.scanned_at, error_message = NULL", blobId, state,
        extractorVersion, currentTimestamp());
}

private void persistArchivePassword(ref Database db, long blobId, string password)
{
    if (password.length == 0)
    {
        db.execute("DELETE FROM archive_passwords WHERE blob_id = ?", blobId);
        return;
    }
    db.execute("INSERT INTO archive_passwords (blob_id, password) VALUES (?, ?) "
        ~ "ON CONFLICT(blob_id) DO UPDATE SET password = excluded.password",
        blobId, password);
}

private void persistTorrentInfo(ref Database db, long blobId, TorrentInfo info)
{
    db.execute("DELETE FROM torrent_files WHERE torrent_blob_id = ?", blobId);
    db.execute("DELETE FROM torrent_info WHERE blob_id = ?", blobId);
    if (info is null || info.empty)
        return;

    db.execute("INSERT INTO torrent_info "
        ~ "(blob_id, name, magnet_uri, total_size, is_multi_file, "
        ~ "info_hash_hex, announce, piece_length, pieces_count) "
        ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", blobId, info.name,
        info.magnetURI, cast(long) info.totalSize, info.isMultiFile ? 1 : 0,
        info.infoHashHex, info.announce, cast(long) info.pieceLength,
        cast(long) info.piecesCount);
    foreach (index, entry; info.files)
    {
        if (entry is null)
            continue;
        db.execute("INSERT INTO torrent_files "
            ~ "(torrent_blob_id, file_index, relative_path, file_size) "
            ~ "VALUES (?, ?, ?, ?)", blobId, cast(long) index,
            entry.path.join("/"), cast(long) entry.length);
    }
}

private Nullable!Blob checksumBlob(string value)
{
    Nullable!Blob result;
    if (value.length > 0)
    {
        import std.base64 : Base64, Base64Exception;
        try
            result = cast(Blob) Base64.decode(value);
        catch (Base64Exception)
        {
            /* Treat malformed base64 like a missing digest. */
        }
    }
    return result;
}

private bool hasValidDigests(Nullable!Blob md5, Nullable!Blob sha1,
    Nullable!Blob xxh64)
{
    return !md5.isNull && !sha1.isNull && !xxh64.isNull
        && md5.get.length == 16 && sha1.get.length == 20
        && xxh64.get.length == 8;
}

private string currentTimestamp()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toISOExtString;
}
