/** Frontend-neutral request and run-control types for long-running operations. */
module dosierskanilo.operations;

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
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
    pausing,
    paused,
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
        return next == OperationState.pausing || next == OperationState.cancelling
            || next == OperationState.completed || next == OperationState.cancelled
            || next == OperationState.failed;
    case OperationState.pausing:
        return next == OperationState.paused || next == OperationState.running
            || next == OperationState.cancelling || next == OperationState.completed
            || next == OperationState.failed;
    case OperationState.paused:
        return next == OperationState.running || next == OperationState.cancelling;
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
    /// Continue with an empty catalog if an existing JSON input is malformed.
    bool forceJsonOverwrite;
    /// Analyze and merge duplicate records after scanning.
    bool mergeDuplicates;
    /// Do not replace the input JSON catalog after computing results.
    bool dryRun;
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
    /// Continue with an empty catalog if an existing JSON input is malformed.
    bool forceJsonOverwrite;
    /// Do not replace the input JSON catalog after computing analysis results.
    bool dryRun;
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
    /// Optional byte-level progress for a current per-blob subtask.
    ulong subtaskCompleted;
    ulong subtaskTotal;
    bool subtaskTotalKnown;
    /// Display unit for the optional subtask counters (for example bytes or entries).
    string subtaskUnit;
    /// True when a pause request can be acknowledged at a reachable safe checkpoint.
    bool pauseAvailable;
    string path;
    string message;
}

/** Progress callbacks run synchronously on a reporting worker thread. */
alias OperationProgressCallback = void delegate(OperationProgress event);

/** Exception wrapper used to preserve progress-callback failures at API boundaries. */
class OperationCallbackException : Exception
{
    this(string message)
    {
        super(message);
    }
}

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
    /// Whether any source mutation committed before this terminal result.
    bool changesCommitted;
    /// Populated for `scan` operations; other summaries remain their init value.
    ScanSummary scanSummary;
    /// Populated when metadata work was part of the request.
    MetadataSummary metadataSummary;
    /// Populated for analysis operations and JSON scans with merge-duplicates.
    AnalysisSummary analysisSummary;
}

/** Cooperative pause/cancellation control and progress channel for one operation. */
final class OperationControl
{
private:
    shared bool cancelRequested;
    shared bool* cancellationMirror;
    bool pauseRequested;
    bool pauseAvailable;
    Mutex runControlMutex;
    Condition runControlCondition;
    OperationProgressCallback progressCallback;
    Mutex callbackMutex;

public:
    /** Keep this object alive until the operation and all its workers have joined. */
    this(OperationProgressCallback progressCallback = null)
    {
        this.progressCallback = progressCallback;
        runControlMutex = new Mutex();
        runControlCondition = new Condition(runControlMutex);
        /* druntime mutexes are recursive, so a callback may report progress
         * itself without deadlocking on the serialization lock. */
        callbackMutex = new Mutex();
    }

    /** Set cancellation and wake an operation waiting at a pause checkpoint. */
    void requestCancellation()
    {
        atomicStore(cancelRequested, true);
        synchronized (runControlMutex)
        {
            pauseRequested = false;
            runControlCondition.notifyAll();
            if (cancellationMirror !is null)
                atomicStore(*cancellationMirror, true);
        }
    }

    /** Whether a caller requested cooperative cancellation. */
    @property bool cancellationRequested() const nothrow
    {
        return atomicLoad(cancelRequested);
    }

    /**
     * Bind an optional legacy cancellation flag that existing extractors poll.
     * The pointed-to storage must remain alive until this operation and all its
     * workers have joined. Call `unbindCancellationMirror()` before the storage
     * goes out of scope.
     */
    void bindCancellationMirror(shared bool* mirror)
    {
        synchronized (runControlMutex)
        {
            cancellationMirror = mirror;
            if (mirror !is null && cancellationRequested)
                atomicStore(*mirror, true);
        }
    }

    /** Stop mirroring cancellation into previously bound external storage. */
    void unbindCancellationMirror()
    {
        synchronized (runControlMutex)
            cancellationMirror = null;
    }

    /** Whether the current phase has a reachable, safe pause checkpoint. */
    @property bool pauseIsAvailable()
    {
        synchronized (runControlMutex)
            return pauseAvailable && !cancellationRequested;
    }

    /**
     * Advertise whether a pause request can be honored at a future safe point.
     * Executors must set this false while holding a transaction, statement, or
     * non-interruptible replacement sequence.
     */
    void setPauseAvailable(bool available)
    {
        synchronized (runControlMutex)
            pauseAvailable = available;
    }

    /** Request a cooperative pause; false means no safe point is currently reachable. */
    bool requestPause()
    {
        synchronized (runControlMutex)
        {
            if (cancellationRequested)
                return false;
            if (pauseRequested)
                return true;
            if (!pauseAvailable)
                return false;
            pauseRequested = true;
            return true;
        }
    }

    /** Resume a paused operation and wake its worker. */
    bool requestResume()
    {
        synchronized (runControlMutex)
        {
            if (!pauseRequested)
                return false;
            pauseRequested = false;
            runControlCondition.notifyAll();
            return true;
        }
    }

    /**
     * Stop at an operation-defined safe checkpoint when pause was requested.
     * The caller must have drained workers and released active storage
     * transactions/statements before calling this method. False means
     * cancellation took precedence while the operation was stopped.
     */
    bool pauseAtCheckpoint(OperationProgress progress)
    {
        synchronized (runControlMutex)
        {
            if (cancellationRequested)
                return false;
            if (!pauseRequested)
                return true;
            pauseAvailable = false;
        }

        progress.state = OperationState.paused;
        progress.pauseAvailable = false;
        if (progress.message.length == 0)
            progress.message = "Paused at a safe checkpoint.";
        report(progress);

        bool cancelled;
        synchronized (runControlMutex)
        {
            while (pauseRequested && !cancellationRequested)
                runControlCondition.wait();
            cancelled = cancellationRequested;
            pauseAvailable = false;
        }

        progress.state = cancelled ? OperationState.cancelling : OperationState.running;
        progress.pauseAvailable = false;
        progress.message = cancelled ? "Cancellation requested while paused."
            : "Operation resumed.";
        report(progress);
        return !cancelled;
    }

    /** Deliver an event; callback invocations are serialized, but may use a worker thread. */
    void report(OperationProgress event)
    {
        synchronized (runControlMutex)
        {
            if (event.state == OperationState.running)
            {
                if (cancellationRequested)
                    event.state = OperationState.cancelling;
                else if (pauseRequested)
                    event.state = OperationState.pausing;
            }
            event.pauseAvailable = pauseAvailable && !cancellationRequested;
        }
        if (progressCallback is null)
            return;
        synchronized (callbackMutex)
        {
            try
                progressCallback(event);
            catch (Exception ex)
                throw new OperationCallbackException(ex.msg);
        }
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
    if (request.target.mode == OperationStorageMode.repository
        && request.dryRun)
        return validationError(OperationRequestError.unsupportedOptionCombination,
            "Dry-run is supported only for JSON scans.");
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
            || request.metadataOptions.rescan || request.dryRun))
        return validationError(OperationRequestError.unsupportedOptionCombination,
            "Repository analyze cannot include metadata extraction options or dry-run.");
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
    repositoryScan.mergeDuplicates = true;
    assert(validateOperationRequest(repositoryScan).valid);
    repositoryScan.dryRun = true;
    assert(validateOperationRequest(repositoryScan).error
        == OperationRequestError.unsupportedOptionCombination);

    auto jsonScan = ScanOperationRequest(
        2, OperationTarget.jsonTarget("/catalog.json", "/library"));
    assert(validateOperationRequest(jsonScan).valid);
    jsonScan.mergeDuplicates = true;
    jsonScan.dryRun = true;
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
    repositoryAnalysis.dryRun = true;
    assert(validateOperationRequest(repositoryAnalysis).error
        == OperationRequestError.unsupportedOptionCombination);
    repositoryAnalysis.dryRun = false;
    repositoryAnalysis.metadataOptions.scanTorrents = true;
    assert(validateOperationRequest(repositoryAnalysis).error
        == OperationRequestError.unsupportedOptionCombination);

    auto jsonAnalysis = AnalysisOperationRequest(
        7, OperationTarget.jsonTarget("/catalog.json"));
    jsonAnalysis.metadataOptions.calculateChecksums = true;
    assert(validateOperationRequest(jsonAnalysis).valid,
        "JSON analyze may run scanner jobs before analysis");
    jsonAnalysis.dryRun = true;
    assert(validateOperationRequest(jsonAnalysis).valid);
    jsonAnalysis.options.mergeDuplicates = false;
    assert(validateOperationRequest(jsonAnalysis).error
        == OperationRequestError.unsupportedOptionCombination);
}

@("operation lifecycle models pause and cancellation without resurrection")
unittest
{
    assert(validOperationStateTransition(OperationState.queued,
        OperationState.running));
    assert(validOperationStateTransition(OperationState.queued,
        OperationState.cancelled));
    assert(validOperationStateTransition(OperationState.running,
        OperationState.cancelling));
    assert(validOperationStateTransition(OperationState.running,
        OperationState.pausing));
    assert(validOperationStateTransition(OperationState.pausing,
        OperationState.paused));
    assert(validOperationStateTransition(OperationState.pausing,
        OperationState.running), "a completed unit may miss a pending pause");
    assert(validOperationStateTransition(OperationState.paused,
        OperationState.running));
    assert(validOperationStateTransition(OperationState.paused,
        OperationState.cancelling));
    assert(validOperationStateTransition(OperationState.pausing,
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
    assert(!validOperationStateTransition(OperationState.paused,
        OperationState.completed));
}

@("operation pause reports acknowledgement and resume in order")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import std.datetime : dur;

    shared bool sawPaused;
    shared bool sawPausing;
    shared bool pausingPreservedCounts;
    shared bool sawRunning;
    shared bool checkpointContinued;
    auto control = new OperationControl((OperationProgress event) {
        if (event.state == OperationState.paused)
            atomicStore(sawPaused, true);
        else if (event.state == OperationState.pausing)
        {
            atomicStore(sawPausing, true);
            atomicStore(pausingPreservedCounts, event.completed == 3
                && event.total == 9 && event.pauseAvailable);
        }
        else if (event.state == OperationState.running
            && event.message == "Operation resumed.")
            atomicStore(sawRunning, true);
    });
    OperationProgress progress;
    progress.operationId = 7;
    progress.operation = OperationKind.scan;
    progress.state = OperationState.running;
    progress.phase = OperationPhase.scanning;
    progress.completed = 3;
    progress.total = 9;
    progress.totalKnown = true;

    assert(!control.requestPause(), "unavailable pause points are not offered");
    control.setPauseAvailable(true);
    assert(control.pauseIsAvailable);
    assert(control.requestPause());
    assert(control.requestPause(), "repeated pause requests are idempotent");
    control.report(progress);

    auto worker = new Thread({
        atomicStore(checkpointContinued, control.pauseAtCheckpoint(progress));
    });
    worker.start();
    size_t attempts;
    while (!atomicLoad(sawPaused) && attempts++ < 5000)
        Thread.sleep(dur!"msecs"(1));
    auto acknowledged = atomicLoad(sawPaused);
    auto resumed = control.requestResume();
    worker.join();

    assert(acknowledged, "pause is reported only after reaching the checkpoint");
    assert(atomicLoad(sawPausing), "pending pause is distinct from acknowledgement");
    assert(atomicLoad(pausingPreservedCounts));
    assert(resumed);
    assert(atomicLoad(sawRunning));
    assert(atomicLoad(checkpointContinued));
    assert(progress.completed == 3 && progress.total == 9,
        "checkpoint progress values remain unchanged");
}

@("cancellation wakes a paused operation and takes precedence over resume")
unittest
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import std.datetime : dur;

    shared bool sawPaused;
    shared bool sawCancelling;
    shared bool checkpointContinued;
    auto control = new OperationControl((OperationProgress event) {
        if (event.state == OperationState.paused)
            atomicStore(sawPaused, true);
        else if (event.state == OperationState.cancelling)
            atomicStore(sawCancelling, true);
    });
    control.setPauseAvailable(true);
    assert(control.requestPause());
    OperationProgress progress;
    progress.operationId = 8;
    progress.operation = OperationKind.metadata;
    progress.phase = OperationPhase.archives;
    auto worker = new Thread({
        atomicStore(checkpointContinued, control.pauseAtCheckpoint(progress));
    });
    worker.start();
    size_t attempts;
    while (!atomicLoad(sawPaused) && attempts++ < 5000)
        Thread.sleep(dur!"msecs"(1));
    auto acknowledged = atomicLoad(sawPaused);
    control.requestCancellation();
    worker.join();

    assert(acknowledged, "worker reached the pause checkpoint");
    assert(control.cancellationRequested);
    assert(atomicLoad(sawCancelling));
    assert(!atomicLoad(checkpointContinued));
    assert(!control.requestResume(), "cancellation clears the paused wait");
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

    shared bool legacyCancellation;
    auto mirroredControl = new OperationControl();
    mirroredControl.bindCancellationMirror(&legacyCancellation);
    assert(!atomicLoad(legacyCancellation));
    mirroredControl.requestCancellation();
    assert(atomicLoad(legacyCancellation),
        "legacy extractors observe the same cooperative cancellation request");
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
