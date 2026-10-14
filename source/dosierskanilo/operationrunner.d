/** Executors for frontend-neutral long-running operations. */
module dosierskanilo.operationrunner;

import std.exception : enforce;

import dosierskanilo.operations;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlobCatalog;
import dosierskanilo.repository : Repository;
import dosierskanilo.repository.types : MetadataScanOptions;
import dosierskanilo.operationlease : OperationTargetBusyException,
    TargetWriteLease;
import dosierskanilo.service.jsonoperations : analyzeJsonCatalog,
    commitJsonCatalog, scanJsonCatalog;

/**
 * Execute a SQLite repository or explicit JSON catalog scan through the shared
 * operation contract. Request-shape validation remains a separate pre-dispatch
 * step.
 */
OperationResult runOperation(ScanOperationRequest request,
    OperationControl control)
{
    auto validation = validateOperationRequest(request);
    enforce(validation.valid, validation.message);
    if (control is null)
        control = new OperationControl();

    OperationResult result;
    result.operationId = request.operationId;
    result.operation = OperationKind.scan;
    result.state = OperationState.running;
    TargetWriteLease lease;
    try
        lease = acquireOperationTargetLease(request.target);
    catch (OperationTargetBusyException ex)
        return failedOperation(request.operationId, OperationKind.scan,
            OperationErrorCode.targetBusy, ex.msg);
    catch (Exception ex)
        return failedOperation(request.operationId, OperationKind.scan,
            OperationErrorCode.backendFailure, ex.msg);
    scope (exit)
        lease.release();

    if (request.target.mode == OperationStorageMode.jsonCatalog)
    {
        auto jsonResult = runJsonScanOperation(request, control);
        lease.release();
        return jsonResult;
    }

    control.setPauseAvailable(false);
    Repository repository;
    try
    {
        reportOperation(control, request.operationId, OperationKind.scan,
            OperationPhase.validating, OperationState.running,
            "Opening repository.");
        if (control.cancellationRequested)
        {
            result.state = OperationState.cancelled;
        }
        else
        {
            repository = Repository.open(request.target.repositoryRoot);
            auto execution = repository.scanControlled(request.scanOptions,
                control, request.operationId, lease);
            result.scanSummary = execution.summary;
            result.changesCommitted = execution.committed;
            if (execution.cancelled)
                result.state = OperationState.cancelled;
            else if (requestsMetadata(request.metadataOptions))
            {
                auto metadata = repository.updateMetadataControlled(
                    request.metadataOptions, control, request.operationId, lease);
                result.metadataSummary = metadata.summary;
                result.changesCommitted = result.changesCommitted
                    || metadata.committed;
                result.state = metadata.cancelled ? OperationState.cancelled
                    : OperationState.completed;
            }
            else
                result.state = OperationState.completed;
        }
    }
    catch (OperationCallbackException ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.callbackFailure;
        result.error = ex.msg;
    }
    catch (Exception ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.backendFailure;
        result.error = ex.msg;
    }
    finally
    {
        if (repository !is null)
            repository.close();
    }

    if (result.state == OperationState.completed
        || result.state == OperationState.cancelled)
        result.errorCode = OperationErrorCode.none;
    auto phase = result.state == OperationState.failed
        ? OperationPhase.validating : OperationPhase.scanning;
    auto message = result.state == OperationState.completed
        ? "Repository scan completed."
        : result.state == OperationState.cancelled
            ? "Repository scan cancelled; staged changes were discarded."
            : result.error;
    try
        reportOperation(control, request.operationId, OperationKind.scan,
            phase, result.state, message, result.scanSummary.filesFound, false);
    catch (OperationCallbackException ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.callbackFailure;
        result.error = ex.msg;
    }
    return result;
}

/** Execute repository metadata extraction through the shared operation contract. */
OperationResult runOperation(MetadataOperationRequest request,
    OperationControl control)
{
    auto validation = validateOperationRequest(request);
    enforce(validation.valid, validation.message);
    enforce(request.target.mode == OperationStorageMode.repository,
        "The metadata executor requires a repository target.");
    if (control is null)
        control = new OperationControl();

    OperationResult result;
    result.operationId = request.operationId;
    result.operation = OperationKind.metadata;
    result.state = OperationState.running;
    TargetWriteLease lease;
    try
        lease = acquireOperationTargetLease(request.target);
    catch (OperationTargetBusyException ex)
        return failedOperation(request.operationId, OperationKind.metadata,
            OperationErrorCode.targetBusy, ex.msg);
    catch (Exception ex)
        return failedOperation(request.operationId, OperationKind.metadata,
            OperationErrorCode.backendFailure, ex.msg);
    scope (exit)
        lease.release();

    control.setPauseAvailable(false);
    Repository repository;
    try
    {
        reportOperation(control, request.operationId, OperationKind.metadata,
            OperationPhase.validating, OperationState.running,
            "Opening repository.");
        if (control.cancellationRequested)
            result.state = OperationState.cancelled;
        else
        {
            repository = Repository.open(request.target.repositoryRoot);
            auto execution = repository.updateMetadataControlled(request.options,
                control, request.operationId, lease);
            result.metadataSummary = execution.summary;
            result.changesCommitted = execution.committed;
            result.state = execution.cancelled ? OperationState.cancelled
                : OperationState.completed;
        }
    }
    catch (OperationCallbackException ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.callbackFailure;
        result.error = ex.msg;
    }
    catch (Exception ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.backendFailure;
        result.error = ex.msg;
    }
    finally
    {
        if (repository !is null)
            repository.close();
    }

    if (result.state == OperationState.completed
        || result.state == OperationState.cancelled)
        result.errorCode = OperationErrorCode.none;
    try
        reportOperation(control, request.operationId, OperationKind.metadata,
            metadataFinalPhase(request.options), result.state,
            result.state == OperationState.completed
                ? "Repository metadata operation completed."
                : result.state == OperationState.cancelled
                    ? "Repository metadata operation cancelled."
                    : result.error,
            result.metadataSummary.blobsVisited);
    catch (OperationCallbackException ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.callbackFailure;
        result.error = ex.msg;
    }
    return result;
}

/** Execute repository analysis through the shared operation contract. */
OperationResult runOperation(AnalysisOperationRequest request,
    OperationControl control)
{
    auto validation = validateOperationRequest(request);
    enforce(validation.valid, validation.message);
    if (control is null)
        control = new OperationControl();

    OperationResult result;
    result.operationId = request.operationId;
    result.operation = OperationKind.analyze;
    result.state = OperationState.running;
    TargetWriteLease lease;
    try
        lease = acquireOperationTargetLease(request.target);
    catch (OperationTargetBusyException ex)
        return failedOperation(request.operationId, OperationKind.analyze,
            OperationErrorCode.targetBusy, ex.msg);
    catch (Exception ex)
        return failedOperation(request.operationId, OperationKind.analyze,
            OperationErrorCode.backendFailure, ex.msg);
    scope (exit)
        lease.release();

    if (request.target.mode == OperationStorageMode.jsonCatalog)
    {
        auto jsonResult = runJsonAnalysisOperation(request, control);
        lease.release();
        return jsonResult;
    }

    control.setPauseAvailable(false);
    Repository repository;
    try
    {
        reportOperation(control, request.operationId, OperationKind.analyze,
            OperationPhase.validating, OperationState.running,
            "Opening repository.");
        if (control.cancellationRequested)
            result.state = OperationState.cancelled;
        else
        {
            repository = Repository.open(request.target.repositoryRoot);
            auto execution = repository.analyzeControlled(request.options,
                control, request.operationId, lease);
            result.analysisSummary = execution.summary;
            result.changesCommitted = execution.committed;
            result.state = execution.cancelled ? OperationState.cancelled
                : OperationState.completed;
        }
    }
    catch (OperationCallbackException ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.callbackFailure;
        result.error = ex.msg;
    }
    catch (Exception ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.backendFailure;
        result.error = ex.msg;
    }
    finally
    {
        if (repository !is null)
            repository.close();
    }

    if (result.state == OperationState.completed
        || result.state == OperationState.cancelled)
        result.errorCode = OperationErrorCode.none;
    try
        reportOperation(control, request.operationId, OperationKind.analyze,
            OperationPhase.analysisCleanup, result.state,
            result.state == OperationState.completed
                ? "Repository analysis completed."
                : result.state == OperationState.cancelled
                    ? "Repository analysis cancelled; staged changes were discarded."
                    : result.error,
            result.analysisSummary.mergedBlobs);
    catch (OperationCallbackException ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.callbackFailure;
        result.error = ex.msg;
    }
    return result;
}

private OperationPhase metadataFinalPhase(MetadataScanOptions options)
{
    if (options.scanTorrents) return OperationPhase.torrents;
    if (options.scanArchives) return OperationPhase.archives;
    if (options.extractMediaInfo) return OperationPhase.mediaInfo;
    if (options.detectFileTypes) return OperationPhase.fileTypes;
    if (options.calculateChecksums) return OperationPhase.checksums;
    return OperationPhase.discovering;
}

private OperationResult runJsonScanOperation(ScanOperationRequest request,
    OperationControl control)
{
    OperationResult result;
    result.operationId = request.operationId;
    result.operation = OperationKind.scan;
    result.state = OperationState.running;
    control.setPauseAvailable(false);
    try
    {
        reportOperation(control, request.operationId, OperationKind.scan,
            OperationPhase.jsonRead, OperationState.running,
            "Reading JSON catalog.");
        if (control.cancellationRequested)
            result.state = OperationState.cancelled;
        else
        {
            auto execution = scanJsonCatalog(request.target.catalogPath,
                request.target.filesystemRoot, request.forceJsonOverwrite,
                request.scanOptions, request.metadataOptions, control,
                request.operationId);
            result.scanSummary = execution.scanSummary;
            result.metadataSummary = execution.metadataSummary;
            if (execution.cancelled)
                result.state = OperationState.cancelled;
            else if (!commitJsonAtSafePoint(request.target.catalogPath,
                execution.catalog, control, request.operationId,
                OperationKind.scan))
                result.state = OperationState.cancelled;
            else
            {
                result.changesCommitted = true;
                result.state = OperationState.completed;
            }
        }
    }
    catch (OperationCallbackException ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.callbackFailure;
        result.error = ex.msg;
    }
    catch (Exception ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.backendFailure;
        result.error = ex.msg;
    }
    if (result.state == OperationState.completed
        || result.state == OperationState.cancelled)
        result.errorCode = OperationErrorCode.none;
    return result;
}

private OperationResult runJsonAnalysisOperation(AnalysisOperationRequest request,
    OperationControl control)
{
    OperationResult result;
    result.operationId = request.operationId;
    result.operation = OperationKind.analyze;
    result.state = OperationState.running;
    control.setPauseAvailable(false);
    try
    {
        reportOperation(control, request.operationId, OperationKind.analyze,
            OperationPhase.jsonRead, OperationState.running,
            "Reading JSON catalog.");
        if (control.cancellationRequested)
            result.state = OperationState.cancelled;
        else
        {
            auto execution = analyzeJsonCatalog(request.target.catalogPath,
                request.forceJsonOverwrite, request.metadataOptions,
                request.options, control, request.operationId);
            result.metadataSummary = execution.metadataSummary;
            result.analysisSummary = execution.analysisSummary;
            if (execution.cancelled)
                result.state = OperationState.cancelled;
            else if (!commitJsonAtSafePoint(request.target.catalogPath,
                execution.catalog, control, request.operationId,
                OperationKind.analyze))
                result.state = OperationState.cancelled;
            else
            {
                result.changesCommitted = true;
                result.state = OperationState.completed;
            }
        }
    }
    catch (OperationCallbackException ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.callbackFailure;
        result.error = ex.msg;
    }
    catch (Exception ex)
    {
        result.state = OperationState.failed;
        result.errorCode = OperationErrorCode.backendFailure;
        result.error = ex.msg;
    }
    if (result.state == OperationState.completed
        || result.state == OperationState.cancelled)
        result.errorCode = OperationErrorCode.none;
    return result;
}

private bool commitJsonAtSafePoint(string catalogPath,
    ref NamedBinaryBlobCatalog catalog, OperationControl control, ulong operationId,
    OperationKind operation)
{
    control.setPauseAvailable(true);
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = operation;
    progress.state = OperationState.running;
    progress.phase = OperationPhase.jsonWrite;
    progress.message = "Ready to replace JSON catalog.";
    control.report(progress);
    if (!control.pauseAtCheckpoint(progress) || control.cancellationRequested)
        return false;
    control.setPauseAvailable(false);
    enforce(commitJsonCatalog(catalogPath, catalog),
        "Failed to write JSON catalog without replacing the existing data.");
    return true;
}

private void reportOperation(OperationControl control, ulong operationId,
    OperationKind operation, OperationPhase phase, OperationState state,
    string message, size_t completed = 0, bool totalKnown = false)
{
    OperationProgress progress;
    progress.operationId = operationId;
    progress.operation = operation;
    progress.state = state;
    progress.phase = phase;
    progress.completed = completed;
    progress.totalKnown = totalKnown;
    progress.message = message;
    control.report(progress);
}

private OperationResult failedOperation(ulong operationId, OperationKind operation,
    OperationErrorCode errorCode, string message)
{
    OperationResult result;
    result.operationId = operationId;
    result.operation = operation;
    result.state = OperationState.failed;
    result.errorCode = errorCode;
    result.error = message;
    return result;
}

private TargetWriteLease acquireOperationTargetLease(OperationTarget target)
{
    if (target.mode == OperationStorageMode.repository)
    {
        auto repositoryRoot = Repository.findRoot(target.repositoryRoot);
        if (repositoryRoot.length > 0)
            target.repositoryRoot = repositoryRoot;
    }
    return TargetWriteLease.acquire(target);
}

private bool requestsMetadata(MetadataScanOptions options)
{
    return options.calculateChecksums || options.detectFileTypes
        || options.extractMediaInfo || options.scanArchives || options.scanTorrents;
}

@("controlled repository scan can pause and resume at a staging checkpoint")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.conv : to;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-scan-pause-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    foreach (index; 0 .. 5)
        write(buildPath(root, "file-" ~ index.to!string ~ ".txt"), "content");
    auto repository = Repository.initialize(root);
    repository.close();

    shared bool requestedPause;
    shared bool acknowledgedPause;
    shared bool acknowledgedResume;
    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.scanning
            && event.state == OperationState.running && event.completed > 0
            && !atomicLoad(requestedPause))
        {
            atomicStore(requestedPause, control.requestPause());
        }
        else if (event.state == OperationState.paused)
        {
            atomicStore(acknowledgedPause, true);
            control.requestResume();
        }
        else if (event.state == OperationState.running
            && event.message == "Operation resumed.")
            atomicStore(acknowledgedResume, true);
    });
    ScanOperationRequest request;
    request.operationId = 101;
    request.target = OperationTarget.repositoryTarget(root);
    auto result = runOperation(request, control);

    assert(result.state == OperationState.completed, result.error);
    assert(result.scanSummary.filesAdded == 5);
    assert(atomicLoad(requestedPause));
    assert(atomicLoad(acknowledgedPause));
    assert(atomicLoad(acknowledgedResume));
}

@("cancelled repository scan leaves catalog unchanged")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.file : exists, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import dosierskanilo.testdata : copySyntheticCatalogForTest;

    auto root = buildPath(tempDir(), "operation-scan-cancel-"
        ~ randomUUID().toString());
    copySyntheticCatalogForTest(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    auto repository = Repository.initialize(root);
    repository.close();
    ScanOperationRequest request;
    request.operationId = 102;
    request.target = OperationTarget.repositoryTarget(root);
    request.scanOptions.recursive = true;
    auto initial = runOperation(request, new OperationControl());
    assert(initial.state == OperationState.completed);
    assert(initial.scanSummary.filesAdded == 12);

    OperationControl failureControl = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.scanning && event.completed > 0)
            throw new Exception("injected generated-catalog scan failure");
    });
    request.operationId = 103;
    auto failed = runOperation(request, failureControl);
    assert(failed.state == OperationState.failed);
    assert(failed.errorCode == OperationErrorCode.callbackFailure);
    assert(!failed.changesCommitted);
    repository = Repository.open(root);
    assert(repository.blobCount == 12);
    repository.close();

    write(buildPath(root, "new.txt"), "new");
    shared bool cancellationSent;
    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.scanning && event.completed > 0
            && !atomicLoad(cancellationSent))
        {
            control.requestCancellation();
            atomicStore(cancellationSent, true);
        }
    });
    request.operationId = 104;
    auto cancelled = runOperation(request, control);
    assert(cancelled.state == OperationState.cancelled);
    assert(cancelled.errorCode == OperationErrorCode.none);
    assert(!cancelled.changesCommitted);
    assert(atomicLoad(cancellationSent));

    repository = Repository.open(root);
    scope (exit)
        repository.close();
    assert(repository.blobCount == 12,
        "temporary staged rows must not change the catalog after cancellation");
}

@("controlled metadata acknowledges pause after committing complete blob units")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-metadata-pause-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "one.txt"), "one");
    write(buildPath(root, "two.txt"), "two");
    auto repository = Repository.initialize(root);
    repository.close();

    ScanOperationRequest scanRequest;
    scanRequest.operationId = 201;
    scanRequest.target = OperationTarget.repositoryTarget(root);
    assert(runOperation(scanRequest, new OperationControl()).state
        == OperationState.completed);

    shared bool pauseSent;
    shared bool pauseAcknowledged;
    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.operation == OperationKind.metadata
            && event.phase == OperationPhase.checksums
            && event.state == OperationState.running && event.completed > 0
            && !atomicLoad(pauseSent))
            atomicStore(pauseSent, control.requestPause());
        else if (event.state == OperationState.paused)
        {
            atomicStore(pauseAcknowledged, true);
            control.requestResume();
        }
    });
    MetadataOperationRequest request;
    request.operationId = 202;
    request.target = OperationTarget.repositoryTarget(root);
    request.options.calculateChecksums = true;
    auto result = runOperation(request, control);

    assert(result.state == OperationState.completed, result.error);
    assert(result.metadataSummary.checksumsUpdated == 2);
    assert(atomicLoad(pauseSent));
    assert(atomicLoad(pauseAcknowledged));
}

@("metadata cancellation retains only complete committed blob results")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-metadata-cancel-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "one.txt"), "one");
    write(buildPath(root, "two.txt"), "two");
    auto repository = Repository.initialize(root);
    repository.close();
    ScanOperationRequest scan;
    scan.operationId = 211;
    scan.target = OperationTarget.repositoryTarget(root);
    assert(runOperation(scan, new OperationControl()).state
        == OperationState.completed);

    shared bool cancellationSent;
    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.operation == OperationKind.metadata
            && event.phase == OperationPhase.checksums
            && event.state == OperationState.running
            && !atomicLoad(cancellationSent))
        {
            control.requestCancellation();
            atomicStore(cancellationSent, true);
        }
    });
    MetadataOperationRequest request;
    request.operationId = 212;
    request.target = OperationTarget.repositoryTarget(root);
    request.options.calculateChecksums = true;
    request.options.threads = 2;
    auto result = runOperation(request, control);

    assert(result.state == OperationState.cancelled);
    assert(atomicLoad(cancellationSent));
    assert(result.changesCommitted,
        "completed per-blob metadata commits remain visible after cancellation");
    assert(result.metadataSummary.checksumsUpdated == 2,
        "the drained active batch persists only full blob results");
    repository = Repository.open(root);
    scope (exit)
        repository.close();
    foreach (blob; repository.loadCatalog())
        assert(blob.checkSums.hasDigests);
}

@("controlled analysis pause preserves transaction atomicity")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-analysis-pause-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "one.txt"), "duplicate");
    write(buildPath(root, "two.txt"), "duplicate");
    auto repository = Repository.initialize(root);
    repository.close();

    ScanOperationRequest scan;
    scan.operationId = 301;
    scan.target = OperationTarget.repositoryTarget(root);
    assert(runOperation(scan, new OperationControl()).state
        == OperationState.completed);
    MetadataOperationRequest metadata;
    metadata.operationId = 302;
    metadata.target = OperationTarget.repositoryTarget(root);
    metadata.options.calculateChecksums = true;
    assert(runOperation(metadata, new OperationControl()).state
        == OperationState.completed);

    shared bool pauseRequested;
    shared bool pauseAcknowledged;
    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.analysisDuplicates
            && event.state == OperationState.running
            && !atomicLoad(pauseRequested))
            atomicStore(pauseRequested, control.requestPause());
        else if (event.state == OperationState.paused)
        {
            atomicStore(pauseAcknowledged, true);
            control.requestResume();
        }
    });
    AnalysisOperationRequest request;
    request.operationId = 303;
    request.target = OperationTarget.repositoryTarget(root);
    auto result = runOperation(request, control);

    assert(result.state == OperationState.completed);
    assert(result.analysisSummary.duplicateGroups == 1);
    assert(result.analysisSummary.mergedBlobs == 1);
    assert(atomicLoad(pauseRequested));
    assert(atomicLoad(pauseAcknowledged));
}

@("cancelled analysis leaves staged catalog changes unapplied")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-analysis-cancel-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "one.txt"), "duplicate");
    write(buildPath(root, "two.txt"), "duplicate");
    auto repository = Repository.initialize(root);
    repository.close();

    ScanOperationRequest scan;
    scan.operationId = 401;
    scan.target = OperationTarget.repositoryTarget(root);
    assert(runOperation(scan, new OperationControl()).state
        == OperationState.completed);
    MetadataOperationRequest metadata;
    metadata.operationId = 402;
    metadata.target = OperationTarget.repositoryTarget(root);
    metadata.options.calculateChecksums = true;
    assert(runOperation(metadata, new OperationControl()).state
        == OperationState.completed);

    shared bool cancellationSent;
    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.analysisCleanup
            && event.state == OperationState.running
            && !atomicLoad(cancellationSent))
        {
            control.requestCancellation();
            atomicStore(cancellationSent, true);
        }
    });
    AnalysisOperationRequest request;
    request.operationId = 403;
    request.target = OperationTarget.repositoryTarget(root);
    auto result = runOperation(request, control);

    assert(result.state == OperationState.cancelled);
    assert(atomicLoad(cancellationSent));
    assert(!result.changesCommitted);
    repository = Repository.open(root);
    scope (exit)
        repository.close();
    assert(repository.blobCount == 2);
}

@("cancelled JSON scan never creates or replaces its catalog")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-json-scan-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto catalogPath = buildPath(tempDir(), "operation-json-catalog-"
        ~ randomUUID().toString() ~ ".json");
    scope (exit)
    {
        if (exists(catalogPath))
            remove(catalogPath);
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "first.txt"), "first");

    shared bool cancellationSent;
    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.scanning
            && event.state == OperationState.running && event.completed > 0
            && !atomicLoad(cancellationSent))
        {
            control.requestCancellation();
            atomicStore(cancellationSent, true);
        }
    });
    ScanOperationRequest request;
    request.operationId = 501;
    request.target = OperationTarget.jsonTarget(catalogPath, root);
    auto result = runOperation(request, control);

    assert(result.state == OperationState.cancelled);
    assert(atomicLoad(cancellationSent));
    assert(!result.changesCommitted);
    assert(!exists(catalogPath));
}

@("JSON scan and analyze use shared operation requests and preserve JSON targets")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.algorithm.searching : startsWith;
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, mkdirRecurse,
        remove, rmdirRecurse, tempDir, write;
    import std.path : baseName, buildPath;
    import std.uuid : randomUUID;
    import dosierskanilo.model.namedbinaryblob : deserializeDataClassJsonWrapperFile;

    auto token = randomUUID().toString();
    auto root = buildPath(tempDir(), "operation-json-roundtrip-" ~ token);
    mkdirRecurse(root);
    auto catalogPath = buildPath(tempDir(), "operation-json-roundtrip-"
        ~ token ~ ".json");
    auto backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
    scope (exit)
    {
        if (exists(catalogPath))
            remove(catalogPath);
        foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
        {
            if (entry.name.baseName.startsWith(backupPrefix) && exists(entry.name))
                remove(entry.name);
        }
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "one.txt"), "same payload");
    write(buildPath(root, "two.txt"), "same payload");

    ScanOperationRequest scan;
    scan.operationId = 502;
    scan.target = OperationTarget.jsonTarget(catalogPath, root);
    scan.metadataOptions.calculateChecksums = true;
    shared bool pauseSent;
    shared bool pauseAcknowledged;
    OperationControl scanControl;
    scanControl = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.jsonWrite
            && event.state == OperationState.running
            && !atomicLoad(pauseSent))
            atomicStore(pauseSent, scanControl.requestPause());
        else if (event.state == OperationState.paused)
        {
            atomicStore(pauseAcknowledged, true);
            scanControl.requestResume();
        }
    });
    auto scanned = runOperation(scan, scanControl);
    assert(scanned.state == OperationState.completed, scanned.error);
    assert(scanned.scanSummary.filesAdded == 2);
    assert(scanned.metadataSummary.checksumsUpdated == 2);
    assert(atomicLoad(pauseSent));
    assert(atomicLoad(pauseAcknowledged));
    assert(exists(catalogPath));

    AnalysisOperationRequest analyze;
    analyze.operationId = 503;
    analyze.target = OperationTarget.jsonTarget(catalogPath);
    auto analyzed = runOperation(analyze, new OperationControl());
    assert(analyzed.state == OperationState.completed, analyzed.error);
    assert(analyzed.analysisSummary.duplicateGroups == 1);
    assert(analyzed.analysisSummary.mergedBlobs == 1);
    auto catalog = deserializeDataClassJsonWrapperFile(catalogPath);
    assert(catalog.dataArray.length == 1);
    assert(catalog.dataArray[0].fileSpecs.length == 2);
}

@("cancelled JSON analysis leaves the catalog file unchanged")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse,
        tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto token = randomUUID().toString();
    auto root = buildPath(tempDir(), "operation-json-analysis-cancel-" ~ token);
    mkdirRecurse(root);
    auto catalogPath = buildPath(tempDir(), "operation-json-analysis-cancel-"
        ~ token ~ ".json");
    scope (exit)
    {
        if (exists(catalogPath))
            remove(catalogPath);
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "one.txt"), "same payload");
    write(buildPath(root, "two.txt"), "same payload");
    ScanOperationRequest scan;
    scan.operationId = 701;
    scan.target = OperationTarget.jsonTarget(catalogPath, root);
    scan.metadataOptions.calculateChecksums = true;
    assert(runOperation(scan, new OperationControl()).state
        == OperationState.completed);
    auto originalCatalog = readText(catalogPath);

    shared bool cancellationSent;
    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.analysisDuplicates
            && event.state == OperationState.running
            && !atomicLoad(cancellationSent))
        {
            control.requestCancellation();
            atomicStore(cancellationSent, true);
        }
    });
    AnalysisOperationRequest analyze;
    analyze.operationId = 702;
    analyze.target = OperationTarget.jsonTarget(catalogPath);
    auto result = runOperation(analyze, control);

    assert(result.state == OperationState.cancelled);
    assert(atomicLoad(cancellationSent));
    assert(!result.changesCommitted);
    assert(readText(catalogPath) == originalCatalog);
}

@("JSON analysis preserves missing records unless drop-missing was requested")
unittest
{
    import std.algorithm.searching : startsWith;
    import std.datetime.systime : Clock;
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, remove,
        tempDir;
    import std.path : baseName, buildPath;
    import std.uuid : randomUUID;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION3,
        NamedBinaryBlob, NamedBinaryBlobCatalog,
        deserializeDataClassJsonWrapperFile, serializeDataClassWrapperFile;

    auto token = randomUUID().toString();
    auto catalogPath = buildPath(tempDir(), "operation-json-missing-"
        ~ token ~ ".json");
    auto backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
    scope (exit)
    {
        if (exists(catalogPath))
            remove(catalogPath);
        foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
            if (entry.name.baseName.startsWith(backupPrefix) && exists(entry.name))
                remove(entry.name);
    }
    auto missingPath = buildPath(tempDir(), "missing-" ~ token ~ ".txt");
    auto blob = new NamedBinaryBlob(missingPath, 42, Clock.currTime());
    auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, [blob]);
    serializeDataClassWrapperFile(catalogPath, catalog);

    AnalysisOperationRequest request;
    request.operationId = 901;
    request.target = OperationTarget.jsonTarget(catalogPath);
    auto retained = runOperation(request, new OperationControl());
    assert(retained.state == OperationState.completed, retained.error);
    assert(retained.analysisSummary.missingFiles == 1);
    assert(retained.analysisSummary.droppedFiles == 0);
    assert(retained.changesCommitted);
    assert(deserializeDataClassJsonWrapperFile(catalogPath).dataArray.length == 1,
        "analysis without drop-missing must preserve unavailable source records");

    request.operationId = 902;
    request.options.dropMissing = true;
    auto dropped = runOperation(request, new OperationControl());
    assert(dropped.state == OperationState.completed, dropped.error);
    assert(dropped.analysisSummary.droppedFiles == 1);
    assert(deserializeDataClassJsonWrapperFile(catalogPath).dataArray.length == 0);
}

@("JSON operations selectively drop a missing generated source")
unittest
{
    import std.algorithm.searching : startsWith;
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, remove,
        rmdirRecurse, tempDir;
    import std.path : baseName, buildPath;
    import std.uuid : randomUUID;
    import dosierskanilo.model.namedbinaryblob :
        deserializeDataClassJsonWrapperFile;
    import dosierskanilo.testdata : copySyntheticCatalogForTest;

    auto token = randomUUID().toString();
    auto root = buildPath(tempDir(), "operation-json-generated-missing-" ~ token);
    copySyntheticCatalogForTest(root);
    auto catalogPath = buildPath(tempDir(), "operation-json-generated-missing-"
        ~ token ~ ".json");
    auto backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
    scope (exit)
    {
        if (exists(catalogPath))
            remove(catalogPath);
        foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
            if (entry.name.baseName.startsWith(backupPrefix) && exists(entry.name))
                remove(entry.name);
        if (exists(root))
            rmdirRecurse(root);
    }

    ScanOperationRequest scan;
    scan.operationId = 905;
    scan.target = OperationTarget.jsonTarget(catalogPath, root);
    scan.scanOptions.recursive = true;
    scan.metadataOptions.calculateChecksums = true;
    auto scanned = runOperation(scan, new OperationControl());
    assert(scanned.state == OperationState.completed, scanned.error);
    assert(scanned.scanSummary.filesAdded == 12);

    auto missingPath = buildPath(root, "same-size", "different.txt");
    remove(missingPath);
    AnalysisOperationRequest analyze;
    analyze.operationId = 906;
    analyze.target = OperationTarget.jsonTarget(catalogPath);
    auto retained = runOperation(analyze, new OperationControl());
    assert(retained.state == OperationState.completed, retained.error);
    assert(retained.analysisSummary.missingFiles == 1);
    assert(retained.analysisSummary.droppedFiles == 0);
    bool missingReferenceRetained;
    foreach (blob; deserializeDataClassJsonWrapperFile(catalogPath).dataArray)
        foreach (file; blob.fileSpecs)
            if (file.fileName == missingPath)
                missingReferenceRetained = true;
    assert(missingReferenceRetained);

    analyze.operationId = 907;
    analyze.options.dropMissing = true;
    auto dropped = runOperation(analyze, new OperationControl());
    assert(dropped.state == OperationState.completed, dropped.error);
    assert(dropped.analysisSummary.droppedFiles == 1);
    bool missingReferenceStillPresent;
    foreach (blob; deserializeDataClassJsonWrapperFile(catalogPath).dataArray)
        foreach (file; blob.fileSpecs)
            if (file.fileName == missingPath)
                missingReferenceStillPresent = true;
    assert(!missingReferenceStillPresent);
}

@("repository and JSON operation requests preserve scan and analysis parity")
unittest
{
    import std.algorithm.sorting : sort;
    import std.algorithm.searching : canFind, endsWith, startsWith;
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd,
        remove, rmdirRecurse, tempDir;
    import std.conv : to;
    import std.format : format;
    import std.path : baseName, buildNormalizedPath, buildPath, dirSeparator;
    import std.uuid : randomUUID;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
        deserializeDataClassJsonWrapperFile;
    import dosierskanilo.repository.types : JsonExportOptions;
    import dosierskanilo.testdata : copySyntheticCatalogForTest;

    auto token = randomUUID().toString();
    auto root = buildPath(tempDir(), "operation-mode-parity-" ~ token);
    copySyntheticCatalogForTest(root);
    auto catalogPath = buildPath(tempDir(), "operation-mode-parity-"
        ~ token ~ ".json");
    auto exportPath = buildPath(tempDir(), "operation-mode-parity-export-"
        ~ token ~ ".json");
    auto backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
    scope (exit)
    {
        if (exists(catalogPath))
            remove(catalogPath);
        if (exists(exportPath))
            remove(exportPath);
        foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
            if (entry.name.baseName.startsWith(backupPrefix) && exists(entry.name))
                remove(entry.name);
        if (exists(root))
            rmdirRecurse(root);
    }
    auto repository = Repository.initialize(root);
    repository.close();

    ScanOperationRequest sqliteScan;
    sqliteScan.operationId = 801;
    sqliteScan.target = OperationTarget.repositoryTarget(root);
    sqliteScan.scanOptions.recursive = true;
    sqliteScan.metadataOptions.calculateChecksums = true;
    sqliteScan.metadataOptions.detectFileTypes = true;
    sqliteScan.metadataOptions.extractMediaInfo = true;
    sqliteScan.metadataOptions.scanArchives = true;
    sqliteScan.metadataOptions.deepArchiveScan = true;
    sqliteScan.metadataOptions.scanTorrents = true;
    sqliteScan.metadataOptions.threads = 2;
    auto sqliteScanned = runOperation(sqliteScan, new OperationControl());
    ScanOperationRequest jsonScan;
    jsonScan.operationId = 802;
    jsonScan.target = OperationTarget.jsonTarget(catalogPath, root);
    jsonScan.scanOptions.recursive = true;
    jsonScan.metadataOptions.calculateChecksums = true;
    jsonScan.metadataOptions.detectFileTypes = true;
    jsonScan.metadataOptions.extractMediaInfo = true;
    jsonScan.metadataOptions.scanArchives = true;
    jsonScan.metadataOptions.deepArchiveScan = true;
    jsonScan.metadataOptions.scanTorrents = true;
    jsonScan.metadataOptions.threads = 2;
    auto jsonScanned = runOperation(jsonScan, new OperationControl());
    assert(sqliteScanned.state == OperationState.completed, sqliteScanned.error);
    assert(jsonScanned.state == OperationState.completed, jsonScanned.error);
    assert(sqliteScanned.scanSummary.filesFound == jsonScanned.scanSummary.filesFound,
        format("SQLite found %s files; JSON found %s.",
            sqliteScanned.scanSummary.filesFound, jsonScanned.scanSummary.filesFound));
    assert(sqliteScanned.scanSummary.filesAdded == jsonScanned.scanSummary.filesAdded,
        format("SQLite added %s files; JSON added %s.",
            sqliteScanned.scanSummary.filesAdded, jsonScanned.scanSummary.filesAdded));
    assert(sqliteScanned.metadataSummary.checksumsUpdated
        == jsonScanned.metadataSummary.checksumsUpdated);
    assert(sqliteScanned.metadataSummary.fileTypesUpdated
        == jsonScanned.metadataSummary.fileTypesUpdated);
    assert(sqliteScanned.metadataSummary.mediaInfoUpdated
        == jsonScanned.metadataSummary.mediaInfoUpdated);
    assert(sqliteScanned.metadataSummary.archivesUpdated
        == jsonScanned.metadataSummary.archivesUpdated);
    assert(sqliteScanned.metadataSummary.torrentsUpdated
        == jsonScanned.metadataSummary.torrentsUpdated);
    assert(sqliteScanned.metadataSummary.failed == jsonScanned.metadataSummary.failed);
    assert(sqliteScanned.scanSummary.filesFound == 12);
    assert(sqliteScanned.metadataSummary.checksumsUpdated == 12);
    assert(sqliteScanned.metadataSummary.archivesUpdated == 3);
    assert(sqliteScanned.metadataSummary.torrentsUpdated == 2);

    AnalysisOperationRequest sqliteAnalyze;
    sqliteAnalyze.operationId = 803;
    sqliteAnalyze.target = OperationTarget.repositoryTarget(root);
    auto sqliteAnalyzed = runOperation(sqliteAnalyze, new OperationControl());
    AnalysisOperationRequest jsonAnalyze;
    jsonAnalyze.operationId = 804;
    jsonAnalyze.target = OperationTarget.jsonTarget(catalogPath);
    auto jsonAnalyzed = runOperation(jsonAnalyze, new OperationControl());
    assert(sqliteAnalyzed.state == OperationState.completed, sqliteAnalyzed.error);
    assert(jsonAnalyzed.state == OperationState.completed,
        format("JSON state %s, error '%s'.", jsonAnalyzed.state,
            jsonAnalyzed.error));
    assert(sqliteAnalyzed.analysisSummary.duplicateGroups
        == jsonAnalyzed.analysisSummary.duplicateGroups,
        "SQLite duplicates=" ~ sqliteAnalyzed.analysisSummary.duplicateGroups.to!string
        ~ ", JSON duplicates=" ~ jsonAnalyzed.analysisSummary.duplicateGroups.to!string);
    assert(sqliteAnalyzed.analysisSummary.mergedBlobs
        == jsonAnalyzed.analysisSummary.mergedBlobs,
        "SQLite merged=" ~ sqliteAnalyzed.analysisSummary.mergedBlobs.to!string
        ~ ", JSON merged=" ~ jsonAnalyzed.analysisSummary.mergedBlobs.to!string);
    assert(sqliteAnalyzed.analysisSummary.duplicateGroups == 1);
    assert(sqliteAnalyzed.analysisSummary.mergedBlobs == 1);
    repository = Repository.open(root);
    scope (exit)
        repository.close();
    auto jsonCatalog = deserializeDataClassJsonWrapperFile(catalogPath);
    auto sqliteCatalog = repository.loadCatalog();
    assert(jsonCatalog.dataVersion == DATA_CLASS_VERSION5);
    size_t referenceCount;
    size_t sharedBlobs;
    bool nestedJsonIndex;
    bool nestedSqliteIndex;
    string[string] sqliteDigestsByPath;
    string[string] jsonDigestsByPath;
    auto sourcePrefix = buildNormalizedPath(root) ~ dirSeparator;
    foreach (blob; sqliteCatalog)
    {
        foreach (file; blob.fileSpecs)
            if (file.fileName.endsWith("!/nested.zip"))
                nestedSqliteIndex = true;
        referenceCount += blob.fileSpecs.length;
        foreach (file; blob.fileSpecs)
        {
            auto path = buildNormalizedPath(file.fileName);
            auto relative = path.startsWith(sourcePrefix)
                ? path[sourcePrefix.length .. $] : file.fileName;
            sqliteDigestsByPath[relative] = blob.checkSums.sha1sum_b64;
        }
        if (blob.fileSpecs.length == 2)
            ++sharedBlobs;
    }
    foreach (blob; jsonCatalog.dataArray)
    {
        foreach (file; blob.fileSpecs)
        {
            if (file.fileName.endsWith("!/nested.zip"))
                nestedJsonIndex = true;
            auto path = buildNormalizedPath(file.fileName);
            auto relative = path.startsWith(sourcePrefix)
                ? path[sourcePrefix.length .. $] : file.fileName;
            jsonDigestsByPath[relative] = blob.checkSums.sha1sum_b64;
        }
    }
    assert(nestedJsonIndex && nestedSqliteIndex);
    assert(referenceCount == sqliteDigestsByPath.length);
    assert(sharedBlobs > 0);
    string[] sqlitePaths;
    string[] jsonPaths;
    foreach (path; sqliteDigestsByPath.keys)
        sqlitePaths ~= path;
    foreach (path; jsonDigestsByPath.keys)
        jsonPaths ~= path;
    sqlitePaths.sort;
    jsonPaths.sort;
    assert(sqlitePaths == jsonPaths);
    foreach (path; sqlitePaths)
        assert(sqliteDigestsByPath[path] == jsonDigestsByPath[path]);

    JsonExportOptions exportOptions;
    exportOptions.pathPrefix = "archives";
    repository.exportJson(exportPath, exportOptions);
    auto archiveSubset = deserializeDataClassJsonWrapperFile(exportPath);
    assert(archiveSubset.dataVersion == DATA_CLASS_VERSION5);
    assert(archiveSubset.dataArray.length > 3);
    bool exportedNestedArchive;
    foreach (blob; archiveSubset.dataArray)
        foreach (file; blob.fileSpecs)
            if (file.fileName.endsWith("!/nested.zip"))
                exportedNestedArchive = true;
    assert(exportedNestedArchive);
    string[] exportedArchivePaths;
    foreach (blob; archiveSubset.dataArray)
    {
        foreach (file; blob.fileSpecs)
            exportedArchivePaths ~= file.fileName;
    }
    exportedArchivePaths.sort;
    assert(exportedArchivePaths.canFind("archives/nested.zip"));
    assert(exportedArchivePaths.canFind("archives/sample.tar"));
    assert(exportedArchivePaths.canFind("archives/sample.zip"));
}

@("repository write lease remains held while an operation is paused")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import std.datetime : dur;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "operation-lease-paused-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }
    write(buildPath(root, "one.txt"), "one");
    auto repository = Repository.initialize(root);
    repository.close();

    shared bool pauseRequested;
    shared bool pauseAcknowledged;
    ScanOperationRequest request;
    request.operationId = 601;
    request.target = OperationTarget.repositoryTarget(root);
    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.phase == OperationPhase.scanning
            && event.state == OperationState.running && event.completed > 0
            && !atomicLoad(pauseRequested))
            atomicStore(pauseRequested, control.requestPause());
        else if (event.state == OperationState.paused)
            atomicStore(pauseAcknowledged, true);
    });
    OperationResult firstResult;
    auto worker = new Thread({ firstResult = runOperation(request, control); });
    worker.start();
    size_t attempts;
    while (!atomicLoad(pauseAcknowledged) && attempts++ < 5000)
        Thread.sleep(dur!"msecs"(1));
    auto acknowledged = atomicLoad(pauseAcknowledged);

    request.operationId = 602;
    auto secondResult = runOperation(request, new OperationControl());
    control.requestResume();
    worker.join();

    assert(acknowledged, "the first operation reached a safe pause point");
    assert(secondResult.state == OperationState.failed);
    assert(secondResult.errorCode == OperationErrorCode.targetBusy);
    assert(firstResult.state == OperationState.completed);
}
