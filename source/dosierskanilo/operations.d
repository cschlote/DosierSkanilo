/** Frontend-neutral request and run-control types for long-running operations. */
module dosierskanilo.operations;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;

import dosierskanilo.repository.types : AnalysisSummary, MetadataScanOptions,
    MetadataSummary, RepositoryAnalysisOptions, RepositoryScanOptions, ScanSummary;

/** Select the storage implementation explicitly for an operation. */
enum OperationStorageMode
{
    repository,
    jsonCatalog
}

/** Shared operation families supported by the first operation API version. */
enum OperationKind
{
    scan,
    metadata,
    analyze
}

/** Lifecycle states used in progress notifications and terminal results. */
enum OperationState
{
    queued,
    running,
    cancelling,
    completed,
    cancelled,
    failed
}

/** Whether a task lifecycle transition is allowed by the shared contract. */
bool validOperationStateTransition(OperationState current, OperationState next)
{
    final switch (current)
    {
    case OperationState.queued:
        return next == OperationState.running || next == OperationState.cancelled
            || next == OperationState.failed;
    case OperationState.running:
        return next == OperationState.cancelling || next == OperationState.completed
            || next == OperationState.cancelled || next == OperationState.failed;
    case OperationState.cancelling:
        return next == OperationState.completed || next == OperationState.cancelled
            || next == OperationState.failed;
    case OperationState.completed, OperationState.cancelled, OperationState.failed:
        return false;
    }
}

/** Backend phase reported by an operation; totals may not yet be known. */
enum OperationPhase
{
    none,
    validating,
    discovering,
    scanning,
    reconcilingMissingFiles,
    checksums,
    fileTypes,
    mediaInfo,
    archives,
    torrents,
    analysisMissingFiles,
    analysisDuplicates,
    analysisCleanup,
    jsonRead,
    jsonWrite
}

/** Explicit filesystem/catalog target; no target is inferred by this API. */
struct OperationTarget
{
    OperationStorageMode mode;
    /// Root of the initialized `.dosierskanilo` repository.
    string repositoryRoot;
    /// Explicit direct-JSON catalog path.
    string catalogPath;
    /// Filesystem root for JSON scan. JSON analyze needs only `catalogPath`.
    string filesystemRoot;

    /** Construct an explicit SQLite repository target. */
    static OperationTarget repositoryTarget(string root)
    {
        OperationTarget target;
        target.mode = OperationStorageMode.repository;
        target.repositoryRoot = root;
        return target;
    }

    /** Construct an explicit JSON catalog target. */
    static OperationTarget jsonTarget(string catalog, string filesystem = "")
    {
        OperationTarget target;
        target.mode = OperationStorageMode.jsonCatalog;
        target.catalogPath = catalog;
        target.filesystemRoot = filesystem;
        return target;
    }
}

/** Request for a filesystem scan and any metadata selected for the scan. */
struct ScanOperationRequest
{
    /// Caller-assigned nonzero identity echoed in progress and result values.
    ulong operationId;
    OperationTarget target;
    RepositoryScanOptions scanOptions;
    MetadataScanOptions metadataOptions;
}

/** Request for standalone repository metadata extraction. */
struct MetadataOperationRequest
{
    ulong operationId;
    OperationTarget target;
    MetadataScanOptions options;
}

/** Request for duplicate/missing-file analysis. */
struct AnalysisOperationRequest
{
    ulong operationId;
    OperationTarget target;
    RepositoryAnalysisOptions options;
    /// Direct JSON analyze may run the existing selected scanner jobs first.
    /// Repository analyze rejects metadata options, as the current CLI does.
    MetadataScanOptions metadataOptions;
}

/** Validation errors detectable without opening a repository or catalog. */
enum OperationRequestError
{
    none,
    invalidOperationId,
    missingRepositoryRoot,
    invalidRepositoryTarget,
    missingCatalogPath,
    missingFilesystemRoot,
    unsupportedStorageMode,
    unsupportedOptionCombination,
    missingMetadataSelection
}

/** Typed validation outcome for a request. */
struct OperationRequestValidation
{
    OperationRequestError error;
    string message;

    @property bool valid() const
    {
        return error == OperationRequestError.none;
    }
}

/** Progress value passed from an operation executor to either frontend. */
struct OperationProgress
{
    ulong operationId;
    OperationKind operation;
    OperationState state;
    OperationPhase phase;
    ulong completed;
    ulong total;
    /// False means `completed` is a work count/status value, not a percentage.
    bool totalKnown;
    string path;
    string message;
}

/** Progress callbacks run synchronously on a reporting worker thread. */
alias OperationProgressCallback = void delegate(OperationProgress event);

/** Stable operation-level failure categories; extractor failures remain summaries. */
enum OperationErrorCode
{
    none,
    targetBusy,
    callbackFailure,
    backendFailure
}

/** Terminal result for one completed, cancelled, or failed operation. */
struct OperationResult
{
    ulong operationId;
    OperationKind operation;
    OperationState state;
    OperationErrorCode errorCode;
    string error;
    /// Populated for `scan` operations; other summaries remain their init value.
    ScanSummary scanSummary;
    /// Populated when metadata work was part of the request.
    MetadataSummary metadataSummary;
    /// Populated for `analyze` operations.
    AnalysisSummary analysisSummary;
}

/** Cooperative cancellation flag and serialized progress callback for one task. */
final class OperationControl
{
private:
    shared bool cancelRequested;
    OperationProgressCallback progressCallback;
    Mutex callbackMutex;

public:
    /** Keep this object alive until the operation and all its workers have joined. */
    this(OperationProgressCallback progressCallback = null)
    {
        this.progressCallback = progressCallback;
        callbackMutex = new Mutex();
    }

    /** Set a sticky cancellation request; executors observe it at safe points. */
    void requestCancellation() nothrow
    {
        atomicStore(cancelRequested, true);
    }

    /** Whether a caller requested cooperative cancellation. */
    @property bool cancellationRequested() const nothrow
    {
        return atomicLoad(cancelRequested);
    }

    /** Deliver an event; callback invocations are serialized, but may use a worker thread. */
    void report(OperationProgress event)
    {
        if (progressCallback is null)
            return;
        synchronized (callbackMutex)
            progressCallback(event);
    }
}

private OperationRequestValidation validationError(OperationRequestError error,
    string message)
{
    return OperationRequestValidation(error, message);
}

private OperationRequestValidation validateTarget(OperationTarget target,
    bool requireFilesystemRoot)
{
    final switch (target.mode)
    {
    case OperationStorageMode.repository:
        if (target.repositoryRoot.length == 0)
            return validationError(OperationRequestError.missingRepositoryRoot,
                "Repository operations require an explicit repository root.");
        if (target.catalogPath.length > 0 || target.filesystemRoot.length > 0)
            return validationError(OperationRequestError.invalidRepositoryTarget,
                "Repository targets cannot also contain JSON paths.");
        break;
    case OperationStorageMode.jsonCatalog:
        if (target.repositoryRoot.length > 0)
            return validationError(OperationRequestError.invalidRepositoryTarget,
                "JSON targets cannot also contain a repository root.");
        if (target.catalogPath.length == 0)
            return validationError(OperationRequestError.missingCatalogPath,
                "JSON operations require an explicit catalog path.");
        if (requireFilesystemRoot && target.filesystemRoot.length == 0)
            return validationError(OperationRequestError.missingFilesystemRoot,
                "JSON scan requires an explicit filesystem root.");
        break;
    }
    return OperationRequestValidation.init;
}

private bool requestsMetadata(MetadataScanOptions options)
{
    return options.calculateChecksums || options.detectFileTypes
        || options.extractMediaInfo || options.scanArchives || options.scanTorrents;
}

private OperationRequestValidation validateIdentity(ulong operationId)
{
    if (operationId == 0)
        return validationError(OperationRequestError.invalidOperationId,
            "Operation IDs must be nonzero.");
    return OperationRequestValidation.init;
}

/** Validate a scan request without opening either target. */
OperationRequestValidation validateOperationRequest(ScanOperationRequest request)
{
    auto identity = validateIdentity(request.operationId);
    if (!identity.valid)
        return identity;
    auto targetValidation = validateTarget(request.target, true);
    if (!targetValidation.valid)
        return targetValidation;
    if (request.target.mode == OperationStorageMode.jsonCatalog
        && request.scanOptions.dropMissing)
        return validationError(OperationRequestError.unsupportedOptionCombination,
            "JSON scan does not support drop-missing.");
    return OperationRequestValidation.init;
}

/** Validate a metadata request; standalone metadata extraction is SQLite-only. */
OperationRequestValidation validateOperationRequest(MetadataOperationRequest request)
{
    auto identity = validateIdentity(request.operationId);
    if (!identity.valid)
        return identity;
    if (request.target.mode != OperationStorageMode.repository)
        return validationError(OperationRequestError.unsupportedStorageMode,
            "Standalone metadata extraction is supported only for repositories.");
    auto targetValidation = validateTarget(request.target, false);
    if (!targetValidation.valid)
        return targetValidation;
    if (!requestsMetadata(request.options))
        return validationError(OperationRequestError.missingMetadataSelection,
            "Metadata operation requires at least one extractor.");
    return OperationRequestValidation.init;
}

/** Validate analysis target/options while preserving the separate JSON contract. */
OperationRequestValidation validateOperationRequest(AnalysisOperationRequest request)
{
    auto identity = validateIdentity(request.operationId);
    if (!identity.valid)
        return identity;
    auto targetValidation = validateTarget(request.target, false);
    if (!targetValidation.valid)
        return targetValidation;
    if (request.target.mode == OperationStorageMode.repository
        && (requestsMetadata(request.metadataOptions)
            || request.metadataOptions.rescan))
        return validationError(OperationRequestError.unsupportedOptionCombination,
            "Repository analyze cannot include metadata extraction options.");
    if (request.target.mode == OperationStorageMode.jsonCatalog
        && !request.options.mergeDuplicates)
        return validationError(OperationRequestError.unsupportedOptionCombination,
            "JSON analyze always merges duplicate records.");
    return OperationRequestValidation.init;
}

@("operation requests validate explicit targets and supported mode combinations")
unittest
{
    auto missingRepository = ScanOperationRequest(operationId: 1);
    assert(validateOperationRequest(missingRepository).error
        == OperationRequestError.missingRepositoryRoot);

    auto noIdentity = ScanOperationRequest(
        target: OperationTarget.repositoryTarget("/library"));
    assert(validateOperationRequest(noIdentity).error
        == OperationRequestError.invalidOperationId);

    auto repositoryScan = ScanOperationRequest(
        1, OperationTarget.repositoryTarget("/library"));
    assert(validateOperationRequest(repositoryScan).valid);

    auto jsonScan = ScanOperationRequest(
        2, OperationTarget.jsonTarget("/catalog.json", "/library"));
    assert(validateOperationRequest(jsonScan).valid);
    jsonScan.scanOptions.dropMissing = true;
    assert(validateOperationRequest(jsonScan).error
        == OperationRequestError.unsupportedOptionCombination);

    auto jsonScanMissingRoot = ScanOperationRequest(
        3, OperationTarget.jsonTarget("/catalog.json"));
    assert(validateOperationRequest(jsonScanMissingRoot).error
        == OperationRequestError.missingFilesystemRoot);

    auto jsonMetadata = MetadataOperationRequest(
        4, OperationTarget.jsonTarget("/catalog.json"));
    assert(validateOperationRequest(jsonMetadata).error
        == OperationRequestError.unsupportedStorageMode);

    auto emptyMetadata = MetadataOperationRequest(
        5, OperationTarget.repositoryTarget("/library"));
    assert(validateOperationRequest(emptyMetadata).error
        == OperationRequestError.missingMetadataSelection);
    emptyMetadata.options.rescan = true;
    assert(validateOperationRequest(emptyMetadata).error
        == OperationRequestError.missingMetadataSelection);
    emptyMetadata.options.calculateChecksums = true;
    assert(validateOperationRequest(emptyMetadata).valid);

    auto repositoryAnalysis = AnalysisOperationRequest(
        6, OperationTarget.repositoryTarget("/library"));
    assert(validateOperationRequest(repositoryAnalysis).valid);
    repositoryAnalysis.metadataOptions.scanTorrents = true;
    assert(validateOperationRequest(repositoryAnalysis).error
        == OperationRequestError.unsupportedOptionCombination);

    auto jsonAnalysis = AnalysisOperationRequest(
        7, OperationTarget.jsonTarget("/catalog.json"));
    jsonAnalysis.metadataOptions.calculateChecksums = true;
    assert(validateOperationRequest(jsonAnalysis).valid,
        "JSON analyze may run scanner jobs before analysis");
    jsonAnalysis.options.mergeDuplicates = false;
    assert(validateOperationRequest(jsonAnalysis).error
        == OperationRequestError.unsupportedOptionCombination);
}

@("operation lifecycle permits safe terminals and rejects resurrection")
unittest
{
    assert(validOperationStateTransition(OperationState.queued,
        OperationState.running));
    assert(validOperationStateTransition(OperationState.queued,
        OperationState.cancelled));
    assert(validOperationStateTransition(OperationState.running,
        OperationState.cancelling));
    assert(validOperationStateTransition(OperationState.running,
        OperationState.completed));
    assert(validOperationStateTransition(OperationState.cancelling,
        OperationState.completed), "completed work wins after its last checkpoint");
    assert(validOperationStateTransition(OperationState.cancelling,
        OperationState.cancelled));
    assert(!validOperationStateTransition(OperationState.queued,
        OperationState.completed));
    assert(!validOperationStateTransition(OperationState.completed,
        OperationState.running));
    assert(!validOperationStateTransition(OperationState.cancelled,
        OperationState.failed));
}

@("operation control cancellation is atomic and progress is a value event")
unittest
{
    import core.thread : Thread;

    OperationProgress received;
    bool called;
    auto control = new OperationControl((OperationProgress event) {
        received = event;
        called = true;
    });
    assert(!control.cancellationRequested);
    auto canceller = new Thread({ control.requestCancellation(); });
    canceller.start();
    canceller.join();
    assert(control.cancellationRequested);

    OperationProgress progress;
    progress.operationId = 42;
    progress.operation = OperationKind.scan;
    progress.state = OperationState.running;
    progress.phase = OperationPhase.discovering;
    progress.message = "Discovering files";
    control.report(progress);
    assert(called);
    assert(received.operationId == 42);
    assert(received.phase == OperationPhase.discovering);
    assert(!received.totalKnown);
}

@("operation progress callbacks are serialized across workers")
unittest
{
    import core.atomic : atomicExchange, atomicLoad, atomicOp, atomicStore;
    import core.thread : Thread;
    import std.datetime : dur;

    shared bool callbackActive;
    shared bool callbacksOverlapped;
    shared size_t callbackCount;
    auto control = new OperationControl((OperationProgress _) {
        if (atomicExchange(&callbackActive, true))
            atomicStore(callbacksOverlapped, true);
        Thread.sleep(dur!"msecs"(1));
        atomicStore(callbackActive, false);
        atomicOp!"+="(callbackCount, 1);
    });
    OperationProgress event;
    Thread[] workers;
    foreach (_; 0 .. 4)
    {
        workers ~= new Thread({
            foreach (_; 0 .. 10)
                control.report(event);
        });
    }
    foreach (worker; workers)
        worker.start();
    foreach (worker; workers)
        worker.join();

    assert(atomicLoad(callbackCount) == 40);
    assert(!atomicLoad(callbacksOverlapped));
}
