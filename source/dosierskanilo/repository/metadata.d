/** Metadata extraction against repository-managed file references. */
module dosierskanilo.repository.metadata;

import d2sqlite3;

import std.array : join;
import std.conv : to;
import std.path : buildPath;
import std.parallelism : Task, TaskPool, task;
import std.string : empty;
import std.typecons : Nullable;

import dosierarkivo.archive : archiveIndexVersion,
    normalizeArchiveEntryPath;
import dosierskanilo.metadata.mediainfosig : MediaInfoSig;
import dosierskanilo.metadata.torrentinfo : TorrentInfo;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.operations : OperationControl, OperationKind,
    OperationPhase, OperationProgress, OperationState;
import dosierskanilo.repository.archiveindex : deleteUnreachableBlobs,
    ensureArchiveMemberBlob, resolveArchiveMemberBlobLinks;
import dosierskanilo.repository.types;

private class MetadataWorkItem
{
    long blobId;
    NamedBinaryBlob blob;
    MetadataScanOptions options;
    bool doChecksums;
    bool doFileType;
    bool doMediaInfo;
    bool doArchives;
    bool doTorrents;
    string[string] errors;
}

private void runMetadataWork(MetadataWorkItem item)
{
    void attempt(string kind, void delegate() action)
    {
        try
            action();
        catch (Exception ex)
            item.errors[kind] = ex.msg;
    }

    if (item.doChecksums)
        attempt("checksums", { updateDigests(item.blob); });
    if (item.doFileType)
        attempt("file_type", { updateFileType(item.blob); });
    if (item.doMediaInfo)
        attempt("media_info", { updateMediaInfo(item.blob, item.options.rescan); });
    if (item.doArchives)
        attempt("archives", {
            updateArchives(item.blob, item.options.rescan,
                item.options.deepArchiveScan, null, null,
                item.options.archivePasswordCallback);
        });
    if (item.doTorrents)
        attempt("torrents", { updateTorrentInfo(item.blob, item.options.rescan); });
}

private long[] metadataBlobIds(ref Database db, string filePath)
{
    long[] blobIds;
    if (filePath.empty)
    {
        foreach (row; db.execute("SELECT id FROM blobs ORDER BY id"))
            blobIds ~= row.peek!long(0);
    }
    else
    {
        foreach (row; db.execute("SELECT DISTINCT b.id FROM blobs b "
            ~ "JOIN file_refs f ON f.blob_id = b.id "
            ~ "WHERE f.relative_path = ? ORDER BY b.id", filePath))
            blobIds ~= row.peek!long(0);
    }
    return blobIds;
}

/** Run the selected metadata jobs one blob at a time. */
MetadataSummary updateRepositoryMetadata(ref Database db, string rootPath,
    MetadataScanOptions options)
{
    scope (exit)
        if (options.scanArchives)
        {
            resolveArchiveMemberBlobLinks(db);
            deleteUnreachableBlobs(db);
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
                persistChecksums(db, blobId, blob);
                setMetadataStatus(db, blobId, "checksums",
                    metadataState(blob.checkSums.hasDigests), "");
                summary.checksumsUpdated++;
            }
            catch (Exception ex)
            {
                setMetadataStatus(db, blobId, "checksums", "failed", ex.msg);
                summary.failed++;
            }
        }

        if (options.detectFileTypes && blob.fileType.length == 0)
        {
            setMetadataStatus(db, blobId, "file_type", "pending", "");
            try
            {
                updateFileType(blob);
                db.execute("UPDATE blobs SET file_type = ? WHERE id = ?",
                    blob.fileType, blobId);
                setMetadataStatus(db, blobId, "file_type",
                    metadataState(blob.fileType.length > 0), "");
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
                persistMediaInfo(db, blobId, blob.mediaInfoSig);
                setMetadataStatus(db, blobId, "media_info", metadataState(
                    blob.mediaInfoSig !is null && !blob.mediaInfoSig.empty), "");
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
                    null, null, options.archivePasswordCallback);
                persistArchives(db, blobId, blob.archiveSpecs,
                    options.deepArchiveScan);
                persistArchivePassword(db, blobId, blob.archivePassword);
                setMetadataStatus(db, blobId, "archives",
                    metadataState(blob.archiveSpecs !is null), "");
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
                persistTorrentInfo(db, blobId, blob.torrentInfo);
                setMetadataStatus(db, blobId, "torrents",
                    metadataState(blob.torrentInfo !is null), "");
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
        if (options.scanArchives)
        {
            resolveArchiveMemberBlobLinks(db);
            deleteUnreachableBlobs(db);
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
            item.doChecksums = options.calculateChecksums
                && !blob.checkSums.hasDigests;
            item.doFileType = options.detectFileTypes
                && blob.fileType.length == 0;
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
        // acknowledged. Each blob's requested metadata is one transaction.
        foreach (item; items)
        {
            if (hasMetadataWork(item))
            {
                db.begin();
                try
                {
                    persistMetadataWork(db, item, execution.summary);
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
            }
            execution.summary.blobsVisited++;
        }

        foreach (item; items)
        {
            foreach (phase; phases)
            {
                if (!reportMetadataProgress(control, operationId, phase,
                    execution.summary.blobsVisited, blobIds.length,
                    item.blob.getFirstFileName()))
                {
                    execution.cancelled = true;
                    return execution;
                }
            }
        }
        if (control !is null && control.cancellationRequested)
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
    progress.totalKnown = phase != OperationPhase.discovering;
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
        item.doFileType = options.detectFileTypes && blob.fileType.length == 0;
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
        persistMetadataWork(db, item, summary);
    }
    pool.finish(true);
    pool.stop();
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
                item.options.deepArchiveScan);
            persistArchivePassword(db, item.blobId, item.blob.archivePassword);
        });
    finish("torrents", item.doTorrents, item.blob.torrentInfo !is null,
        { persistTorrentInfo(db, item.blobId, item.blob.torrentInfo); });
}

private NamedBinaryBlob loadBlob(ref Database db, string rootPath, long blobId)
{
    auto blobResult = db.execute("SELECT b.file_size, b.file_type, p.password "
        ~ "FROM blobs b LEFT JOIN archive_passwords p ON p.blob_id = b.id "
        ~ "WHERE b.id = ?", blobId);
    if (blobResult.empty)
        return null;

    auto blobRow = blobResult.front;
    auto blob = new NamedBinaryBlob();
    blob.fileSize = cast(size_t) blobRow.peek!long(0);
    blob.fileType = blobRow.peek!(Nullable!string)(1).isNull
        ? "" : blobRow.peek!(Nullable!string)(1).get;
    blob.archivePassword = blobRow.peek!(Nullable!string)(2).isNull
        ? "" : blobRow.peek!(Nullable!string)(2).get;

    auto refs = db.execute("SELECT relative_path, time_last_modified "
        ~ "FROM file_refs WHERE blob_id = ? AND exists_on_disk = 1 "
        ~ "ORDER BY relative_path", blobId);
    foreach (row; refs)
    {
        auto modified = row.peek!(Nullable!string)(1);
        blob.fileSpecs ~= new FileSpec(
            buildPath(rootPath, row.peek!string(0)),
            modified.isNull ? "" : modified.get);
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
    return state == "completed" || state == "empty";
}

private bool archiveIndexCurrent(ref Database db, long blobId, bool requireDeep)
{
    return !db.execute("SELECT 1 FROM archive_indexes WHERE blob_id = ? "
        ~ "AND indexer_version = ? AND (? = 0 OR deep_scanned = 1)", blobId,
        archiveIndexVersion, requireDeep ? 1 : 0).empty;
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
    bool deepScanned)
{
    if (entries is null)
    {
        db.execute("DELETE FROM archive_entries WHERE blob_id = ?", blobId);
        db.execute("DELETE FROM archive_indexes WHERE blob_id = ?", blobId);
        return;
    }

    struct ExistingEntry
    {
        long id;
    }
    ExistingEntry[][string] existingByIdentity;
    foreach (row; db.execute("SELECT id, normalized_path, path_safe, occurrence "
        ~ "FROM archive_entries WHERE blob_id = ?", blobId))
    {
        auto key = archiveEntryIdentityKey(row.peek!long(2) != 0,
            row.peek!string(1), cast(size_t) row.peek!long(3));
        existingByIdentity[key] ~= ExistingEntry(row.peek!long(0));
    }

    bool[long] retainedIds;
    bool membershipChanged;
    size_t[string] occurrences;
    const bool preserveDeep = !deepScanned
        && archiveIndexCurrent(db, blobId, true);
    foreach (entryIndex, entry; entries)
    {
        if (entry is null)
            continue;
        bool pathSafe;
        bool isDirectory;
        const auto normalizedPath = normalizeArchiveEntryPath(entry.fileName,
            pathSafe, isDirectory);
        auto identityPath = pathSafe ? normalizedPath : entry.fileName;
        auto occurrenceKey = (pathSafe ? "safe\0" : "unsafe\0") ~ identityPath;
        auto occurrence = occurrences.get(occurrenceKey, 0);
        occurrences[occurrenceKey] = occurrence + 1;
        const auto identityKey = archiveEntryIdentityKey(pathSafe, identityPath,
            occurrence);
        auto md5 = checksumBlob(entry.checkSums.md5sum_b64);
        auto sha1 = checksumBlob(entry.checkSums.sha1sum_b64);
        auto xxh64 = checksumBlob(entry.checkSums.xxh64sum_b64);
        auto memberBlobId = ensureArchiveMemberBlob(db,
            cast(long) entry.fileSize, md5, sha1, xxh64);
        entry.entryIndex = entryIndex;
        entry.occurrence = occurrence;
        entry.hasIndexIdentity = true;
        entry.contentBlobId = memberBlobId;
        entry.contentIdentity = "";
        Nullable!long memberBlobReference;
        if (memberBlobId > 0)
            memberBlobReference = memberBlobId;

        long entryId;
        if (auto matches = identityKey in existingByIdentity)
            foreach (existing; *matches)
                if (existing.id !in retainedIds)
                {
                    entryId = existing.id;
                    break;
                }

        if (entryId > 0)
        {
            if (preserveDeep)
                db.execute("UPDATE archive_entries SET entry_index = ?, "
                    ~ "file_name = ?, normalized_path = ?, path_safe = ?, "
                    ~ "is_directory = ? WHERE id = ?", cast(long) entryIndex,
                    entry.fileName, identityPath, pathSafe ? 1 : 0,
                    isDirectory ? 1 : 0, entryId);
            else
                db.execute("UPDATE archive_entries SET entry_index = ?, file_name = ?, "
                    ~ "normalized_path = ?, path_safe = ?, is_directory = ?, "
                    ~ "file_size = ?, time_last_modified = ?, md5 = ?, sha1 = ?, "
                    ~ "xxh64 = ?, content_blob_id = ? WHERE id = ?",
                    cast(long) entryIndex, entry.fileName, identityPath,
                    pathSafe ? 1 : 0, isDirectory ? 1 : 0,
                    cast(long) entry.fileSize, entry.timeLastModified,
                    md5, sha1, xxh64, memberBlobReference, entryId);
            retainedIds[entryId] = true;
        }
        else
        {
            membershipChanged = true;
            db.execute("INSERT INTO archive_entries (blob_id, entry_index, "
                ~ "occurrence, file_name, normalized_path, path_safe, is_directory, "
                ~ "file_size, time_last_modified, md5, sha1, xxh64, content_blob_id) "
                ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", blobId,
                cast(long) entryIndex, cast(long) occurrence, entry.fileName,
                identityPath, pathSafe ? 1 : 0, isDirectory ? 1 : 0,
                cast(long) entry.fileSize, entry.timeLastModified,
                md5, sha1, xxh64, memberBlobReference);
            entryId = db.lastInsertRowid;
            retainedIds[entryId] = true;
        }

        if (memberBlobId > 0 && (deepScanned || entry.nestedEntries !is null
            || entry.archivePassword.length > 0))
        {
            persistArchivePassword(db, memberBlobId, entry.archivePassword);
            persistArchives(db, memberBlobId, entry.nestedEntries, deepScanned);
        }
    }
    foreach (matches; existingByIdentity.values)
        foreach (existing; matches)
            if (existing.id !in retainedIds)
            {
                membershipChanged = true;
                db.execute("DELETE FROM archive_entries WHERE id = ?", existing.id);
            }
    const bool indexDeep = deepScanned || (preserveDeep && !membershipChanged);
    db.execute("INSERT INTO archive_indexes (blob_id, indexer_version, indexed_at, "
        ~ "deep_scanned) VALUES (?, ?, ?, ?) ON CONFLICT(blob_id) DO UPDATE SET "
        ~ "indexer_version = excluded.indexer_version, "
        ~ "indexed_at = excluded.indexed_at, "
        ~ "deep_scanned = excluded.deep_scanned", blobId,
        archiveIndexVersion, currentTimestamp(),
        indexDeep ? 1 : 0);
}

private string archiveEntryIdentityKey(bool pathSafe, string path,
    size_t occurrence)
{
    return (pathSafe ? "safe\0" : "unsafe\0") ~ path ~ "\0"
        ~ occurrence.to!string;
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
        import std.base64 : Base64;
        result = cast(Blob) Base64.decode(value);
    }
    return result;
}

private string currentTimestamp()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toISOExtString;
}
