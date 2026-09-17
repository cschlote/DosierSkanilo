/** SQL-based duplicate and missing-file analysis. */
module dosierskanilo.repository.analysis;

import d2sqlite3;

import std.conv : to;
import std.string : split;

import dosierskanilo.repository.types;

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
                    db.execute("DELETE FROM blobs WHERE id = ?", dropId);
                    summary.mergedBlobs++;
                }
            }
        }

        summary.orphanedBlobs = cast(size_t) db.execute(
            "SELECT count(*) FROM blobs WHERE id NOT IN "
            ~ "(SELECT DISTINCT blob_id FROM file_refs)").oneValue!long;
        db.execute("DELETE FROM blobs WHERE id NOT IN "
            ~ "(SELECT DISTINCT blob_id FROM file_refs)");
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
