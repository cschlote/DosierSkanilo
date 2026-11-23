/** Explicit save and discard session over one JSON catalog document.
 *
 *
 * The session tracks changes against the loaded fingerprint before saving.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.jsoncatalogdocument;

import std.algorithm.searching : startsWith;
import std.conv : to;
import std.file : exists;
import std.path : absolutePath, buildNormalizedPath, isAbsolute, dirName,
    isAbsolute;
import dosierarkivo.archive : nativePathToStoragePath, parseArchiveVirtualPath,
    ParsedArchiveVirtualPath;
import dosierskanilo.catalogbackend;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5;
import dosierskanilo.operationlease : TargetCatalogReplacementLease;
import dosierskanilo.operationrunner;
import dosierskanilo.service.jsonoperations : analyzeJsonCatalogInto,
    commitJsonCatalogUnderLease, normalizeJsonCatalogPaths, scanJsonCatalogInto;
import dosierskanilo.operations : AnalysisOperationRequest, OperationControl,
    OperationErrorCode, OperationKind, OperationResult, OperationState,
    OperationStorageMode, OperationTarget, ScanOperationRequest;
import dosierskanilo.jsoncatalogbackend : catalogFileFingerprint, cloneCatalog,
    JsonCatalogBackend;

/** Explicit save/discard session over one JSON catalog document. */
package final class JsonCatalogDocument : CatalogDocument
{
    /// Backend whose in-memory catalog this session edits.
    private JsonCatalogBackend backend;
    /// On-disk fingerprint recorded when the catalog was loaded or saved.
    private string loadedFingerprint;
    /// Whether the in-memory catalog has changes not yet saved.
    private bool dirty;
    /// Whether `close` has been called on this session.
    private bool closed;

    /**
     * Create a document session over an already-open backend.
     *
     * Params:
     *     backend = Backend whose catalog is edited by this session.
     */
    this(JsonCatalogBackend backend)
    {
        this.backend = backend;
        loadedFingerprint = backend.loadFingerprint;
    }

    /**
     * Throw when this document session has been closed.
     *
     * Throws: `CatalogBackendException` with `CatalogBackendErrorCode.closed`.
     */
    private void requireOpen() const
    {
        if (closed)
            throw new CatalogBackendException(CatalogBackendErrorCode.closed,
                "The catalog document session is closed.");
    }

    /**
     * Validate that a document operation targets this session's catalog.
     *
     * Params:
     *     request = Target supplied by the operation request.
     *     scan = Reserved for scan-specific checks; the catalog target is
     *         currently validated the same way for scans and analyses.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidTarget` when the target is not a JSON
     *     catalog or names a different catalog path.
     */
    private void requireTarget(OperationTarget request, bool scan) const
    {
        /* Document operations identify the catalog; the scan root is an
         * operation input and does not have to match the read root bound for
         * tree queries. */
        const target = backend.backendTarget;
        if (request.mode != OperationStorageMode.jsonCatalog
            || request.catalogPath != target.catalogPath)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidTarget,
                "The operation target does not match the opened document.");
    }

    /**
     * Report whether the in-memory catalog has unsaved changes.
     *
     * Returns: True when changes are pending.
     * Throws: `CatalogBackendException` when the session is closed.
     */
    override bool modified() const
    {
        requireOpen();
        return dirty;
    }

    /**
     * Return the fingerprint captured when the catalog was loaded or saved.
     *
     * Returns: The `size:mtime` fingerprint string.
     * Throws: `CatalogBackendException` when the session is closed.
     */
    override string fingerprint() const
    {
        requireOpen();
        return loadedFingerprint;
    }

    /**
     * Suggest a filesystem root shared by the catalog's absolute file paths.
     *
     * Returns: The common parent directory of absolute physical paths, or the
     *     catalog directory when paths are relative or no common root exists.
     * Throws: `CatalogBackendException` when the session is closed.
     */
    override string suggestedFilesystemRoot()
    {
        requireOpen();
        import std.path : absolutePath, buildNormalizedPath, dirName, isAbsolute;

        string commonRoot;
        bool sawRelative;
        foreach (blob; backend.catalog.dataArray)
        {
            if (blob is null)
                continue;
            foreach (spec; blob.fileSpecs)
            {
                if (spec is null || spec.fileName.length == 0)
                    continue;
                auto path = spec.fileName;
                ParsedArchiveVirtualPath parsed;
                try
                    parsed = parseArchiveVirtualPath(path);
                catch (Exception)
                    continue;
                if (!isAbsolute(parsed.physicalPath))
                {
                    sawRelative = true;
                    continue;
                }
                auto normalized = buildNormalizedPath(absolutePath(
                    parsed.physicalPath));
                if (commonRoot.length == 0)
                    commonRoot = dirName(normalized);
                else
                {
                    while (commonRoot.length > 0
                        && !normalized.startsWith(commonRoot ~ "/"))
                        commonRoot = dirName(commonRoot);
                }
            }
        }
        if (sawRelative || commonRoot.length == 0)
            return absolutePath(dirName(backend.backendTarget.catalogPath));
        return commonRoot;
    }

    /**
     * Bind or clear the filesystem root used for tree queries.
     *
     * Params:
     *     root = New absolute root; an empty string unbinds the root.
     * Throws: `CatalogBackendException` when the session is closed.
     */
    override void bindFilesystemRoot(string root)
    {
        requireOpen();
        backend.sourceRoot = root.length > 0
            ? nativePathToStoragePath(buildNormalizedPath(absolutePath(root)))
            : "";
        if (backend.sourceRoot.length > 0)
            backend.rebuildIndex();
        else
            backend.clearIndex();
    }

    /**
     * Apply a scan to the in-memory catalog without committing it.
     *
     * Failures are reported in the returned result rather than thrown; a
     * non-dry-run scan marks the session dirty and rebuilds the index.
     *
     * Params:
     *     request = Scan request including target, options, and dry-run flag.
     *     control = Progress and cancellation control; a default is created when
     *         null.
     * Returns: The scan result with summaries and a final state.
     * Throws: `CatalogBackendException` when the session is closed or the target
     *     does not match the opened catalog.
     */
    override OperationResult applyScan(ScanOperationRequest request,
        OperationControl control)
    {
        requireOpen();
        requireTarget(request.target, true);
        if (control is null)
            control = new OperationControl();
        OperationResult result;
        result.operationId = request.operationId;
        result.operation = OperationKind.scan;
        result.state = OperationState.running;
        try
        {
            auto working = cloneCatalog(backend.catalog);
            const application = scanJsonCatalogInto(working,
                request.target.filesystemRoot, request.scanOptions,
                request.metadataOptions, request.mergeDuplicates, control,
                request.operationId);
            result.scanSummary = application.scanSummary;
            result.metadataSummary = application.metadataSummary;
            result.analysisSummary = application.analysisSummary;
            result.state = application.cancelled
                ? OperationState.cancelled : OperationState.completed;
            if (!request.dryRun)
            {
                backend.catalog = working;
                dirty = true;
                backend.rebuildIndex();
            }
        }
        catch (Exception ex)
        {
            result.state = OperationState.failed;
            result.errorCode = OperationErrorCode.backendFailure;
            result.error = ex.msg;
        }
        result.changesCommitted = false;
        return result;
    }

    /**
     * Apply metadata and analysis work to the in-memory catalog without saving.
     *
     * Failures are reported in the returned result rather than thrown; a
     * non-dry-run analysis marks the session dirty and rebuilds the index.
     *
     * Params:
     *     request = Analysis request including target, options, and dry-run flag.
     *     control = Progress and cancellation control; a default is created when
     *         null.
     * Returns: The analysis result with summaries and a final state.
     * Throws: `CatalogBackendException` when the session is closed or the target
     *     does not match the opened catalog.
     */
    override OperationResult applyAnalysis(AnalysisOperationRequest request,
        OperationControl control)
    {
        requireOpen();
        requireTarget(request.target, false);
        if (control is null)
            control = new OperationControl();
        OperationResult result;
        result.operationId = request.operationId;
        result.operation = OperationKind.analyze;
        result.state = OperationState.running;
        try
        {
            const auto baseRoot = backend.sourceRoot.length > 0
                ? backend.sourceRoot
                : dirName(backend.backendTarget.catalogPath);
            auto working = cloneCatalog(backend.catalog);
            const application = analyzeJsonCatalogInto(working,
                baseRoot, request.metadataOptions, request.options, control,
                request.operationId);
            result.metadataSummary = application.metadataSummary;
            result.analysisSummary = application.analysisSummary;
            result.state = application.cancelled
                ? OperationState.cancelled : OperationState.completed;
            if (!request.dryRun)
            {
                backend.catalog = working;
                dirty = true;
                backend.rebuildIndex();
            }
        }
        catch (Exception ex)
        {
            result.state = OperationState.failed;
            result.errorCode = OperationErrorCode.backendFailure;
            result.error = ex.msg;
        }
        result.changesCommitted = false;
        return result;
    }

    /**
     * Write pending changes to disk if the catalog has not changed underneath.
     *
     * Paths are normalized for the current format before the JSON document is
     * committed. On success the loaded fingerprint is refreshed and the backend
     * index rebuilt.
     *
     * Params:
     *     pretty = Whether to indent the serialized JSON.
     * Throws: `CatalogBackendException` when the session is closed,
     *     `CatalogBackendErrorCode.writeConflict` when the file changed on disk,
     *     or any exception from committing the catalog.
     */
    override void save(bool pretty = false)
    {
        requireOpen();
        if (!dirty)
            return;
        /* Hold the replacement lease across the conflict check and the write so
         * two document sessions cannot both pass the check. */
        auto replacementLease = TargetCatalogReplacementLease.acquireJsonCatalog(
            backend.backendTarget.catalogPath);
        scope (exit)
            replacementLease.release();
        const current = catalogFileFingerprint(
            backend.backendTarget.catalogPath);
        if (current != loadedFingerprint)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.writeConflict,
                "The catalog changed on disk since it was loaded.");
        const auto baseRoot = backend.sourceRoot.length > 0
            ? backend.sourceRoot
            : dirName(backend.backendTarget.catalogPath);
        normalizeJsonCatalogPaths(backend.catalog.dataArray, baseRoot,
            backend.catalog.dataVersion == DATA_CLASS_VERSION5);
        commitJsonCatalogUnderLease(backend.backendTarget.catalogPath,
            backend.catalog, null, pretty);
        loadedFingerprint = catalogFileFingerprint(
            backend.backendTarget.catalogPath);
        backend.loadFingerprint = loadedFingerprint;
        dirty = false;
        backend.rebuildIndex();
    }

    /**
     * Reload the catalog from disk and drop unsaved changes.
     *
     * Throws: `CatalogBackendException` when the session is closed or the catalog
     *     cannot be reloaded.
     */
    override void discard()
    {
        requireOpen();
        backend.reloadCatalog();
        loadedFingerprint = backend.loadFingerprint;
        dirty = false;
    }

    /**
     * Mark this document session as closed.
     *
     * No further operations are accepted, but the owning backend stays open.
     */
    override void close()
    {
        closed = true;
    }
}
