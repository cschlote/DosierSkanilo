/** Canonical JSON-v5 import/export and read projections over the normalized
 * repository. Legacy v0-v4 catalogs are upgraded during import.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.transfer;

import d2sqlite3;

import std.algorithm : reverse, startsWith;
import std.algorithm.searching : canFind;
import std.array : join;
import std.base64 : Base64;
import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, isAbsolute;
import std.string : empty, endsWith, replace, split;
import std.typecons : Nullable;

import dosierskanilo.logging : logLine, logLineVerbose;
import dosierarkivo.archive : appendArchiveVirtualPath, archiveIndexVersion,
    archivePathFilterSql, archivePathSeparator, escapeArchiveVirtualPath,
    nativePathToStoragePath, parseArchiveVirtualPath,
    ParsedArchiveVirtualPath;
import dosierskanilo.metadata.mediainfosig;
import dosierskanilo.operations : OperationControl, OperationKind,
    OperationPhase, OperationProgress, OperationState;
import dosierskanilo.progress : ProgressCallBack;
import dosierskanilo.service.storageio : writeStorageJsonFile;
import dosierskanilo.metadata.torrentinfo;
import dosierskanilo.model.namedbinaryblob;
import dosierskanilo.repository.archiveindex : deleteUnreachableBlobs,
    isVirtualFileReferenceSql, resolveArchiveMemberBlobLinks;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.schema : migrate;
import dosierskanilo.repository.types;

/** Archive index state queued for import, keyed by the inserted blob ID. */
private struct ImportedArchiveIndex
{
    /// Database ID of the blob whose archive index was scanned.
    long blobId;
    /// True when the stored index came from a deep scan.
    bool deep;
}

/** Import a JSON catalog into an open repository database.
 *
 * Existing catalog rows are replaced; appending is not implemented.
 *
 * Params:
 *     db = Open repository database that receives the imported data.
 *     rootPath = Repository root used to make catalog paths relative.
 *     jsonFile = Path of the JSON catalog to import.
 *     options = Import options, including the existing-data replacement mode.
 * Throws: `RepositoryException` when append mode is requested; catalog read,
 *     parse and database write failures propagate.
 */
void importCatalogJson(ref Database db, string rootPath, string jsonFile,
    JsonImportOptions options)
{
    importCatalogJsonControlled(db, rootPath, jsonFile, options, null, 0);
}

/**
 * Import a JSON catalog with cooperative cancellation.
 *
 * Params:
 *     db = Open repository database that receives the imported data.
 *     rootPath = Repository root used to make catalog paths relative.
 *     jsonFile = Path of the JSON catalog to import.
 *     options = Import options, including the existing-data replacement mode.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Identifier reported with progress events.
 * Returns: `true` when the import committed; `false` when cancellation was
 *     requested, in which case the transaction is rolled back and no imported
 *     row is visible.
 * Throws: `RepositoryException` when append mode is requested; catalog read,
 *     parse and database write failures propagate.
 */
bool importCatalogJsonControlled(ref Database db, string rootPath,
    string jsonFile, JsonImportOptions options, OperationControl control,
    ulong operationId)
{
    ProgressCallBack progress;
    if (control !is null)
        progress.contextual = (size_t completed, size_t total) {
            reportImportProgress(control, operationId,
                OperationPhase.jsonRead, completed, total,
                "Reading JSON catalog.");
        };
    auto catalog = deserializeDataClassJsonWrapperFile(jsonFile,
        control is null ? null : &progress);
    if (!options.replaceExisting)
        throw new RepositoryException("Appending JSON data is not implemented yet.");
    upgradeDataClassCatalogToV5(catalog);
    if (control !is null && control.cancellationRequested)
        return false;

    try
    {
        db.begin();
        clearCatalog(db);

        const size_t total = catalog.dataArray.length;
        size_t processed;
        reportImportProgress(control, operationId, OperationPhase.jsonWrite,
            0, total, "Importing JSON catalog.");

        ImportedArchiveIndex[] archiveIndexes;
        ImportReferenceStats referenceStats;
        long[] blobIds;
        blobIds.length = catalog.dataArray.length;

        /* Insert every content record before any reference. A blob can carry
         * both physical and virtual specs, and a virtual member may sort before
         * its container. Splitting the passes prevents order-dependent
         * "missing physical container" failures. */
        foreach (index, blob; catalog.dataArray)
        {
            if (blob is null)
                continue;
            const auto blobId = insertBlobRecord(db, blob);
            blobIds[index] = blobId;
            if (blob.archiveIndexKnown)
                archiveIndexes ~= ImportedArchiveIndex(blobId,
                    blob.archiveIndexDeep);
            if (control !is null)
            {
                if (control.cancellationRequested)
                {
                    db.rollback();
                    return false;
                }
                if (++processed % 512 == 0)
                    reportImportProgress(control, operationId,
                        OperationPhase.jsonWrite, processed, total,
                        "Importing JSON catalog.");
            }
        }

        foreach (index, blob; catalog.dataArray)
        {
            if (blob is null)
                continue;
            foreach (spec; blob.fileSpecs)
            {
                if (spec is null || spec.fileName.empty)
                    continue;
                ParsedArchiveVirtualPath parsed;
                try
                    parsed = parseImportPath(rootPath, spec.fileName);
                catch (Exception)
                    continue;
                if (parsed.isVirtual)
                    continue;
                insertFileReference(db, rootPath, blobIds[index], blob, spec,
                    parsed, referenceStats);
            }
            if (control !is null && control.cancellationRequested)
            {
                db.rollback();
                return false;
            }
        }

        struct VirtualReferenceWork
        {
            long blobId;
            NamedBinaryBlob blob;
            FileSpec spec;
            ParsedArchiveVirtualPath parsed;
            size_t depth;
        }

        import std.algorithm.sorting : sort;
        VirtualReferenceWork[] virtualWork;
        foreach (index, blob; catalog.dataArray)
        {
            if (blob is null)
                continue;
            foreach (spec; blob.fileSpecs)
            {
                if (spec is null || spec.fileName.empty)
                    continue;
                ParsedArchiveVirtualPath parsed;
                try
                    parsed = parseImportPath(rootPath, spec.fileName);
                catch (Exception)
                    continue;
                if (!parsed.isVirtual)
                    continue;
                virtualWork ~= VirtualReferenceWork(blobIds[index], blob, spec,
                    parsed, parsed.entries.length);
            }
        }
        virtualWork.sort!((left, right) => left.depth < right.depth);
        if (virtualWork.length > 0 && control !is null)
            reportImportProgress(control, operationId, OperationPhase.jsonWrite,
                processed, total, "Linking archive members.");
        foreach (work; virtualWork)
        {
            insertFileReference(db, rootPath, work.blobId, work.blob, work.spec,
                work.parsed, referenceStats);
            if (control !is null && control.cancellationRequested)
            {
                db.rollback();
                return false;
            }
        }

        if (control !is null)
            reportImportProgress(control, operationId, OperationPhase.jsonWrite,
                processed, total,
                "Finalizing import: archive links and cleanup.");
        import core.time : MonoTime;
        auto phaseStarted = MonoTime.currTime;
        persistImportedArchiveStatuses(db, archiveIndexes);
        logLineVerbose("[import] archive statuses elapsedMs=",
            cast(long) (MonoTime.currTime - phaseStarted).total!"msecs");
        phaseStarted = MonoTime.currTime;
        resolveArchiveMemberBlobLinks(db);
        logLineVerbose("[import] archive member links elapsedMs=",
            cast(long) (MonoTime.currTime - phaseStarted).total!"msecs");
        phaseStarted = MonoTime.currTime;
        deleteUnreachableBlobs(db);
        logLineVerbose("[import] unreachable blobs elapsedMs=",
            cast(long) (MonoTime.currTime - phaseStarted).total!"msecs");

        phaseStarted = MonoTime.currTime;
        db.execute("UPDATE repository SET updated_at = ?, "
            ~ "media_info_version = ?, file_utility_version = ? WHERE id = 1",
            currentTimestamp(), catalog.mediaInfoVersion,
            catalog.fileUtilityVersion);
        if (control !is null)
        {
            reportImportProgress(control, operationId, OperationPhase.jsonWrite,
                processed, total, "Importing JSON catalog.");
            if (control.cancellationRequested)
            {
                db.rollback();
                return false;
            }
        }
        if (referenceStats.identicalSkipped > 0
            || referenceStats.richerReplaced > 0
            || referenceStats.conflictSkipped > 0
            || referenceStats.outsideSkipped > 0)
            logLine("Import references: ", referenceStats.identicalSkipped,
                " identical duplicates skipped, ",
                referenceStats.richerReplaced, " stale references replaced, ",
                referenceStats.conflictSkipped, " conflicts kept first, ",
                referenceStats.outsideSkipped,
                " outside the repository root skipped.");
        phaseStarted = MonoTime.currTime;
        db.commit();
        logLineVerbose("[import] commit elapsedMs=",
            cast(long) (MonoTime.currTime - phaseStarted).total!"msecs");
        return true;
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

/** Report catalog-import progress when a control is attached.
 *
 * Params:
 *     control = Optional operation control; a null control reports nothing.
 *     operationId = Identifier carried by the progress event.
 *     phase = Import phase carried by the progress event.
 *     completed = Completed work units.
 *     total = Total work units.
 *     message = Human-readable progress message.
 */
private void reportImportProgress(OperationControl control, ulong operationId,
    OperationPhase phase, size_t completed, size_t total, string message)
{
    if (control is null)
        return;
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = OperationKind.catalogImport;
    progress.state = OperationState.running;
    progress.phase = phase;
    progress.completed = completed;
    progress.total = total;
    progress.totalKnown = true;
    progress.message = message;
    control.report(progress);
}

/** Export repository data as the current JSON catalog format.
 *
 * Params:
 *     db = Open repository database to read.
 *     rootPath = Repository root used to resolve physical paths.
 *     jsonFile = Destination path of the JSON catalog.
 *     options = Export options such as pretty-printing and path form.
 * Throws: `CatalogWriteException` when the canonical catalog cannot be
 *     written and only a recovery file is produced.
 */
void exportCatalogJson(ref Database db, string rootPath, string jsonFile,
    JsonExportOptions options)
{
    exportCatalogJsonControlled(db, rootPath, jsonFile, options, null, 0);
}

/** Export repository data with cooperative cancellation.
 *
 * Params:
 *     db = Open repository database to read.
 *     rootPath = Repository root used to resolve physical paths.
 *     jsonFile = Destination path of the JSON catalog.
 *     options = Export options such as pretty-printing and path form.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Identifier reported with progress events.
 * Returns: `false` when cancellation was requested or the canonical catalog
 *     could not be written (for example a recovery-only write). The detailed
 *     write outcome is available through the storage layer logs.
 */
bool exportCatalogJsonControlled(ref Database db, string rootPath,
    string jsonFile, JsonExportOptions options, OperationControl control,
    ulong operationId)
{
    if (control !is null && control.cancellationRequested)
        return false;
    auto blobs = loadCatalogFromDatabase(db, rootPath, options);
    if (control !is null && control.cancellationRequested)
        return false;
    auto wrapper = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, blobs);
    return writeStorageJsonFile(jsonFile, wrapper, ".json", currentTimestamp(),
        "", () {
            if (control is null)
                return false;
            reportExportProgress(control, operationId, 0, blobs.length,
                "Writing JSON catalog.");
            return control.cancellationRequested;
        }, options.prettyJson);
}

/** Report catalog-export progress when a control is attached.
 *
 * Params:
 *     control = Optional operation control; a null control reports nothing.
 *     operationId = Identifier carried by the progress event.
 *     completed = Completed work units.
 *     total = Total work units.
 *     message = Human-readable progress message.
 */
private void reportExportProgress(OperationControl control, ulong operationId,
    size_t completed, size_t total, string message)
{
    if (control is null)
        return;
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = OperationKind.catalogExport;
    progress.state = OperationState.running;
    progress.phase = OperationPhase.jsonWrite;
    progress.completed = completed;
    progress.total = total;
    progress.totalKnown = true;
    progress.message = message;
    control.report(progress);
}

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

/** List immediate child directories without materializing the catalog.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Parent selection, filters and page bounds.
 * Returns: Matching directories ordered by relative path; empty when the parent
 *     has no matching children.
 */
RepositoryDirectory[] listDirectoriesFromDatabase(ref Database db,
    RepositoryDirectoryQuery options)
{
    auto statement = db.prepare(
        "SELECT d.id, d.parent_id, d.name, d.relative_path, "
        ~         "(SELECT count(*) FROM directories child WHERE child.parent_id = d.id), "
        ~ "(SELECT count(*) FROM file_refs f JOIN blobs b ON b.id = f.blob_id "
        ~ "WHERE f.directory_id = d.id" ~ directoryFileFilterSql(options) ~ "), "
        ~ "COALESCE((SELECT sum(b.file_size) FROM file_refs f "
        ~ "JOIN blobs b ON b.id = f.blob_id WHERE "
        ~ "(f.relative_path = d.relative_path "
        ~ "OR (f.relative_path >= d.relative_path || '/' "
        ~ "AND f.relative_path < d.relative_path || '0')) "
        ~ directoryFileFilterSql(options) ~ "), 0) "
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

/** Count all physical file references in the repository.
 *
 * Archive members are excluded.
 *
 * Params:
 *     db = Open repository database to read.
 * Returns: The number of stored physical file references.
 */
size_t countPhysicalFileReferences(ref Database db)
{
    auto result = db.execute("SELECT count(*) FROM file_refs WHERE "
        ~ "NOT (" ~ isVirtualFileReferenceSql("relative_path") ~ ")");
    return cast(size_t) result.front.peek!long(0);
}

/** Count root children and aggregate repository size without loading file rows.
 *
 * Params:
 *     db = Open repository database to read.
 * Returns: Root directory count, physical root-file count and aggregate size
 *     across all physical file references.
 */
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

/** Build the SQL fragment that filters file references for directory listings.
 *
 * Params:
 *     options = Directory query filters to translate.
 *     fileAlias = SQL alias of the `file_refs` table.
 *     blobAlias = SQL alias of the joined `blobs` table.
 * Returns: A fragment starting with " AND" for each active filter, or an empty
 *     string when no file-level filter is active.
 */
private string directoryFileFilterSql(RepositoryDirectoryQuery options,
    string fileAlias = "f", string blobAlias = "b")
{
    string sql;
    if (!options.includeArchiveMembers)
        sql ~= " AND NOT (" ~ isVirtualFileReferenceSql(fileAlias ~ ".relative_path") ~ ")";
    if (!options.text.empty)
        sql ~= " AND " ~ archivePathFilterSql(fileAlias ~ ".relative_path",
            ":directory_text", options.caseSensitive);
    if (options.availableOnly)
        sql ~= " AND " ~ fileAlias ~ ".exists_on_disk = 1";

    string[] media;
    if (options.video) media ~= "EXISTS (SELECT 1 FROM media_video_streams x WHERE x.blob_id = " ~ blobAlias ~ ".id)";
    if (options.audio) media ~= "EXISTS (SELECT 1 FROM media_audio_streams x WHERE x.blob_id = " ~ blobAlias ~ ".id)";
    if (options.image) media ~= "EXISTS (SELECT 1 FROM media_image_streams x WHERE x.blob_id = " ~ blobAlias ~ ".id)";
    if (options.textStream) media ~= "EXISTS (SELECT 1 FROM media_text_streams x WHERE x.blob_id = " ~ blobAlias ~ ".id)";
    if (media.length > 0)
        sql ~= options.mediaNegated ? " AND NOT (" ~ media.join(" OR ") ~ ")"
            : " AND (" ~ media.join(" OR ") ~ ")";

    string[] other;
    if (options.fileType) other ~= "(" ~ blobAlias ~ ".file_type IS NOT NULL AND length("
        ~ blobAlias ~ ".file_type) > 0)";
    if (options.archive) other ~= "EXISTS (SELECT 1 FROM metadata_status a "
        ~ "WHERE a.blob_id = " ~ blobAlias ~ ".id AND a.metadata_kind = 'archives' "
        ~ "AND a.state IN ('completed', 'empty'))";
    if (options.torrent) other ~= "EXISTS (SELECT 1 FROM torrent_info t WHERE t.blob_id = "
        ~ blobAlias ~ ".id)";
    if (other.length > 0)
        sql ~= " AND (" ~ other.join(" OR ") ~ ")";
    return sql;
}

/** Build the SQL fragment that keeps only directories with matching descendants.
 *
 * Params:
 *     options = Directory query filters to translate.
 * Returns: A recursive `EXISTS` fragment starting with " AND", or an empty
 *     string when no descendant filter is active.
 */
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
        sql ~= " AND " ~ archivePathFilterSql("f.relative_path",
            ":directory_text", options.caseSensitive);
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

/** Bind the text parameter used by the directory filter fragments.
 *
 * Params:
 *     statement = Prepared directory query statement.
 *     options = Directory query filters whose text is bound when non-empty.
 */
private void bindDirectoryFilter(ref Statement statement, RepositoryDirectoryQuery options)
{
    if (!options.text.empty)
        statement.bind(":directory_text", options.text);
}

/** List immediate file references without materializing blob details.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Directory selection, filters and page bounds.
 * Returns: The matching file references in query order; empty when nothing
 *     matches.
 */
RepositoryFile[] listFilesFromDatabase(ref Database db, RepositoryFileQuery options)
{
    return listFilesPageFromDatabase(db, options).files;
}

/** Convert a page size to a SQLite LIMIT value; -1 means "all rows".
 *
 * Params:
 *     limit = Requested page size.
 *     fetchExtra = Reserve room for one look-ahead row when true.
 * Returns: The LIMIT value, or -1 when `limit` is effectively unbounded.
 */
private long pageLimitSql(size_t limit, bool fetchExtra = false)
{
    if (limit >= cast(size_t) long.max)
        return -1L;
    const auto value = cast(long) limit;
    return fetchExtra ? value + 1 : value;
}

/** List one keyset-paged file chunk and report continuation state.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Directory selection, filters, sort order and cursor state.
 * Returns: The page of file references with `hasMore` and, when a further page
 *     exists, an opaque `nextCursor`; empty when nothing matches.
 */
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
        sql ~= " AND " ~ archivePathFilterSql("f.relative_path", ":text",
            options.caseSensitive);
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
    const useOffset = options.afterPath.empty && options.offset > 0;
    if (useOffset)
        sql ~= " OFFSET :offset";
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
    statement.bind(":limit", pageLimitSql(options.limit, true));
    if (useOffset)
        statement.bind(":offset", cast(long) options.offset);

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

/** Populate display fields for a file reference, resolving archive members.
 *
 * Every reference gets a display name. A virtual archive member additionally
 * receives its container reference, blob ID and stable identity, looked up from
 * the parent path.
 *
 * Params:
 *     db = Open repository database.
 *     file = File reference with at least its path populated.
 * Returns: The same reference with its display and archive fields filled in.
 */
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

/** Build the stable identity of the reference stored at `path`.
 *
 * Physical references use a "p" prefix followed by their row ID; virtual
 * references prefix their parent identity and append their own row ID.
 *
 * Params:
 *     db = Open repository database.
 *     path = Stored reference path to resolve.
 *     depth = Current recursion depth used as a guard.
 * Returns: The identity string, or an empty string when no reference exists at
 *     `path`.
 * Throws: `Exception` when nesting exceeds the supported depth of 32.
 */
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

/** Load one physical reference by its stable repository ID.
 *
 * Params:
 *     db = Open repository database to read.
 *     fileReferenceId = Stable `file_refs.id` value to load.
 * Returns: The populated reference, or `RepositoryFile.init` when no such row
 *     exists.
 */
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

/** List archive entries for one blob without loading the complete blob.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Container blob ID plus page offset and limit.
 * Returns: Deduplicated archive entries ordered by stored path; empty when the
 *     blob has no virtual members or the page is beyond them.
 */
RepositoryArchiveEntry[] listArchiveEntriesFromDatabase(ref Database db,
    RepositoryArchiveQuery options)
{
    string[] containerPaths;
    foreach (row; db.execute("SELECT relative_path FROM file_refs WHERE blob_id = ? "
        ~ "ORDER BY relative_path", options.blobId))
        containerPaths ~= row.peek!string(0).idup;

    if (containerPaths.length == 0 || options.limit == 0)
        return [];

    /* Container ranges live in a temporary table. This avoids two SQL bind
     * variables per reference and lets SQLite apply the page limit after
     * identity deduplication. */
    db.execute("DROP TABLE IF EXISTS temp.archive_container_prefixes");
    db.execute("CREATE TEMP TABLE archive_container_prefixes ("
        ~ "prefix TEXT PRIMARY KEY, upper TEXT NOT NULL)");
    scope (exit)
        db.execute("DROP TABLE IF EXISTS temp.archive_container_prefixes");
    auto insert = db.prepare("INSERT OR IGNORE INTO "
        ~ "temp.archive_container_prefixes (prefix, upper) VALUES (?, ?)");
    foreach (containerPath; containerPaths)
    {
        /* Stored reference paths are already in canonical display grammar. */
        const prefix = containerPath ~ archivePathSeparator();
        insert.inject(prefix, prefix[0 .. $ - 1] ~ "0");
        insert.reset();
    }

    RepositoryArchiveEntry[] result;
    auto statement = db.prepare(
        "SELECT MIN(f.id), MIN(f.relative_path), f.time_last_modified, "
        ~ "b.id, b.file_size, b.md5, b.sha1, b.xxh64, "
        ~ "substr(f.relative_path, length(p.prefix) + 1) AS member_key "
        ~ "FROM file_refs f JOIN blobs b ON b.id = f.blob_id "
        ~ "JOIN temp.archive_container_prefixes p "
        ~ "ON f.relative_path >= p.prefix AND f.relative_path < p.upper "
        ~ "WHERE " ~ isVirtualFileReferenceSql("f.relative_path") ~ " "
        ~ "GROUP BY member_key ORDER BY member_key LIMIT ? OFFSET ?");
    statement.bind(1, cast(long) options.limit);
    statement.bind(2, cast(long) options.offset);
    foreach (row; statement.execute())
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
        RepositoryArchiveEntry entry;
        entry.id = row.peek!long(0);
        entry.containerBlobId = options.blobId;
        entry.entryIndex = options.offset + result.length;
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
        result ~= entry;
    }
    return result;
}

/** Load one stable archive-index row without knowing its container blob first.
 *
 * Params:
 *     db = Open repository database to read.
 *     archiveEntryId = Stable `file_refs.id` value of the archive entry.
 * Returns: The populated entry, or `RepositoryArchiveEntry.init` when the row
 *     is missing or is not a virtual archive reference.
 */
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

/** List torrent files for one blob without loading torrent metadata.
 *
 * Params:
 *     db = Open repository database to read.
 *     options = Torrent blob ID plus page offset and limit.
 * Returns: The requested torrent file entries in file-index order; empty when
 *     the torrent has no files or the page is beyond them.
 */
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

/** Delete all catalog rows from the repository.
 *
 * Removes file references, directories and blobs, but leaves repository-level
 * settings such as the schema version untouched.
 *
 * Params:
 *     db = Open repository database inside the import transaction.
 */
private void clearCatalog(ref Database db)
{
    db.execute("DELETE FROM file_refs");
    db.execute("DELETE FROM directories");
    db.execute("DELETE FROM blobs");
}

/** Write archive-index metadata rows for imported containers.
 *
 * A container is marked "completed" when any imported virtual reference names
 * it as its parent, and "empty" otherwise. The extractor version records
 * whether the index came from a shallow or deep scan.
 *
 * Params:
 *     db = Open repository database inside the import transaction.
 *     archiveIndexes = Imported containers whose state is persisted.
 */
private void persistImportedArchiveStatuses(ref Database db,
    ImportedArchiveIndex[] archiveIndexes)
{
    if (archiveIndexes.length == 0)
        return;

    /* Collect parent container paths of virtual references once. The previous
     * nested loop compared every archive index against every file reference,
     * which became quadratic on large catalogs. */
    bool[string] archiveParents;
    foreach (row; db.execute("SELECT relative_path FROM file_refs WHERE "
        ~ isVirtualFileReferenceSql("relative_path")))
    {
        const parent = parentArchivePath(row.peek!string(0));
        if (parent.length > 0)
            archiveParents[parent] = true;
    }

    foreach (archive; archiveIndexes)
    {
        bool hasEntries;
        foreach (row; db.execute("SELECT relative_path FROM file_refs "
            ~ "WHERE blob_id = ?", archive.blobId))
            if (row.peek!string(0) in archiveParents)
            {
                hasEntries = true;
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

/** Return the container path that holds a virtual archive reference.
 *
 * Params:
 *     path = Stored archive path, possibly virtual.
 * Returns: The parent container path, or an empty string when `path` is not a
 *     parseable virtual path or has no parent layer.
 */
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

/** Reference-conflict counters collected during one catalog import. */
private struct ImportReferenceStats
{
    /// References skipped because an identical reference already existed.
    size_t identicalSkipped;
    /// Existing references replaced by a richer reference.
    size_t richerReplaced;
    /// References skipped because an incompatible reference kept its place.
    size_t conflictSkipped;
    /// References skipped because they lay outside the repository root.
    size_t outsideSkipped;
}

/** Insert one blob and its optional password, media and torrent metadata.
 *
 * Params:
 *     db = Open repository database inside the import transaction.
 *     blob = Catalog record to store.
 * Returns: The database ID assigned to the inserted blob row.
 */
private long insertBlobRecord(ref Database db, NamedBinaryBlob blob)
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
    insertMediaInfo(db, id, blob.mediaInfoSig);
    insertTorrentInfo(db, id, blob.torrentInfo);
    return id;
}

/** Decode a stored path and fold double-escaped archive members back into
 * their container when no literal `!` directory exists below the root.
 *
 * Params:
 *     rootPath = Repository root used to test the literal physical path.
 *     path = Stored path to parse.
 * Returns: The parsed path, re-parsed without the extra escape when that
 *     recovers an archive member; the original parse is kept when the literal
 *     path exists or re-parsing fails.
 */
private ParsedArchiveVirtualPath parseImportPath(string rootPath, string path)
{
    auto parsed = parseArchiveVirtualPath(path);
    if (parsed.isVirtual
        || !parsed.physicalPath.canFind(archivePathSeparator()))
        return parsed;
    const auto literal = isAbsolute(parsed.physicalPath)
        ? buildNormalizedPath(parsed.physicalPath)
        : buildPath(buildNormalizedPath(rootPath), parsed.physicalPath);
    bool literalExists;
    try
        literalExists = exists(literal);
    catch (Exception)
    {
    }
    if (literalExists)
        return parsed;
    try
        return parseArchiveVirtualPath(parsed.physicalPath);
    catch (Exception)
        return parsed;
}

/** Insert or reconcile one file reference during import.
 *
 * A new path is inserted once; an existing path is compared by size and
 * digests. The richer reference replaces a stale or incomplete one, while an
 * incompatible duplicate keeps the existing reference and increments the
 * conflict counter. Paths outside the repository root are skipped.
 *
 * Params:
 *     db = Open repository database inside the import transaction.
 *     rootPath = Repository root used to make physical paths relative.
 *     id = Blob ID that owns the reference.
 *     blob = Catalog record supplying size and digests.
 *     spec = Reference metadata, including its stored path.
 *     parsed = Parsed form of the reference path.
 *     stats = Import counters updated in place.
 * Throws: `Exception` when a virtual member has no physical container
 *     reference in the catalog.
 */
private void insertFileReference(ref Database db, string rootPath, long id,
    NamedBinaryBlob blob, FileSpec spec, ParsedArchiveVirtualPath parsed,
    ref ImportReferenceStats stats)
{
    string physicalRelativePath;
    if (!tryRepositoryRelativePath(rootPath, parsed.physicalPath,
            physicalRelativePath))
    {
        ++stats.outsideSkipped;
        return;
    }
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

    const auto md5 = encodeBase64(blob.checkSums.md5sum_b64);
    const auto sha1 = encodeBase64(blob.checkSums.sha1sum_b64);
    const auto xxh64 = encodeBase64(blob.checkSums.xxh64sum_b64);
    enum conflictSuffix = " ON CONFLICT(relative_path) DO NOTHING";
    if (directoryId.isNull)
    {
        db.execute("INSERT INTO file_refs "
            ~ "(blob_id, relative_path, time_last_modified, "
            ~ "exists_on_disk, last_seen_at) VALUES (?, ?, ?, 1, ?)"
            ~ conflictSuffix,
            id, relative, spec.timeLastModified, currentTimestamp());
    }
    else
    {
        db.execute("INSERT INTO file_refs "
            ~ "(blob_id, directory_id, relative_path, time_last_modified, "
            ~ "exists_on_disk, last_seen_at) VALUES (?, ?, ?, ?, 1, ?)"
            ~ conflictSuffix,
            id, directoryId.get, relative, spec.timeLastModified,
            currentTimestamp());
    }
    if (db.changes != 0)
        return;

    auto existing = db.execute("SELECT f.blob_id, b.file_size, b.md5, "
        ~ "b.sha1, b.xxh64 FROM file_refs f JOIN blobs b ON b.id = f.blob_id "
        ~ "WHERE f.relative_path = ?", relative);
    if (existing.empty)
        return;
    auto row = existing.front;
    const auto existingBlobId = row.peek!long(0);
    if (existingBlobId == id)
    {
        ++stats.identicalSkipped;
        return;
    }
    const auto existingSize = cast(ulong) row.peek!long(1);
    auto existingMd5 = row.peek!(Nullable!Blob)(2);
    auto existingSha1 = row.peek!(Nullable!Blob)(3);
    auto existingXxh64 = row.peek!(Nullable!Blob)(4);
    const bool sameContent = existingSize == blob.fileSize
        && existingMd5 == md5 && existingSha1 == sha1
        && existingXxh64 == xxh64;
    if (sameContent)
    {
        ++stats.identicalSkipped;
        return;
    }
    const bool existingComplete = !existingMd5.isNull
        && !existingSha1.isNull && !existingXxh64.isNull;
    const bool richer = (blob.checkSums.hasDigests && !existingComplete)
        || (existingSize == 0 && blob.fileSize > 0);
    if (richer)
    {
        db.execute("UPDATE file_refs SET blob_id = ?, "
            ~ "time_last_modified = ?, last_seen_at = ? "
            ~ "WHERE relative_path = ?", id, spec.timeLastModified,
            currentTimestamp(), relative);
        ++stats.richerReplaced;
        return;
    }
    logLineVerbose("Skipping conflicting duplicate file reference '",
        relative, "' (kept blob ", existingBlobId, ")");
    ++stats.conflictSkipped;
}

/** Ensure all directory rows for a relative path exist.
 *
 * Directory paths share the escaped namespace with file references.
 *
 * Params:
 *     db = Open repository database inside the import transaction.
 *     relativeDirectory = Relative directory path to create.
 * Returns: ID of the deepest directory, or 0 for the root/empty path.
 */
private long ensureDirectory(ref Database db, string relativeDirectory)
{
    if (relativeDirectory.empty || relativeDirectory == ".")
        return 0;

    auto normalized = repositoryRelativePath("", relativeDirectory);
    long parentId;
    string current;
    string canonical;
    foreach (part; normalized.split("/"))
    {
        if (part.empty || part == ".")
            continue;
        current = current.empty ? part : current ~ "/" ~ part;
        /* Directory identities share the escaped namespace with file
         * references. Keeping the raw path here would break prefix queries
         * below a directory whose name contains an exclamation mark. */
        canonical = escapeArchiveVirtualPath(current);
        if (parentId == 0)
        {
            db.execute("INSERT OR IGNORE INTO directories "
                ~ "(parent_id, relative_path, name) VALUES (NULL, ?, ?)",
                canonical, part);
        }
        else
        {
            db.execute("INSERT OR IGNORE INTO directories "
                ~ "(parent_id, relative_path, name) VALUES (?, ?, ?)",
                parentId, canonical, part);
        }
        parentId = db.execute("SELECT id FROM directories "
            ~ "WHERE relative_path = ?", canonical).oneValue!long;
    }
    return parentId;
}

/** Convert a path to repository-relative form when it lies inside the root.
 *
 * Params:
 *     rootPath = Repository root; an empty root rejects absolute paths.
 *     path = Path to convert, in native or absolute form.
 *     relative = Receives the storage-form relative path on success.
 * Returns: `true` when `path` is relative or lies below `rootPath`; `false`
 *     when it equals or lies outside the root.
 */
private bool tryRepositoryRelativePath(string rootPath, string path,
    out string relative)
{
    import std.algorithm.searching : startsWith;

    auto normalized = nativePathToStoragePath(buildNormalizedPath(path));
    if (!isAbsolute(normalized))
    {
        relative = normalized;
        return true;
    }
    if (rootPath.empty)
        return false;
    auto normalizedRoot = nativePathToStoragePath(buildNormalizedPath(rootPath));
    if (normalized == normalizedRoot)
        return false;
    const auto prefix = normalizedRoot == "/" ? "/" : normalizedRoot ~ "/";
    if (!normalized.startsWith(prefix))
        return false;
    relative = normalized[prefix.length .. $];
    return true;
}

/** Convert a path to repository-relative form, rejecting paths outside the root.
 *
 * Params:
 *     rootPath = Repository root; an empty root keeps relative paths as-is.
 *     path = Path to convert.
 * Returns: The storage-form path relative to the root.
 * Throws: `RepositoryException` when the path equals the root or lies outside
 *     it.
 */
private string repositoryRelativePath(string rootPath, string path)
{
    auto normalized = nativePathToStoragePath(buildNormalizedPath(path));
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

/** Insert media signature and stream rows for one blob.
 *
 * Params:
 *     db = Open repository database inside the import transaction.
 *     blobId = Blob the media data belongs to.
 *     info = Media information to store; null or empty data inserts nothing.
 */
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

/** Insert torrent info and file rows for one blob.
 *
 * Params:
 *     db = Open repository database inside the import transaction.
 *     blobId = Blob the torrent data belongs to.
 *     info = Torrent metadata to store; null or empty data inserts nothing.
 *         Null file entries are skipped.
 */
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
    if (state != "completed" && state != "empty")
        return;
    blob.archiveIndexKnown = true;
    const auto extractorVersion = row.peek!(Nullable!string)(1);
    if (!extractorVersion.isNull)
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

/** Encode a stored binary digest as base64 text.
 *
 * Params:
 *     value = Binary digest to encode.
 * Returns: The base64 text, or an empty string when `value` is null or empty.
 */
private string decodeBase64(Nullable!Blob value)
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

/** Return the current local time as an ISO extended timestamp.
 *
 * Returns: The current clock value formatted for storage in timestamp columns.
 */
private string currentTimestamp()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toISOExtString;
}

@("SQLite archive ranges include non-BMP members and aggregates")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO directories (id, parent_id, relative_path, name) "
        ~ "VALUES (1, NULL, 'archives', 'archives')");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, 100), (2, 1), (3, 2)");
    db.execute("INSERT INTO file_refs (id, blob_id, directory_id, relative_path, "
        ~ "time_last_modified, exists_on_disk, last_seen_at) VALUES "
        ~ "(1, 1, 1, 'archives/emoji.zip', '2026-01-01T00:00:00', 1, ?), "
        ~ "(2, 2, 1, 'archives/emoji.zip!/😀.txt', '2026-01-01T00:00:00', 1, ?), "
        ~ "(3, 3, 1, 'archives/emoji.zip!/z.txt', '2026-01-01T00:00:00', 1, ?)",
        "2026-01-01T00:00:00", "2026-01-01T00:00:00",
        "2026-01-01T00:00:00");
    db.execute("INSERT INTO metadata_status (blob_id, metadata_kind, state, "
        ~ "extractor_version, scanned_at, error_message) VALUES "
        ~ "(1, 'archives', 'completed', ?, ?, NULL)",
        archiveIndexVersion ~ ":deep", "2026-01-01T00:00:00");

    auto entries = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 0, 10));
    assert(entries.length == 2);
    bool foundEmoji;
    bool foundZ;
    foreach (entry; entries)
    {
        foundEmoji = foundEmoji || entry.name == "😀.txt";
        foundZ = foundZ || entry.name == "z.txt";
    }
    assert(foundEmoji && foundZ);

    RepositoryDirectoryQuery directoryQuery;
    directoryQuery.limit = 10;
    directoryQuery.includeArchiveMembers = true;
    auto directories = listDirectoriesFromDatabase(db, directoryQuery);
    assert(directories.length == 1);
    assert(directories[0].fileCount == 3);
    assert(directories[0].aggregateSize == 103);
}

@("JSON import resolves duplicate file references")
unittest
{
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import dosierskanilo.model.filespec : FileSpec;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
        NamedBinaryBlob, NamedBinaryBlobCatalog, serializeDataClassWrapperFile;
    import dosierskanilo.repository.schema : migrate;

    const token = randomUUID().toString();
    const catalogPath = buildPath(tempDir(), "duplicate-import-" ~ token
        ~ ".json");
    scope (exit)
        if (exists(catalogPath))
            remove(catalogPath);

    auto first = new NamedBinaryBlob();
    first.fileSize = 1;
    first.fileSpecs = [new FileSpec("a.txt", ""),
        new FileSpec("dup.txt", "")];
    auto second = new NamedBinaryBlob();
    second.fileSize = 2;
    second.fileSpecs = [new FileSpec("b.txt", ""),
        new FileSpec("dup.txt", "")];
    auto stale = new NamedBinaryBlob();
    stale.fileSize = 0;
    stale.fileSpecs = [new FileSpec("c.txt", ""),
        new FileSpec("stale.txt", "")];
    auto fresh = new NamedBinaryBlob();
    fresh.fileSize = 9;
    fresh.fileSpecs = [new FileSpec("d.txt", ""),
        new FileSpec("stale.txt", "")];

    NamedBinaryBlobCatalog catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
        [first, second, stale, fresh]);
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    JsonImportOptions options;
    assert(importCatalogJsonControlled(db, tempDir(), catalogPath, options,
        null, 0));

    size_t referenceCount;
    long dupBlob;
    long staleBlob;
    foreach (row; db.execute("SELECT relative_path, blob_id FROM file_refs "
        ~ "ORDER BY relative_path"))
    {
        ++referenceCount;
        const relative = decodeNullableString(
            row.peek!(Nullable!string)(0));
        if (relative == "dup.txt")
            dupBlob = row.peek!long(1);
        if (relative == "stale.txt")
            staleBlob = row.peek!long(1);
    }
    assert(referenceCount == 6, referenceCount.to!string);
    assert(dupBlob != 0);
    assert(staleBlob != 0);
    assert(db.execute("SELECT file_size FROM blobs WHERE id = ?", dupBlob)
        .oneValue!long == 1, "first complete reference wins a conflict");
    assert(db.execute("SELECT file_size FROM blobs WHERE id = ?", staleBlob)
        .oneValue!long == 9, "a real reference replaces a stale zero-size one");
}

@("JSON import links virtual members when their blob also has a physical path")
unittest
{
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import dosierskanilo.model.filespec : FileSpec;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
        NamedBinaryBlob, NamedBinaryBlobCatalog, serializeDataClassWrapperFile;
    import dosierskanilo.repository.schema : migrate;

    const catalogPath = buildPath(tempDir(), "import-order-" ~ randomUUID()
        .toString() ~ ".json");
    scope (exit)
        if (exists(catalogPath))
            remove(catalogPath);

    auto container = new NamedBinaryBlob();
    container.fileSize = 10;
    container.fileSpecs = [new FileSpec("z.zip", "")];
    /* The first path sorts before the container, so the virtual member is
     * encountered before its physical container. */
    auto combined = new NamedBinaryBlob();
    combined.fileSize = 5;
    combined.fileSpecs = [new FileSpec("a.txt", ""),
        new FileSpec("z.zip!/member.txt", "")];
    NamedBinaryBlobCatalog catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
        [container, combined]);
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    JsonImportOptions options;
    assert(importCatalogJsonControlled(db, tempDir(), catalogPath, options,
        null, 0));
    assert(db.execute("SELECT count(*) FROM file_refs WHERE relative_path = ?",
        "z.zip!/member.txt").oneValue!long == 1);
    assert(db.execute("SELECT b.file_size FROM file_refs f JOIN blobs b "
        ~ "ON b.id = f.blob_id WHERE f.relative_path = ?",
        "z.zip!/member.txt").oneValue!long == 5);
}

@("JSON import folds double-escaped archive member paths")
unittest
{
    import std.file : exists, remove, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import dosierskanilo.model.filespec : FileSpec;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
        NamedBinaryBlob, NamedBinaryBlobCatalog, serializeDataClassWrapperFile;
    import dosierskanilo.repository.schema : migrate;

    const catalogPath = buildPath(tempDir(), "import-double-escaped-"
        ~ randomUUID().toString() ~ ".json");
    scope (exit)
        if (exists(catalogPath))
            remove(catalogPath);

    auto container = new NamedBinaryBlob();
    container.fileSize = 10;
    container.fileSpecs = [new FileSpec("archive.zip", "")];
    auto stale = new NamedBinaryBlob();
    stale.fileSize = 0;
    stale.fileSpecs = [new FileSpec("archive.zip!!/member.txt", "")];
    auto member = new NamedBinaryBlob();
    member.fileSize = 5;
    member.fileSpecs = [new FileSpec("archive.zip!/member.txt", "")];
    NamedBinaryBlobCatalog catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
        [container, stale, member]);
    serializeDataClassWrapperFile(catalogPath, catalog);

    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    JsonImportOptions options;
    assert(importCatalogJsonControlled(db, tempDir(), catalogPath, options,
        null, 0));
    assert(db.execute("SELECT count(*) FROM file_refs WHERE relative_path "
        ~ "LIKE '%!!%'").oneValue!long == 0);
    assert(db.execute("SELECT b.file_size FROM file_refs f JOIN blobs b "
        ~ "ON b.id = f.blob_id WHERE f.relative_path = ?",
        "archive.zip!/member.txt").oneValue!long == 5);
}

@("archive path SQL filters accept display and canonical spelling")
unittest
{
    auto db = Database(":memory:");
    db.execute("CREATE TABLE paths (path TEXT NOT NULL)");
    db.execute("INSERT INTO paths (path) VALUES (?)", "dir!!/clip!!.mp4");
    db.execute("INSERT INTO paths (path) VALUES (?)", "dir/clip.mp4");
    db.execute("INSERT INTO paths (path) VALUES (?)",
        "container.zip!/member!!.txt");
    auto statement = db.prepare("SELECT count(*) FROM paths WHERE "
        ~ archivePathFilterSql("path", ":text", false));
    statement.bind(":text", "dir!/clip!.mp4");
    assert(statement.execute().oneValue!long == 1);
    statement.reset();
    statement.bind(":text", "dir!!/clip!!.mp4");
    assert(statement.execute().oneValue!long == 1);
    statement.reset();
    statement.bind(":text", "container.zip!/member!.txt");
    assert(statement.execute().oneValue!long == 1);
    statement.reset();
    statement.bind(":text", "missing");
    assert(statement.execute().oneValue!long == 0);
}

@("archive entry listing paginates deduplicated container references")
unittest
{
    auto db = Database(":memory:");
    migrate(db, "2026-01-01T00:00:00");
    db.execute("INSERT INTO blobs (id, file_size) VALUES (1, 100), (2, 1), (3, 2)");
    db.execute("INSERT INTO file_refs (id, blob_id, relative_path, exists_on_disk) "
        ~ "VALUES (1, 1, 'archives/a.zip', 1), "
        ~ "(2, 2, 'archives/a.zip!/x.txt', 1), "
        ~ "(3, 3, 'archives/a.zip!/y.txt', 1), "
        ~ "(4, 1, 'archives/b.zip', 1), "
        ~ "(5, 2, 'archives/b.zip!/x.txt', 1)");

    auto first = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 0, 1));
    assert(first.length == 1);
    assert(first[0].name == "x.txt");
    assert(first[0].entryIndex == 0);

    auto second = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 1, 1));
    assert(second.length == 1);
    assert(second[0].name == "y.txt");
    assert(second[0].entryIndex == 1);

    auto empty = listArchiveEntriesFromDatabase(db,
        RepositoryArchiveQuery(1, 2, 1));
    assert(empty.length == 0);
}
