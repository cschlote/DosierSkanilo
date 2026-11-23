/** Session, operation, and import members of `JsonCatalogBackend`.
 *
 *
 * Lifecycle, target validation, and the batch operations run through the shared
 * operation runner and refresh the in-memory index afterwards.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.jsonsession;

import std.conv : to;
import std.file : exists, getSize, timeLastModified;
import std.path : absolutePath, baseName, buildNormalizedPath;
import dosierarkivo.archive : nativePathToStoragePath, parseArchiveVirtualPath;
import dosierskanilo.catalogbackend;
import dosierskanilo.catalogstatus : CatalogStatus;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
    deserializeDataClassJsonWrapperFile;
import dosierskanilo.repository.types : JsonImportOptions, RepositoryInfo;
import dosierskanilo.operationrunner;
import dosierskanilo.operations : AnalysisOperationRequest,
    MetadataOperationRequest, OperationControl, OperationKind, OperationResult,
    OperationStorageMode, OperationTarget, ScanOperationRequest;
import dosierskanilo.jsoncatalogbackend : catalogFileFingerprint;
import dosierskanilo.jsoncatalogdocument : JsonCatalogDocument;

/** Members of `JsonCatalogBackend` mixed into the class; see jsonsession.d. */
mixin template JsonBackendSession()
{
    /**
     * Return the explicit save/discard session for this catalog document.
     *
     * The session is created on first use and reused for later calls.
     *
     * Returns: The document session owned by this backend.
     * Throws: `CatalogBackendException` with `CatalogBackendErrorCode.closed`
     *     when the backend has been closed.
     */
    override CatalogDocument document()
    {
        requireOpen();
        if (documentSession is null)
            documentSession = new JsonCatalogDocument(this);
        return documentSession;
    }

    /**
     * Return the normalized target this backend was opened with.
     *
     * Returns: The target with canonicalized catalog and filesystem paths.
     * Throws: `CatalogBackendException` when the backend has been closed.
     */
    override OperationTarget target()
    {
        requireOpen();
        return backendTarget;
    }

    /**
     * Describe the catalog source for display purposes.
     *
     * Returns: Source information with `OperationStorageMode.jsonCatalog` and the
     *     catalog file's base name as display name.
     * Throws: `CatalogBackendException` when the backend has been closed.
     */
    override CatalogSourceInfo sourceInfo()
    {
        requireOpen();
        CatalogSourceInfo result;
        result.storageMode = OperationStorageMode.jsonCatalog;
        result.displayName = baseName(backendTarget.catalogPath);
        return result;
    }

    /**
     * Summarize the catalog as a repository.
     *
     * Returns: Repository information whose root is the bound source root when
     *     present, otherwise the catalog path, plus the catalog schema version.
     * Throws: `CatalogBackendException` when the backend has been closed.
     */
    override RepositoryInfo repositoryInfo()
    {
        requireOpen();
        RepositoryInfo result;
        result.rootPath = sourceRoot.length > 0 ? sourceRoot : backendTarget.catalogPath;
        result.schemaVersion = catalog.dataVersion;
        return result;
    }

    /** Return aggregate counters for the loaded JSON document.
     *
     * The counts are derived from one pass over the in-memory record array and
     * the already-built tree index. Directory and availability counters are
     * flagged unavailable when the index could not be built.
     *
     * Returns: The current catalog status.
     * Throws: `CatalogBackendException` with `closed`.
     */
    override CatalogStatus catalogStatus()
    {
        requireOpen();
        CatalogStatus result;
        result.storageMode = OperationStorageMode.jsonCatalog;
        result.sourcePath = backendTarget.catalogPath;
        result.schemaVersion = catalog.dataVersion;
        result.mediaInfoVersion = catalog.mediaInfoVersion;
        result.fileUtilityVersion = catalog.fileUtilityVersion;
        result.error = catalogLoadError;
        result.treeStatisticsAvailable = catalogLoadError.length == 0
            && sourceRoot.length > 0 && treeQueriesAvailable;

        bool[string] directoryPaths;
        size_t[string] fingerprintCounts;
        foreach (blob; catalog.dataArray)
        {
            if (blob is null)
                continue;
            ++result.blobCount;
            if (blob.checkSums.hasDigests)
                ++result.checksumBlobCount;
            if (blob.fileType.length > 0)
                ++result.fileTypeBlobCount;
            if (blob.mediaInfoSig !is null)
                ++result.mediaBlobCount;
            if (blob.archiveIndexKnown || blob.archiveSpecs !is null)
                ++result.archiveBlobCount;
            if (blob.torrentInfo !is null)
                ++result.torrentBlobCount;
            if (blob.checkSums.hasDigests
                && blob.getFirstFileName().length > 0)
            {
                const key = blob.fileSize.to!string ~ "\0"
                    ~ blob.checkSums.md5sum_b64 ~ "\0"
                    ~ blob.checkSums.sha1sum_b64 ~ "\0"
                    ~ blob.checkSums.xxh64sum_b64;
                ++fingerprintCounts[key];
            }

            const bool parseVirtual = catalog.dataVersion == DATA_CLASS_VERSION5
                || blob.fileSpecsUseArchiveVirtualGrammar;
            foreach (spec; blob.fileSpecs)
            {
                if (spec is null || spec.fileName.length == 0)
                    continue;
                bool virtualPath;
                string physicalPath = spec.fileName;
                if (parseVirtual)
                {
                    try
                    {
                        const parsed = parseArchiveVirtualPath(spec.fileName);
                        virtualPath = parsed.isVirtual;
                        physicalPath = parsed.physicalPath;
                    }
                    catch (Exception)
                    {
                        /* Keep unparsable legacy names as physical references. */
                    }
                }
                if (virtualPath)
                {
                    ++result.archiveMemberCount;
                    continue;
                }
                ++result.physicalReferenceCount;
                result.aggregateSize += blob.fileSize;
                const parent = parentPath(
                    nativePathToStoragePath(physicalPath));
                if (parent.length > 0)
                    directoryPaths[parent] = true;
            }
        }
        result.referenceCount = result.physicalReferenceCount
            + result.archiveMemberCount;
        result.directoryCount = directoryPaths.length;
        if (result.treeStatisticsAvailable)
        {
            result.directoryCount = directoryRows.length;
            foreach (row; fileRows)
                if (row.availability == CatalogReferenceAvailability.unavailable)
                    ++result.missingReferenceCount;
        }
        foreach (count; fingerprintCounts)
            if (count > 1)
                ++result.duplicateGroupCount;

        if (exists(backendTarget.catalogPath))
        {
            result.catalogSize = getSize(backendTarget.catalogPath);
            result.updatedAt = timeLastModified(
                backendTarget.catalogPath).toISOExtString;
        }
        return result;
    }

    /**
     * Report the operations and query features this JSON source supports.
     *
     * Scanning is advertised only when a filesystem root is bound. Tree and
     * filtered-export support additionally require a successfully loaded,
     * consistent index.
     *
     * Returns: Capabilities for this backend instance.
     * Throws: `CatalogBackendException` when the backend has been closed.
     */
    override CatalogBackendCapabilities capabilities()
    {
        requireOpen();
        CatalogBackendCapabilities result;
        result.operations = [OperationKind.analyze];
        if (sourceRoot.length > 0)
            result.operations ~= OperationKind.scan;
        result.supportsTreeQueries = catalogLoadError.length == 0
            && treeQueriesAvailable;
        result.supportsConcurrentReads = false;
        result.supportsReadsDuringMutation = false;
        result.supportsFilteredExport = catalogLoadError.length == 0
            && treeQueriesAvailable;
        result.supportsArchiveEntryQueries = true;
        result.supportsTorrentEntryQueries = !torrentEntryDetailsUnavailable;
        result.supportsFirstClassArchiveReferences = true;
        result.persistence = CatalogPersistence.inMemoryDocument;
        return result;
    }

    /**
     * Reject in-place JSON import through this adapter.
     *
     * Params:
     *     jsonPath = Source path; not used because import is rejected.
     *     options = Import options; not used because import is rejected.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.unsupportedOperation` unconditionally, or when
     *     the backend is closed.
     */
    override void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init)
    {
        requireOpen();
        throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedOperation,
            "JSON catalogs cannot import into themselves through this adapter.");
    }

    /**
     * Reject controlled in-place JSON import; delegates to `importJson`.
     *
     * Params:
     *     jsonPath = Source path; not used because import is rejected.
     *     options = Import options; not used because import is rejected.
     *     control = Operation control; not used because import is rejected.
     *     operationId = Operation ID; not used because import is rejected.
     * Returns: Never returns normally because `importJson` always throws.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.unsupportedOperation` unconditionally.
     */
    override bool importJsonControlled(string jsonPath, JsonImportOptions options,
        OperationControl control, ulong operationId)
    {
        importJson(jsonPath, options);
        return true;
    }

    /**
     * Run a scan operation against this JSON catalog.
     *
     * Params:
     *     request = Scan request including target, options, and dry-run flag.
     *     control = Progress and cancellation control.
     * Returns: The operation result; the catalog is reloaded when changes were
     *     committed.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidTarget` for a mismatched target or
     *     missing filesystem root, and
     *     `CatalogBackendErrorCode.unsupportedOperation` when scanning is not
     *     supported.
     */
    override OperationResult runOperation(ScanOperationRequest request,
        OperationControl control)
    {
        requireTarget(request.target, OperationKind.scan);
        if (!capabilities().supports(OperationKind.scan))
            throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedOperation,
                "JSON scanning requires a filesystem root bound to the backend.");
        return executeAndRefresh(request, control);
    }

    /**
     * Reject standalone metadata operations for JSON catalogs.
     *
     * Params:
     *     request = Metadata request whose target is validated first.
     *     control = Progress and cancellation control; unused.
     * Returns: Never returns normally because metadata operations are always
     *     rejected.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidTarget` for a mismatched target, and
     *     `CatalogBackendErrorCode.unsupportedOperation` unconditionally
     *     otherwise.
     */
    override OperationResult runOperation(MetadataOperationRequest request,
        OperationControl control)
    {
        requireTarget(request.target, OperationKind.metadata);
        throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedOperation,
            "Standalone metadata operations are not supported for JSON catalogs.");
    }

    /**
     * Run an analysis operation against this JSON catalog.
     *
     * Params:
     *     request = Analysis request including target, options, and dry-run flag.
     *     control = Progress and cancellation control.
     * Returns: The operation result; the catalog is reloaded when changes were
     *     committed.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidTarget` for a mismatched target.
     */
    override OperationResult runOperation(AnalysisOperationRequest request,
        OperationControl control)
    {
        requireTarget(request.target, OperationKind.analyze);
        return executeAndRefresh(request, control);
    }

    /**
     * Close the backend and drop all derived indexes.
     *
     * The in-memory catalog document is retained; only query indexes are
     * released.
     */
    override void close()
    {
        closed = true;
        fileRows = null;
        directoryRows = null;
        contentByToken = null;
        archiveEntriesByToken = null;
        torrentEntriesByToken = null;
        archiveMemberRowsByDirectory = null;
    }

    /**
     * Throw when the backend has already been closed.
     *
     * Throws: `CatalogBackendException` with `CatalogBackendErrorCode.closed`.
     */
    package void requireOpen() const
    {
        if (closed)
            throw new CatalogBackendException(CatalogBackendErrorCode.closed,
                "JSON catalog backend is closed.");
    }

    /**
     * Require an open, readable catalog whose tree queries are available.
     *
     * Throws: `CatalogBackendException` with `CatalogBackendErrorCode.closed`,
     *     `CatalogBackendErrorCode.backendFailure` when the catalog failed to
     *     load, or `CatalogBackendErrorCode.unsupportedFeature` when no consistent
     *     tree index exists.
     */
    package void requireTreeQueries() const
    {
        requireOpen();
        if (catalogLoadError.length > 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                "Could not read JSON catalog: " ~ catalogLoadError);
        if (!treeQueriesAvailable)
            throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedFeature,
                "JSON tree queries require a bound root and root-contained references.");
    }

    /**
     * Validate that an operation target matches the opened JSON catalog.
     *
     * Params:
     *     request = Target supplied by the operation request.
     *     operation = Operation kind; scan additionally requires both the bound
     *         and requested filesystem roots.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidTarget` when the catalog path, mode,
     *     repository root, or filesystem root does not match.
     */
    package void requireTarget(OperationTarget request, OperationKind operation) const
    {
        requireOpen();
        if (request.mode != OperationStorageMode.jsonCatalog
            || request.catalogPath.length == 0
            || canonicalPath(request.catalogPath) != backendTarget.catalogPath
            || request.repositoryRoot.length > 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "Operation target does not match the opened JSON catalog.");
        if (request.filesystemRoot.length > 0
            && canonicalPath(request.filesystemRoot) != sourceRoot)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "Operation filesystem root does not match the opened JSON source.");
        if (operation == OperationKind.scan
            && (sourceRoot.length == 0 || request.filesystemRoot.length == 0))
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "JSON scan requires the explicitly bound filesystem root.");
    }

    /**
     * Run a scan through the shared operation runner and refresh the index.
     *
     * Params:
     *     request = Scan request forwarded to the operation runner.
     *     control = Progress and cancellation control.
     * Returns: The operation result.
     */
    package OperationResult executeAndRefresh(ScanOperationRequest request,
        OperationControl control)
    {
        auto result = dosierskanilo.operationrunner.runOperation(request, control);
        if (result.changesCommitted)
            reloadCatalog();
        return result;
    }

    /**
     * Run an analysis through the shared operation runner and refresh the index.
     *
     * Params:
     *     request = Analysis request forwarded to the operation runner.
     *     control = Progress and cancellation control.
     * Returns: The operation result.
     */
    package OperationResult executeAndRefresh(AnalysisOperationRequest request,
        OperationControl control)
    {
        auto result = dosierskanilo.operationrunner.runOperation(request, control);
        if (result.changesCommitted)
            reloadCatalog();
        return result;
    }

    /**
     * Re-read the catalog from disk and rebuild every derived index.
     *
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.backendFailure` when the catalog cannot be
     *     read again.
     */
    package void reloadCatalog()
    {
        loadFingerprint = catalogFileFingerprint(backendTarget.catalogPath);
        try
            catalog = deserializeDataClassJsonWrapperFile(backendTarget.catalogPath);
        catch (Exception failure)
            throw new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                "JSON operation committed but its output could not be reloaded: "
                ~ failure.msg);
        catalogLoadError = "";
        rebuildIndex();
    }

    /**
     * Normalize a path to an absolute native storage path.
     *
     * Params:
     *     path = Path to normalize.
     * Returns: The absolute, normalized storage representation.
     */
    package string canonicalPath(string path) const
    {
        return nativePathToStoragePath(buildNormalizedPath(absolutePath(path)));
    }

    /**
     * Validate that a target denotes an explicit JSON catalog source.
     *
     * Params:
     *     target = Target to validate.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidTarget` unless the mode is
     *     `OperationStorageMode.jsonCatalog`, the catalog path is set, and no
     *     repository root is given.
     */
    package void enforceJsonTarget(OperationTarget target) const
    {
        if (target.mode != OperationStorageMode.jsonCatalog
            || target.catalogPath.length == 0 || target.repositoryRoot.length > 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "JSON backend requires an explicit JSON catalog target.");
    }

    /**
     * Require the version-5 JSON export format.
     *
     * Params:
     *     options = Export options to validate.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.unsupportedFeature` for any other format.
     */
    package void enforceJsonExportFormat(CatalogExportOptions options) const
    {
        if (options.format != CatalogExportFormat.jsonV5)
            throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedFeature,
                "JSON catalog adapter exports version 5 only.");
    }
}
