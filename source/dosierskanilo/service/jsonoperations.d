/** Controlled scan, metadata, analysis, and persistence operations for explicit
 * JSON catalogs.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.service.jsonoperations;

import std.algorithm.searching : startsWith;
import std.datetime.systime;
import std.file : DirEntry, SpanMode, dirEntries, isFile;
import std.parallelism : Task, TaskPool, task;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, dirSeparator, isAbsolute;
import std.string : empty, endsWith, replace, split;
import std.conv : to;

import dosierarkivo.archive : appendArchiveVirtualPath,
    escapeArchiveVirtualPath, nativePathToStoragePath, parseArchiveVirtualPath,
    ParsedArchiveVirtualPath;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob,
    DATA_CLASS_VERSION5, NamedBinaryBlobCatalog,
    deserializeDataClassJsonWrapperFile, isCatalogFormatFailure,
    cleanupInvalidatedDataClassObjs, invalidateDataClassObjs, mergeDataClassObjects,
    updateArchives, updateDigests,
    updateFileType, updateMediaInfo, updateTorrentInfo;
import dosierskanilo.operations : OperationCallbackException, OperationControl,
    OperationKind, OperationPhase, OperationProgress, OperationState;
import dosierskanilo.operationlease : TargetCatalogReplacementLease;
import dosierskanilo.progress : ProgressCallBack;
import dosierskanilo.repository.types : AnalysisSummary, MetadataScanOptions,
    MetadataSummary, RepositoryAnalysisOptions, RepositoryScanOptions, ScanSummary;
import dosierskanilo.service.storageio : CatalogWriteException,
    writeCatalogJsonFile, writeStorageJsonFile;

/** Detached result of loading, scanning and enriching a JSON catalog. */
struct JsonScanExecutionResult
{
    NamedBinaryBlobCatalog catalog; ///< Updated catalog, or the input on cancellation.
    ScanSummary scanSummary; ///< Filesystem scan counters.
    MetadataSummary metadataSummary; ///< Scan-time metadata counters.
    AnalysisSummary analysisSummary; ///< Duplicate-merge counters.
    bool cancelled; ///< True when cooperative cancellation stopped the run.
}

/** Metadata-only result for an in-memory JSON catalog. */
struct JsonMetadataExecutionResult
{
    MetadataSummary summary; ///< Metadata counters.
    bool cancelled; ///< True when cooperative cancellation stopped the run.
}

/** Detached result of loading and analyzing a JSON catalog. */
struct JsonAnalysisExecutionResult
{
    NamedBinaryBlobCatalog catalog; ///< Updated catalog, or the input on cancellation.
    MetadataSummary metadataSummary; ///< Optional pre-analysis metadata counters.
    AnalysisSummary analysisSummary; ///< Duplicate/missing-file analysis counters.
    bool cancelled; ///< True when cooperative cancellation stopped the run.
}

/** Summaries of one scan applied directly to an in-memory catalog. */
struct JsonScanApplication
{
    ScanSummary scanSummary; ///< Filesystem scan counters.
    MetadataSummary metadataSummary; ///< Scan-time metadata counters.
    AnalysisSummary analysisSummary; ///< Duplicate-merge counters.
    bool cancelled; ///< True when cooperative cancellation stopped the run.
}

/** Summaries of one analysis applied directly to an in-memory catalog. */
struct JsonAnalysisApplication
{
    MetadataSummary metadataSummary; ///< Optional pre-analysis metadata counters.
    AnalysisSummary analysisSummary; ///< Duplicate/missing-file analysis counters.
    bool cancelled; ///< True when cooperative cancellation stopped the run.
}

/** Scan a filesystem into an already loaded catalog without writing it.
 *
 * Stored paths are made absolute for the scan and normalized back to the scan
 * root afterwards. Metadata extraction and optional duplicate merging update
 * the catalog in place.
 *
 * Params:
 *     catalog = Loaded catalog updated in place.
 *     filesystemRoot = Root directory to scan and base for stored paths.
 *     scanOptions = Filesystem traversal options.
 *     metadataOptions = Metadata extraction options.
 *     mergeDuplicates = Merge duplicate content after metadata extraction.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Identifier reported with progress events.
 * Returns: The scan, metadata and analysis summaries plus the cancellation
 *     state. On cancellation the catalog may already be partially updated.
 */
JsonScanApplication scanJsonCatalogInto(ref NamedBinaryBlobCatalog catalog,
    string filesystemRoot, RepositoryScanOptions scanOptions,
    MetadataScanOptions metadataOptions, bool mergeDuplicates,
    OperationControl control, ulong operationId)
{
    JsonScanApplication application;
    const bool pathsUseV5Grammar = catalog.dataVersion == DATA_CLASS_VERSION5;
    absolutizeJsonStoredPaths(catalog.dataArray, filesystemRoot,
        pathsUseV5Grammar);
    scope (exit)
        normalizeJsonCatalogPaths(catalog.dataArray, filesystemRoot,
            pathsUseV5Grammar);
    if (!scanJsonDirectory(filesystemRoot, scanOptions,
        catalog.dataVersion == DATA_CLASS_VERSION5,
        catalog.dataArray, control, operationId, application.scanSummary))
    {
        application.cancelled = true;
        return application;
    }
    auto metadata = updateJsonMetadata(catalog.dataArray,
        metadataOptions, OperationKind.scan, control, operationId);
    application.metadataSummary = metadata.summary;
    application.cancelled = metadata.cancelled;
    if (!application.cancelled && mergeDuplicates)
    {
        RepositoryAnalysisOptions analysisOptions;
        if (!analyzeJsonRecords(catalog.dataArray, analysisOptions,
            catalog.dataVersion == DATA_CLASS_VERSION5, OperationKind.scan,
            control, operationId, application.analysisSummary))
            application.cancelled = true;
    }
    return application;
}

/** Enrich an already loaded catalog with metadata and analysis, without writing.
 *
 * Stored paths are made absolute for the operation and normalized back to the
 * scan root afterwards.
 *
 * Params:
 *     catalog = Loaded catalog updated in place.
 *     filesystemRoot = Base directory used to resolve stored paths.
 *     metadataOptions = Metadata extraction options.
 *     analysisOptions = Missing-file and duplicate analysis options.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Identifier reported with progress events.
 * Returns: The metadata and analysis summaries plus the cancellation state. On
 *     cancellation the catalog may already be partially updated.
 */
JsonAnalysisApplication analyzeJsonCatalogInto(ref NamedBinaryBlobCatalog catalog,
    string filesystemRoot, MetadataScanOptions metadataOptions,
    RepositoryAnalysisOptions analysisOptions, OperationControl control,
    ulong operationId)
{
    JsonAnalysisApplication application;
    const bool pathsUseV5Grammar = catalog.dataVersion == DATA_CLASS_VERSION5;
    absolutizeJsonStoredPaths(catalog.dataArray, filesystemRoot,
        pathsUseV5Grammar);
    scope (exit)
        normalizeJsonCatalogPaths(catalog.dataArray, filesystemRoot,
            pathsUseV5Grammar);
    auto metadata = updateJsonMetadata(catalog.dataArray,
        metadataOptions, OperationKind.analyze, control, operationId);
    application.metadataSummary = metadata.summary;
    if (metadata.cancelled)
    {
        application.cancelled = true;
        return application;
    }
    if (!analyzeJsonRecords(catalog.dataArray, analysisOptions,
        catalog.dataVersion == DATA_CLASS_VERSION5,
        OperationKind.analyze, control, operationId,
        application.analysisSummary))
        application.cancelled = true;
    return application;
}

/** Load a JSON catalog, scan its filesystem root, and run selected extractors.
 *
 * Params:
 *     catalogPath = Path of the JSON catalog to load.
 *     filesystemRoot = Root directory to scan.
 *     forceOverwrite = Replace an unreadable or format-incompatible catalog
 *         with an empty one.
 *     scanOptions = Filesystem traversal options.
 *     metadataOptions = Metadata extraction options.
 *     mergeDuplicates = Merge duplicate content after metadata extraction.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Identifier reported with progress events.
 * Returns: The loaded and updated catalog together with the scan, metadata and
 *     analysis summaries and the cancellation state.
 * Throws: `Exception` for catalog read or parse failures that `forceOverwrite`
 *     must not mask.
 */
JsonScanExecutionResult scanJsonCatalog(string catalogPath, string filesystemRoot,
    bool forceOverwrite, RepositoryScanOptions scanOptions,
    MetadataScanOptions metadataOptions, bool mergeDuplicates,
    OperationControl control, ulong operationId)
{
    JsonScanExecutionResult execution;
    execution.catalog = loadJsonCatalog(catalogPath, forceOverwrite, control,
        OperationKind.scan, operationId);
    const application = scanJsonCatalogInto(execution.catalog, filesystemRoot,
        scanOptions, metadataOptions, mergeDuplicates, control, operationId);
    execution.scanSummary = application.scanSummary;
    execution.metadataSummary = application.metadataSummary;
    execution.analysisSummary = application.analysisSummary;
    execution.cancelled = application.cancelled;
    return execution;
}

/** Load and enrich a JSON catalog for an explicit JSON analysis operation.
 *
 * When `filesystemRoot` is empty, the catalog file's directory is used as the
 * path base.
 *
 * Params:
 *     catalogPath = Path of the JSON catalog to load.
 *     filesystemRoot = Base directory for stored paths; empty selects the
 *         catalog directory.
 *     forceOverwrite = Replace an unreadable or format-incompatible catalog
 *         with an empty one.
 *     metadataOptions = Metadata extraction options.
 *     analysisOptions = Missing-file and duplicate analysis options.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Identifier reported with progress events.
 * Returns: The loaded and updated catalog together with the metadata and
 *     analysis summaries and the cancellation state.
 * Throws: `Exception` for catalog read or parse failures that `forceOverwrite`
 *     must not mask.
 */
JsonAnalysisExecutionResult analyzeJsonCatalog(string catalogPath,
    string filesystemRoot, bool forceOverwrite, MetadataScanOptions metadataOptions,
    RepositoryAnalysisOptions analysisOptions, OperationControl control,
    ulong operationId)
{
    JsonAnalysisExecutionResult execution;
    execution.catalog = loadJsonCatalog(catalogPath, forceOverwrite, control,
        OperationKind.analyze, operationId);
    const auto baseRoot = filesystemRoot.length > 0
        ? filesystemRoot : dirName(catalogPath);
    const application = analyzeJsonCatalogInto(execution.catalog, baseRoot,
        metadataOptions, analysisOptions, control, operationId);
    execution.metadataSummary = application.metadataSummary;
    execution.analysisSummary = application.analysisSummary;
    execution.cancelled = application.cancelled;
    return execution;
}

/** Persist a computed JSON catalog after the final safe cancellation checkpoint.
 *
 * Params:
 *     catalogPath = Destination path of the JSON catalog.
 *     catalog = Catalog data to serialize.
 *     pretty = Pretty-print the JSON output when true.
 * Returns: `true` when the canonical catalog file was written.
 * Throws: `CatalogWriteException` when the write produced only a recovery
 *     file or otherwise failed.
 */
bool commitJsonCatalog(string catalogPath, ref NamedBinaryBlobCatalog catalog,
    bool pretty = false)
{
    return commitJsonCatalog(catalogPath, catalog, null, pretty);
}

/** Persist a JSON catalog while honoring cancellation during serialization.
 *
 * Params:
 *     catalogPath = Destination path of the JSON catalog.
 *     catalog = Catalog data to serialize.
 *     cancelCheck = Predicate polled during serialization; returning `true`
 *         requests cancellation.
 *     pretty = Pretty-print the JSON output when true.
 * Returns: `true` when the canonical catalog file was written; `false` when
 *     cancellation prevented the write.
 * Throws: `CatalogWriteException` when the write produced only a recovery
 *     file or otherwise failed.
 */
bool commitJsonCatalog(string catalogPath, ref NamedBinaryBlobCatalog catalog,
    bool delegate() cancelCheck, bool pretty = false)
{
    auto replacementLease = TargetCatalogReplacementLease.acquireJsonCatalog(
        catalogPath);
    scope (exit)
        replacementLease.release();
    return commitJsonCatalogUnderLease(catalogPath, catalog, cancelCheck, pretty);
}

/** Persist a JSON catalog while the caller already owns the replacement lease.
 *
 * This is the inner write used by `commitJsonCatalog` and by document sessions
 * that must re-check the on-disk fingerprint after acquiring the lease.
 *
 * Params:
 *     catalogPath = Destination path of the JSON catalog.
 *     catalog = Catalog data to serialize.
 *     cancelCheck = Predicate polled during serialization; may be null.
 *     pretty = Pretty-print the JSON output when true.
 * Returns: `true` when the canonical catalog file was written; `false` when
 *     cancellation prevented the write.
 * Throws: `CatalogWriteException` when the write produced only a recovery file
 *     or otherwise failed.
 */
package(dosierskanilo) bool commitJsonCatalogUnderLease(string catalogPath,
    ref NamedBinaryBlobCatalog catalog, bool delegate() cancelCheck,
    bool pretty = false)
{
    auto result = writeCatalogJsonFile(catalogPath, catalog, ".json",
        Clock.currTime.toISOExtString(), "", cancelCheck, pretty);
    if (result.cancelled)
        return false;
    if (result.written && !result.recovery)
        return true;
    throw new CatalogWriteException(result);
}

/** Load a JSON catalog for a controlled operation.
 *
 * A missing catalog file, or a format-incompatible catalog when
 * `forceOverwrite` is set, yields an empty version-5 catalog.
 *
 * Params:
 *     catalogPath = Path of the JSON catalog to read.
 *     forceOverwrite = Replace an unreadable or format-incompatible catalog
 *         with an empty one instead of propagating the error.
 *     control = Optional operation control used for progress and cancellation.
 *     operation = Operation kind reported in progress events.
 *     operationId = Identifier reported with progress events.
 * Returns: The loaded catalog, or an empty version-5 catalog when the file is
 *     absent or may be replaced.
 * Throws: `Exception` for read or parse failures that `forceOverwrite` must
 *     not mask.
 */
private NamedBinaryBlobCatalog loadJsonCatalog(string catalogPath,
    bool forceOverwrite, OperationControl control, OperationKind operation,
    ulong operationId)
{
    import std.file : exists;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5;

    ProgressCallBack progress;
    if (control !is null)
    {
        progress.contextual = (size_t completed, size_t total) {
            reportJsonProgress(control, operationId, operation,
                OperationPhase.jsonRead, completed, total, true,
                "Loading JSON catalog.", catalogPath);
        };
    }

    if (!exists(catalogPath))
        return NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, []);
    try
        return deserializeDataClassJsonWrapperFile(catalogPath,
            control is null ? null : &progress);
    catch (Exception ex)
    {
        if (!forceOverwrite || !isCatalogFormatFailure(ex))
            throw ex;
        return NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, []);
    }
}

/** Add all primary file paths of one blob to the scan lookup index.
 *
 * Params:
 *     byPath = Lookup map updated in place; existing keys are kept.
 *     blob = Catalog record whose file paths are indexed; null is ignored.
 */
private void indexBlobPaths(ref NamedBinaryBlob[string] byPath,
    NamedBinaryBlob blob)
{
    if (blob is null)
        return;
    foreach (spec; blob.fileSpecs)
        if (spec !is null && spec.fileName.length > 0
            && spec.fileName !in byPath)
            byPath[spec.fileName] = blob;
}

/** Add or refresh filesystem entries in an in-memory catalog.
 *
 * Existing blobs are matched by stored path. A changed file is either split
 * out of a merged blob into a fresh record or updated in place with its
 * derived metadata cleared.
 *
 * Params:
 *     root = Filesystem directory to scan.
 *     options = Recursion and hidden-file selection options.
 *     pathsUseV5Grammar = Store paths using the escaped v5 archive grammar.
 *     blobs = Catalog blob array updated in place.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Identifier reported with progress events.
 *     summary = Scan counters updated in place.
 * Returns: `true` when the scan completed; `false` when it was cancelled.
 */
private bool scanJsonDirectory(string root, RepositoryScanOptions options,
    bool pathsUseV5Grammar, ref NamedBinaryBlob[] blobs,
    OperationControl control, ulong operationId, ref ScanSummary summary)
{
    if (!reportJsonProgress(control, operationId, OperationKind.scan,
        OperationPhase.discovering, 0, 0, false, "Scanning filesystem.", ""))
        return false;

    NamedBinaryBlob[string] existingByPath;
    foreach (blob; blobs)
        indexBlobPaths(existingByPath, blob);

    foreach (DirEntry entry; dirEntries(root,
        options.recursive ? SpanMode.depth : SpanMode.shallow))
    {
        if (!options.pickHidden && hasHiddenPathComponent(root, entry.name))
            continue;
        if (isFile(entry.name))
        {
            summary.filesFound++;
            auto storedFileName = pathsUseV5Grammar
                ? escapeArchiveVirtualPath(nativePathToStoragePath(
                    absolutePath(entry.name)))
                : nativePathToStoragePath(absolutePath(entry.name));
            NamedBinaryBlob existing;
            if (auto indexed = storedFileName in existingByPath)
                existing = *indexed;
            else
            {
                foreach (blob; blobs)
                {
                    if (blob !is null && blob.hasFileName(storedFileName))
                    {
                        existing = blob;
                        break;
                    }
                }
            }

            if (existing is null)
            {
                auto added = new NamedBinaryBlob(storedFileName, entry.size,
                    entry.timeLastModified);
                added.fileSpecsUseArchiveVirtualGrammar = pathsUseV5Grammar;
                blobs ~= added;
                indexBlobPaths(existingByPath, added);
                existingByPath[storedFileName] = added;
                summary.filesAdded++;
            }
            else
            {
                auto fileSpec = existing.getFileSpec(storedFileName);
                auto modified = entry.timeLastModified.toISOExtString;
                if (existing.fileSize != entry.size
                    || fileSpec.timeLastModified != modified)
                {
                    if (existing.fileSpecs.length > 1)
                    {
                        existing.deleteFileSpec(storedFileName);
                        auto replacement = new NamedBinaryBlob(storedFileName,
                            entry.size, entry.timeLastModified);
                        replacement.fileSpecsUseArchiveVirtualGrammar =
                            pathsUseV5Grammar;
                        blobs ~= replacement;
                        indexBlobPaths(existingByPath, replacement);
                        existingByPath[storedFileName] = replacement;
                    }
                    else
                    {
                        existing.fileSize = entry.size;
                        fileSpec.timeLastModified = modified;
                        clearJsonDerivedMetadata(existing);
                    }
                    summary.filesChanged++;
                }
            }
        }
        else
            summary.directoriesFound++;

        if (!reportJsonProgress(control, operationId, OperationKind.scan,
            OperationPhase.scanning, summary.filesFound + summary.directoriesFound,
            0, false, "Scanning filesystem.", entry.name))
            return false;
    }
    return !cancellationRequested(control);
}

/** Convert a stored path into a path relative to `root` in storage grammar.
 *
 * Params:
 *     root = Base directory that bounds the result.
 *     path = Stored path, either absolute or relative to `root`.
 * Returns: The storage-form relative path, or an empty string when the path
 *     equals the root or lies outside it.
 */
private string storedPathRelativeTo(string root, string path)
{
    const auto base = buildNormalizedPath(absolutePath(root));
    const auto full = buildNormalizedPath(isAbsolute(path)
        ? absolutePath(path) : buildPath(base, path));
    const auto prefix = base == "/" ? "/" : base ~ "/";
    if (full == base || !full.startsWith(prefix))
        return "";
    return nativePathToStoragePath(full[prefix.length .. $]);
}

/** Rewrite catalog paths to absolute storage paths for an operation.
 *
 * References that cannot be parsed or that lie outside `root` are dropped, as
 * are duplicate references within one blob. Blobs left without references are
 * removed from the array.
 *
 * Params:
 *     blobs = Catalog blob array rewritten in place.
 *     root = Base directory used to resolve relative paths.
 *     pathsUseV5Grammar = Emit escaped v5 archive grammar and preserve entry
 *         layers carried by virtual paths.
 */
private void absolutizeJsonStoredPaths(ref NamedBinaryBlob[] blobs,
    string root, bool pathsUseV5Grammar)
{
    const auto base = buildNormalizedPath(absolutePath(root));
    const auto prefix = base == "/" ? "/" : base ~ "/";
    NamedBinaryBlob[] kept;
    foreach (blob; blobs)
    {
        if (blob is null)
            continue;
        FileSpec[] references;
        bool[string] seen;
        foreach (spec; blob.fileSpecs)
        {
            if (spec is null || spec.fileName.length == 0)
                continue;
            ParsedArchiveVirtualPath parsed;
            try
                parsed = parseArchiveVirtualPath(spec.fileName);
            catch (Exception)
                continue;
            const auto full = buildNormalizedPath(isAbsolute(parsed.physicalPath)
                ? parsed.physicalPath : buildPath(base, parsed.physicalPath));
            if (full == base || !full.startsWith(prefix))
                continue;
            if (pathsUseV5Grammar)
            {
                auto canonical = escapeArchiveVirtualPath(
                    nativePathToStoragePath(full));
                foreach (entry; parsed.entries)
                    canonical = appendArchiveVirtualPath(canonical,
                        entry.relativePath, entry.hasOccurrence
                            ? entry.occurrence : size_t.max);
                spec.fileName = canonical;
            }
            else
                spec.fileName = nativePathToStoragePath(full);
            if (spec.fileName in seen)
                continue;
            seen[spec.fileName] = true;
            references ~= spec;
        }
        blob.fileSpecs = references;
        if (blob.fileSpecs.length > 0)
            kept ~= blob;
    }
    blobs = kept;
}

/** Rewrite absolute catalog paths back to paths relative to the scan root.
 *
 * References that cannot be parsed or that lie outside `root` are dropped, as
 * are duplicate references within one blob. Blobs left without references are
 * removed from the array.
 *
 * Params:
 *     blobs = Catalog blob array rewritten in place.
 *     root = Base directory the relative paths are formed against.
 *     pathsUseV5Grammar = Emit escaped v5 archive grammar and preserve entry
 *         layers carried by virtual paths.
 */
package(dosierskanilo) void normalizeJsonCatalogPaths(ref NamedBinaryBlob[] blobs,
    string root, bool pathsUseV5Grammar)
{
    NamedBinaryBlob[] kept;
    foreach (blob; blobs)
    {
        if (blob is null)
            continue;
        FileSpec[] references;
        bool[string] seen;
        foreach (spec; blob.fileSpecs)
        {
            if (spec is null || spec.fileName.length == 0)
                continue;
            ParsedArchiveVirtualPath parsed;
            try
                parsed = parseArchiveVirtualPath(spec.fileName);
            catch (Exception)
                continue;
            const relative = storedPathRelativeTo(root, parsed.physicalPath);
            if (relative.length == 0)
                continue;
            if (pathsUseV5Grammar)
            {
                auto canonical = escapeArchiveVirtualPath(relative);
                foreach (entry; parsed.entries)
                    canonical = appendArchiveVirtualPath(canonical,
                        entry.relativePath, entry.hasOccurrence
                            ? entry.occurrence : size_t.max);
                spec.fileName = canonical;
            }
            else
                spec.fileName = relative;
            if (spec.fileName in seen)
                continue;
            seen[spec.fileName] = true;
            references ~= spec;
        }
        blob.fileSpecs = references;
        if (blob.fileSpecs.length > 0)
            kept ~= blob;
    }
    blobs = kept;
}

/** Clear all derived metadata after a file changed on disk.
 *
 * Params:
 *     blob = Catalog record whose checksums, file type, media, archive and
 *         torrent data are reset.
 */
private void clearJsonDerivedMetadata(NamedBinaryBlob blob)
{
    blob.checkSums = CheckSums();
    blob.fileType = null;
    blob.mediaInfoSig = null;
    blob.archiveSpecs = null;
    blob.archiveIndexKnown = false;
    blob.archiveIndexDeep = false;
    blob.archivePassword = "";
    blob.torrentInfo = null;
}

/** Test whether a path below `root` contains a dot-prefixed component.
 *
 * Params:
 *     root = Base directory that defines the inspected path suffix.
 *     path = Path to test.
 * Returns: `true` when any component below `root` starts with a dot, or when
 *     the path lies outside `root` and its base name is hidden.
 */
private bool hasHiddenPathComponent(string root, string path)
{
    auto normalizedRoot = buildNormalizedPath(absolutePath(root));
    auto normalizedPath = buildNormalizedPath(absolutePath(path));
    auto prefix = normalizedRoot;
    if (prefix.length == 0 || !prefix.endsWith(dirSeparator))
        prefix ~= dirSeparator;
    if (!normalizedPath.startsWith(prefix))
        return normalizedPath.baseName.startsWith(".");
    auto relative = normalizedPath[prefix.length .. $];
    foreach (component; relative.split(dirSeparator))
        if (component.startsWith("."))
            return true;
    return false;
}

@("JSON recursive scan skips hidden directory contents with trailing root separator")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "json-hidden-scan-" ~ randomUUID().toString());
    auto privateDirectory = buildPath(root, ".dosierskanilo");
    mkdirRecurse(privateDirectory);
    write(buildPath(root, "visible.txt"), "visible");
    write(buildPath(privateDirectory, "repository.sqlite"), "private");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto rootWithTrailingSeparator = root ~ dirSeparator;
    assert(hasHiddenPathComponent("./",
        buildPath(".dosierskanilo", "repository.sqlite")));
    assert(!hasHiddenPathComponent("./", "visible.txt"));
    assert(hasHiddenPathComponent(rootWithTrailingSeparator,
        buildPath(privateDirectory, "repository.sqlite")));
    assert(!hasHiddenPathComponent(rootWithTrailingSeparator,
        buildPath(root, "visible.txt")));

    RepositoryScanOptions options;
    options.recursive = true;
    NamedBinaryBlob[] blobs;
    ScanSummary summary;
    assert(scanJsonDirectory(rootWithTrailingSeparator, options, true,
        blobs, null, 1, summary));
    assert(summary.filesFound == 1);
    assert(blobs.length == 1);
}

@("JSON rescan splits changed paths from merged blobs")
unittest
{
    import std.algorithm.searching : any;
    import std.datetime.systime : SysTime;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir,
        timeLastModified, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "json-rescan-split-"
        ~ randomUUID().toString());
    const auto firstPath = buildPath(root, "first.bin");
    const auto secondPath = buildPath(root, "second.bin");
    mkdirRecurse(root);
    write(firstPath, "aaa");
    write(secondPath, "bbb");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    auto blob = new NamedBinaryBlob([firstPath, secondPath], 3,
        timeLastModified(secondPath));
    NamedBinaryBlob[] blobs = [blob];

    write(firstPath, "changed");

    RepositoryScanOptions options;
    ScanSummary summary;
    assert(scanJsonDirectory(root, options, false, blobs, null, 1, summary));
    assert(summary.filesFound == 2);
    assert(summary.filesChanged == 1);
    assert(blobs.length == 2);
    assert(blob.hasFileName(secondPath));
    assert(blobs.any!(candidate => candidate.hasFileName(firstPath)));
}

@("JSON rescan clears derived metadata for changed files")
unittest
{
    import std.datetime.systime : SysTime;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "json-rescan-metadata-"
        ~ randomUUID().toString());
    const auto filePath = buildPath(root, "changed.bin");
    mkdirRecurse(root);
    write(filePath, "original");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    auto blob = new NamedBinaryBlob(filePath, 8, SysTime(1_000_000));
    blob.checkSums.md5sum_b64 = "stale-digest";
    blob.fileType = "stale file type";
    blob.archiveIndexKnown = true;
    blob.archiveIndexDeep = true;
    NamedBinaryBlob[] blobs = [blob];

    RepositoryScanOptions options;
    ScanSummary summary;
    assert(scanJsonDirectory(root, options, false, blobs, null, 1, summary));
    assert(summary.filesChanged == 1);
    assert(!blob.checkSums.hasDigests);
    assert(blob.fileType.empty);
    assert(!blob.archiveIndexKnown);
    assert(!blob.archiveIndexDeep);
}

@("JSON metadata batch isolates per-item failures")
unittest
{
    import dosierskanilo.model.filespec : FileSpec;
    import std.datetime.systime : SysTime;
    import std.file : exists, mkdir, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.stdio : writeln;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "json-metadata-failure-"
        ~ randomUUID().toString());
    auto goodPath = buildPath(root, "good.txt");
    auto directoryPath = buildPath(root, "broken.dir");
    mkdirRecurse(root);
    write(goodPath, "good");
    mkdir(directoryPath);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    auto goodBlob = new NamedBinaryBlob(goodPath, 4, SysTime(1_000_000));
    auto brokenBlob = new NamedBinaryBlob();
    brokenBlob.fileSpecs = [new FileSpec(directoryPath, "")];
    NamedBinaryBlob[] blobs = [goodBlob, brokenBlob];

    MetadataScanOptions options;
    options.calculateChecksums = true;

    const auto result = updateJsonMetadata(blobs, options,
        OperationKind.scan, null, 1);
    assert(!result.cancelled);
    const visited = result.summary.blobsVisited;
    const failures = result.summary.failed;
    assert(visited == 2 && failures == 1, visited.to!string ~ "/"
        ~ failures.to!string);
    assert(goodBlob.checkSums.hasDigests);

    /* The threaded batch must isolate the failing item as well. */
    auto threadedGood = new NamedBinaryBlob(goodPath, 4, SysTime(1_000_000));
    auto threadedBroken = new NamedBinaryBlob();
    threadedBroken.fileSpecs = [new FileSpec(directoryPath, "")];
    JsonMetadataWork[] items;
    foreach (blob; [threadedGood, threadedBroken])
    {
        auto item = prepareJsonMetadataWork(blob, options, null);
        item.control = null;
        item.operation = OperationKind.scan;
        item.operationId = 1;
        item.progressCompleted = 1;
        item.progressTotal = 2;
        items ~= item;
    }
    runJsonMetadataBatch(items, 3);
    assert(items[0].errors.empty);
    assert("checksums" in items[1].errors);
    assert(items[1].errors["checksums"].length > 0);
    assert(threadedGood.checkSums.hasDigests);
}

@("JSON metadata run survives corrupt archive alongside good files")
unittest
{
    import std.datetime.systime : SysTime;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "json-metadata-corrupt-"
        ~ randomUUID().toString());
    auto goodPath = buildPath(root, "good.txt");
    mkdirRecurse(root);
    write(goodPath, "good");
    write(buildPath(root, "broken.zip"), "not-a-real-zip");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    auto goodBlob = new NamedBinaryBlob(goodPath, 4, SysTime(1_000_000));
    auto corruptBlob = new NamedBinaryBlob(buildPath(root, "broken.zip"), 13,
        SysTime(1_000_000));
    NamedBinaryBlob[] scanBlobs = [goodBlob, corruptBlob];

    MetadataScanOptions options;
    options.calculateChecksums = true;
    options.scanArchives = true;
    const auto result = updateJsonMetadata(scanBlobs, options,
        OperationKind.scan, null, 1);
    assert(!result.cancelled);
    assert(result.summary.blobsVisited == 2);
    assert(goodBlob.checkSums.hasDigests);
}

version (Windows) {} else
@("JSON scan, metadata, and serialization preserve POSIX backslashes")
unittest
{
    import dosierskanilo.model.namedbinaryblob : deserializeDataClassJsonFile,
        serializeDataClassArrayFile;
    import std.algorithm.searching : endsWith;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "json-backslash-"
        ~ randomUUID().toString());
    const auto fileName = "a\\b.txt";
    const auto filePath = buildPath(root, fileName);
    const auto jsonPath = buildPath(root, "catalog.json");
    mkdirRecurse(root);
    write(filePath, "backslash payload");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    NamedBinaryBlob[] blobs;
    RepositoryScanOptions scanOptions;
    ScanSummary scanSummary;
    assert(scanJsonDirectory(root, scanOptions, true, blobs, null, 1,
        scanSummary));
    assert(blobs.length == 1);
    assert(blobs[0].fileSpecs.length == 1);
    assert(blobs[0].fileSpecs[0].fileName.endsWith(fileName));

    MetadataScanOptions metadataOptions;
    metadataOptions.calculateChecksums = true;
    const auto metadata = updateJsonMetadata(blobs, metadataOptions,
        OperationKind.scan, null, 1);
    assert(!metadata.cancelled);
    assert(metadata.summary.failed == 0);
    assert(blobs[0].checkSums.hasDigests);

    serializeDataClassArrayFile(jsonPath, blobs);
    const auto loaded = deserializeDataClassJsonFile(jsonPath);
    assert(loaded.length == 1);
    assert(loaded[0].fileSpecs.length == 1);
    assert(loaded[0].fileSpecs[0].fileName.endsWith(fileName));
}

/** One unit of JSON metadata extraction queued for a worker.
 *
 * The item snapshots the selected job kinds so a worker does not need to
 * re-evaluate catalog options, and records the first failure per job kind.
 */
private struct JsonMetadataWork
{
    /// Catalog record whose metadata is updated in place.
    NamedBinaryBlob blob;
    /// Metadata extraction options captured when the job was prepared.
    MetadataScanOptions options;
    /// Optional operation control used for progress and cancellation.
    OperationControl control;
    /// Operation kind reported in progress events.
    OperationKind operation;
    /// Identifier reported with progress events.
    ulong operationId;
    /// Number of blobs finished before this item, reported as overall progress.
    ulong progressCompleted;
    /// Total number of blobs in the batch, reported as overall progress.
    ulong progressTotal;
    /// Optional shared cancellation flag mirrored from the operation control.
    shared(bool)* cancellationFlag;
    /// True when checksums still need to be computed.
    bool doChecksums;
    /// True when the file type still needs to be detected.
    bool doFileType;
    /// True when media information still needs to be extracted.
    bool doMediaInfo;
    /// True when archive contents still need to be indexed.
    bool doArchives;
    /// True when torrent metadata still needs to be read.
    bool doTorrents;
    /** First per-job failure message; keyed by the job kind that failed. */
    string[string] errors;
}

/** Report metadata work progress unless the operation was cancelled.
 *
 * Params:
 *     item = Work item supplying the blob path and overall progress counters.
 *     phase = Operation phase reported for this job kind.
 *     subtaskCompleted = Completed units within the current phase.
 *     subtaskTotal = Total units within the current phase, when known.
 *     subtaskTotalKnown = Whether `subtaskTotal` is meaningful.
 *     subtaskUnit = Unit name for the subtask counters, such as "bytes".
 */
private void reportJsonMetadataWorkProgress(JsonMetadataWork item,
    OperationPhase phase, ulong subtaskCompleted = 0,
    ulong subtaskTotal = 0, bool subtaskTotalKnown = false,
    string subtaskUnit = "")
{
    if (item.control is null || item.control.cancellationRequested)
        return;
    OperationProgress progress;
    progress.operationId = item.operationId;
    progress.operation = item.operation;
    progress.state = OperationState.running;
    progress.phase = phase;
    progress.completed = item.progressCompleted;
    progress.total = item.progressTotal;
    progress.totalKnown = true;
    progress.subtaskCompleted = subtaskCompleted;
    progress.subtaskTotal = subtaskTotal;
    progress.subtaskTotalKnown = subtaskTotalKnown;
    progress.subtaskUnit = subtaskUnit;
    progress.path = item.blob.getFirstFileName();
    progress.message = "Processing JSON metadata.";
    item.control.report(progress);
}

/** Run one metadata job and record ordinary failures on the work item.
 *
 * Params:
 *     item = Work item that receives the failure message under `kind`.
 *     kind = Job kind key used in `item.errors`, such as "checksums".
 *     action = Job body to run.
 * Throws: `OperationCallbackException` immediately, so an interrupted
 *     operation is not downgraded to a per-item failure.
 */
private void attemptJsonMetadataWork(JsonMetadataWork* item, string kind,
    void delegate() action)
{
    try
        action();
    catch (OperationCallbackException ex)
        throw ex;
    catch (Exception ex)
        item.errors[kind] = ex.msg;
}

/** Query the work item's shared cancellation flag.
 *
 * Params:
 *     item = Work item whose optional flag is read atomically.
 * Returns: `true` when a cancellation flag is present and set; otherwise
 *     `false`.
 */
private bool jsonWorkCancelled(JsonMetadataWork* item)
{
    if (item.cancellationFlag is null)
        return false;
    import core.atomic : atomicLoad;
    return atomicLoad(*item.cancellationFlag);
}

/** Run the metadata jobs selected on one work item.
 *
 * Jobs run in a fixed order (checksums, file type, media info, archives,
 * torrents) and stop early at cancellation checkpoints between them. Failures
 * are recorded per job kind and do not prevent later jobs from running.
 *
 * Params:
 *     item = Work item whose blob is updated in place and whose `errors` map
 *         collects failures.
 */
private void runJsonMetadataWork(JsonMetadataWork* item)
{
    if (jsonWorkCancelled(item))
        return;
    if (item.doChecksums)
    {
        reportJsonMetadataWorkProgress(*item, OperationPhase.checksums);
        ProgressCallBack progress;
        if (item.control !is null)
        {
            progress.contextual = (size_t completed, size_t total) {
                reportJsonMetadataWorkProgress(*item, OperationPhase.checksums,
                    completed, total, true, "bytes");
            };
        }
        attemptJsonMetadataWork(item, "checksums", {
            updateDigests(item.blob, item.cancellationFlag,
                item.control is null ? null : &progress);
        });
    }
    if (jsonWorkCancelled(item))
        return;
    if (item.doFileType)
    {
        reportJsonMetadataWorkProgress(*item, OperationPhase.fileTypes);
        attemptJsonMetadataWork(item, "file_type",
            { updateFileType(item.blob); });
    }
    if (jsonWorkCancelled(item))
        return;
    if (item.doMediaInfo)
    {
        reportJsonMetadataWorkProgress(*item, OperationPhase.mediaInfo);
        attemptJsonMetadataWork(item, "media_info",
            { updateMediaInfo(item.blob, item.options.rescan); });
    }
    if (jsonWorkCancelled(item))
        return;
    if (item.doArchives)
    {
        reportJsonMetadataWorkProgress(*item, OperationPhase.archives);
        ProgressCallBack progress;
        if (item.control !is null)
        {
            progress.contextual = (size_t completed, size_t total) {
                reportJsonMetadataWorkProgress(*item, OperationPhase.archives,
                    completed, total, true, "entries");
            };
        }
        attemptJsonMetadataWork(item, "archives", {
            updateArchives(item.blob, item.options.rescan,
                item.options.deepArchiveScan, item.cancellationFlag,
                item.control is null ? null : &progress,
                item.options.archivePasswordCallback,
                0, 8, "", null, item.options.detectFileTypes,
                item.options.extractMediaInfo,
                item.options.archiveBulkMode);
        });
    }
    if (jsonWorkCancelled(item))
        return;
    if (item.doTorrents)
    {
        reportJsonMetadataWorkProgress(*item, OperationPhase.torrents);
        attemptJsonMetadataWork(item, "torrents",
            { updateTorrentInfo(item.blob); });
    }
}

/** Build a work item that selects only the metadata still missing on a blob.
 *
 * Params:
 *     blob = Catalog record to inspect and later update.
 *     options = Metadata extraction options controlling the selected jobs.
 *     cancellationFlag = Optional shared cancellation flag for the worker.
 * Returns: A work item with the job-selection flags set; progress and operation
 *     fields remain for the caller to fill in.
 */
private JsonMetadataWork prepareJsonMetadataWork(NamedBinaryBlob blob,
    MetadataScanOptions options, shared(bool)* cancellationFlag)
{
    JsonMetadataWork item;
    item.blob = blob;
    item.options = options;
    item.cancellationFlag = cancellationFlag;
    item.doChecksums = options.calculateChecksums && !blob.checkSums.hasDigests;
    item.doFileType = options.detectFileTypes && blob.fileType.empty;
    item.doMediaInfo = options.extractMediaInfo
        && (blob.mediaInfoSig is null || options.rescan);
    item.doArchives = options.scanArchives
        && (options.rescan || (blob.archiveSpecs is null
            && (!blob.archiveIndexKnown
                || (options.deepArchiveScan && !blob.archiveIndexDeep))));
    item.doTorrents = options.scanTorrents && blob.torrentInfo is null;
    return item;
}

/** Test whether a work item has any job left to run.
 *
 * Params:
 *     item = Work item whose job-selection flags are inspected.
 * Returns: `true` when at least one extraction job is selected.
 */
private bool hasJsonMetadataWork(JsonMetadataWork item)
{
    return item.doChecksums || item.doFileType || item.doMediaInfo
        || item.doArchives || item.doTorrents;
}

/** Run a batch of metadata work items, optionally on a worker pool.
 *
 * Params:
 *     items = Work items updated in place; the loop stops early at
 *         cancellation checkpoints.
 *     threads = Worker count; values less than or equal to one run serially.
 */
private void runJsonMetadataBatch(JsonMetadataWork[] items, size_t threads)
{
    if (threads <= 1)
    {
        foreach (ref item; items)
        {
            if (jsonWorkCancelled(&item))
                break;
            runJsonMetadataWork(&item);
        }
        return;
    }

    TaskPool pool = new TaskPool(threads);
    Task!(runJsonMetadataWork, JsonMetadataWork*)*[] tasks;
    try
    {
        foreach (ref item; items)
        {
            auto worker = task!runJsonMetadataWork(&item);
            tasks ~= worker;
            pool.put(worker);
        }
        foreach (worker; tasks)
            worker.workForce();
    }
    finally
    {
        pool.finish(true);
        pool.stop();
    }
}

/** List the operation phases enabled by a metadata option set.
 *
 * Params:
 *     options = Metadata extraction options to translate.
 * Returns: Enabled phases in processing order; empty when no extraction is
 *     enabled.
 */
private OperationPhase[] jsonMetadataPhases(MetadataScanOptions options)
{
    OperationPhase[] phases;
    if (options.calculateChecksums) phases ~= OperationPhase.checksums;
    if (options.detectFileTypes) phases ~= OperationPhase.fileTypes;
    if (options.extractMediaInfo) phases ~= OperationPhase.mediaInfo;
    if (options.scanArchives) phases ~= OperationPhase.archives;
    if (options.scanTorrents) phases ~= OperationPhase.torrents;
    return phases;
}

/** Run selected metadata extractions over an in-memory catalog.
 *
 * Blobs are processed in bounded batches, either serially or on a worker pool,
 * and each blob keeps its already valid metadata. Cancellation is checked
 * between batches and before each job kind.
 *
 * Params:
 *     blobs = Catalog blob array updated in place.
 *     options = Metadata extraction options and worker count.
 *     operation = Operation kind reported in progress events.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Identifier reported with progress events.
 * Returns: A result carrying the updated counters and a cancellation flag;
 *     summary counters stay zero when no extraction was requested.
 */
private JsonMetadataExecutionResult updateJsonMetadata(ref NamedBinaryBlob[] blobs,
    MetadataScanOptions options, OperationKind operation, OperationControl control,
    ulong operationId)
{
    JsonMetadataExecutionResult execution;
    if (!(options.calculateChecksums || options.detectFileTypes
        || options.extractMediaInfo || options.scanArchives || options.scanTorrents))
        return execution;

    shared(bool) cancellationFlag;
    if (control !is null)
        control.bindCancellationMirror(&cancellationFlag);
    scope (exit)
        if (control !is null)
            control.unbindCancellationMirror();
    auto threads = options.threads > 0 ? options.threads : 1;
    auto batchSize = threads * 4;
    auto phases = jsonMetadataPhases(options);
    size_t nextIndex;
    while (nextIndex < blobs.length)
    {
        if (!reportJsonProgress(control, operationId, operation,
            OperationPhase.discovering, execution.summary.blobsVisited,
            blobs.length, true, "Preparing JSON metadata jobs.", ""))
        {
            execution.cancelled = true;
            return execution;
        }

        JsonMetadataWork[] batch;
        while (nextIndex < blobs.length && batch.length < batchSize)
        {
            if (cancellationRequested(control))
                break;
            auto blob = blobs[nextIndex++];
            if (blob is null || blob.getFirstExistingFileName.empty)
                continue;
            auto item = prepareJsonMetadataWork(blob, options, &cancellationFlag);
            item.control = control;
            item.operation = operation;
            item.operationId = operationId;
            item.progressCompleted = cast(ulong) nextIndex;
            item.progressTotal = cast(ulong) blobs.length;
            batch ~= item;
        }
        if (cancellationRequested(control))
        {
            execution.cancelled = true;
            return execution;
        }
        if (batch.length == 0)
            continue;

        runJsonMetadataBatch(batch, threads);
        foreach (item; batch)
        {
            execution.summary.blobsVisited++;
            if (item.errors.length > 0)
            {
                execution.summary.failed++;
                continue;
            }
            if (item.doChecksums && item.blob.checkSums.hasDigests)
                execution.summary.checksumsUpdated++;
            if (item.doFileType && item.blob.fileType.length > 0)
                execution.summary.fileTypesUpdated++;
            if (item.doArchives && item.options.detectFileTypes)
                execution.summary.fileTypesUpdated +=
                    countArchiveFileTypes(item.blob.archiveSpecs);
            if (item.doMediaInfo && item.blob.mediaInfoSig !is null
                && !item.blob.mediaInfoSig.empty)
                execution.summary.mediaInfoUpdated++;
            if (item.doArchives && item.options.extractMediaInfo)
                execution.summary.mediaInfoUpdated +=
                    countArchiveMediaInfo(item.blob.archiveSpecs);
            if (item.doArchives && (item.blob.archiveIndexKnown
                || item.blob.archiveSpecs !is null))
                execution.summary.archivesUpdated++;
            if (item.doTorrents && item.blob.torrentInfo !is null)
                execution.summary.torrentsUpdated++;
        }

        const auto checkpointPhase = phases.length > 0
            ? phases[$ - 1] : OperationPhase.discovering;
        const auto checkpointPath = batch[$ - 1].blob.getFirstFileName();
        if (!checkpointJsonProgress(control, operationId, operation,
            checkpointPhase, execution.summary.blobsVisited, blobs.length,
            checkpointPath))
        {
            execution.cancelled = true;
            return execution;
        }
    }
    execution.cancelled = cancellationRequested(control);
    return execution;
}

/** Count archive entries that carry a detected file type.
 *
 * Nested archive entries are counted recursively.
 *
 * Params:
 *     entries = Archive entries to inspect; null entries are skipped.
 * Returns: Number of non-empty file types across the whole tree.
 */
private size_t countArchiveFileTypes(ArchiveSpec[] entries)
{
    size_t result;
    foreach (entry; entries)
    {
        if (entry is null)
            continue;
        if (entry.fileType.length > 0)
            ++result;
        result += countArchiveFileTypes(entry.nestedEntries);
    }
    return result;
}

/** Count archive entries that carry media information.
 *
 * Nested archive entries are counted recursively.
 *
 * Params:
 *     entries = Archive entries to inspect; null entries are skipped.
 * Returns: Number of non-empty media signatures across the whole tree.
 */
private size_t countArchiveMediaInfo(ArchiveSpec[] entries)
{
    size_t result;
    foreach (entry; entries)
    {
        if (entry is null)
            continue;
        if (entry.mediaInfoSig !is null && !entry.mediaInfoSig.empty)
            ++result;
        result += countArchiveMediaInfo(entry.nestedEntries);
    }
    return result;
}

/** Count missing files, optionally drop them, and merge duplicate content.
 *
 * Duplicate candidates are grouped by size first and then by SHA-1 digest; each
 * digest group with more than one record is merged. A group that cannot be
 * merged is skipped without affecting other groups.
 *
 * Params:
 *     blobs = Catalog blob array updated in place.
 *     options = Analysis options; `dropMissing` removes orphaned records.
 *     sourceIsV5 = Whether stored paths use the v5 archive grammar.
 *     operation = Operation kind reported in progress events.
 *     control = Optional operation control for progress and cancellation.
 *     operationId = Identifier reported with progress events.
 *     summary = Analysis counters updated in place.
 * Returns: `true` when the analysis completed; `false` when it was cancelled.
 */
private bool analyzeJsonRecords(ref NamedBinaryBlob[] blobs,
    RepositoryAnalysisOptions options, bool sourceIsV5,
    OperationKind operation, OperationControl control, ulong operationId,
    ref AnalysisSummary summary)
{
    size_t missingRecords;
    foreach (blob; blobs)
        if (blob !is null && jsonBlobIsOrphaned(blob, sourceIsV5))
            missingRecords++;
    summary.missingFiles = missingRecords;
    if (options.dropMissing)
    {
        summary.droppedFiles = missingRecords;
        NamedBinaryBlob[] retained;
        foreach (blob; blobs)
            if (blob !is null && !jsonBlobIsOrphaned(blob, sourceIsV5))
                retained ~= blob;
        blobs = retained;
    }
    if (!reportJsonProgress(control, operationId, operation,
        OperationPhase.analysisMissingFiles, missingRecords, blobs.length, true,
        "Missing-file analysis completed.", ""))
        return false;

    NamedBinaryBlob[][size_t] sizeGroups;
    foreach (blob; blobs)
    {
        if (blob !is null && blob.checkSums.hasDigests)
            sizeGroups[blob.fileSize] ~= blob;
    }

    shared(bool) cancellationFlag;
    if (control !is null)
        control.bindCancellationMirror(&cancellationFlag);
    scope (exit)
        if (control !is null)
            control.unbindCancellationMirror();
    NamedBinaryBlob[] merged;
    size_t groupsVisited;
    foreach (size; sizeGroups.keys)
    {
        auto group = sizeGroups[size];
        if (group.length < 2)
            continue;
        NamedBinaryBlob[][string] digestGroups;
        foreach (blob; group)
        {
            if (cancellationRequested(control))
                return false;
            updateDigests(blob, &cancellationFlag, null);
            if (cancellationFlag)
                return false;
            digestGroups[blob.checkSums.sha1sum_b64] ~= blob;
        }
        foreach (digestGroup; digestGroups)
        {
            if (digestGroup.length > 1)
            {
                try
                {
                    merged ~= mergeDataClassObjects(digestGroup);
                    invalidateDataClassObjs(digestGroup);
                    summary.duplicateGroups++;
                    summary.mergedBlobs += digestGroup.length - 1;
                }
                catch (Exception)
                {
                    // Preserve the legacy behavior: an invalid digest group does
                    // not prevent unrelated groups from being analyzed.
                }
            }
        }
        groupsVisited++;
        if (!reportJsonProgress(control, operationId, operation,
            OperationPhase.analysisDuplicates, groupsVisited, sizeGroups.length,
            true, "Analyzing duplicate candidates.", group[0].getFirstFileName()))
            return false;
    }
    if (merged.length > 0)
        blobs ~= merged;
    // cleanupDataClassObjs also removes records whose source paths are absent.
    // That is only valid when the caller explicitly requested drop-missing;
    // here remove only the empty records invalidated by duplicate merging.
    blobs = cleanupInvalidatedDataClassObjs(blobs);
    return reportJsonProgress(control, operationId, operation,
        OperationPhase.analysisCleanup, blobs.length, blobs.length, true,
        "JSON analysis completed.", "");
}

/** Decide whether a catalog record has lost all of its files.
 *
 * For v5 paths, virtual archive references count as present even when their
 * container cannot be checked, so only records that reference filesystem paths
 * exclusively and have no existing file are treated as orphaned.
 *
 * Params:
 *     blob = Catalog record to test.
 *     sourceIsV5 = Whether stored paths use the v5 archive grammar.
 * Returns: `true` when the record should be considered missing.
 */
private bool jsonBlobIsOrphaned(NamedBinaryBlob blob, bool sourceIsV5)
{
    if (!sourceIsV5 || blob.fileSpecs.length == 0)
        return blob.isBlobOrphaned;
    if (blob.getExistingFiles().length > 0)
        return false;
    bool hasVirtualReference;
    bool hasFilesystemReference;
    foreach (spec; blob.fileSpecs)
    {
        if (spec is null || spec.fileName.empty)
            continue;
        bool isVirtual;
        try
            isVirtual = parseArchiveVirtualPath(spec.fileName).isVirtual;
        catch (Exception)
        {
            // Keep malformed v5 paths on the normal filesystem validation path.
        }
        if (isVirtual)
        {
            hasVirtualReference = true;
            continue;
        }
        hasFilesystemReference = true;
    }
    return hasFilesystemReference && !hasVirtualReference;
}

/** Report operation progress and process pause/cancel requests.
 *
 * Params:
 *     control = Optional operation control; a null control reports success.
 *     operationId = Identifier carried by the progress event.
 *     operation = Operation kind carried by the progress event.
 *     phase = Operation phase carried by the progress event.
 *     completed = Completed work units.
 *     total = Total work units, when known.
 *     totalKnown = Whether `total` is meaningful.
 *     message = Human-readable progress message.
 *     path = Path associated with the event, or an empty string.
 * Returns: `true` when the caller may continue; `false` when cancellation was
 *     requested before or after the checkpoint.
 */
private bool reportJsonProgress(OperationControl control, ulong operationId,
    OperationKind operation, OperationPhase phase, size_t completed, size_t total,
    bool totalKnown, string message, string path)
{
    if (control is null)
        return true;
    if (control.cancellationRequested)
        return false;
    control.setPauseAvailable(true);
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = operation;
    progress.state = OperationState.running;
    progress.phase = phase;
    progress.completed = completed;
    progress.total = total;
    progress.totalKnown = totalKnown;
    progress.path = path;
    progress.message = message;
    control.report(progress);
    return control.pauseAtCheckpoint(progress)
        && !control.cancellationRequested;
}

/** Honor pause/cancel requests after JSON metadata workers have drained.
 *
 * Params:
 *     control = Optional operation control; a null control reports success.
 *     operationId = Identifier carried by the progress event.
 *     operation = Operation kind carried by the progress event.
 *     phase = Operation phase carried by the progress event.
 *     completed = Completed work units.
 *     total = Total work units.
 *     path = Path associated with the event, or an empty string.
 * Returns: `true` when processing may continue; `false` when cancellation was
 *     requested before or after the checkpoint.
 */
private bool checkpointJsonProgress(OperationControl control, ulong operationId,
    OperationKind operation, OperationPhase phase, size_t completed,
    size_t total, string path)
{
    if (control is null)
        return true;
    if (control.cancellationRequested)
        return false;
    control.setPauseAvailable(true);
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = operation;
    progress.state = OperationState.running;
    progress.phase = phase;
    progress.completed = completed;
    progress.total = total;
    progress.totalKnown = true;
    progress.path = path;
    progress.message = "JSON metadata results are ready.";
    return control.pauseAtCheckpoint(progress)
        && !control.cancellationRequested;
}

/** Query whether an operation control requested cancellation.
 *
 * Params:
 *     control = Optional operation control.
 * Returns: `true` when a control is present and cancellation was requested;
 *     otherwise `false`.
 */
private bool cancellationRequested(OperationControl control)
{
    return control !is null && control.cancellationRequested;
}

@("JSON metadata work stops at cancellation checkpoints between job kinds")
unittest
{
    import std.file : exists, remove, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const path = buildPath(tempDir(), "json-cancel-"
        ~ randomUUID().toString() ~ ".txt");
    write(path, "payload");
    scope (exit)
        if (exists(path))
            remove(path);

    import std.datetime.systime : SysTime;
    auto blob = new NamedBinaryBlob(path, 7, SysTime(0));
    MetadataScanOptions options;
    options.detectFileTypes = true;
    options.scanTorrents = true;
    shared(bool) cancelled = true;
    JsonMetadataWork item;
    item.blob = blob;
    item.options = options;
    item.cancellationFlag = &cancelled;
    item.doFileType = true;
    item.doTorrents = true;
    runJsonMetadataWork(&item);
    assert(item.errors.length == 0);
    assert(blob.fileType.length == 0);
    assert(blob.torrentInfo is null);
}

@("JSON scan stores paths relative to the scan base directory")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "json-relative-scan-"
        ~ randomUUID().toString());
    mkdirRecurse(buildPath(root, "nested"));
    write(buildPath(root, "nested", "sample.txt"), "payload");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    NamedBinaryBlobCatalog catalog;
    catalog.dataVersion = DATA_CLASS_VERSION5;
    RepositoryScanOptions scanOptions;
    MetadataScanOptions metadataOptions;
    const application = scanJsonCatalogInto(catalog, root, scanOptions,
        metadataOptions, false, null, 1);
    assert(!application.cancelled);
    assert(catalog.dataArray.length == 1);
    assert(catalog.dataArray[0].fileSpecs.length == 1);
    assert(catalog.dataArray[0].fileSpecs[0].fileName == "nested/sample.txt",
        catalog.dataArray[0].fileSpecs[0].fileName);
}

@("JSON path normalization keeps only references below the base directory")
unittest
{
    import std.file : tempDir;
    import std.path : buildPath;

    const root = buildPath(tempDir(), "json-normalize-base");
    auto blob = new NamedBinaryBlob();
    blob.fileSize = 1;
    blob.fileSpecs = [
        new FileSpec(buildPath(root, "inside.txt"), ""),
        new FileSpec("./relative.txt", ""),
        new FileSpec("/etc/hosts", ""),
    ];
    NamedBinaryBlob[] blobs = [blob];
    normalizeJsonCatalogPaths(blobs, root, true);
    assert(blobs.length == 1);
    assert(blobs[0].fileSpecs.length == 2);
    assert(blobs[0].fileSpecs[0].fileName == "inside.txt",
        blobs[0].fileSpecs[0].fileName);
    assert(blobs[0].fileSpecs[1].fileName == "relative.txt",
        blobs[0].fileSpecs[1].fileName);
}
