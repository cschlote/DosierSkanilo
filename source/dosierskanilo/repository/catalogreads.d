/** Read projections that load complete blobs with bounded statements.
 *
 * Blob details, fingerprints, and catalog pages are assembled from batches so
 * the GUI and CLI never materialize the complete SQLite catalog.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.catalogreads;

import d2sqlite3;
import std.algorithm : startsWith;
import std.array : join;
import std.base64 : Base64;
import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.path : buildPath;
import std.string : empty, endsWith, split;
import std.typecons : Nullable;
import core.time : MonoTime;
import dosierskanilo.logging : logLineVerbose;
import dosierarkivo.archive : appendArchiveVirtualPath, archiveIndexVersion,
    archivePathFilterSql, escapeArchiveVirtualPath, parseArchiveVirtualPath;
import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.metadata.torrentinfo;
import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.schema : migrate;
import dosierskanilo.repository.types;
import dosierskanilo.repository.referencequeries : pageLimitSql;

/** Load repository data into the existing domain model for library consumers.
 *
 * Params:
 *     db = Open repository database to read.
 *     rootPath = Repository root used to resolve physical paths.
 *     options = Export options controlling which details are loaded.
 * Returns: One record per loadable blob, ordered by database ID; blobs without
 *     usable references are omitted unless unreferenced content is allowed.
 */
NamedBinaryBlob[] loadCatalogFromDatabase(ref Database db, string rootPath,
    JsonExportOptions options)
{
    NamedBinaryBlob[] blobs;
    long[] blobIds;
    auto result = db.execute("SELECT id FROM blobs ORDER BY id");
    foreach (row; result)
        blobIds ~= row.peek!long(0);
    foreach (blobId; blobIds)
    {
        auto blob = loadBlobDetailsFromDatabase(db, rootPath, blobId, options);
        if (blob !is null)
            blobs ~= blob;
    }
    return blobs;
}

/** Load a bounded page of repository blobs for UI consumers.
 *
 * Params:
 *     db = Open repository database to read.
 *     rootPath = Repository root used to resolve physical paths.
 *     offset = Number of blobs to skip, ordered by database ID.
 *     limit = Maximum number of blobs to return.
 *     options = Export options controlling which details are loaded.
 * Returns: The requested blob records, ordered by database ID; empty when the
 *     page lies beyond the available rows.
 */
NamedBinaryBlob[] loadCatalogPageFromDatabase(ref Database db, string rootPath,
    size_t offset, size_t limit, JsonExportOptions options)
{
    NamedBinaryBlob[] blobs;
    long[] blobIds;
    auto result = db.execute("SELECT id FROM blobs ORDER BY id LIMIT ? OFFSET ?",
        cast(long) limit, cast(long) offset);
    foreach (row; result)
        blobIds ~= row.peek!long(0);
    foreach (blobId; blobIds)
    {
        auto blob = loadBlobDetailsFromDatabase(db, rootPath, blobId, options);
        if (blob !is null)
            blobs ~= blob;
    }
    return blobs;
}

/** Load a bounded page using repository-side text and metadata filters.
 *
 * Params:
 *     db = Open repository database to read.
 *     rootPath = Repository root used to resolve physical paths.
 *     options = Query filters, cursor state and page size.
 *     exportOptions = Export options controlling which details are loaded.
 * Returns: The matching blob records in query order; empty when nothing
 *     matches.
 */
NamedBinaryBlob[] loadCatalogQueryPageFromDatabase(ref Database db, string rootPath,
    RepositoryQueryOptions options, JsonExportOptions exportOptions)
{
    return loadCatalogQueryPageWithIdsFromDatabase(db, rootPath, options,
        exportOptions).blobs;
}

/** Load a bounded filtered page and retain its blob IDs.
 *
 * Params:
 *     db = Open repository database to read.
 *     rootPath = Repository root used to resolve physical paths.
 *     options = Query filters, cursor state and page size; the limit must be
 *         greater than zero.
 *     exportOptions = Export options controlling which details are loaded.
 * Returns: The page with blob records, retained IDs, UI flags and continuation
 *     state. Blobs that cannot be loaded are omitted from the parallel arrays.
 * Throws: `RepositoryException` when `options.limit` is zero.
 */
RepositoryBlobPage loadCatalogQueryPageWithIdsFromDatabase(ref Database db,
    string rootPath, RepositoryQueryOptions options, JsonExportOptions exportOptions)
{
    /* The wrapper Repository methods validate the page size before calling
     * here; this record remains directly callable from library code, so the
     * cursor arithmetic below must not crash on a zero limit. */
    enforce!RepositoryException(options.limit > 0,
        "Repository query page size must be greater than zero.");
    auto statement = prepareCatalogQuery(db, "SELECT b.id FROM blobs b", options,
        true);

    RepositoryBlobPage page;
    long[] blobIds;
    auto result = statement.execute();
    foreach (row; result)
        blobIds ~= row.peek!long(0);
    if (options.useCursor && blobIds.length > options.limit)
    {
        page.hasMore = true;
        page.nextCursor = blobIds[options.limit - 1];
        blobIds = blobIds[0 .. options.limit];
    }
    const flagValues = loadBlobFlagsBatch(db, blobIds);
    auto blobs = loadBlobDetailsBatchFromDatabase(db, rootPath, blobIds,
        exportOptions);
    foreach (index, blobId; blobIds)
    {
        if (blobs[index] is null)
            continue;
        page.blobIds ~= blobId;
        page.blobs ~= blobs[index];
        page.flags ~= flagValues[index];
    }
    return page;
}

/** Count rows matching repository query filters.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Query filters to apply.
 * Returns: The number of matching blob rows; the total blob count when no
 *     filter is active.
 */
long countCatalogQueryFromDatabase(ref Database db, RepositoryQueryOptions options)
{
    if (options.text.empty && !options.video && !options.audio && !options.image
        && !options.textStream && !options.fileType && !options.archive
        && !options.torrent && options.blobIds.length == 0
        && !options.referencedOnly)
        return db.execute("SELECT count(*) FROM blobs").oneValue!long;
    auto statement = prepareCatalogQuery(db, "SELECT count(*) FROM blobs b",
        options, false);
    return statement.execute().oneValue!long;
}

/** Build and bind the SQL statement behind a catalog query.
 *
 * The fragment adds the requested blob filters, optional pagination, and the
 * text filter, which also matches a literal 20-byte SHA-1 digest when the text
 * is valid base64.
 *
 * Params:
 *     db = Open repository database.
 *     selectSql = SELECT clause ending before the WHERE condition.
 *     options = Catalog query filters and cursor state.
 *     paged = Add ordering, limit and offset clauses when true.
 * Returns: A prepared statement with all filter parameters bound.
 */
private Statement prepareCatalogQuery(ref Database db, string selectSql,
    RepositoryQueryOptions options, bool paged)
{
    string sql = selectSql ~ " WHERE 1 = 1";
    if (options.referencedOnly)
        sql ~= " AND EXISTS (SELECT 1 FROM file_refs f WHERE f.blob_id = b.id)";
    string[] blobIdParameters;
    if (options.blobIds.length > 0)
    {
        foreach (index; 0 .. options.blobIds.length)
            blobIdParameters ~= ":blob_id_" ~ index.to!string;
        sql ~= " AND b.id IN (" ~ blobIdParameters.join(", ") ~ ")";
    }
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
            ~ "AND " ~ archivePathFilterSql("f.relative_path", ":text",
                options.caseSensitive) ~ ")";
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
            addOtherCondition("EXISTS (SELECT 1 FROM metadata_status a "
                ~ "WHERE a.blob_id = b.id AND a.metadata_kind = 'archives' "
                ~ "AND a.state IN ('completed', 'empty'))");
        if (options.torrent)
            addOtherCondition("EXISTS (SELECT 1 FROM torrent_info t "
                ~ "WHERE t.blob_id = b.id)");
        sql ~= ")";
    }
    if (paged)
    {
        if (options.useCursor && options.afterBlobId > 0)
            sql ~= " AND b.id > :after_blob_id";
        sql ~= " ORDER BY b.id LIMIT :limit";
        if (!options.useCursor)
            sql ~= " OFFSET :offset";
    }

    auto statement = db.prepare(sql);
    foreach (index, blobId; options.blobIds)
        statement.bind(blobIdParameters[index], blobId);
    if (!options.text.empty)
        statement.bind(":text", options.text);
    if (sha1Search.length == 20)
        statement.bind(":sha1", cast(Blob) sha1Search);
    if (paged)
    {
        auto limit = options.useCursor && options.limit < size_t.max
            ? pageLimitSql(options.limit, true)
            : pageLimitSql(options.limit);
        statement.bind(":limit", limit);
        if (options.useCursor && options.afterBlobId > 0)
            statement.bind(":after_blob_id", options.afterBlobId);
        else if (!options.useCursor)
            statement.bind(":offset", cast(long) options.offset);
    }
    return statement;
}

/** Load only the content size and digests for one blob.
 *
 * This avoids the reference, media, archive and torrent statements of a full
 * detail load when callers only need a fingerprint.
 *
 * Params:
 *     db = Open repository database to read.
 *     blobId = Stable database ID of the blob.
 * Returns: A blob carrying only size and digests, or `null` when no such blob
 *     exists.
 */
NamedBinaryBlob loadBlobFingerprintFromDatabase(ref Database db, long blobId)
{
    auto result = db.execute("SELECT file_size, md5, sha1, xxh64 FROM blobs "
        ~ "WHERE id = ?", blobId);
    if (result.empty)
        return null;
    auto row = result.front;
    auto blob = new NamedBinaryBlob();
    blob.fileSize = cast(size_t) row.peek!long(0);
    blob.checkSums.md5sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(1));
    blob.checkSums.sha1sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(2));
    blob.checkSums.xxh64sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(3));
    return blob;
}

/** Load one blob and all related details by stable database ID.
 *
 * Params:
 *     db = Open repository database to read.
 *     rootPath = Repository root used to resolve physical paths.
 *     blobId = Stable database ID of the blob.
 *     options = Export options controlling details and unreferenced content.
 * Returns: The populated blob, or `null` when the blob does not exist or has no
 *     references while unreferenced content is disallowed.
 */
NamedBinaryBlob loadBlobDetailsFromDatabase(ref Database db, string rootPath,
    long blobId, JsonExportOptions options)
{
    size_t fileSize;
    string md5sum;
    string sha1sum;
    string xxh64sum;
    string fileType;
    string archivePassword;
    {
        auto result = db.execute("SELECT file_size, md5, sha1, xxh64, file_type "
            ~ "FROM blobs WHERE id = ?", blobId);
        if (result.empty)
            return null;
        auto row = result.front;
        fileSize = cast(size_t) row.peek!long(0);
        md5sum = decodeBase64(row.peek!(Nullable!Blob)(1));
        sha1sum = decodeBase64(row.peek!(Nullable!Blob)(2));
        xxh64sum = decodeBase64(row.peek!(Nullable!Blob)(3));
        fileType = decodeNullableString(row.peek!(Nullable!string)(4));
    }
    auto passwordResult = db.execute(
        "SELECT password FROM archive_passwords WHERE blob_id = ?", blobId);
    if (!passwordResult.empty)
        archivePassword = passwordResult.front.peek!string(0);
    auto specsStarted = MonoTime.currTime;
    auto paths = loadFileSpecs(db, blobId, rootPath, options);
    const auto specsMs = cast(long) (MonoTime.currTime - specsStarted).total!"msecs";
    if (paths.length == 0 && !options.allowUnreferencedContent)
        return null;

    auto blob = new NamedBinaryBlob();
    blob.fileSize = fileSize;
    blob.checkSums.md5sum_b64 = md5sum;
    blob.checkSums.sha1sum_b64 = sha1sum;
    blob.checkSums.xxh64sum_b64 = xxh64sum;
    blob.fileType = fileType;
    blob.archivePassword = archivePassword;
    blob.fileSpecs = paths;
    blob.fileSpecsUseArchiveVirtualGrammar = true;

    if (options.includeDetails)
    {
        auto mediaStarted = MonoTime.currTime;
        loadMediaInfo(db, blobId, blob);
        const auto mediaMs = cast(long) (MonoTime.currTime - mediaStarted).total!"msecs";
        auto archiveStarted = MonoTime.currTime;
        if (options.includeArchiveEntries)
            loadArchiveIndexState(db, blobId, blob);
        const auto archiveMs =
            cast(long) (MonoTime.currTime - archiveStarted).total!"msecs";
        auto torrentStarted = MonoTime.currTime;
        loadTorrentInfo(db, blobId, blob, options.includeTorrentFiles);
        const auto torrentMs =
            cast(long) (MonoTime.currTime - torrentStarted).total!"msecs";
        logLineVerbose("[details] parts specs=", specsMs, " media=", mediaMs,
            " archive=", archiveMs, " torrent=", torrentMs,
            " specs=", paths.length);
    }
    return blob;
}

/** Create a FileSpec from a stored reference path.
 *
 * Params:
 *     fileName = Stored file or virtual archive path.
 *     modified = Last-modified timestamp text, or an empty string.
 *     rootPath = Repository root used when absolute paths are requested.
 *     options = Export options; `absolutePaths` rewrites the physical path.
 * Returns: A new FileSpec for the reference.
 */
private FileSpec fileSpecFromStoredPath(string fileName, string modified,
    string rootPath, JsonExportOptions options)
{
    if (options.absolutePaths)
    {
        import std.path : buildPath;

        const auto parsed = parseArchiveVirtualPath(fileName);
        fileName = escapeArchiveVirtualPath(buildPath(rootPath,
            parsed.physicalPath));
        foreach (entry; parsed.entries)
            fileName = appendArchiveVirtualPath(fileName,
                entry.relativePath, entry.hasOccurrence ? entry.occurrence
                    : size_t.max);
    }
    return new FileSpec(fileName, modified);
}

/** Load page details with a bounded number of set queries instead of per row.
 *
 * Params:
 *     db = Open repository database to read.
 *     rootPath = Repository root used to resolve physical paths.
 *     blobIds = Blob IDs whose details are loaded.
 *     options = Export options controlling details, prefix filtering and
 *         unreferenced content.
 * Returns: Details in the same order as `blobIds`; entries that are missing or
 *     have no allowed references remain `null`. Empty when `blobIds` is empty.
 */
private NamedBinaryBlob[] loadBlobDetailsBatchFromDatabase(ref Database db,
    string rootPath, long[] blobIds, JsonExportOptions options)
{
    if (blobIds.length == 0)
        return [];

    string[] placeholders;
    foreach (index; 0 .. blobIds.length)
        placeholders ~= ":detail_blob_" ~ index.to!string;
    const inList = placeholders.join(", ");

    static void bindIds(ref Statement statement, string[] placeholders,
        long[] blobIds)
    {
        foreach (index, blobId; blobIds)
            statement.bind(placeholders[index], blobId);
    }

    struct BlobBase
    {
        size_t fileSize;
        string md5sum;
        string sha1sum;
        string xxh64sum;
        string fileType;
    }
    BlobBase[long] baseById;
    {
        auto statement = db.prepare("SELECT id, file_size, md5, sha1, xxh64, "
            ~ "file_type FROM blobs WHERE id IN (" ~ inList ~ ")");
        bindIds(statement, placeholders, blobIds);
        foreach (row; statement.execute())
        {
            BlobBase base;
            base.fileSize = cast(size_t) row.peek!long(1);
            base.md5sum = decodeBase64(row.peek!(Nullable!Blob)(2));
            base.sha1sum = decodeBase64(row.peek!(Nullable!Blob)(3));
            base.xxh64sum = decodeBase64(row.peek!(Nullable!Blob)(4));
            base.fileType = decodeNullableString(row.peek!(Nullable!string)(5));
            baseById[row.peek!long(0)] = base;
        }
    }

    string[long] passwordByBlob;
    {
        auto statement = db.prepare("SELECT blob_id, password FROM "
            ~ "archive_passwords WHERE blob_id IN (" ~ inList ~ ")");
        bindIds(statement, placeholders, blobIds);
        foreach (row; statement.execute())
            passwordByBlob[row.peek!long(0)] = row.peek!string(1).idup;
    }

    FileSpec[][long] specsByBlob;
    {
        string sql = "SELECT blob_id, relative_path, time_last_modified "
            ~ "FROM file_refs WHERE blob_id IN (" ~ inList ~ ")";
        if (!options.pathPrefix.empty)
            sql ~= " AND (relative_path = :prefix OR relative_path LIKE :prefix_like)";
        sql ~= " ORDER BY blob_id, relative_path";
        auto statement = db.prepare(sql);
        bindIds(statement, placeholders, blobIds);
        if (!options.pathPrefix.empty)
        {
            statement.bind(":prefix", options.pathPrefix);
            statement.bind(":prefix_like", options.pathPrefix ~ "/%");
        }
        foreach (row; statement.execute())
        {
            const auto modified = row.peek!(Nullable!string)(2);
            specsByBlob[row.peek!long(0)] ~= fileSpecFromStoredPath(
                row.peek!string(1), modified.isNull ? "" : modified.get,
                rootPath, options);
        }
    }

    struct ArchiveState
    {
        bool known;
        bool deep;
    }
    ArchiveState[long] archiveByBlob;
    {
        auto statement = db.prepare("SELECT blob_id, state, extractor_version "
            ~ "FROM metadata_status WHERE metadata_kind = 'archives' "
            ~ "AND blob_id IN (" ~ inList ~ ")");
        bindIds(statement, placeholders, blobIds);
        foreach (row; statement.execute())
        {
            const auto state = row.peek!string(1);
            if (state != "completed" && state != "empty")
                continue;
            const auto extractorVersion = row.peek!(Nullable!string)(2);
            archiveByBlob[row.peek!long(0)] = ArchiveState(true,
                !extractorVersion.isNull
                    && extractorVersion.get.endsWith(":deep"));
        }
    }

    MediaInfoSig[long] mediaByBlob;
    if (options.includeDetails)
    {
        auto signatureStatement = db.prepare("SELECT blob_id FROM "
            ~ "media_signatures WHERE blob_id IN (" ~ inList ~ ")");
        bindIds(signatureStatement, placeholders, blobIds);
        foreach (row; signatureStatement.execute())
            mediaByBlob[row.peek!long(0)] = new MediaInfoSig();

        struct StreamQuery
        {
            string sql;
            void function(long blobId, ref MediaInfoSig info, Row row) add;
        }
        StreamQuery[] streamQueries;
        streamQueries ~= StreamQuery("SELECT blob_id, stream_index, format, "
            ~ "width, height FROM media_image_streams WHERE blob_id IN ("
            ~ inList ~ ") ORDER BY blob_id, stream_index",
            (long blobId, ref MediaInfoSig info, Row row) {
                info.imageStreams ~= new MediaInfoImage(row.peek!int(1),
                    row.peek!string(2), cast(ulong) row.peek!long(3),
                    cast(ulong) row.peek!long(4));
            });
        streamQueries ~= StreamQuery("SELECT blob_id, stream_index, language, "
            ~ "format, width, height, frame_rate, bit_rate, duration "
            ~ "FROM media_video_streams WHERE blob_id IN (" ~ inList ~ ") "
            ~ "ORDER BY blob_id, stream_index",
            (long blobId, ref MediaInfoSig info, Row row) {
                info.videoStreams ~= new MediaInfoVideo(row.peek!int(1),
                    row.peek!string(2), row.peek!string(3),
                    cast(ulong) row.peek!long(4),
                    cast(ulong) row.peek!long(5), row.peek!double(6),
                    cast(ulong) row.peek!long(7), row.peek!string(8));
            });
        streamQueries ~= StreamQuery("SELECT blob_id, stream_index, language, "
            ~ "format, channels, bit_rate, duration FROM media_audio_streams "
            ~ "WHERE blob_id IN (" ~ inList ~ ") ORDER BY blob_id, stream_index",
            (long blobId, ref MediaInfoSig info, Row row) {
                info.audioStreams ~= new MediaInfoAudio(row.peek!int(1),
                    row.peek!string(2), row.peek!string(3),
                    cast(ulong) row.peek!long(4),
                    cast(ulong) row.peek!long(5), row.peek!string(6));
            });
        streamQueries ~= StreamQuery("SELECT blob_id, stream_index, language, "
            ~ "format, frame_rate, bit_rate, duration FROM media_text_streams "
            ~ "WHERE blob_id IN (" ~ inList ~ ") ORDER BY blob_id, stream_index",
            (long blobId, ref MediaInfoSig info, Row row) {
                info.textStreams ~= new MediaInfoText(row.peek!int(1),
                    row.peek!string(2), row.peek!string(3),
                    row.peek!double(4), cast(ulong) row.peek!long(5),
                    row.peek!string(6));
            });

        foreach (streamQuery; streamQueries)
        {
            auto streamStatement = db.prepare(streamQuery.sql);
            bindIds(streamStatement, placeholders, blobIds);
            foreach (row; streamStatement.execute())
            {
                const blobId = row.peek!long(0);
                auto info = blobId in mediaByBlob;
                if (info is null)
                    continue;
                streamQuery.add(blobId, *info, row);
            }
        }
    }

    struct TorrentBase
    {
        string name;
        string magnetURI;
        ulong totalSize;
        bool isMultiFile;
        string infoHashHex;
        string announce;
        ulong pieceLength;
        ulong piecesCount;
    }
    TorrentBase[long] torrentByBlob;
    TorrentFileEntry[][long] torrentFilesByBlob;
    if (options.includeDetails)
    {
        auto torrentStatement = db.prepare("SELECT blob_id, name, magnet_uri, "
            ~ "total_size, is_multi_file, info_hash_hex, announce, "
            ~ "piece_length, pieces_count FROM torrent_info WHERE blob_id IN ("
            ~ inList ~ ")");
        bindIds(torrentStatement, placeholders, blobIds);
        foreach (row; torrentStatement.execute())
        {
            TorrentBase info;
            info.name = decodeNullableString(row.peek!(Nullable!string)(1));
            info.magnetURI = decodeNullableString(row.peek!(Nullable!string)(2));
            info.totalSize = cast(ulong) row.peek!long(3);
            info.isMultiFile = row.peek!long(4) != 0;
            info.infoHashHex = decodeNullableString(
                row.peek!(Nullable!string)(5));
            info.announce = decodeNullableString(row.peek!(Nullable!string)(6));
            info.pieceLength = cast(ulong) row.peek!long(7);
            info.piecesCount = cast(ulong) row.peek!long(8);
            torrentByBlob[row.peek!long(0)] = info;
        }

        if (options.includeTorrentFiles)
        {
            auto fileStatement = db.prepare("SELECT torrent_blob_id, "
                ~ "relative_path, file_size FROM torrent_files "
                ~ "WHERE torrent_blob_id IN (" ~ inList ~ ") "
                ~ "ORDER BY torrent_blob_id, file_index");
            bindIds(fileStatement, placeholders, blobIds);
            foreach (row; fileStatement.execute())
            {
                auto entry = new TorrentFileEntry();
                entry.path = row.peek!string(1).split("/");
                entry.length = cast(ulong) row.peek!long(2);
                torrentFilesByBlob[row.peek!long(0)] ~= entry;
            }
        }
    }

    NamedBinaryBlob[] result;
    result.length = blobIds.length;
    foreach (index, blobId; blobIds)
    {
        auto base = blobId in baseById;
        if (base is null)
            continue;
        auto specs = blobId in specsByBlob;
        if ((specs is null || specs.length == 0)
            && !options.allowUnreferencedContent)
            continue;

        auto blob = new NamedBinaryBlob();
        blob.fileSize = base.fileSize;
        blob.checkSums.md5sum_b64 = base.md5sum;
        blob.checkSums.sha1sum_b64 = base.sha1sum;
        blob.checkSums.xxh64sum_b64 = base.xxh64sum;
        blob.fileType = base.fileType;
        auto password = blobId in passwordByBlob;
        if (password !is null)
            blob.archivePassword = *password;
        if (specs !is null)
            blob.fileSpecs = *specs;
        blob.fileSpecsUseArchiveVirtualGrammar = true;

        if (options.includeDetails)
        {
            auto media = blobId in mediaByBlob;
            if (media !is null)
                blob.mediaInfoSig = *media;
            if (options.includeArchiveEntries)
            {
                auto archive = blobId in archiveByBlob;
                if (archive !is null)
                {
                    blob.archiveIndexKnown = archive.known;
                    blob.archiveIndexDeep = archive.deep;
                }
            }
            auto torrent = blobId in torrentByBlob;
            if (torrent !is null)
            {
                auto info = new TorrentInfo();
                info.name = torrent.name;
                info.magnetURI = torrent.magnetURI;
                info.totalSize = torrent.totalSize;
                info.isMultiFile = torrent.isMultiFile;
                info.infoHashHex = torrent.infoHashHex;
                info.announce = torrent.announce;
                info.pieceLength = torrent.pieceLength;
                info.piecesCount = torrent.piecesCount;
                if (options.includeTorrentFiles)
                {
                    auto files = blobId in torrentFilesByBlob;
                    if (files !is null)
                        info.files = *files;
                }
                blob.torrentInfo = info;
            }
        }
        result[index] = blob;
    }
    return result;
}

/** Load UI flags for several blobs with one query.
 *
 * Params:
 *     db = Open repository database.
 *     blobIds = Blob IDs whose flags are requested.
 * Returns: Flags in the same order as `blobIds`; entries without a row get
 *     `RepositoryBlobFlags.init`. Empty when `blobIds` is empty.
 */
private RepositoryBlobFlags[] loadBlobFlagsBatch(ref Database db,
    long[] blobIds)
{
    if (blobIds.length == 0)
        return [];

    string[] placeholders;
    foreach (index; 0 .. blobIds.length)
        placeholders ~= ":flag_blob_" ~ index.to!string;
    auto sql = "SELECT b.id, "
        ~ "(b.file_type IS NOT NULL AND length(b.file_type) > 0), "
        ~ "EXISTS (SELECT 1 FROM media_signatures ms WHERE ms.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_video_streams mv WHERE mv.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_audio_streams ma WHERE ma.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_image_streams mi WHERE mi.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_text_streams mt WHERE mt.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM metadata_status ar WHERE ar.blob_id = b.id "
        ~ "AND ar.metadata_kind = 'archives' AND ar.state IN ('completed', 'empty')), "
        ~ "EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.blob_id = b.id) "
        ~ "FROM blobs b WHERE b.id IN (" ~ placeholders.join(", ") ~ ")";
    auto statement = db.prepare(sql);
    foreach (index, blobId; blobIds)
        statement.bind(placeholders[index], blobId);

    RepositoryBlobFlags[long] flagsById;
    foreach (row; statement.execute())
    {
        RepositoryBlobFlags flags;
        flags.hasFileType = row.peek!long(1) != 0;
        flags.hasMedia = row.peek!long(2) != 0;
        flags.hasVideo = row.peek!long(3) != 0;
        flags.hasAudio = row.peek!long(4) != 0;
        flags.hasImage = row.peek!long(5) != 0;
        flags.hasText = row.peek!long(6) != 0;
        flags.hasArchive = row.peek!long(7) != 0;
        flags.hasTorrent = row.peek!long(8) != 0;
        flagsById[row.peek!long(0)] = flags;
    }

    RepositoryBlobFlags[] result;
    foreach (blobId; blobIds)
        result ~= blobId in flagsById ? flagsById[blobId]
            : RepositoryBlobFlags.init;
    return result;
}

/** Load the file references of one blob as FileSpec values.
 *
 * Params:
 *     db = Open repository database.
 *     blobId = Blob whose references are loaded.
 *     rootPath = Repository root used when absolute paths are requested.
 *     options = Export options controlling prefix filtering and path form.
 * Returns: References ordered by stored path; empty when the blob has none.
 */
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
            const auto parsed = parseArchiveVirtualPath(fileName);
            fileName = escapeArchiveVirtualPath(buildPath(rootPath,
                parsed.physicalPath));
            foreach (entry; parsed.entries)
                fileName = appendArchiveVirtualPath(fileName,
                    entry.relativePath, entry.hasOccurrence ? entry.occurrence
                        : size_t.max);
        }
        specs ~= new FileSpec(fileName,
            modified.isNull ? "" : modified.get);
    }
    return specs;
}

/** Load media signature and stream data into a blob.
 *
 * Params:
 *     db = Open repository database.
 *     blobId = Blob whose media data is loaded.
 *     blob = Catalog record updated in place; left untouched when no media
 *         signature exists.
 */
private void loadMediaInfo(ref Database db, long blobId, ref NamedBinaryBlob blob)
{
    bool hasSignature;
    {
        auto signature = db.execute("SELECT blob_id FROM media_signatures "
            ~ "WHERE blob_id = ?", blobId);
        hasSignature = !signature.empty;
    }
    if (!hasSignature)
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

/** Load archive index state into a blob.
 *
 * Only `completed` and `empty` archive rows count as a known index. The
 * extractor version suffix determines whether the index was deep.
 *
 * Params:
 *     db = Open repository database.
 *     blobId = Blob whose archive state is loaded.
 *     blob = Catalog record updated in place; left untouched when no usable
 *         state row exists.
 */
private void loadArchiveIndexState(ref Database db, long blobId,
    ref NamedBinaryBlob blob)
{
    auto result = db.execute("SELECT state, extractor_version FROM metadata_status "
        ~ "WHERE blob_id = ? AND metadata_kind = 'archives'", blobId);
    if (result.empty)
        return;
    auto row = result.front;
    const auto state = row.peek!string(0);
    if (state != "completed" && state != "empty" && state != "partial")
        return;
    blob.archiveIndexKnown = true;
    const auto extractorVersion = row.peek!(Nullable!string)(1);
    if (state == "partial")
    {
        blob.archiveIndexDeep = false;
        const prefix = archiveIndexVersion ~ ":partial:";
        if (!extractorVersion.isNull
            && extractorVersion.get.startsWith(prefix))
            try
                blob.archiveScanCursor =
                    extractorVersion.get[prefix.length .. $].to!size_t;
            catch (Exception)
                blob.archiveScanCursor = 0;
    }
    else if (!extractorVersion.isNull)
        blob.archiveIndexDeep = extractorVersion.get.endsWith(":deep");
}

/** Load torrent metadata into a blob.
 *
 * Params:
 *     db = Open repository database.
 *     blobId = Blob whose torrent data is loaded.
 *     blob = Catalog record updated in place; left untouched when no torrent
 *         row exists.
 *     includeFiles = Also load the per-file list when true.
 */
private void loadTorrentInfo(ref Database db, long blobId, ref NamedBinaryBlob blob,
    bool includeFiles = true)
{
    auto info = new TorrentInfo();
    {
        auto result = db.execute("SELECT name, magnet_uri, total_size, is_multi_file, "
            ~ "info_hash_hex, announce, piece_length, pieces_count "
            ~ "FROM torrent_info WHERE blob_id = ?", blobId);
        if (result.empty)
            return;
        auto row = result.front;
        info.name = decodeNullableString(row.peek!(Nullable!string)(0));
        info.magnetURI = decodeNullableString(row.peek!(Nullable!string)(1));
        info.totalSize = cast(ulong) row.peek!long(2);
        info.isMultiFile = row.peek!long(3) != 0;
        info.infoHashHex = decodeNullableString(row.peek!(Nullable!string)(4));
        info.announce = decodeNullableString(row.peek!(Nullable!string)(5));
        info.pieceLength = cast(ulong) row.peek!long(6);
        info.piecesCount = cast(ulong) row.peek!long(7);
    }
    if (includeFiles)
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

/** Decode a base64 text digest into binary form for storage.
 *
 * Despite its name, the function decodes text into a `Blob`. Invalid base64 is
 * tolerated to preserve legacy placeholder digests.
 *
 * Params:
 *     value = Base64-encoded digest text.
 * Returns: The decoded bytes, or a null `Nullable` when `value` is empty or
 *     not valid base64.
 */
package Nullable!Blob encodeBase64(string value)
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

/** Encode a stored binary digest as base64 text.
 *
 * Params:
 *     value = Binary digest to encode.
 * Returns: The base64 text, or an empty string when `value` is null or empty.
 */
package string decodeBase64(Nullable!Blob value)
{
    if (value.isNull || value.get.length == 0)
        return "";
    return Base64.encode(value.get);
}

/** Unwrap an optional database string.
 *
 * Params:
 *     value = Nullable string read from the database.
 * Returns: The stored value, or an empty string when the value is null.
 */
package string decodeNullableString(Nullable!string value)
{
    return value.isNull ? "" : value.get;
}

@("catalog page details use a bounded number of statements")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO directories (id, parent_id, relative_path, name) "
        ~ "VALUES (1, NULL, 'media', 'media')");
    foreach (index; 1 .. 6)
    {
        const blobId = cast(long) index;
        db.execute("INSERT INTO blobs (id, file_size, file_type) VALUES (?, ?, NULL)",
            blobId, 100 + blobId);
        db.execute("INSERT INTO file_refs (id, blob_id, directory_id, "
            ~ "relative_path, time_last_modified, exists_on_disk, last_seen_at) "
            ~ "VALUES (?, ?, 1, ?, '2026-01-01T00:00:00', 1, ?)",
            blobId, blobId, "media/file" ~ index.to!string ~ ".bin",
            "2026-01-01T00:00:00");
    }
    db.execute("INSERT INTO media_signatures (blob_id) VALUES (1), (2)");
    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
        ~ "extractor_version, scanned_at, error_message) VALUES "
        ~ "(3, 'archives', 'completed', '', '2026-01-01T00:00:00', NULL)");
    db.execute("INSERT INTO torrent_info (blob_id, name, magnet_uri, total_size, "
        ~ "is_multi_file, info_hash_hex, announce, piece_length, pieces_count) "
        ~ "VALUES (4, 'four.torrent', '', 4, 0, '', '', 16384, 1)");
    db.execute("INSERT INTO torrent_files (id, torrent_blob_id, file_index, "
        ~ "relative_path, file_size) VALUES (1, 4, 0, 'four.bin', 4)");

    size_t statements;
    db.setTraceCallback((string sql) nothrow { ++statements; });
    auto page = loadCatalogQueryPageWithIdsFromDatabase(db, "/repo",
        RepositoryQueryOptions(0, 10), JsonExportOptions());
    db.setTraceCallback(null);

    assert(page.blobs.length == 5);
    assert(page.flags.length == 5);
    /* One query each for the page, flags, blobs, passwords, refs, archive
     * state, media signature, four stream tables, torrent info and files. */
    assert(statements <= 14, "page issued " ~ statements.to!string ~ " statements");
}
