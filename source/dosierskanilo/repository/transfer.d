/** Canonical JSON-v5 import and export of the normalized repository.
 *
 * Legacy v0-v4 catalogs are upgraded during import. Cancellation publishes
 * nothing.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.transfer;

import d2sqlite3;
import std.algorithm : startsWith;
import std.algorithm.searching : canFind;
import std.array : join;
import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.path : buildNormalizedPath, buildPath, dirName, isAbsolute;
import std.string : empty, split;
import std.typecons : Nullable;
import core.time : MonoTime;
import dosierskanilo.logging : logLine, logLineVerbose;
import dosierarkivo.archive : appendArchiveVirtualPath, archiveIndexVersion,
    archivePathSeparator, escapeArchiveVirtualPath, nativePathToStoragePath,
    parseArchiveVirtualPath, ParsedArchiveVirtualPath;
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
import dosierskanilo.repository.catalogreads : loadCatalogFromDatabase,
    encodeBase64, decodeNullableString;

/** Archive index state queued for import, keyed by the inserted blob ID. */
private struct ImportedArchiveIndex
{
    /// Database ID of the blob whose archive index was scanned.
    long blobId;
    /// True when the stored index came from a deep scan.
    bool deep;
    /// Next descriptor index for a resumable partial index.
    size_t cursor;
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
                    blob.archiveIndexDeep, blob.archiveScanCursor);
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
        const auto state = archive.cursor > 0 ? "partial"
            : hasEntries ? "completed" : "empty";
        const auto extractorVersion = archive.cursor > 0
            ? archiveIndexVersion ~ ":partial:" ~ archive.cursor.to!string
            : archiveIndexVersion ~ (archive.deep ? ":deep" : ":shallow");
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
package string parentArchivePath(string path)
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

/** Return the current local time as an ISO extended timestamp.
 *
 * Returns: The current clock value formatted for storage in timestamp columns.
 */
package string currentTimestamp()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toISOExtString;
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
