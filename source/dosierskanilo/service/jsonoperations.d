/** Controlled operations over explicit JSON catalogs. */
module dosierskanilo.service.jsonoperations;

import std.algorithm.searching : startsWith;
import std.datetime.systime;
import std.file : DirEntry, SpanMode, dirEntries, isFile;
import std.parallelism : Task, TaskPool, task;
import std.path : baseName, buildNormalizedPath, dirSeparator;
import std.string : empty, replace, split;

import dosierarkivo.archive : escapeArchiveVirtualPath,
    parseArchiveVirtualPath;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob,
    DATA_CLASS_VERSION5, NamedBinaryBlobCatalog,
    deserializeDataClassJsonWrapperFile,
    cleanupInvalidatedDataClassObjs, invalidateDataClassObjs, mergeDataClassObjects,
    updateArchives, updateDigests,
    updateFileType, updateMediaInfo, updateTorrentInfo;
import dosierskanilo.operations : OperationControl, OperationKind,
    OperationPhase, OperationProgress, OperationState;
import dosierskanilo.operationlease : TargetCatalogReplacementLease;
import dosierskanilo.repository.types : AnalysisSummary, MetadataScanOptions,
    MetadataSummary, RepositoryAnalysisOptions, RepositoryScanOptions, ScanSummary;
import dosierskanilo.service.storageio : writeStorageJsonFile;

/** Execute a JSON scan and optional metadata phase before committing the file. */
struct JsonScanExecutionResult
{
    NamedBinaryBlobCatalog catalog;
    ScanSummary scanSummary;
    MetadataSummary metadataSummary;
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
    MetadataScanOptions metadataOptions, OperationControl control, ulong operationId)
{
    JsonScanExecutionResult execution;
    execution.catalog = loadJsonCatalog(catalogPath, forceOverwrite);
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
    return execution;
}

/** Load and enrich a JSON catalog for an explicit JSON analysis operation. */
JsonAnalysisExecutionResult analyzeJsonCatalog(string catalogPath,
    bool forceOverwrite, MetadataScanOptions metadataOptions,
    RepositoryAnalysisOptions analysisOptions, OperationControl control,
    ulong operationId)
{
    JsonAnalysisExecutionResult execution;
    execution.catalog = loadJsonCatalog(catalogPath, forceOverwrite);
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
        control, operationId, execution.analysisSummary))
        execution.cancelled = true;
    return execution;
}

/** Persist a computed JSON catalog after the final safe cancellation checkpoint. */
bool commitJsonCatalog(string catalogPath, ref NamedBinaryBlobCatalog catalog)
{
    auto replacementLease = TargetCatalogReplacementLease.acquireJsonCatalog(
        catalogPath);
    scope (exit)
        replacementLease.release();
    return writeStorageJsonFile(catalogPath, catalog);
}

private NamedBinaryBlobCatalog loadJsonCatalog(string catalogPath,
    bool forceOverwrite)
{
    import std.file : exists;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5;

    if (!exists(catalogPath))
        return NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, []);
    try
        return deserializeDataClassJsonWrapperFile(catalogPath);
    catch (Exception ex)
    {
        if (!forceOverwrite)
            throw ex;
        return NamedBinaryBlobCatalog(DATA_CLASS_VERSION5, []);
    }
}

private bool scanJsonDirectory(string root, RepositoryScanOptions options,
    bool pathsUseV5Grammar, ref NamedBinaryBlob[] blobs,
    OperationControl control, ulong operationId, ref ScanSummary summary)
{
    if (!reportJsonProgress(control, operationId, OperationKind.scan,
        OperationPhase.discovering, 0, 0, false, "Scanning filesystem.", ""))
        return false;

    foreach (DirEntry entry; dirEntries(root,
        options.recursive ? SpanMode.depth : SpanMode.shallow))
    {
        if (!options.pickHidden && hasHiddenPathComponent(root, entry.name))
            continue;
        if (isFile(entry.name))
        {
            summary.filesFound++;
            auto storedFileName = pathsUseV5Grammar
                ? escapeArchiveVirtualPath(entry.name.replace('\\', '/'))
                : entry.name;
            NamedBinaryBlob existing;
            foreach (blob; blobs)
            {
                if (blob !is null && blob.hasFileName(storedFileName))
                {
                    existing = blob;
                    break;
                }
            }

            if (existing is null)
            {
                auto added = new NamedBinaryBlob(storedFileName, entry.size,
                    entry.timeLastModified);
                added.fileSpecsUseArchiveVirtualGrammar = pathsUseV5Grammar;
                blobs ~= added;
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
                        existing.deleteFileSpec(entry.name);
                        blobs ~= new NamedBinaryBlob(entry.name, entry.size,
                            entry.timeLastModified);
                    }
                    else
                    {
                        existing.fileSize = entry.size;
                        fileSpec.timeLastModified = modified;
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

private bool hasHiddenPathComponent(string root, string path)
{
    auto normalizedRoot = buildNormalizedPath(root);
    auto normalizedPath = buildNormalizedPath(path);
    auto prefix = normalizedRoot ~ dirSeparator;
    if (!normalizedPath.startsWith(prefix))
        return normalizedPath.baseName.startsWith(".");
    auto relative = normalizedPath[prefix.length .. $];
    foreach (component; relative.split(dirSeparator))
        if (component.startsWith("."))
            return true;
    return false;
}

private struct JsonMetadataWork
{
    NamedBinaryBlob blob;
    MetadataScanOptions options;
    shared(bool)* cancellationFlag;
    bool doChecksums;
    bool doFileType;
    bool doMediaInfo;
    bool doArchives;
    bool doTorrents;
}

private void runJsonMetadataWork(JsonMetadataWork item)
{
    if (item.doChecksums)
        updateDigests(item.blob, item.cancellationFlag, null);
    if (item.doFileType)
        updateFileType(item.blob);
    if (item.doMediaInfo)
        updateMediaInfo(item.blob, item.options.rescan);
    if (item.doArchives)
        updateArchives(item.blob, item.options.rescan, item.options.deepArchiveScan,
            item.cancellationFlag, null, item.options.archivePasswordCallback);
    if (item.doTorrents)
        updateTorrentInfo(item.blob);
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
            batch ~= prepareJsonMetadataWork(blob, options, &cancellationFlag);
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
            if (item.doMediaInfo && item.blob.mediaInfoSig !is null
                && !item.blob.mediaInfoSig.empty)
                execution.summary.mediaInfoUpdated++;
            if (item.doArchives && (item.blob.archiveIndexKnown
                || item.blob.archiveSpecs !is null))
                execution.summary.archivesUpdated++;
            if (item.doTorrents && item.blob.torrentInfo !is null)
                execution.summary.torrentsUpdated++;
        }

        foreach (item; batch)
        {
            foreach (phase; phases)
            {
                if (!reportJsonProgress(control, operationId, operation,
                    phase, execution.summary.blobsVisited, blobs.length, true,
                    "JSON metadata results are ready.", item.blob.getFirstFileName()))
                {
                    execution.cancelled = true;
                    return execution;
                }
            }
        }
    }
    execution.cancelled = cancellationRequested(control);
    return execution;
}

private bool analyzeJsonRecords(ref NamedBinaryBlob[] blobs,
    RepositoryAnalysisOptions options, bool sourceIsV5,
    OperationControl control, ulong operationId,
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
    if (!reportJsonProgress(control, operationId, OperationKind.analyze,
        OperationPhase.analysisMissingFiles, missingRecords, blobs.length, true,
        "Missing-file analysis completed.", ""))
        return false;

    NamedBinaryBlob[][size_t] sizeGroups;
    foreach (blob; blobs)
    {
        if (blob !is null && blob.checkSums.hasDigests
            && jsonBlobHasFilesystemReference(blob, sourceIsV5))
            sizeGroups[blob.fileSize] ~= blob;
    }

    shared(bool) cancellationFlag;
    if (control !is null)
        control.bindCancellationMirror(&cancellationFlag);
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
        if (!reportJsonProgress(control, operationId, OperationKind.analyze,
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
    return reportJsonProgress(control, operationId, OperationKind.analyze,
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

private bool jsonBlobHasFilesystemReference(NamedBinaryBlob blob,
    bool sourceIsV5)
{
    if (!sourceIsV5 || blob.fileSpecs.length == 0)
        return true;
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

private bool cancellationRequested(OperationControl control)
{
    return control !is null && control.cancellationRequested;
}
