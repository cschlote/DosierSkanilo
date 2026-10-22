/** JSON transfer between the normalized repository and the legacy format. */
module dosierskanilo.repository.transfer;

import d2sqlite3;

import std.algorithm : reverse, startsWith;
import std.algorithm.searching : canFind;
import std.array : join;
import std.base64 : Base64;
import std.conv : to;
import std.exception : enforce;
import std.path : baseName, buildNormalizedPath, dirName, isAbsolute;
import std.string : empty, endsWith, replace, split;
import std.typecons : Nullable;

import dosierarkivo.archive : appendArchiveVirtualPath, archiveIndexVersion,
    escapeArchiveVirtualPath, parseArchiveVirtualPath,
    ParsedArchiveVirtualPath;
import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.metadata.torrentinfo;
import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.repository.archiveindex : deleteUnreachableBlobs,
    isVirtualFileReferenceSql, resolveArchiveMemberBlobLinks;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.schema : migrate;
import dosierskanilo.repository.types;

private struct ImportedArchiveIndex
{
    long blobId;
    bool deep;
}

/** Import a JSON catalog into an open repository database. */
void importCatalogJson(ref Database db, string rootPath, string jsonFile,
    JsonImportOptions options)
{
    auto catalog = deserializeDataClassJsonWrapperFile(jsonFile);
    if (!options.replaceExisting)
        throw new RepositoryException("Appending JSON data is not implemented yet.");
    upgradeDataClassCatalogToV5(catalog);

    try
    {
        db.begin();
        clearCatalog(db);

        ImportedArchiveIndex[] archiveIndexes;
        foreach (physicalPass; [true, false])
            foreach (blob; catalog.dataArray)
            {
                if (blob is null || hasPhysicalFileReference(blob)
                    != physicalPass)
                    continue;
                const auto blobId = insertBlob(db, rootPath, blob);
                if (blob.archiveIndexKnown)
                    archiveIndexes ~= ImportedArchiveIndex(blobId,
                        blob.archiveIndexDeep);
            }
        persistImportedArchiveStatuses(db, archiveIndexes);
        resolveArchiveMemberBlobLinks(db);
        deleteUnreachableBlobs(db);

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
    auto wrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, blobs);
    serializeDataClassWrapperFile(jsonFile, wrapper);
}

/** Load repository data into the existing domain model for library consumers. */
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

/** Load a bounded page of repository blobs for UI consumers. */
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

/** Load a bounded page using repository-side text and metadata filters. */
NamedBinaryBlob[] loadCatalogQueryPageFromDatabase(ref Database db, string rootPath,
    RepositoryQueryOptions options, JsonExportOptions exportOptions)
{
    return loadCatalogQueryPageWithIdsFromDatabase(db, rootPath, options,
        exportOptions).blobs;
}

/** List immediate child directories without materializing the catalog. */
RepositoryDirectory[] listDirectoriesFromDatabase(ref Database db,
    RepositoryDirectoryQuery options)
{
    auto statement = db.prepare(
        "SELECT d.id, d.parent_id, d.name, d.relative_path, "
        ~ "(SELECT count(*) FROM directories child WHERE child.parent_id = d.id), "
        ~ "(SELECT count(*) FROM file_refs f WHERE f.directory_id = d.id AND "
        ~ "NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ")), "
        ~ "COALESCE((SELECT sum(b.file_size) FROM file_refs f "
        ~ "JOIN blobs b ON b.id = f.blob_id WHERE (f.relative_path = d.relative_path "
        ~ "OR f.relative_path LIKE d.relative_path || '/%') "
        ~ "AND NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ")), 0) "
        ~ "FROM directories d WHERE "
        ~ (options.parentId == 0 ? "d.parent_id IS NULL" : "d.parent_id = :parent_id")
        ~ directoryFilterSql(options)
        ~ " ORDER BY d.relative_path LIMIT :limit OFFSET :offset");
    if (options.parentId != 0)
        statement.bind(":parent_id", options.parentId);
    bindDirectoryFilter(statement, options);
    statement.bind(":limit", cast(long) options.limit);
    statement.bind(":offset", cast(long) options.offset);

    RepositoryDirectory[] result;
    foreach (row; statement.execute())
    {
        auto parent = row.peek!(Nullable!long)(1);
        result ~= RepositoryDirectory(row.peek!long(0), parent.isNull ? 0 : parent.get,
            row.peek!string(2), row.peek!string(3), cast(size_t) row.peek!long(4),
            cast(size_t) row.peek!long(5), cast(ulong) row.peek!long(6));
    }
    return result;
}

/** Count root children and aggregate repository size without loading file rows. */
RepositoryRootSummary loadRootSummaryFromDatabase(ref Database db)
{
    auto result = db.execute("SELECT "
        ~ "(SELECT count(*) FROM directories WHERE parent_id IS NULL), "
        ~ "(SELECT count(*) FROM file_refs WHERE directory_id IS NULL AND "
        ~ "NOT (" ~ isVirtualFileReferenceSql("relative_path") ~ ")), "
        ~ "COALESCE((SELECT sum(b.file_size) FROM file_refs f "
        ~ "JOIN blobs b ON b.id = f.blob_id WHERE "
        ~ "NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ")), 0)");
    auto row = result.front;
    return RepositoryRootSummary(cast(size_t) row.peek!long(0),
        cast(size_t) row.peek!long(1), cast(ulong) row.peek!long(2));
}

private string directoryFilterSql(RepositoryDirectoryQuery options)
{
    if (options.text.empty && !options.video && !options.audio && !options.image
        && !options.textStream && !options.fileType && !options.archive
        && !options.torrent && !options.availableOnly)
        return "";

    string sql = " AND EXISTS (WITH RECURSIVE subtree(id) AS (SELECT d.id UNION ALL "
        ~ "SELECT child.id FROM directories child JOIN subtree s ON child.parent_id = s.id) "
        ~ "SELECT 1 FROM file_refs f JOIN blobs b ON b.id = f.blob_id "
        ~ "WHERE f.directory_id IN (SELECT id FROM subtree)";
    if (!options.includeArchiveMembers)
        sql ~= " AND NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ")";
    if (!options.text.empty)
        sql ~= options.caseSensitive
            ? " AND instr(f.relative_path, :directory_text) > 0"
            : " AND instr(lower(f.relative_path), lower(:directory_text)) > 0";
    if (options.availableOnly)
        sql ~= " AND f.exists_on_disk = 1";

    string[] media;
    if (options.video) media ~= "EXISTS (SELECT 1 FROM media_video_streams x WHERE x.blob_id = b.id)";
    if (options.audio) media ~= "EXISTS (SELECT 1 FROM media_audio_streams x WHERE x.blob_id = b.id)";
    if (options.image) media ~= "EXISTS (SELECT 1 FROM media_image_streams x WHERE x.blob_id = b.id)";
    if (options.textStream) media ~= "EXISTS (SELECT 1 FROM media_text_streams x WHERE x.blob_id = b.id)";
    if (media.length > 0)
        sql ~= options.mediaNegated ? " AND NOT (" ~ media.join(" OR ") ~ ")"
            : " AND (" ~ media.join(" OR ") ~ ")";

    string[] other;
    if (options.fileType) other ~= "(b.file_type IS NOT NULL AND length(b.file_type) > 0)";
    if (options.archive) other ~= "EXISTS (SELECT 1 FROM metadata_status a "
        ~ "WHERE a.blob_id = b.id AND a.metadata_kind = 'archives' "
        ~ "AND a.state IN ('completed', 'empty'))";
    if (options.torrent) other ~= "EXISTS (SELECT 1 FROM torrent_info t WHERE t.blob_id = b.id)";
    if (other.length > 0)
        sql ~= " AND (" ~ other.join(" OR ") ~ ")";
    return sql ~ ")";
}

private void bindDirectoryFilter(ref Statement statement, RepositoryDirectoryQuery options)
{
    if (!options.text.empty)
        statement.bind(":directory_text", options.text);
}

/** List immediate file references without materializing blob details. */
RepositoryFile[] listFilesFromDatabase(ref Database db, RepositoryFileQuery options)
{
    return listFilesPageFromDatabase(db, options).files;
}

/** List one keyset-paged file chunk and report continuation state. */
RepositoryFilePage listFilesPageFromDatabase(ref Database db, RepositoryFileQuery options)
{
    auto sql = "SELECT f.id, COALESCE(f.directory_id, 0), f.blob_id, "
        ~ "f.relative_path, f.time_last_modified, f.exists_on_disk, b.file_size, "
        ~ "(b.file_type IS NOT NULL AND length(b.file_type) > 0), "
        ~ "EXISTS (SELECT 1 FROM media_signatures ms WHERE ms.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_video_streams mv WHERE mv.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_audio_streams ma WHERE ma.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_image_streams mi WHERE mi.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_text_streams mt WHERE mt.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM metadata_status ar WHERE ar.blob_id = b.id "
        ~ "AND ar.metadata_kind = 'archives' AND ar.state IN ('completed', 'empty')), "
        ~ "EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.blob_id = b.id), "
        ~ "CASE WHEN " ~ isVirtualFileReferenceSql("f.relative_path") ~ " "
        ~ "THEN 1 ELSE 0 END, 0, 0, 0, 0, '' FROM file_refs f "
        ~ "JOIN blobs b ON b.id = f.blob_id WHERE ";
    /* Do not wrap the column in COALESCE: that would disable
     * idx_file_refs_directory. Zero means the root (NULL) directory. */
    sql ~= options.directoryId == 0
        ? "f.directory_id IS NULL"
        : "f.directory_id = :directory_id";
    if (!options.includeArchiveMembers)
        sql ~= " AND NOT (" ~ isVirtualFileReferenceSql("f.relative_path") ~ ")";
    if (!options.text.empty)
        sql ~= options.caseSensitive ? " AND instr(f.relative_path, :text) > 0"
            : " AND instr(lower(f.relative_path), lower(:text)) > 0";
    if (options.availableOnly)
        sql ~= " AND f.exists_on_disk = 1";
    string[] mediaConditions;
    if (options.video)
        mediaConditions ~= "EXISTS (SELECT 1 FROM media_video_streams mv WHERE mv.blob_id = b.id)";
    if (options.audio)
        mediaConditions ~= "EXISTS (SELECT 1 FROM media_audio_streams ma WHERE ma.blob_id = b.id)";
    if (options.image)
        mediaConditions ~= "EXISTS (SELECT 1 FROM media_image_streams mi WHERE mi.blob_id = b.id)";
    if (options.textStream)
        mediaConditions ~= "EXISTS (SELECT 1 FROM media_text_streams mt WHERE mt.blob_id = b.id)";
    if (mediaConditions.length > 0)
        sql ~= options.mediaNegated ? " AND NOT (" ~ mediaConditions.join(" OR ") ~ ")"
            : " AND (" ~ mediaConditions.join(" OR ") ~ ")";

    string[] otherConditions;
    if (options.fileType)
        otherConditions ~= "(b.file_type IS NOT NULL AND length(b.file_type) > 0)";
    if (options.archive)
        otherConditions ~= "EXISTS (SELECT 1 FROM metadata_status ar "
            ~ "WHERE ar.blob_id = b.id AND ar.metadata_kind = 'archives' "
            ~ "AND ar.state IN ('completed', 'empty'))";
    if (options.torrent)
        otherConditions ~= "EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.blob_id = b.id)";
    if (otherConditions.length > 0)
        sql ~= " AND (" ~ otherConditions.join(" OR ") ~ ")";
    if (!options.afterPath.empty)
    {
        auto pathOperator = options.beforeCursor ? "<" : ">";
        auto sizeOperator = options.beforeCursor ? "<" : ">";
        final switch (options.sortOrder)
        {
        case RepositoryFileSortOrder.pathAscending:
            sql ~= " AND (f.relative_path " ~ pathOperator ~ " :after_path OR (f.relative_path = :after_path AND f.id "
                ~ (options.beforeCursor ? "<" : ">") ~ " :after_id))";
            break;
        case RepositoryFileSortOrder.pathDescending:
            sql ~= " AND (f.relative_path " ~ (options.beforeCursor ? ">" : "<")
                ~ " :after_path OR (f.relative_path = :after_path AND f.id "
                ~ (options.beforeCursor ? ">" : "<") ~ " :after_id))";
            break;
        case RepositoryFileSortOrder.sizeAscending:
            sql ~= " AND (b.file_size " ~ sizeOperator ~ " :after_size OR (b.file_size = :after_size AND "
                ~ "(f.relative_path " ~ pathOperator ~ " :after_path OR (f.relative_path = :after_path AND f.id "
                ~ (options.beforeCursor ? "<" : ">") ~ " :after_id))))";
            break;
        case RepositoryFileSortOrder.sizeDescending:
            sql ~= " AND (b.file_size " ~ (options.beforeCursor ? ">" : "<") ~ " :after_size OR "
                ~ "(b.file_size = :after_size AND (f.relative_path " ~ pathOperator
                ~ " :after_path OR (f.relative_path = :after_path AND f.id "
                ~ (options.beforeCursor ? "<" : ">") ~ " :after_id))))";
            break;
        }
    }
    final switch (options.sortOrder)
    {
    case RepositoryFileSortOrder.pathAscending:
        sql ~= options.beforeCursor ? " ORDER BY f.relative_path DESC, f.id DESC"
            : " ORDER BY f.relative_path ASC, f.id ASC";
        break;
    case RepositoryFileSortOrder.pathDescending:
        sql ~= options.beforeCursor ? " ORDER BY f.relative_path ASC, f.id ASC"
            : " ORDER BY f.relative_path DESC, f.id DESC";
        break;
    case RepositoryFileSortOrder.sizeAscending:
        sql ~= options.beforeCursor ? " ORDER BY b.file_size DESC, f.relative_path DESC, f.id DESC"
            : " ORDER BY b.file_size ASC, f.relative_path ASC, f.id ASC";
        break;
    case RepositoryFileSortOrder.sizeDescending:
        sql ~= options.beforeCursor ? " ORDER BY b.file_size ASC, f.relative_path DESC, f.id DESC"
            : " ORDER BY b.file_size DESC, f.relative_path ASC, f.id ASC";
        break;
    }
    sql ~= " LIMIT :limit";
    auto statement = db.prepare(sql);
    if (options.directoryId != 0)
        statement.bind(":directory_id", options.directoryId);
    if (!options.text.empty)
        statement.bind(":text", options.text);
    if (!options.afterPath.empty)
    {
        statement.bind(":after_path", options.afterPath);
        statement.bind(":after_id", options.afterId);
        if (options.sortOrder == RepositoryFileSortOrder.sizeAscending
            || options.sortOrder == RepositoryFileSortOrder.sizeDescending)
            statement.bind(":after_size", cast(long) options.afterSize);
    }
    auto sqlLimit = options.limit == size_t.max ? -1L : cast(long) options.limit + 1;
    statement.bind(":limit", sqlLimit);

    RepositoryFilePage page;
    foreach (row; statement.execute())
    {
        auto modified = row.peek!(Nullable!string)(4);
        auto file = RepositoryFile(row.peek!long(0), row.peek!long(1), row.peek!long(2),
            "", row.peek!string(3), cast(ulong) row.peek!long(6),
            modified.isNull ? "" : modified.get, row.peek!long(5) != 0,
            row.peek!long(7) != 0, row.peek!long(8) != 0, row.peek!long(9) != 0,
            row.peek!long(10) != 0, row.peek!long(11) != 0, row.peek!long(12) != 0,
            row.peek!long(13) != 0, row.peek!long(14) != 0,
            row.peek!long(15) != 0, row.peek!long(16), row.peek!long(17),
            row.peek!long(18), cast(size_t) row.peek!long(19),
            row.peek!string(20));
        page.files ~= hydrateVirtualFileReference(db, file);
    }
    if (page.files.length > options.limit)
    {
        page.hasMore = true;
        page.files = page.files[0 .. options.limit];
    }
    if (options.beforeCursor)
        reverse(page.files);
    if (page.hasMore && page.files.length > 0)
    {
        auto cursorFile = options.beforeCursor ? page.files[0] : page.files[$ - 1];
        page.nextCursor = RepositoryFileCursor(cursorFile.relativePath,
            cursorFile.id, cursorFile.size);
    }
    return page;
}

private RepositoryFile hydrateVirtualFileReference(ref Database db,
    RepositoryFile file)
{
    const auto parsed = parseArchiveVirtualPath(file.relativePath);
    if (!parsed.isVirtual)
    {
        file.name = baseName(parsed.physicalPath);
        return file;
    }

    const auto finalLayer = parsed.entries[$ - 1];
    const auto parentPath = parentArchivePath(file.relativePath);
    auto parent = db.execute("SELECT id, blob_id, relative_path FROM file_refs "
        ~ "WHERE relative_path = ?", parentPath);
    file.name = baseName(finalLayer.relativePath);
    file.archiveMember = true;
    file.archiveEntryId = file.id;
    file.archiveEntryIndex = file.id > 0 ? cast(size_t) file.id : 0;
    file.archiveContainerIdentity = archiveReferenceIdentityForPath(db,
        parentPath);
    if (!parent.empty)
    {
        file.containerReferenceId = parent.front.peek!long(0);
        file.archiveContainerBlobId = parent.front.peek!long(1);
    }
    return file;
}

private string archiveReferenceIdentityForPath(ref Database db, string path,
    size_t depth = 0)
{
    enforce(depth < 32, "Archive reference identity exceeds the maximum depth.");
    auto result = db.execute("SELECT id FROM file_refs WHERE relative_path = ?",
        path);
    if (result.empty)
        return "";
    const auto parsed = parseArchiveVirtualPath(path);
    if (!parsed.isVirtual)
        return "p" ~ result.front.peek!long(0).to!string;
    const auto parentIdentity = archiveReferenceIdentityForPath(db,
        parentArchivePath(path), depth + 1);
    return parentIdentity ~ ":" ~ result.front.peek!long(0).to!string;
}

/** Load one physical reference by its stable repository ID. */
RepositoryFile loadFileReferenceFromDatabase(ref Database db, long fileReferenceId)
{
    auto result = db.execute("SELECT f.id, COALESCE(f.directory_id, 0), f.blob_id, "
        ~ "f.relative_path, f.time_last_modified, f.exists_on_disk, b.file_size, "
        ~ "(b.file_type IS NOT NULL AND length(b.file_type) > 0), "
        ~ "EXISTS (SELECT 1 FROM media_signatures ms WHERE ms.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_video_streams mv WHERE mv.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_audio_streams ma WHERE ma.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_image_streams mi WHERE mi.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM media_text_streams mt WHERE mt.blob_id = b.id), "
        ~ "EXISTS (SELECT 1 FROM metadata_status ar WHERE ar.blob_id = b.id "
        ~ "AND ar.metadata_kind = 'archives' AND ar.state IN ('completed', 'empty')), "
        ~ "EXISTS (SELECT 1 FROM torrent_info ti WHERE ti.blob_id = b.id) "
        ~ "FROM file_refs f JOIN blobs b ON b.id = f.blob_id WHERE f.id = ?",
        fileReferenceId);
    if (result.empty)
        return RepositoryFile.init;
    auto row = result.front;
    auto modified = row.peek!(Nullable!string)(4);
    auto file = RepositoryFile(row.peek!long(0), row.peek!long(1), row.peek!long(2),
        "", row.peek!string(3),
        cast(ulong) row.peek!long(6), modified.isNull ? "" : modified.get,
        row.peek!long(5) != 0, row.peek!long(7) != 0,
        row.peek!long(8) != 0, row.peek!long(9) != 0,
        row.peek!long(10) != 0, row.peek!long(11) != 0,
        row.peek!long(12) != 0, row.peek!long(13) != 0,
        row.peek!long(14) != 0, false, 0, 0, 0, 0, "");
    return hydrateVirtualFileReference(db, file);
}

/** List archive entries for one blob without loading the complete blob. */
RepositoryArchiveEntry[] listArchiveEntriesFromDatabase(ref Database db,
    RepositoryArchiveQuery options)
{
    string[] containerPaths;
    foreach (row; db.execute("SELECT relative_path FROM file_refs WHERE blob_id = ? "
        ~ "ORDER BY relative_path", options.blobId))
        containerPaths ~= row.peek!string(0).idup;
    RepositoryArchiveEntry[] allEntries;
    bool[string] seenIdentity;
    foreach (row; db.execute("SELECT f.id, f.relative_path, f.time_last_modified, "
        ~ "b.id, b.file_size, b.md5, b.sha1, b.xxh64 FROM file_refs f "
        ~ "JOIN blobs b ON b.id = f.blob_id ORDER BY f.relative_path"))
    {
        const auto path = row.peek!string(1);
        ParsedArchiveVirtualPath parsed;
        try
            parsed = parseArchiveVirtualPath(path);
        catch (Exception)
            continue;
        if (!parsed.isVirtual || !containerPaths.canFind(parentArchivePath(path)))
            continue;
        const auto layer = parsed.entries[$ - 1];
        const auto identity = layer.relativePath ~ "\0"
            ~ (layer.hasOccurrence ? layer.occurrence.to!string : "0");
        if (identity in seenIdentity)
            continue;
        seenIdentity[identity] = true;
        RepositoryArchiveEntry entry;
        entry.id = row.peek!long(0);
        entry.containerBlobId = options.blobId;
        entry.entryIndex = allEntries.length;
        entry.occurrence = layer.hasOccurrence ? layer.occurrence : 0;
        entry.name = layer.relativePath;
        entry.relativePath = layer.relativePath;
        entry.hasSafePath = true;
        entry.size = cast(ulong) row.peek!long(4);
        const auto modified = row.peek!(Nullable!string)(2);
        entry.modifiedAt = modified.isNull ? "" : modified.get.idup;
        entry.checkSums.md5sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(5));
        entry.checkSums.sha1sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(6));
        entry.checkSums.xxh64sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(7));
        entry.contentBlobId = row.peek!long(3);
        allEntries ~= entry;
    }
    const auto start = options.offset < allEntries.length
        ? options.offset : allEntries.length;
    const auto end = options.limit > allEntries.length - start
        ? allEntries.length : start + options.limit;
    auto result = allEntries[start .. end];
    return result;
}

/** Load one stable archive-index row without knowing its container blob first. */
RepositoryArchiveEntry loadArchiveEntryFromDatabase(ref Database db,
    long archiveEntryId)
{
    auto result = db.execute("SELECT f.id, f.blob_id, f.relative_path, "
        ~ "f.time_last_modified, b.file_size, b.md5, b.sha1, b.xxh64 "
        ~ "FROM file_refs f JOIN blobs b ON b.id = f.blob_id WHERE f.id = ?",
        archiveEntryId);
    if (result.empty)
        return RepositoryArchiveEntry.init;
    auto row = result.front;
    ParsedArchiveVirtualPath parsed;
    try
        parsed = parseArchiveVirtualPath(row.peek!string(2));
    catch (Exception)
        return RepositoryArchiveEntry.init;
    if (!parsed.isVirtual)
        return RepositoryArchiveEntry.init;
    const auto layer = parsed.entries[$ - 1];
    const auto containerPath = parentArchivePath(row.peek!string(2));
    auto container = db.execute("SELECT blob_id FROM file_refs WHERE relative_path = ?",
        containerPath);
    RepositoryArchiveEntry entry;
    entry.id = row.peek!long(0);
    entry.containerBlobId = container.empty ? 0
        : container.front.peek!long(0);
    entry.entryIndex = cast(size_t) row.peek!long(0);
    entry.occurrence = layer.hasOccurrence ? layer.occurrence : 0;
    entry.name = layer.relativePath;
    entry.relativePath = layer.relativePath;
    entry.hasSafePath = true;
    entry.size = cast(ulong) row.peek!long(4);
    const auto modified = row.peek!(Nullable!string)(3);
    entry.modifiedAt = modified.isNull ? "" : modified.get;
    entry.checkSums.md5sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(5));
    entry.checkSums.sha1sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(6));
    entry.checkSums.xxh64sum_b64 = decodeBase64(row.peek!(Nullable!Blob)(7));
    entry.contentBlobId = row.peek!long(1);
    return entry;
}

/** List torrent files for one blob without loading torrent metadata. */
RepositoryTorrentFile[] listTorrentFilesFromDatabase(ref Database db,
    RepositoryTorrentQuery options)
{
    auto statement = db.prepare("SELECT id, relative_path, file_size "
        ~ "FROM torrent_files WHERE torrent_blob_id = ? ORDER BY file_index "
        ~ "LIMIT ? OFFSET ?");
    statement.bind(1, options.blobId);
    statement.bind(2, cast(long) options.limit);
    statement.bind(3, cast(long) options.offset);
    RepositoryTorrentFile[] result;
    foreach (row; statement.execute())
        result ~= RepositoryTorrentFile(row.peek!long(0), row.peek!string(1),
            cast(ulong) row.peek!long(2));
    return result;
}

/** Load a bounded filtered page and retain its blob IDs. */
RepositoryBlobPage loadCatalogQueryPageWithIdsFromDatabase(ref Database db,
    string rootPath, RepositoryQueryOptions options, JsonExportOptions exportOptions)
{
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
    foreach (blobId; blobIds)
    {
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
    if (options.text.empty && !options.video && !options.audio && !options.image
        && !options.textStream && !options.fileType && !options.archive
        && !options.torrent)
        return db.execute("SELECT count(*) FROM blobs").oneValue!long;
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
            ~ (options.caseSensitive ? "AND instr(f.relative_path, :text) > 0)"
                : "AND instr(lower(f.relative_path), lower(:text)) > 0)");
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
    if (!options.text.empty)
        statement.bind(":text", options.text);
    if (sha1Search.length == 20)
        statement.bind(":sha1", cast(Blob) sha1Search);
    if (paged)
    {
        auto limit = options.useCursor && options.limit < size_t.max
            ? cast(long) options.limit + 1
            : options.limit == size_t.max ? -1L : cast(long) options.limit;
        statement.bind(":limit", limit);
        if (options.useCursor && options.afterBlobId > 0)
            statement.bind(":after_blob_id", options.afterBlobId);
        else if (!options.useCursor)
            statement.bind(":offset", cast(long) options.offset);
    }
    return statement;
}

/** Load one blob and all related details by stable database ID. */
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
    auto paths = loadFileSpecs(db, blobId, rootPath, options);
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
        loadMediaInfo(db, blobId, blob);
        if (options.includeArchiveEntries)
            loadArchiveIndexState(db, blobId, blob);
        loadTorrentInfo(db, blobId, blob, options.includeTorrentFiles);
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
    flags.hasArchive = !db.execute("SELECT 1 FROM metadata_status "
        ~ "WHERE blob_id = ? AND metadata_kind = 'archives' "
        ~ "AND state IN ('completed', 'empty')", blobId).empty;
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

private bool hasPhysicalFileReference(NamedBinaryBlob blob)
{
    foreach (spec; blob.fileSpecs)
    {
        if (spec is null || spec.fileName.empty)
            continue;
        try
        {
            if (!parseArchiveVirtualPath(spec.fileName).isVirtual)
                return true;
        }
        catch (Exception)
            return true;
    }
    return false;
}

private void persistImportedArchiveStatuses(ref Database db,
    ImportedArchiveIndex[] archiveIndexes)
{
    string[] referencePaths;
    foreach (row; db.execute("SELECT relative_path FROM file_refs"))
        referencePaths ~= row.peek!string(0).idup;

    foreach (archive; archiveIndexes)
    {
        bool hasEntries;
        foreach (row; db.execute("SELECT relative_path FROM file_refs "
            ~ "WHERE blob_id = ?", archive.blobId))
        {
            auto containerPath = row.peek!string(0);
            foreach (candidate; referencePaths)
                if (parentArchivePath(candidate) == containerPath)
                {
                    hasEntries = true;
                    break;
                }
            if (hasEntries)
                break;
        }
        const auto state = hasEntries ? "completed" : "empty";
        const auto extractorVersion = archiveIndexVersion
            ~ (archive.deep ? ":deep" : ":shallow");
        db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
            ~ "extractor_version, scanned_at, error_message) VALUES (?, 'archives', "
            ~ "?, ?, ?, NULL) ON CONFLICT(blob_id, metadata_kind) DO UPDATE SET "
            ~ "state = excluded.state, extractor_version = excluded.extractor_version, "
            ~ "scanned_at = excluded.scanned_at, error_message = NULL",
            archive.blobId, state, extractorVersion, currentTimestamp());
    }
}

private string parentArchivePath(string path)
{
    ParsedArchiveVirtualPath parsed;
    try
        parsed = parseArchiveVirtualPath(path);
    catch (Exception)
        return "";
    if (parsed.entries.length == 0)
        return "";
    auto result = escapeArchiveVirtualPath(parsed.physicalPath);
    foreach (entry; parsed.entries[0 .. $ - 1])
        result = appendArchiveVirtualPath(result, entry.relativePath,
            entry.hasOccurrence ? entry.occurrence : size_t.max);
    return result;
}

private long insertBlob(ref Database db, string rootPath, NamedBinaryBlob blob)
{
    auto md5 = encodeBase64(blob.checkSums.md5sum_b64);
    auto sha1 = encodeBase64(blob.checkSums.sha1sum_b64);
    auto xxh64 = encodeBase64(blob.checkSums.xxh64sum_b64);
    db.execute("INSERT INTO blobs "
        ~ "(file_size, md5, sha1, xxh64, file_type) VALUES (?, ?, ?, ?, ?)",
        cast(long) blob.fileSize, md5, sha1, xxh64, blob.fileType);
    auto id = db.lastInsertRowid;

    if (!blob.archivePassword.empty)
        db.execute("INSERT INTO archive_passwords (blob_id, password) VALUES (?, ?)",
            id, blob.archivePassword);

    foreach (spec; blob.fileSpecs)
    {
        if (spec is null || spec.fileName.empty)
            continue;
        auto parsed = parseArchiveVirtualPath(spec.fileName);
        const auto physicalRelativePath = repositoryRelativePath(rootPath,
            parsed.physicalPath);
        string relative;
        Nullable!long directoryId;
        if (parsed.isVirtual)
        {
            relative = escapeArchiveVirtualPath(physicalRelativePath);
            foreach (entry; parsed.entries)
                relative = appendArchiveVirtualPath(relative, entry.relativePath,
                    entry.hasOccurrence ? entry.occurrence : size_t.max);
            auto physicalReference = db.execute("SELECT directory_id FROM file_refs "
                ~ "WHERE relative_path = ?", escapeArchiveVirtualPath(
                    physicalRelativePath));
            enforce(!physicalReference.empty,
                "JSON v5 archive member has no physical container reference: "
                ~ spec.fileName);
            directoryId = physicalReference.front.peek!(Nullable!long)(0);
        }
        else
        {
            relative = escapeArchiveVirtualPath(physicalRelativePath);
            const auto directory = ensureDirectory(db,
                dirName(physicalRelativePath));
            if (directory > 0)
                directoryId = Nullable!long(directory);
        }
        if (directoryId.isNull)
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
                id, directoryId.get, relative, spec.timeLastModified,
                currentTimestamp());
        }
    }

    insertMediaInfo(db, id, blob.mediaInfoSig);
    insertTorrentInfo(db, id, blob.torrentInfo);
    return id;
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

private void loadArchiveIndexState(ref Database db, long blobId,
    ref NamedBinaryBlob blob)
{
    auto result = db.execute("SELECT state, extractor_version FROM metadata_status "
        ~ "WHERE blob_id = ? AND metadata_kind = 'archives'", blobId);
    if (result.empty)
        return;
    auto row = result.front;
    const auto state = row.peek!string(0);
    if (state != "completed" && state != "empty")
        return;
    blob.archiveIndexKnown = true;
    const auto extractorVersion = row.peek!(Nullable!string)(1);
    if (!extractorVersion.isNull)
        blob.archiveIndexDeep = extractorVersion.get.endsWith(":deep");
}

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

@("repository transfer queries")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");

    db.execute("INSERT INTO directories (id, parent_id, relative_path, name) "
        ~ "VALUES (1, NULL, 'archives', 'archives')");
    db.execute("INSERT INTO blobs (id, file_size, file_type) VALUES "
        ~ "(1, 128, 'application/zip'), "
        ~ "(2, 11, NULL), "
        ~ "(3, 32, NULL)");
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(1, 1, 1, 'archives/container.zip', '2026-01-01T00:00:00', 1, ?), "
        ~ "(2, 2, 1, 'archives/container.zip!/nested/readme.txt', "
        ~ "'2026-01-01T00:00:00', 1, ?), "
        ~ "(3, 3, NULL, 'root.txt', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00", "2026-01-01T00:00:00",
        "2026-01-01T00:00:00");
    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
        ~ "extractor_version, scanned_at, error_message) VALUES "
        ~ "(1, 'archives', 'completed', ?, ?, NULL)",
        archiveIndexVersion ~ ":deep", "2026-01-01T00:00:00");
    db.execute("INSERT INTO torrent_info (blob_id, name, magnet_uri, total_size, "
        ~ "is_multi_file, info_hash_hex, announce, piece_length, pieces_count) "
        ~ "VALUES (3, 'demo.torrent', '', 7, 1, '', '', 16384, 1)");
    db.execute("INSERT INTO torrent_files (id, torrent_blob_id, file_index, "
        ~ "relative_path, file_size) VALUES (1, 3, 0, 'files/part1.bin', 7)");

    auto rootSummary = loadRootSummaryFromDatabase(db);
    assert(rootSummary.childDirectoryCount == 1);
    assert(rootSummary.fileCount == 1);
    assert(rootSummary.aggregateSize == 160);

    auto directories = listDirectoriesFromDatabase(db,
        RepositoryDirectoryQuery(0, 0, 10));
    assert(directories.length == 1);
    assert(directories[0].relativePath == "archives");

    auto filesWithoutMembers = listFilesPageFromDatabase(db,
        RepositoryFileQuery(1, 0, 10));
    assert(filesWithoutMembers.files.length == 1);
    assert(filesWithoutMembers.files[0].relativePath == "archives/container.zip");

    auto filesWithMembers = listFilesPageFromDatabase(db,
        RepositoryFileQuery(1, 0, 10, "", false, false, false, false, false,
            false, false, false, false, false, true));
    assert(filesWithMembers.files.length == 2);
    assert(filesWithMembers.files[1].archiveMember);
    assert(filesWithMembers.files[1].archiveContainerBlobId == 1);

    auto archiveEntry = loadArchiveEntryFromDatabase(db, 2);
    assert(archiveEntry.id == 2);
    assert(archiveEntry.containerBlobId == 1);
    assert(archiveEntry.entryIndex == 2);
    assert(archiveEntry.name == "nested/readme.txt");

    auto archiveEntries = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 0, 10));
    assert(archiveEntries.length == 1);
    assert(archiveEntries[0].containerBlobId == 1);
    assert(archiveEntries[0].name == "nested/readme.txt");

    auto torrentFiles = listTorrentFilesFromDatabase(db,
        RepositoryTorrentQuery(3, 0, 10));
    assert(torrentFiles.length == 1);
    assert(torrentFiles[0].relativePath == "files/part1.bin");

    auto blob = loadCatalogFromDatabase(db, "/repo",
        JsonExportOptions("", false, true, true, true, true));
    assert(blob.length == 3);
    assert(blob[0].fileSpecs.length == 1);
    assert(blob[0].archiveIndexKnown);
    assert(blob[1].fileSpecs.length == 1);
    assert(blob[2].torrentInfo !is null);
}

private string currentTimestamp()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toISOExtString;
}
