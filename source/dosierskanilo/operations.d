/** Frontend-neutral request and run-control types for long-running operations.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.operations;

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;

import dosierskanilo.repository.types : AnalysisSummary, MetadataScanOptions,
    MetadataSummary, RepositoryAnalysisOptions, RepositoryScanOptions, ScanSummary;

/** Select the storage implementation explicitly for an operation. */
enum OperationStorageMode
{
    /// Use the initialized SQLite repository as the operation's storage.
    repository,
    /// Use a direct JSON catalog file as the operation's storage.
    jsonCatalog
}

/** Shared operation families supported by the first operation API version. */
enum OperationKind
{
    /// Scan a filesystem and write catalog records.
    scan,
    /// Extract metadata for existing catalog records.
    metadata,
    /// Analyze a catalog for duplicates and missing files.
    analyze,
    /// Import catalog data from an external source.
    catalogImport,
    /// Export catalog data to an external destination.
    catalogExport
}

/** Lifecycle states used in progress notifications and terminal results. */
enum OperationState
{
    /// Accepted but not yet started.
    queued,
    /// Executing work.
    running,
    /// A pause was requested but not yet acknowledged at a checkpoint.
    pausing,
    /// Stopped at a safe checkpoint and waiting to resume or cancel.
    paused,
    /// Cancellation was requested and cooperative shutdown is in progress.
    cancelling,
    /// Finished successfully.
    completed,
    /// Stopped by cancellation before completing.
    cancelled,
    /// Terminated with an error.
    failed
}

/** Whether a task lifecycle transition is allowed by the shared contract.
 *
 * Params:
 *     current = State the operation is currently in.
 *     next = Proposed state to transition to.
 * Returns: `true` when the shared lifecycle contract allows the transition;
 *     `false` otherwise, including for all transitions out of a terminal state.
 */
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
    /// No particular phase is active or reported.
    none,
    /// Validating the operation request and target.
    validating,
    /// Discovering input files or records.
    discovering,
    /// Scanning filesystem entries and writing initial records.
    scanning,
    /// Reconciling known catalog records against files that are now missing.
    reconcilingMissingFiles,
    /// Calculating content checksums.
    checksums,
    /// Detecting file types.
    fileTypes,
    /// Extracting embedded media information.
    mediaInfo,
    /// Scanning archive contents.
    archives,
    /// Scanning torrent metadata and payload references.
    torrents,
    /// Analyzing missing files.
    analysisMissingFiles,
    /// Analyzing duplicate content.
    analysisDuplicates,
    /// Applying analysis-driven cleanup.
    analysisCleanup,
    /// Reading a JSON catalog.
    jsonRead,
    /// Writing a JSON catalog.
    jsonWrite
}

/** Explicit filesystem/catalog target; no target is inferred by this API. */
struct OperationTarget
{
    OperationStorageMode mode; /// Explicit storage mode selected by the caller.
    /// Root of the initialized `.dosierskanilo` repository.
    string repositoryRoot;
    /// Explicit direct-JSON catalog path.
    string catalogPath;
    /// Filesystem root for JSON scan. JSON analyze needs only `catalogPath`.
    string filesystemRoot;

    /** Construct an explicit SQLite repository target.
     *
     * Params:
     *     root = Root directory of the initialized repository.
     * Returns: A target using `OperationStorageMode.repository` and the given
     *     root.
     */
    static OperationTarget repositoryTarget(string root)
    {
        OperationTarget target;
        target.mode = OperationStorageMode.repository;
        target.repositoryRoot = root;
        return target;
    }

    /** Construct an explicit JSON catalog target.
     *
     * Params:
     *     catalog = Path to the direct-JSON catalog file.
     *     filesystem = Optional filesystem root required by JSON scans.
     * Returns: A target using `OperationStorageMode.jsonCatalog` and the given
     *     paths.
     */
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
    OperationTarget target; ///< Explicit JSON or repository source.
    RepositoryScanOptions scanOptions; ///< Filesystem traversal and cleanup options.
    MetadataScanOptions metadataOptions; ///< Selected scan-time metadata extractors.
    /// Continue with an empty catalog if an existing JSON input is malformed.
    bool forceJsonOverwrite;
    /// Analyze and merge duplicate records after scanning.
    bool mergeDuplicates;
    /// Save collected JSON records when cancellation stops the scan.
    bool savePartialOnCancel;
    /// Do not replace the input JSON catalog after computing results.
    bool dryRun;
    /// Write the replaced JSON catalog with human-readable indentation.
    bool prettyJson;
}

/** Request for standalone repository metadata extraction. */
struct MetadataOperationRequest
{
    ulong operationId; ///< Caller-assigned nonzero identity.
    OperationTarget target; ///< Explicit repository source.
    MetadataScanOptions options; ///< Selected metadata extractors and limits.
}

/** Request for duplicate/missing-file analysis. */
struct AnalysisOperationRequest
{
    ulong operationId; ///< Caller-assigned nonzero identity.
    OperationTarget target; ///< Explicit JSON or repository source.
    RepositoryAnalysisOptions options; ///< Duplicate merge and missing-file options.
    /// Metadata extractor options for direct JSON analysis. Repository analysis
    /// rejects them; JSON analysis runs the selected jobs before duplicate
    /// analysis.
    MetadataScanOptions metadataOptions;
    /// Continue with an empty catalog if an existing JSON input is malformed.
    bool forceJsonOverwrite;
    /// Do not replace the input JSON catalog after computing analysis results.
    bool dryRun;
    /// Write the replaced JSON catalog with human-readable indentation.
    bool prettyJson;
}

/** Validation errors detectable without opening a repository or catalog. */
enum OperationRequestError
{
    /// The request passed validation.
    none,
    /// The operation ID is zero.
    invalidOperationId,
    /// A repository target has no repository root.
    missingRepositoryRoot,
    /// The target mixes repository and JSON path fields.
    invalidRepositoryTarget,
    /// A JSON target has no catalog path.
    missingCatalogPath,
    /// A JSON scan has no filesystem root.
    missingFilesystemRoot,
    /// The operation does not support the selected storage mode.
    unsupportedStorageMode,
    /// An option is not supported for the selected target mode.
    unsupportedOptionCombination,
    /// A metadata operation selected no extractor.
    missingMetadataSelection
}

/** Typed validation outcome for a request. */
struct OperationRequestValidation
{
    OperationRequestError error; /// Stable validation failure category.
    string message; /// Human-readable validation diagnostic.

    /** Whether the request passed validation.
     *
     * Returns: `true` when `error` is `OperationRequestError.none`.
     */
    @property bool valid() const
    {
        return error == OperationRequestError.none;
    }
}

/** Progress value passed from an operation executor to either frontend. */
struct OperationProgress
{
    ulong operationId; /// Caller-assigned operation identity.
    OperationKind operation; /// Operation family that produced this event.
    OperationState state; /// Current lifecycle state.
    OperationPhase phase; /// Fine-grained phase within the operation.
    ulong completed; /// Completed work units, or percentage when `totalKnown`.
    ulong total; /// Total work units, or percentage denominator when `totalKnown`.
    /// False means `completed` is a work count/status value, not a percentage.
    bool totalKnown;
    /// Optional byte-level progress for a current per-blob subtask.
    ulong subtaskCompleted;
    ulong subtaskTotal; ///< Total units for the current subtask.
    bool subtaskTotalKnown; ///< False when `subtaskTotal` is only a status value.
    /// Display unit for the optional subtask counters (for example bytes or entries).
    string subtaskUnit;
    /// True when a pause request can be acknowledged at a reachable safe checkpoint.
    bool pauseAvailable;
    /// Position of `path` in the operation's file order when known.
    size_t fileOrderIndex;
    string path; /// Current file, archive member, or source path when known.
    string message; /// Human-readable status message.
}

/** Progress callbacks run synchronously on a reporting worker thread. */
alias OperationProgressCallback = void delegate(OperationProgress event);

/** Exception wrapper used to preserve progress-callback failures at API boundaries. */
class OperationCallbackException : Exception
{
    /** Construct a wrapper carrying the offending callback's message.
     *
     * Params:
     *     message = Diagnostic text copied from the callback failure.
     */
    this(string message)
    {
        super(message);
    }
}

/** Stable operation-level failure categories; extractor failures remain summaries. */
enum OperationErrorCode
{
    /// No operation-level failure occurred.
    none,
    /// Another operation currently holds the target.
    targetBusy,
    /// A progress callback threw and aborted the operation.
    callbackFailure,
    /// The storage or processing backend reported a failure.
    backendFailure
}

/** Terminal result for one completed, cancelled, or failed operation. */
struct OperationResult
{
    ulong operationId; /// Caller-assigned operation identity.
    OperationKind operation; /// Operation family that produced the result.
    OperationState state; /// Terminal lifecycle state.
    OperationErrorCode errorCode; /// Stable failure category, `none` on success.
    string error; /// Actionable failure diagnostic; may be empty.
    /// Whether any source mutation committed before this terminal result.
    bool changesCommitted;
    /// Populated for `scan` operations; other summaries remain their init value.
    ScanSummary scanSummary;
    /// Populated when metadata work was part of the request.
    MetadataSummary metadataSummary;
    /// Populated for analysis operations and JSON scans with merge-duplicates.
    AnalysisSummary analysisSummary;
    /// Recovery file written when the canonical JSON catalog could not be saved.
    string recoveryPath;
    /// Staging paths attempted by a failed JSON catalog write.
    string[] writeAttempts;
    /// Partial staging file retained for diagnosis after a failed write.
    string failedStagingPath;
}

/** Cooperative pause/cancellation control and progress channel for one operation. */
final class OperationControl
{
private:
    /// Atomic flag set when cooperative cancellation is requested.
    shared bool cancelRequested;
    /// Optional external cancellation flag mirrored on request; may be null.
    shared bool* cancellationMirror;
    /// Whether a pause is pending; guarded by `runControlMutex`.
    bool pauseRequested;
    /// Whether a safe pause checkpoint is currently reachable.
    bool pauseAvailable;
    /// Serializes pause/cancellation state changes and the condition below.
    Mutex runControlMutex;
    /// Wakes a paused worker on resume or cancellation.
    Condition runControlCondition;
    /// Optional callback that receives each progress event.
    OperationProgressCallback progressCallback;
    /// Serializes invocations of `progressCallback` across worker threads.
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

    /** Whether a caller requested cooperative cancellation.
     *
     * Returns: `true` when the local request flag or the bound external mirror
     *     is set.
     */
    @property bool cancellationRequested() const nothrow
    {
        if (atomicLoad(cancelRequested))
            return true;
        return cancellationMirror !is null
            && atomicLoad(*cancellationMirror);
    }

    /**
     * Bind an optional legacy cancellation flag that existing extractors poll.
     * The pointed-to storage must remain alive until this operation and all its
     * workers have joined. Call `unbindCancellationMirror()` before the storage
     * goes out of scope.
     *
     * Params:
     *     mirror = External cancellation flag to poll, or `null` to unbind.
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

    /** Whether the current phase has a reachable, safe pause checkpoint.
     *
     * Returns: `true` when pause is available and cancellation is not pending.
     */
    @property bool pauseIsAvailable()
    {
        synchronized (runControlMutex)
            return pauseAvailable && !cancellationRequested;
    }

    /**
     * Advertise whether a pause request can be honored at a future safe point.
     * Executors must set this false while holding a transaction, statement, or
     * non-interruptible replacement sequence.
     *
     * Params:
     *     available = Whether a pause request can be honored at a reachable
     *         safe point.
     */
    void setPauseAvailable(bool available)
    {
        synchronized (runControlMutex)
            pauseAvailable = available;
    }

    /**
     * Request a cooperative pause.
     *
     * Returns: `true` when already paused or the request was recorded;
     *     `false` when cancellation is pending or no safe point is reachable.
     */
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

    /**
     * Resume a paused operation and wake its worker.
     *
     * Returns: `true` when the operation was paused and is now resumed;
     *     `false` otherwise.
     */
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
     *
     * Params:
     *     progress = Event describing the checkpoint; state and message are
     *         updated while reporting pause/resume transitions.
     * Returns: `false` when cancellation is pending or was requested while
     *     paused; `true` otherwise, including when no pause was requested.
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

    /**
     * Deliver one progress event.
     *
     * Callback invocations are serialized, but may run on a worker thread.
     * The event state is adjusted to `cancelling` or `pausing` when those
     * requests are pending.
     *
     * Params:
     *     event = Progress value delivered to the callback; it is adjusted in
     *         place before delivery.
     * Throws: `OperationCallbackException` when the progress callback throws.
     */
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

/** Build a failed request-validation result.
 *
 * Params:
 *     error = Stable failure category to report.
 *     message = Human-readable diagnostic explaining the failure.
 * Returns: A validation value whose `valid` property is false.
 */
private OperationRequestValidation validationError(OperationRequestError error,
    string message)
{
    return OperationRequestValidation(error, message);
}

/** Check that a target selects exactly one storage backend and carries its
 * required paths.
 *
 * Params:
 *     target = Explicit repository or JSON catalog target to inspect.
 *     requireFilesystemRoot = Whether a JSON target must also name a
 *         filesystem root.
 * Returns: A valid result when the target is consistent, otherwise the first
 *     detected request error.
 */
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

/** Report whether a metadata selection enables at least one extractor.
 *
 * Params:
 *     options = Metadata extractor selection to inspect.
 * Returns: `true` when any checksum, file-type, media, archive, or torrent
 *     extractor is enabled.
 */
private bool requestsMetadata(MetadataScanOptions options)
{
    return options.calculateChecksums || options.detectFileTypes
        || options.extractMediaInfo || options.scanArchives || options.scanTorrents;
}

/** Check that a caller assigned a usable operation identity.
 *
 * Params:
 *     operationId = Caller-assigned operation identifier.
 * Returns: A valid result for a nonzero ID, otherwise `invalidOperationId`.
 */
private OperationRequestValidation validateIdentity(ulong operationId)
{
    if (operationId == 0)
        return validationError(OperationRequestError.invalidOperationId,
            "Operation IDs must be nonzero.");
    return OperationRequestValidation.init;
}

/** Validate a scan request without opening either target.
 *
 * Params:
 *     request = Scan request whose identity, target, and options are checked.
 * Returns: A valid result, or the first detected request error.
 */
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
    if (request.target.mode == OperationStorageMode.repository
        && request.savePartialOnCancel)
        return validationError(OperationRequestError.unsupportedOptionCombination,
            "Saving partial scans is supported only for JSON scans.");
    return OperationRequestValidation.init;
}

/** Validate a metadata request; standalone metadata extraction is SQLite-only.
 *
 * Params:
 *     request = Metadata request whose identity, target, and extractor
 *         selection are checked.
 * Returns: A valid result, or the first detected request error.
 */
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

/** Validate analysis target/options while preserving the separate JSON contract.
 *
 * Params:
 *     request = Analysis request whose identity, target, and options are
 *         checked.
 * Returns: A valid result, or the first detected request error.
 */
OperationRequestValidation validateOperationRequest(AnalysisOperationRequest request)
{
    auto identity = validateIdentity(request.operationId);
    if (!identity.valid)
        return identity;
    auto targetValidation = validateTarget(request.target, false);
    if (!targetValidation.valid)
        return targetValidation;
    if (request.target.mode == OperationStorageMode.repository
        && request.dryRun)
        return validationError(OperationRequestError.unsupportedOptionCombination,
            "Repository analyze does not support dry-run.");
    if (request.target.mode == OperationStorageMode.jsonCatalog
        && !request.options.mergeDuplicates)
        return validationError(OperationRequestError.unsupportedOptionCombination,
            "JSON analyze always merges duplicate records.");
    return OperationRequestValidation.init;
}

@("operation requests validate explicit targets and supported mode combinations")
unittest
{
    auto missingRepository = ScanOperationRequest();
    missingRepository.operationId = 1;
    assert(validateOperationRequest(missingRepository).error
        == OperationRequestError.missingRepositoryRoot);

    auto noIdentity = ScanOperationRequest();
    noIdentity.target = OperationTarget.repositoryTarget("/library");
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
    repositoryScan.dryRun = false;
    repositoryScan.savePartialOnCancel = true;
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
    assert(validateOperationRequest(repositoryAnalysis).valid,
        "repository analyze may run metadata before analysis");

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

@("operation control observes a bound cancellation mirror")
unittest
{
    shared bool mirrorFlag;
    auto control = new OperationControl();
    control.bindCancellationMirror(&mirrorFlag);
    assert(!control.cancellationRequested);
    atomicStore(mirrorFlag, true);
    assert(control.cancellationRequested);
    control.unbindCancellationMirror();
    atomicStore(mirrorFlag, false);
    assert(!control.cancellationRequested);
}
