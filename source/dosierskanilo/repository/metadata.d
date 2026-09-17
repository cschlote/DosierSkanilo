/** Metadata extraction against repository-managed file references. */
module dosierskanilo.repository.metadata;

import d2sqlite3;

import std.array : join;
import std.path : buildPath;
import std.typecons : Nullable;

import dosierskanilo.metadata.mediainfosig : MediaInfoSig;
import dosierskanilo.metadata.torrentinfo : TorrentInfo;
import dosierskanilo.model.archivespec : ArchiveSpec;
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

        if (options.extractMediaInfo && (options.rescan
            || !metadataCompleted(db, blobId, "media_info")))
        {
            setMetadataStatus(db, blobId, "media_info", "pending", "");
            try
            {
                updateMediaInfo(blob, options.rescan);
                persistMediaInfo(db, blobId, blob.mediaInfoSig);
                setMetadataStatus(db, blobId, "media_info", "completed", "");
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
            || !metadataCompleted(db, blobId, "archives")))
        {
            setMetadataStatus(db, blobId, "archives", "pending", "");
            try
            {
                updateArchives(blob, options.rescan, options.deepArchiveScan);
                persistArchives(db, blobId, blob.archiveSpecs);
                setMetadataStatus(db, blobId, "archives", "completed", "");
                if (blob.archiveSpecs !is null)
                    summary.archivesUpdated++;
            }
            catch (Exception ex)
            {
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
                setMetadataStatus(db, blobId, "torrents", "completed", "");
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

private bool metadataCompleted(ref Database db, long blobId, string kind)
{
    auto result = db.execute("SELECT state FROM metadata_status "
        ~ "WHERE blob_id = ? AND metadata_kind = ?", blobId, kind);
    return !result.empty && result.front.peek!string(0) == "completed";
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

private void persistArchives(ref Database db, long blobId, ArchiveSpec[] entries)
{
    db.execute("DELETE FROM archive_entries WHERE blob_id = ?", blobId);
    if (entries is null)
        return;
    foreach (entry; entries)
    {
        if (entry is null)
            continue;
        db.execute("INSERT INTO archive_entries "
            ~ "(blob_id, file_name, file_size, time_last_modified, md5, "
            ~ "sha1, xxh64) VALUES (?, ?, ?, ?, ?, ?, ?)", blobId, entry.fileName,
            cast(long) entry.fileSize, entry.timeLastModified,
            checksumBlob(entry.checkSums.md5sum_b64),
            checksumBlob(entry.checkSums.sha1sum_b64),
            checksumBlob(entry.checkSums.xxh64sum_b64));
    }
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
