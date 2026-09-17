/** JSON transfer between the normalized repository and the legacy format. */
module dosierskanilo.repository.transfer;

import d2sqlite3;

import std.algorithm : startsWith;
import std.array : join;
import std.base64 : Base64;
import std.path : buildNormalizedPath, dirName, isAbsolute;
import std.string : empty, replace, split;
import std.typecons : Nullable;

import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.metadata.torrentinfo;
import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.types;

/** Import a JSON catalog into an open repository database. */
void importCatalogJson(ref Database db, string rootPath, string jsonFile,
    JsonImportOptions options)
{
    auto catalog = deserializeDataClassJsonWrapperFile(jsonFile);
    if (!options.replaceExisting)
        throw new RepositoryException("Appending JSON data is not implemented yet.");

    try
    {
        db.begin();
        clearCatalog(db);

        foreach (blob; catalog.dataArray)
            insertBlob(db, rootPath, blob);

        db.execute("UPDATE repository SET updated_at = ?, "
            ~ "media_info_version = ?, file_utility_version = ? WHERE id = 1",
            currentTimestamp(), catalog.mediaInfoVersion,
            catalog.fileUtilityVersion);
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

/** Export repository data as the current JSON catalog format. */
void exportCatalogJson(ref Database db, string rootPath, string jsonFile,
    JsonExportOptions options)
{
    auto blobs = loadCatalogFromDatabase(db, rootPath, options);
    auto wrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, blobs);
    serializeDataClassWrapperFile(jsonFile, wrapper);
}

/** Load repository data into the existing domain model for library consumers. */
NamedBinaryBlob[] loadCatalogFromDatabase(ref Database db, string rootPath,
    JsonExportOptions options)
{
    NamedBinaryBlob[] blobs;
    auto result = db.execute("SELECT id FROM blobs ORDER BY id");
    foreach (row; result)
    {
        auto blob = loadBlobDetailsFromDatabase(db, rootPath, row.peek!long(0), options);
        if (blob !is null)
            blobs ~= blob;
    }
    return blobs;
}

/** Load a bounded page of repository blobs for UI consumers. */
NamedBinaryBlob[] loadCatalogPageFromDatabase(ref Database db, string rootPath,
    size_t offset, size_t limit, JsonExportOptions options)
{
    NamedBinaryBlob[] blobs;
    auto result = db.execute("SELECT id FROM blobs ORDER BY id LIMIT ? OFFSET ?",
        cast(long) limit, cast(long) offset);
    foreach (row; result)
    {
        auto blob = loadBlobDetailsFromDatabase(db, rootPath, row.peek!long(0), options);
        if (blob !is null)
            blobs ~= blob;
    }
    return blobs;
}

/** Load a bounded page using repository-side text and metadata filters. */
NamedBinaryBlob[] loadCatalogQueryPageFromDatabase(ref Database db, string rootPath,
    RepositoryQueryOptions options, JsonExportOptions exportOptions)
{
    return loadCatalogQueryPageWithIdsFromDatabase(db, rootPath, options,
        exportOptions).blobs;
}

/** Load a bounded filtered page and retain its blob IDs. */
RepositoryBlobPage loadCatalogQueryPageWithIdsFromDatabase(ref Database db,
    string rootPath, RepositoryQueryOptions options, JsonExportOptions exportOptions)
{
    auto statement = prepareCatalogQuery(db, "SELECT b.id FROM blobs b", options,
        true);

    RepositoryBlobPage page;
    auto result = statement.execute();
    foreach (row; result)
    {
        auto blobId = row.peek!long(0);
        auto blob = loadBlobDetailsFromDatabase(db, rootPath, blobId,
            exportOptions);
        if (blob !is null)
        {
            page.blobIds ~= blobId;
            page.blobs ~= blob;
            page.flags ~= loadBlobFlags(db, blobId);
        }
    }
    return page;
}

/** Count rows matching repository query filters. */
long countCatalogQueryFromDatabase(ref Database db, RepositoryQueryOptions options)
{
    auto statement = prepareCatalogQuery(db, "SELECT count(*) FROM blobs b",
        options, false);
    return statement.execute().oneValue!long;
}

private Statement prepareCatalogQuery(ref Database db, string selectSql,
    RepositoryQueryOptions options, bool paged)
{
    string sql = selectSql ~ " WHERE 1 = 1";
    ubyte[] sha1Search;
    if (!options.text.empty)
    {
        try
        {
            auto decoded = Base64.decode(options.text);
            if (decoded.length == 20)
                sha1Search = decoded;
        }
        catch (Exception)
        {
        }
    }
    if (!options.text.empty)
    {
        sql ~= " AND (EXISTS (SELECT 1 FROM file_refs f WHERE f.blob_id = b.id "
            ~ "AND lower(f.relative_path) LIKE lower(:text))";
        if (sha1Search.length == 20)
            sql ~= " OR b.sha1 = :sha1";
        sql ~= ")";
    }

    auto hasMediaFilter = options.video || options.audio || options.image
        || options.textStream;
    if (hasMediaFilter)
    {
        string mediaCondition = "(";
        bool hasPrevious;
        void addMediaCondition(string table)
        {
            if (hasPrevious)
                mediaCondition ~= " OR ";
            mediaCondition ~= "EXISTS (SELECT 1 FROM " ~ table
                ~ " s WHERE s.blob_id = b.id)";
            hasPrevious = true;
        }
        if (options.video)
            addMediaCondition("media_video_streams");
        if (options.audio)
            addMediaCondition("media_audio_streams");
        if (options.image)
            addMediaCondition("media_image_streams");
        if (options.textStream)
            addMediaCondition("media_text_streams");
        mediaCondition ~= ")";
        sql ~= options.mediaNegated ? " AND NOT " : " AND ";
        sql ~= mediaCondition;
    }

    if (options.fileType || options.archive || options.torrent)
    {
        sql ~= " AND (";
        bool hasPrevious;
        void addOtherCondition(string condition)
        {
            if (hasPrevious)
                sql ~= " OR ";
            sql ~= condition;
            hasPrevious = true;
        }
        if (options.fileType)
            addOtherCondition("b.file_type IS NOT NULL AND length(b.file_type) > 0");
        if (options.archive)
            addOtherCondition("EXISTS (SELECT 1 FROM archive_entries a "
                ~ "WHERE a.blob_id = b.id)");
        if (options.torrent)
            addOtherCondition("EXISTS (SELECT 1 FROM torrent_info t "
                ~ "WHERE t.blob_id = b.id)");
        sql ~= ")";
    }
    if (paged)
        sql ~= " ORDER BY b.id LIMIT :limit OFFSET :offset";

    auto statement = db.prepare(sql);
    if (!options.text.empty)
        statement.bind(":text", "%" ~ options.text ~ "%");
    if (sha1Search.length == 20)
        statement.bind(":sha1", cast(Blob) sha1Search);
    if (paged)
    {
        statement.bind(":limit", cast(long) options.limit);
        statement.bind(":offset", cast(long) options.offset);
    }
    return statement;
}

/** Load one blob and all related details by stable database ID. */
NamedBinaryBlob loadBlobDetailsFromDatabase(ref Database db, string rootPath,
    long blobId, JsonExportOptions options)
{
    auto result = db.execute("SELECT file_size, md5, sha1, xxh64, file_type "
        ~ "FROM blobs WHERE id = ?", blobId);
    if (result.empty)
        return null;
    auto row = result.front;
    auto paths = loadFileSpecs(db, blobId, rootPath, options);
    if (paths.length == 0)
        return null;

    auto blob = new NamedBinaryBlob();
    blob.fileSize = cast(size_t) row.peek!long(0);
    blob.checkSums.md5sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(1));
    blob.checkSums.sha1sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(2));
    blob.checkSums.xxh64sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(3));
    blob.fileType = decodeNullableString(row.peek!(Nullable!string)(4));
    blob.fileSpecs = paths;

    if (options.includeDetails)
    {
        loadMediaInfo(db, blobId, blob);
        loadArchiveSpecs(db, blobId, blob);
        loadTorrentInfo(db, blobId, blob);
    }
    return blob;
}

private RepositoryBlobFlags loadBlobFlags(ref Database db, long blobId)
{
    RepositoryBlobFlags flags;
    flags.hasFileType = !db.execute("SELECT 1 FROM blobs WHERE id = ? "
        ~ "AND file_type IS NOT NULL AND length(file_type) > 0", blobId).empty;
    flags.hasMedia = !db.execute("SELECT 1 FROM media_signatures "
        ~ "WHERE blob_id = ?", blobId).empty;
    flags.hasVideo = !db.execute("SELECT 1 FROM media_video_streams "
        ~ "WHERE blob_id = ?", blobId).empty;
    flags.hasAudio = !db.execute("SELECT 1 FROM media_audio_streams "
        ~ "WHERE blob_id = ?", blobId).empty;
    flags.hasImage = !db.execute("SELECT 1 FROM media_image_streams "
        ~ "WHERE blob_id = ?", blobId).empty;
    flags.hasText = !db.execute("SELECT 1 FROM media_text_streams "
        ~ "WHERE blob_id = ?", blobId).empty;
    flags.hasArchive = !db.execute("SELECT 1 FROM archive_entries "
        ~ "WHERE blob_id = ?", blobId).empty;
    flags.hasTorrent = !db.execute("SELECT 1 FROM torrent_info "
        ~ "WHERE blob_id = ?", blobId).empty;
    return flags;
}

private void clearCatalog(ref Database db)
{
    db.execute("DELETE FROM file_refs");
    db.execute("DELETE FROM directories");
    db.execute("DELETE FROM blobs");
}

private void insertBlob(ref Database db, string rootPath, NamedBinaryBlob blob)
{
    auto md5 = encodeBase64(blob.checkSums.md5sum_b64);
    auto sha1 = encodeBase64(blob.checkSums.sha1sum_b64);
    auto xxh64 = encodeBase64(blob.checkSums.xxh64sum_b64);
    db.execute("INSERT INTO blobs "
        ~ "(file_size, md5, sha1, xxh64, file_type) VALUES (?, ?, ?, ?, ?)",
        cast(long) blob.fileSize, md5, sha1, xxh64, blob.fileType);
    auto id = db.lastInsertRowid;

    foreach (spec; blob.fileSpecs)
    {
        if (spec is null || spec.fileName.empty)
            continue;
        auto relative = repositoryRelativePath(rootPath, spec.fileName);
        auto directoryId = ensureDirectory(db, dirName(relative));
        if (directoryId == 0)
        {
            db.execute("INSERT INTO file_refs "
                ~ "(blob_id, relative_path, time_last_modified, "
                ~ "exists_on_disk, last_seen_at) VALUES (?, ?, ?, 1, ?)",
                id, relative, spec.timeLastModified, currentTimestamp());
        }
        else
        {
            db.execute("INSERT INTO file_refs "
                ~ "(blob_id, directory_id, relative_path, time_last_modified, "
                ~ "exists_on_disk, last_seen_at) VALUES (?, ?, ?, ?, 1, ?)",
                id, directoryId, relative, spec.timeLastModified,
                currentTimestamp());
        }
    }

    insertMediaInfo(db, id, blob.mediaInfoSig);
    foreach (entry; blob.archiveSpecs)
    {
        if (entry is null)
            continue;
        db.execute("INSERT INTO archive_entries "
            ~ "(blob_id, file_name, file_size, time_last_modified, md5, "
            ~ "sha1, xxh64) VALUES (?, ?, ?, ?, ?, ?, ?)", id, entry.fileName,
            cast(long) entry.fileSize, entry.timeLastModified,
            encodeBase64(entry.checkSums.md5sum_b64),
            encodeBase64(entry.checkSums.sha1sum_b64),
            encodeBase64(entry.checkSums.xxh64sum_b64));
    }
    insertTorrentInfo(db, id, blob.torrentInfo);
}

private long ensureDirectory(ref Database db, string relativeDirectory)
{
    if (relativeDirectory.empty || relativeDirectory == ".")
        return 0;

    auto normalized = repositoryRelativePath("", relativeDirectory);
    long parentId;
    string current;
    foreach (part; normalized.split("/"))
    {
        if (part.empty || part == ".")
            continue;
        current = current.empty ? part : current ~ "/" ~ part;
        if (parentId == 0)
        {
            db.execute("INSERT OR IGNORE INTO directories "
                ~ "(parent_id, relative_path, name) VALUES (NULL, ?, ?)",
                current, part);
        }
        else
        {
            db.execute("INSERT OR IGNORE INTO directories "
                ~ "(parent_id, relative_path, name) VALUES (?, ?, ?)",
                parentId, current, part);
        }
        parentId = db.execute("SELECT id FROM directories "
            ~ "WHERE relative_path = ?", current).oneValue!long;
    }
    return parentId;
}

private string repositoryRelativePath(string rootPath, string path)
{
    auto normalized = buildNormalizedPath(path).replace('\\', '/');
    auto normalizedRoot = rootPath.empty ? "" : buildNormalizedPath(rootPath);
    if (!isAbsolute(normalized))
        return normalized;
    if (normalized == normalizedRoot)
        throw new RepositoryException("A repository root cannot be a file path.");

    auto prefix = normalizedRoot ~ "/";
    if (!normalized.startsWith(prefix))
        throw new RepositoryException("JSON path is outside repository root: "
            ~ path);
    return normalized[prefix.length .. $];
}

private void insertMediaInfo(ref Database db, long blobId, MediaInfoSig info)
{
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

private void insertTorrentInfo(ref Database db, long blobId, TorrentInfo info)
{
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

private FileSpec[] loadFileSpecs(ref Database db, long blobId, string rootPath,
    JsonExportOptions options)
{
    FileSpec[] specs;
    auto result = options.pathPrefix.empty
        ? db.execute("SELECT relative_path, time_last_modified FROM file_refs "
            ~ "WHERE blob_id = ? ORDER BY relative_path", blobId)
        : db.execute("SELECT relative_path, time_last_modified FROM file_refs "
            ~ "WHERE blob_id = ? AND (relative_path = ? OR relative_path LIKE ?) "
            ~ "ORDER BY relative_path", blobId, options.pathPrefix,
            options.pathPrefix ~ "/%");
    foreach (row; result)
    {
        auto modified = row.peek!(Nullable!string)(1);
        auto fileName = row.peek!string(0);
        if (options.absolutePaths)
        {
            import std.path : buildPath;
            fileName = buildPath(rootPath, fileName);
        }
        specs ~= new FileSpec(fileName,
            modified.isNull ? "" : modified.get);
    }
    return specs;
}

private void loadMediaInfo(ref Database db, long blobId, ref NamedBinaryBlob blob)
{
    auto signature = db.execute("SELECT blob_id FROM media_signatures "
        ~ "WHERE blob_id = ?", blobId);
    if (signature.empty)
        return;
    auto info = new MediaInfoSig();
    foreach (row; db.execute("SELECT stream_index, format, width, height "
        ~ "FROM media_image_streams WHERE blob_id = ? ORDER BY stream_index", blobId))
        info.imageStreams ~= new MediaInfoImage(row.peek!int(0), row.peek!string(1),
            cast(ulong) row.peek!long(2), cast(ulong) row.peek!long(3));
    foreach (row; db.execute("SELECT stream_index, language, format, width, "
        ~ "height, frame_rate, bit_rate, duration FROM media_video_streams "
        ~ "WHERE blob_id = ? ORDER BY stream_index", blobId))
        info.videoStreams ~= new MediaInfoVideo(row.peek!int(0), row.peek!string(1),
            row.peek!string(2), cast(ulong) row.peek!long(3),
            cast(ulong) row.peek!long(4), row.peek!double(5),
            cast(ulong) row.peek!long(6), row.peek!string(7));
    foreach (row; db.execute("SELECT stream_index, language, format, channels, "
        ~ "bit_rate, duration FROM media_audio_streams WHERE blob_id = ? "
        ~ "ORDER BY stream_index", blobId))
        info.audioStreams ~= new MediaInfoAudio(row.peek!int(0), row.peek!string(1),
            row.peek!string(2), cast(ulong) row.peek!long(3),
            cast(ulong) row.peek!long(4), row.peek!string(5));
    foreach (row; db.execute("SELECT stream_index, language, format, frame_rate, "
        ~ "bit_rate, duration FROM media_text_streams WHERE blob_id = ? "
        ~ "ORDER BY stream_index", blobId))
        info.textStreams ~= new MediaInfoText(row.peek!int(0), row.peek!string(1),
            row.peek!string(2), row.peek!double(3), cast(ulong) row.peek!long(4),
            row.peek!string(5));
    blob.mediaInfoSig = info;
}

private void loadArchiveSpecs(ref Database db, long blobId, ref NamedBinaryBlob blob)
{
    foreach (row; db.execute("SELECT file_name, file_size, time_last_modified, "
        ~ "md5, sha1, xxh64 FROM archive_entries WHERE blob_id = ? "
        ~ "ORDER BY file_name", blobId))
    {
        auto modified = row.peek!(Nullable!string)(2);
        auto entry = new ArchiveSpec(row.peek!string(0),
            cast(size_t) row.peek!long(1), modified.isNull ? "" : modified.get,
            CheckSums());
        entry.checkSums.md5sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(3));
        entry.checkSums.sha1sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(4));
        entry.checkSums.xxh64sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(5));
        blob.archiveSpecs ~= entry;
    }
}

private void loadTorrentInfo(ref Database db, long blobId, ref NamedBinaryBlob blob)
{
    auto result = db.execute("SELECT name, magnet_uri, total_size, is_multi_file, "
        ~ "info_hash_hex, announce, piece_length, pieces_count "
        ~ "FROM torrent_info WHERE blob_id = ?", blobId);
    if (result.empty)
        return;
    auto row = result.front;
    auto info = new TorrentInfo();
    info.name = decodeNullableString(row.peek!(Nullable!string)(0));
    info.magnetURI = decodeNullableString(row.peek!(Nullable!string)(1));
    info.totalSize = cast(ulong) row.peek!long(2);
    info.isMultiFile = row.peek!long(3) != 0;
    info.infoHashHex = decodeNullableString(row.peek!(Nullable!string)(4));
    info.announce = decodeNullableString(row.peek!(Nullable!string)(5));
    info.pieceLength = cast(ulong) row.peek!long(6);
    info.piecesCount = cast(ulong) row.peek!long(7);
    foreach (fileRow; db.execute("SELECT relative_path, file_size FROM "
        ~ "torrent_files WHERE torrent_blob_id = ? ORDER BY file_index", blobId))
    {
        auto entry = new TorrentFileEntry();
        entry.path = fileRow.peek!string(0).split("/");
        entry.length = cast(ulong) fileRow.peek!long(1);
        info.files ~= entry;
    }
    blob.torrentInfo = info;
}

private Nullable!Blob encodeBase64(string value)
{
    Nullable!Blob result;
    if (value.empty)
        return result;
    try
        result = cast(Blob) Base64.decode(value);
    catch (Exception)
    {
        // Preserve legacy placeholder digests without rejecting the catalog.
    }
    return result;
}

private string decodeBase64(Nullable!Blob value)
{
    if (value.isNull || value.get.length == 0)
        return "";
    return Base64.encode(value.get);
}

private string decodeNullableString(Nullable!string value)
{
    return value.isNull ? "" : value.get;
}

private string currentTimestamp()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toISOExtString;
}
