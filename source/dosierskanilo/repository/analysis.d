/** SQL-based duplicate and missing-file analysis. */
module dosierskanilo.repository.analysis;

import d2sqlite3;

import std.conv : to;
import std.string : split;

import dosierskanilo.operations : OperationControl, OperationKind,
    OperationPhase, OperationProgress, OperationState;
import dosierskanilo.repository.archiveindex : deleteUnreachableBlobs;
import dosierskanilo.repository.schema : migrate;
import dosierskanilo.repository.types;

/** Return duplicate groups without modifying repository state. */
RepositoryDuplicateGroup[] queryDuplicateGroups(ref Database db, size_t limit = 100)
{
    RepositoryDuplicateGroup[] groups;
    auto result = db.execute("SELECT file_size, group_concat(id) FROM blobs "
        ~ "WHERE md5 IS NOT NULL AND sha1 IS NOT NULL AND xxh64 IS NOT NULL "
        ~ "AND EXISTS (SELECT 1 FROM file_refs f WHERE f.blob_id = blobs.id) "
        ~ "GROUP BY file_size, md5, sha1, xxh64 "
        ~ "HAVING count(*) > 1 ORDER BY file_size, min(id) LIMIT ?",
        cast(long) limit);
    foreach (row; result)
    {
        RepositoryDuplicateGroup group;
        group.fileSize = cast(size_t) row.peek!long(0);
        foreach (id; row.peek!string(1).split(","))
            group.blobIds ~= id.to!long;
        groups ~= group;
    }
    return groups;
}

/** Copy per-blob metadata from a duplicate blob before it is deleted.
 *
 * The merge repoints file references from the dropped blob to the kept blob.
 * Dependent tables use `ON DELETE CASCADE`, so without this step the surviving
 * blob would silently lose torrent data, archive passwords, media streams, or
 * metadata state that only the dropped blob carried. Existing rows of the kept
 * blob win; successful states from the dropped blob replace unsuccessful ones.
 */
private void mergeBlobMetadata(ref Database db, long keepId, long dropId)
{
    db.execute("UPDATE blobs SET file_type = (SELECT file_type FROM blobs "
        ~ "WHERE id = ?2) WHERE id = ?1 AND (file_type IS NULL OR file_type = '') "
        ~ "AND COALESCE((SELECT file_type FROM blobs WHERE id = ?2), '') != ''",
        keepId, dropId);

    db.execute("INSERT OR IGNORE INTO metadata_status (blob_id, metadata_kind, "
        ~ "state, extractor_version, scanned_at, error_message) "
        ~ "SELECT ?1, metadata_kind, state, extractor_version, scanned_at, "
        ~ "error_message FROM metadata_status WHERE blob_id = ?2", keepId, dropId);
    /* Prefer a completed/empty state over an unsuccessful one. */
    db.execute("DELETE FROM metadata_status WHERE blob_id = ?1 "
        ~ "AND state NOT IN ('completed', 'empty') AND metadata_kind IN "
        ~ "(SELECT metadata_kind FROM metadata_status WHERE blob_id = ?2 "
        ~ "AND state IN ('completed', 'empty'))", keepId, dropId);
    db.execute("INSERT OR IGNORE INTO metadata_status (blob_id, metadata_kind, "
        ~ "state, extractor_version, scanned_at, error_message) "
        ~ "SELECT ?1, metadata_kind, state, extractor_version, scanned_at, "
        ~ "error_message FROM metadata_status WHERE blob_id = ?2 "
        ~ "AND state IN ('completed', 'empty')", keepId, dropId);

    db.execute("INSERT OR IGNORE INTO media_signatures "
        ~ "(blob_id, extractor_version, scanned_at) SELECT ?1, "
        ~ "extractor_version, scanned_at FROM media_signatures WHERE blob_id = ?2",
        keepId, dropId);
    db.execute("INSERT OR IGNORE INTO media_image_streams "
        ~ "(blob_id, stream_index, format, width, height) SELECT ?1, "
        ~ "stream_index, format, width, height FROM media_image_streams "
        ~ "WHERE blob_id = ?2", keepId, dropId);
    db.execute("INSERT OR IGNORE INTO media_video_streams "
        ~ "(blob_id, stream_index, language, format, width, height, frame_rate, "
        ~ "bit_rate, duration) SELECT ?1, stream_index, language, format, width, "
        ~ "height, frame_rate, bit_rate, duration FROM media_video_streams "
        ~ "WHERE blob_id = ?2", keepId, dropId);
    db.execute("INSERT OR IGNORE INTO media_audio_streams "
        ~ "(blob_id, stream_index, language, format, channels, bit_rate, "
        ~ "duration) SELECT ?1, stream_index, language, format, channels, "
        ~ "bit_rate, duration FROM media_audio_streams WHERE blob_id = ?2",
        keepId, dropId);
    db.execute("INSERT OR IGNORE INTO media_text_streams "
        ~ "(blob_id, stream_index, language, format, frame_rate, bit_rate, "
        ~ "duration) SELECT ?1, stream_index, language, format, frame_rate, "
        ~ "bit_rate, duration FROM media_text_streams WHERE blob_id = ?2",
        keepId, dropId);

    db.execute("INSERT OR IGNORE INTO torrent_info (blob_id, name, magnet_uri, "
        ~ "total_size, is_multi_file, info_hash_hex, announce, piece_length, "
        ~ "pieces_count) SELECT ?1, name, magnet_uri, total_size, is_multi_file, "
        ~ "info_hash_hex, announce, piece_length, pieces_count FROM torrent_info "
        ~ "WHERE blob_id = ?2", keepId, dropId);
    db.execute("INSERT OR IGNORE INTO torrent_files (torrent_blob_id, "
        ~ "file_index, relative_path, file_size) SELECT ?1, file_index, "
        ~ "relative_path, file_size FROM torrent_files WHERE torrent_blob_id = ?2",
        keepId, dropId);

    db.execute("INSERT OR IGNORE INTO archive_passwords (blob_id, password) "
        ~ "SELECT ?1, password FROM archive_passwords WHERE blob_id = ?2",
        keepId, dropId);
}

/** Analyze current repository rows without materializing the catalog. */
AnalysisSummary analyzeRepository(ref Database db, RepositoryAnalysisOptions options)
{
    AnalysisSummary summary;
    try
    {
        db.begin();
        summary.missingFiles = cast(size_t) db.execute(
            "SELECT count(*) FROM file_refs WHERE exists_on_disk = 0")
            .oneValue!long;

        if (options.dropMissing)
        {
            summary.droppedFiles = summary.missingFiles;
            db.execute("DELETE FROM file_refs WHERE exists_on_disk = 0");
        }

        if (options.mergeDuplicates)
        {
            auto groups = db.execute("SELECT min(id), group_concat(id) FROM blobs "
                ~ "WHERE md5 IS NOT NULL AND sha1 IS NOT NULL AND xxh64 IS NOT NULL "
                ~ "AND EXISTS (SELECT 1 FROM file_refs f WHERE f.blob_id = blobs.id) "
                ~ "GROUP BY file_size, md5, sha1, xxh64 "
                ~ "HAVING count(*) > 1");
            long[][] duplicateGroups;
            foreach (row; groups)
            {
                long[] ids;
                foreach (idText; row.peek!string(1).split(","))
                    ids ~= idText.to!long;
                duplicateGroups ~= ids;
            }

            foreach (ids; duplicateGroups)
            {
                if (ids.length < 2)
                    continue;
                summary.duplicateGroups++;
                /* Keep the lowest id so repeated analyses choose the same
                 * survivor, matching the controlled analysis path. */
                auto keepId = ids[0];
                foreach (id; ids)
                    if (id < keepId)
                        keepId = id;
                foreach (dropId; ids)
                {
                    if (dropId == keepId)
                        continue;
                    mergeBlobMetadata(db, keepId, dropId);
                    db.execute("UPDATE file_refs SET blob_id = ? "
                        ~ "WHERE blob_id = ?", keepId, dropId);
                    db.execute("DELETE FROM blobs WHERE id = ?", dropId);
                    summary.mergedBlobs++;
                }
            }
        }

        summary.orphanedBlobs = deleteUnreachableBlobs(db);
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

/**
 * Prepare analysis changes in temporary tables, then apply them in one atomic
 * catalog transaction. Pause points occur only during the staging phase.
 */
AnalysisExecutionResult analyzeRepositoryControlled(ref Database db,
    RepositoryAnalysisOptions options, OperationControl control, ulong operationId)
{
    AnalysisExecutionResult execution;
    resetAnalysisStage(db);
    scope (exit)
        clearAnalysisStage(db);

    if (!reportAnalysisProgress(control, operationId,
        OperationPhase.analysisMissingFiles, 0, "Preparing missing-file analysis."))
    {
        execution.cancelled = true;
        return execution;
    }
    db.execute("INSERT INTO temp.analysis_missing_plan (id) "
        ~ "SELECT id FROM file_refs WHERE exists_on_disk = 0");
    execution.summary.missingFiles = cast(size_t) db.execute(
        "SELECT count(*) FROM temp.analysis_missing_plan").oneValue!long;
    if (options.dropMissing)
        execution.summary.droppedFiles = execution.summary.missingFiles;
    if (!reportAnalysisProgress(control, operationId,
        OperationPhase.analysisMissingFiles, execution.summary.missingFiles,
        "Missing-file plan ready."))
    {
        execution.cancelled = true;
        return execution;
    }

    if (options.mergeDuplicates)
    {
        db.execute("WITH duplicate_groups AS ("
            ~ "SELECT min(id) AS keep_id, file_size, md5, sha1, xxh64 "
            ~ "FROM blobs WHERE md5 IS NOT NULL AND sha1 IS NOT NULL "
            ~ "AND xxh64 IS NOT NULL AND EXISTS (SELECT 1 FROM file_refs f "
            ~ "WHERE f.blob_id = blobs.id) "
            ~ "GROUP BY file_size, md5, sha1, xxh64 "
            ~ "HAVING count(*) > 1) "
            ~ "INSERT INTO temp.analysis_merge_plan (keep_id, drop_id) "
            ~ "SELECT g.keep_id, b.id FROM duplicate_groups g JOIN blobs b "
            ~ "ON b.file_size = g.file_size AND b.md5 = g.md5 "
            ~ "AND b.sha1 = g.sha1 AND b.xxh64 = g.xxh64 "
            ~ "WHERE b.id != g.keep_id");
        execution.summary.duplicateGroups = cast(size_t) db.execute(
            "SELECT count(*) FROM (SELECT keep_id FROM temp.analysis_merge_plan "
            ~ "GROUP BY keep_id)").oneValue!long;
        execution.summary.mergedBlobs = cast(size_t) db.execute(
            "SELECT count(*) FROM temp.analysis_merge_plan").oneValue!long;
    }
    if (!reportAnalysisProgress(control, operationId,
        OperationPhase.analysisDuplicates, execution.summary.mergedBlobs,
        "Duplicate merge plan ready."))
    {
        execution.cancelled = true;
        return execution;
    }
    if (!reportAnalysisProgress(control, operationId,
        OperationPhase.analysisCleanup, 0, "Ready to commit analysis."))
    {
        execution.cancelled = true;
        return execution;
    }
    if (control !is null)
    {
        control.setPauseAvailable(false);
        if (control.cancellationRequested)
        {
            execution.cancelled = true;
            return execution;
        }
    }

    try
    {
        db.begin();
        if (options.dropMissing)
            db.execute("DELETE FROM file_refs WHERE id IN "
                ~ "(SELECT id FROM temp.analysis_missing_plan)");

        auto merges = db.execute("SELECT keep_id, drop_id FROM "
            ~ "temp.analysis_merge_plan ORDER BY keep_id, drop_id");
        foreach (row; merges)
        {
            auto keepId = row.peek!long(0);
            auto dropId = row.peek!long(1);
            mergeBlobMetadata(db, keepId, dropId);
            db.execute("UPDATE file_refs SET blob_id = ? WHERE blob_id = ?",
                keepId, dropId);
            db.execute("DELETE FROM blobs WHERE id = ?", dropId);
        }

        execution.summary.orphanedBlobs = deleteUnreachableBlobs(db);
        // Cancellation is checked before commit. No pause or callback waits
        // while the operation-wide transaction is active.
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

private void resetAnalysisStage(ref Database db)
{
    db.execute("DROP TABLE IF EXISTS temp.analysis_missing_plan");
    db.execute("DROP TABLE IF EXISTS temp.analysis_merge_plan");
    db.execute("CREATE TEMP TABLE analysis_missing_plan (id INTEGER PRIMARY KEY)");
    db.execute("CREATE TEMP TABLE analysis_merge_plan "
        ~ "(keep_id INTEGER NOT NULL, drop_id INTEGER PRIMARY KEY)");
}

private void clearAnalysisStage(ref Database db)
{
    try
    {
        db.execute("DROP TABLE IF EXISTS temp.analysis_missing_plan");
        db.execute("DROP TABLE IF EXISTS temp.analysis_merge_plan");
    }
    catch (Exception)
    {
    }
}

private bool reportAnalysisProgress(OperationControl control, ulong operationId,
    OperationPhase phase, size_t completed, string message)
{
    if (control is null)
        return true;
    if (control.cancellationRequested)
        return false;
    control.setPauseAvailable(true);
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = OperationKind.analyze;
    progress.state = OperationState.running;
    progress.phase = phase;
    progress.completed = completed;
    progress.totalKnown = phase == OperationPhase.analysisMissingFiles
        || phase == OperationPhase.analysisDuplicates;
    progress.message = message;
    control.report(progress);
    return control.pauseAtCheckpoint(progress)
        && !control.cancellationRequested;
}

@("analyzeRepository")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");

    db.execute("INSERT INTO directories (id, parent_id, relative_path, name) "
        ~ "VALUES (1, NULL, '', '')");
    db.execute("INSERT INTO blobs (id, file_size, md5, sha1, xxh64) VALUES "
        ~ "(1, 100, ?, ?, ?), "
        ~ "(2, 100, ?, ?, ?), "
        ~ "(3, 200, NULL, NULL, NULL), "
        ~ "(4, 300, NULL, NULL, NULL)",
        cast(Blob) "md5-1", cast(Blob) "sha1-1", cast(Blob) "xxh64-1",
        cast(Blob) "md5-1", cast(Blob) "sha1-1", cast(Blob) "xxh64-1");
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(11, 1, 1, 'keep.txt', '2026-01-01T00:00:00', 1, ?), "
        ~ "(12, 2, 1, 'merge.txt', '2026-01-01T00:00:00', 1, ?), "
        ~ "(13, 4, 1, 'missing.txt', '2026-01-01T00:00:00', 0, ?)",
        "2026-01-01T00:00:00", "2026-01-01T00:00:00",
        "2026-01-01T00:00:00");

    auto summary = analyzeRepository(db, RepositoryAnalysisOptions(true, true));

    assert(summary.missingFiles == 1);
    assert(summary.droppedFiles == 1);
    assert(summary.duplicateGroups == 1);
    assert(summary.mergedBlobs == 1);
    assert(summary.orphanedBlobs == 2);
    assert(db.execute("SELECT count(*) FROM file_refs").oneValue!long == 2);
    assert(db.execute("SELECT count(*) FROM blobs").oneValue!long == 1);
    assert(db.execute("SELECT blob_id FROM file_refs ORDER BY id LIMIT 1")
        .oneValue!long == 1);
}

@("mergeBlobMetadata preserves dependent metadata of the dropped blob")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");

    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, 10), (2, 10)");
    db.execute("UPDATE blobs SET file_type = 'application/zip' WHERE id = 2");
    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state) "
        ~ "VALUES (1, 'media', 'failed'), (2, 'media', 'completed'), "
        ~ "(1, 'file_type', 'completed'), (2, 'file_type', 'completed')");
    db.execute("INSERT INTO archive_passwords (blob_id, password) "
        ~ "VALUES (2, 'secret')");
    db.execute("INSERT INTO torrent_info (blob_id, name) VALUES (2, 'x')");
    db.execute("INSERT INTO torrent_files (torrent_blob_id, file_index, "
        ~ "relative_path, file_size) VALUES (2, 0, 'a', 1)");
    db.execute("INSERT INTO media_signatures (blob_id) VALUES (2)");
    db.execute("INSERT INTO media_image_streams (blob_id, stream_index) "
        ~ "VALUES (2, 0)");

    mergeBlobMetadata(db, 1, 2);

    assert(db.execute("SELECT state FROM metadata_status WHERE blob_id = 1 "
        ~ "AND metadata_kind = 'media'").oneValue!string == "completed");
    assert(db.execute("SELECT password FROM archive_passwords WHERE blob_id = 1")
        .oneValue!string == "secret");
    assert(db.execute("SELECT file_type FROM blobs WHERE id = 1")
        .oneValue!string == "application/zip");
    assert(db.execute("SELECT count(*) FROM torrent_info WHERE blob_id = 1")
        .oneValue!long == 1);
    assert(db.execute("SELECT count(*) FROM torrent_files "
        ~ "WHERE torrent_blob_id = 1").oneValue!long == 1);
    assert(db.execute("SELECT count(*) FROM media_signatures WHERE blob_id = 1")
        .oneValue!long == 1);
    assert(db.execute("SELECT count(*) FROM media_image_streams "
        ~ "WHERE blob_id = 1").oneValue!long == 1);
}

@("queryDuplicateGroups")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");

    db.execute("INSERT INTO blobs (id, file_size, md5, sha1, xxh64) VALUES "
        ~ "(1, 11, X'00112233445566778899AABBCCDDEEFF', "
        ~ "X'00112233445566778899AABBCCDDEEFF00112233', "
        ~ "X'0011223344556677'),"
        ~ "(2, 11, X'00112233445566778899AABBCCDDEEFF', "
        ~ "X'00112233445566778899AABBCCDDEEFF00112233', "
        ~ "X'0011223344556677'),"
        ~ "(3, 11, X'00112233445566778899AABBCCDDEEFF', "
        ~ "X'00112233445566778899AABBCCDDEEFF00112233', "
        ~ "X'0011223344556677')");
    db.execute("INSERT INTO file_refs (id, blob_id, relative_path, exists_on_disk) "
        ~ "VALUES (1, 1, 'a.txt', 1), (2, 2, 'b.txt', 1)");

    auto groups = queryDuplicateGroups(db, 10);
    assert(groups.length == 1);
    assert(groups[0].fileSize == 11);
    assert(groups[0].blobIds == [1L, 2L]);
}

@("analyzeRepositoryControlled")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");

    db.execute("INSERT INTO blobs (id, file_size, md5, sha1, xxh64) VALUES "
        ~ "(1, 11, X'00112233445566778899AABBCCDDEEFF', "
        ~ "X'00112233445566778899AABBCCDDEEFF00112233', "
        ~ "X'0011223344556677'),"
        ~ "(2, 11, X'00112233445566778899AABBCCDDEEFF', "
        ~ "X'00112233445566778899AABBCCDDEEFF00112233', "
        ~ "X'0011223344556677'),"
        ~ "(3, 7, NULL, NULL, NULL)");
    db.execute("INSERT INTO file_refs (id, blob_id, relative_path, exists_on_disk) "
        ~ "VALUES (1, 1, 'a.txt', 1), (2, 2, 'b.txt', 1), (3, 3, 'missing.txt', 0)");

    auto execution = analyzeRepositoryControlled(db,
        RepositoryAnalysisOptions(true, true), new OperationControl(), 99);

    assert(!execution.cancelled);
    assert(execution.committed);
    assert(execution.summary.missingFiles == 1);
    assert(execution.summary.droppedFiles == 1);
    assert(execution.summary.duplicateGroups == 1);
    assert(execution.summary.mergedBlobs == 1);
    assert(execution.summary.orphanedBlobs == 1);
    assert(db.execute("SELECT count(*) FROM file_refs WHERE exists_on_disk = 0")
        .oneValue!long == 0);
    assert(db.execute("SELECT count(*) FROM blobs WHERE id = 2")
        .oneValue!long == 0);
}
