/** Controlled operations over explicit JSON catalogs. */
module dosierskanilo.service.jsonoperations;

import std.algorithm.searching : startsWith;
import std.datetime.systime;
import std.file : DirEntry, SpanMode, dirEntries, isFile;
import std.parallelism : Task, TaskPool, task;
import std.path : absolutePath, baseName, buildNormalizedPath, dirSeparator;
import std.string : empty, endsWith, replace, split;

import dosierarkivo.archive : escapeArchiveVirtualPath,
    nativePathToStoragePath, parseArchiveVirtualPath;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob,
    DATA_CLASS_VERSION5, NamedBinaryBlobCatalog,
    deserializeDataClassJsonWrapperFile, isCatalogFormatFailure,
    cleanupInvalidatedDataClassObjs, invalidateDataClassObjs, mergeDataClassObjects,
    updateArchives, updateDigests,
    updateFileType, updateMediaInfo, updateTorrentInfo;
import dosierskanilo.operations : OperationControl, OperationKind,
    OperationPhase, OperationProgress, OperationState;
import dosierskanilo.operationlease : TargetCatalogReplacementLease;
import dosierskanilo.progress : ProgressCallBack;
import dosierskanilo.repository.types : AnalysisSummary, MetadataScanOptions,
    MetadataSummary, RepositoryAnalysisOptions, RepositoryScanOptions, ScanSummary;
import dosierskanilo.service.storageio : writeStorageJsonFile;

/** Execute a JSON scan and optional metadata phase before committing the file. */
struct JsonScanExecutionResult
{
    NamedBinaryBlobCatalog catalog;
    ScanSummary scanSummary;
    MetadataSummary metadataSummary;
    AnalysisSummary analysisSummary;
    bool cancelled;
}

/** Execute JSON metadata extraction without writing the catalog. */
struct JsonMetadataExecutionResult
{
    MetadataSummary summary;
    bool cancelled;
}

/** Execute JSON analysis after any selected metadata jobs. */
struct JsonAnalysisExecutionResult
{
    NamedBinaryBlobCatalog catalog;
    MetadataSummary metadataSummary;
    AnalysisSummary analysisSummary;
    bool cancelled;
}

/** Load a JSON catalog, scan its filesystem root, and run selected extractors. */
JsonScanExecutionResult scanJsonCatalog(string catalogPath, string filesystemRoot,
    bool forceOverwrite, RepositoryScanOptions scanOptions,
    MetadataScanOptions metadataOptions, bool mergeDuplicates,
    OperationControl control, ulong operationId)
{
    JsonScanExecutionResult execution;
    execution.catalog = loadJsonCatalog(catalogPath, forceOverwrite, control,
        OperationKind.scan, operationId);
    if (!scanJsonDirectory(filesystemRoot, scanOptions,
        execution.catalog.dataVersion == DATA_CLASS_VERSION5,
        execution.catalog.dataArray, control, operationId,
        execution.scanSummary))
    {
        execution.cancelled = true;
        return execution;
    }
    auto metadata = updateJsonMetadata(execution.catalog.dataArray,
        metadataOptions, OperationKind.scan, control, operationId);
    execution.metadataSummary = metadata.summary;
    execution.cancelled = metadata.cancelled;
    if (!execution.cancelled && mergeDuplicates)
    {
        RepositoryAnalysisOptions analysisOptions;
        if (!analyzeJsonRecords(execution.catalog.dataArray, analysisOptions,
            execution.catalog.dataVersion == DATA_CLASS_VERSION5, OperationKind.scan,
            control, operationId, execution.analysisSummary))
            execution.cancelled = true;
    }
    return execution;
}

/** Load and enrich a JSON catalog for an explicit JSON analysis operation. */
JsonAnalysisExecutionResult analyzeJsonCatalog(string catalogPath,
    bool forceOverwrite, MetadataScanOptions metadataOptions,
    RepositoryAnalysisOptions analysisOptions, OperationControl control,
    ulong operationId)
{
    JsonAnalysisExecutionResult execution;
    execution.catalog = loadJsonCatalog(catalogPath, forceOverwrite, control,
        OperationKind.analyze, operationId);
    auto metadata = updateJsonMetadata(execution.catalog.dataArray,
        metadataOptions, OperationKind.analyze, control, operationId);
    execution.metadataSummary = metadata.summary;
    if (metadata.cancelled)
    {
        execution.cancelled = true;
        return execution;
    }
    if (!analyzeJsonRecords(execution.catalog.dataArray, analysisOptions,
        execution.catalog.dataVersion == DATA_CLASS_VERSION5,
        OperationKind.analyze, control, operationId,
        execution.analysisSummary))
        execution.cancelled = true;
    return execution;
}

/** Persist a computed JSON catalog after the final safe cancellation checkpoint. */
bool commitJsonCatalog(string catalogPath, ref NamedBinaryBlobCatalog catalog)
{
    return commitJsonCatalog(catalogPath, catalog, null);
}

/** Persist a JSON catalog while honoring cancellation during serialization. */
bool commitJsonCatalog(string catalogPath, ref NamedBinaryBlobCatalog catalog,
    bool delegate() cancelCheck)
{
    auto replacementLease = TargetCatalogReplacementLease.acquireJsonCatalog(
        catalogPath);
    scope (exit)
        replacementLease.release();
    return writeStorageJsonFile(catalogPath, catalog, ".json",
        Clock.currTime.toISOExtString(), "", cancelCheck);
}

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

/// Add all primary file paths of one blob to the scan lookup index.
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
                ? escapeArchiveVirtualPath(nativePathToStoragePath(entry.name))
                : entry.name;
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

private struct JsonMetadataWork
{
    NamedBinaryBlob blob;
    MetadataScanOptions options;
    OperationControl control;
    OperationKind operation;
    ulong operationId;
    ulong progressCompleted;
    ulong progressTotal;
    shared(bool)* cancellationFlag;
    bool doChecksums;
    bool doFileType;
    bool doMediaInfo;
    bool doArchives;
    bool doTorrents;
}

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

private void runJsonMetadataWork(JsonMetadataWork item)
{
    if (item.doChecksums)
    {
        reportJsonMetadataWorkProgress(item, OperationPhase.checksums);
        ProgressCallBack progress;
        if (item.control !is null)
        {
            progress.contextual = (size_t completed, size_t total) {
                reportJsonMetadataWorkProgress(item, OperationPhase.checksums,
                    completed, total, true, "bytes");
            };
        }
        updateDigests(item.blob, item.cancellationFlag,
            item.control is null ? null : &progress);
    }
    if (item.doFileType)
    {
        reportJsonMetadataWorkProgress(item, OperationPhase.fileTypes);
        updateFileType(item.blob);
    }
    if (item.doMediaInfo)
    {
        reportJsonMetadataWorkProgress(item, OperationPhase.mediaInfo);
        updateMediaInfo(item.blob, item.options.rescan);
    }
    if (item.doArchives)
    {
        reportJsonMetadataWorkProgress(item, OperationPhase.archives);
        ProgressCallBack progress;
        if (item.control !is null)
        {
            progress.contextual = (size_t completed, size_t total) {
                reportJsonMetadataWorkProgress(item, OperationPhase.archives,
                    completed, total, true, "entries");
            };
        }
        updateArchives(item.blob, item.options.rescan, item.options.deepArchiveScan,
            item.cancellationFlag, item.control is null ? null : &progress,
            item.options.archivePasswordCallback,
            0, 8, "", null, item.options.detectFileTypes,
            item.options.extractMediaInfo);
    }
    if (item.doTorrents)
    {
        reportJsonMetadataWorkProgress(item, OperationPhase.torrents);
        updateTorrentInfo(item.blob);
    }
}

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

private bool hasJsonMetadataWork(JsonMetadataWork item)
{
    return item.doChecksums || item.doFileType || item.doMediaInfo
        || item.doArchives || item.doTorrents;
}

private void runJsonMetadataBatch(JsonMetadataWork[] items, size_t threads)
{
    if (threads <= 1)
    {
        foreach (item; items)
            runJsonMetadataWork(item);
        return;
    }

    TaskPool pool = new TaskPool(threads);
    Task!(runJsonMetadataWork, JsonMetadataWork)*[] tasks;
    try
    {
        foreach (item; items)
        {
            auto worker = task!runJsonMetadataWork(item);
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

/** Honor pause/cancel requests after JSON metadata workers have drained. */
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

private bool cancellationRequested(OperationControl control)
{
    return control !is null && control.cancellationRequested;
}
