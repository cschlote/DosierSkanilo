/** SQL-based duplicate and missing-file analysis. */
module dosierskanilo.repository.analysis;

import d2sqlite3;

import std.conv : to;
import std.string : split;

import dosierskanilo.operations : OperationControl, OperationKind,
    OperationPhase, OperationProgress, OperationState;
import dosierskanilo.repository.archiveindex : deleteUnreachableBlobs;
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
            auto groups = db.execute("SELECT group_concat(id) FROM blobs "
                ~ "WHERE md5 IS NOT NULL AND sha1 IS NOT NULL AND xxh64 IS NOT NULL "
                ~ "AND EXISTS (SELECT 1 FROM file_refs f WHERE f.blob_id = blobs.id) "
                ~ "GROUP BY file_size, md5, sha1, xxh64 "
                ~ "HAVING count(*) > 1");
            string[] duplicateGroups;
            foreach (row; groups)
                duplicateGroups ~= row.peek!string(0);

            foreach (group; duplicateGroups)
            {
                auto ids = group.split(",");
                if (ids.length < 2)
                    continue;
                summary.duplicateGroups++;
                auto keepId = ids[0].to!long;
                foreach (dropText; ids[1 .. $])
                {
                    auto dropId = dropText.to!long;
                    db.execute("UPDATE file_refs SET blob_id = ? "
                        ~ "WHERE blob_id = ?", keepId, dropId);
                    db.execute("UPDATE archive_entries SET content_blob_id = ? "
                        ~ "WHERE content_blob_id = ?", keepId, dropId);
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
            db.execute("UPDATE file_refs SET blob_id = ? WHERE blob_id = ?",
                keepId, dropId);
            db.execute("UPDATE archive_entries SET content_blob_id = ? "
                ~ "WHERE content_blob_id = ?", keepId, dropId);
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
