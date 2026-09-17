/** Metadata extraction against repository-managed file references. */
module dosierskanilo.repository.metadata;

import d2sqlite3;

import std.path : buildPath;
import std.typecons : Nullable;

import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.repository.types;

/** Run the selected metadata jobs one blob at a time. */
MetadataSummary updateRepositoryMetadata(ref Database db, string rootPath,
    MetadataScanOptions options)
{
    MetadataSummary summary;
    auto result = db.execute("SELECT id FROM blobs ORDER BY id");
    foreach (row; result)
    {
        auto blobId = row.peek!long(0);
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
                setMetadataStatus(db, blobId, "checksums", "completed", "");
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
                setMetadataStatus(db, blobId, "file_type", "completed", "");
                summary.fileTypesUpdated++;
            }
            catch (Exception ex)
            {
                setMetadataStatus(db, blobId, "file_type", "failed", ex.msg);
                summary.failed++;
            }
        }
    }
    return summary;
}

private NamedBinaryBlob loadBlob(ref Database db, string rootPath, long blobId)
{
    auto blobResult = db.execute("SELECT file_size, file_type FROM blobs "
        ~ "WHERE id = ?", blobId);
    if (blobResult.empty)
        return null;

    auto blobRow = blobResult.front;
    auto blob = new NamedBinaryBlob();
    blob.fileSize = cast(size_t) blobRow.peek!long(0);
    blob.fileType = blobRow.peek!(Nullable!string)(1).isNull
        ? "" : blobRow.peek!(Nullable!string)(1).get;

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

private string currentTimestamp()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toISOExtString;
}
