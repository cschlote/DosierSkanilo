/** Storage-neutral catalog query and operation contract.
 *
 *
 * `CatalogBackend` is the read and operation interface, `CatalogDocument` the
 * JSON document session, and `CatalogBackendFactory` the creation boundary.
 * The value types are re-exported from `dosierskanilo.catalogtypes`.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.catalogbackend;

public import dosierskanilo.catalogtypes;

import dosierskanilo.membercontentcache : MemberContentLease;
import dosierskanilo.operations : AnalysisOperationRequest,
    MetadataOperationRequest, OperationControl, OperationResult,
    OperationTarget, ScanOperationRequest;
import dosierskanilo.repository.types : JsonImportOptions, RepositoryBlobPage,
    RepositoryDuplicateGroup, RepositoryInfo, RepositoryQueryOptions;

/**
 * One explicit save/discard session over an in-memory catalog document.
 *
 * Only sources with `CatalogPersistence.inMemoryDocument` provide this view.
 * Applying an operation changes the document buffer and marks it modified;
 * `save` persists the buffer, `discard` reloads from storage. Stored vs.
 * in-memory mutations stay separate from transactional stores.
 *
 * Document sessions are intended for interactive edit/save workflows. Use the
 * batch operation API when a dry-run preview must leave the document untouched.
 */
interface CatalogDocument
{
    /** Whether the document buffer differs from its last loaded/saved state.
     *
     * Returns: `true` when unsaved changes are present.
     */
    bool modified() const;

    /** Adapter fingerprint captured at load time for conflict detection.
     *
     * Returns: The opaque fingerprint of the stored catalog.
     */
    string fingerprint() const;

    /** Suggested filesystem root for rooted tree queries over this document.
     *
     * Returns: A suggested root path; empty when none is known.
     */
    string suggestedFilesystemRoot();

    /** Bind or clear the filesystem root used by tree queries.
     *
     * Params:
     *     root = Root path to bind; empty clears the binding.
     */
    void bindFilesystemRoot(string root);

    /** Apply a scan and optional metadata/duplicate phase to the document buffer.
     *
     * Params:
     *     request = Scan request describing the source and phases.
     *     control = Cooperative operation control handle.
     * Returns: The operation result for the buffered scan.
     */
    OperationResult applyScan(ScanOperationRequest request,
        OperationControl control);

    /** Apply an analysis and optional metadata phase to the document buffer.
     *
     * Params:
     *     request = Analysis request describing the source and phases.
     *     control = Cooperative operation control handle.
     * Returns: The operation result for the buffered analysis.
     */
    OperationResult applyAnalysis(AnalysisOperationRequest request,
        OperationControl control);

    /**
     * Persist the in-memory buffer when the document is modified.
     *
     * Params:
     *   pretty = indent the serialized catalog for human reading.
     * Throws: `CatalogBackendException` with `writeConflict` when the stored
     *     file changed after loading, or `CatalogWriteException` when the
     *     streaming write and its recovery fallback both fail.
     */
    void save(bool pretty = false);

    /**
     * Discard unsaved changes and reload the stored catalog.
     *
     * Throws: `CatalogBackendException` with `backendFailure` when the stored
     *     catalog cannot be reloaded. The session stays open.
     */
    void discard();

    /**
     * Mark the session closed without saving or discarding.
     *
     * Later document calls throw `CatalogBackendException` with `closed`.
     */
    void close();
}

/** One source-bound, storage-neutral view over JSON or repository storage.
 *
 * Query results are detached value snapshots. Cursors are opaque, source- and
 * query-bound values; a committed mutation may invalidate them. `close()` is
 * called after any operation and its workers have completed.
 */
interface CatalogBackend
{
    /** The explicit target accepted by the factory that opened this backend.
     *
     * Returns: The source-bound operation target.
     */
    OperationTarget target();

    /** Storage-neutral source label and kind.
     *
     * Returns: The storage mode and a human-facing display label.
     */
    CatalogSourceInfo sourceInfo();

    /** Repository-style metadata for CLI info output.
     *
     * Returns: Repository root and schema metadata.
     */
    RepositoryInfo repositoryInfo();

    /** Supported operations/features; unsupported behavior is never inferred.
     *
     * Returns: The capability set advertised by this source.
     */
    CatalogBackendCapabilities capabilities();

    /**
     * Open the in-memory document view.
     *
     * Returns: A save/discard session over the document buffer.
     * Throws: `CatalogBackendException` with `unsupportedFeature` for
     *     transactional stores or when the adapter has no document session.
     */
    CatalogDocument document();

    /** Return bounded aggregates for the source root under the shared filter.
     *
     * Params:
     *     filter = Source-neutral filters applied to the aggregates.
     * Returns: Directory, reference, and aggregate-size totals.
     */
    CatalogRootSummary rootSummary(CatalogFilter filter = CatalogFilter.init);

    /** List immediate child directories under the requested parent.
     *
     * Params:
     *     query = Parent directory and source-neutral filters.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded directory page with continuation state.
     */
    CatalogDirectoryPage listDirectories(CatalogDirectoryQuery query,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** List matching immediate file references in the selected stable order.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The requested file page.
     */
    CatalogFilePage listFiles(CatalogFileQuery query,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** Continue forward using a cursor issued for this source and query.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     cursor = Forward continuation cursor returned for the same query.
     * Returns: The next file page.
     */
    CatalogFilePage nextFilesPage(CatalogFileQuery query, CatalogPageCursor cursor);

    /** Continue backward and return rows in the query's display order.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     cursor = Backward continuation cursor returned for the same query.
     * Returns: The preceding file page.
     */
    CatalogFilePage previousFilesPage(CatalogFileQuery query, CatalogPageCursor cursor);

    /**
     * Return a bounded page adjacent to a reference for stateless navigation.
     *
     * `anchorRelativePath` names a reference in the same directory and filter.
     * A forward page starts strictly after it; a backward page ends strictly
     * before it and returns the nearest matches in display order. An empty
     * anchor starts at the first file for forward requests and yields an empty
     * page otherwise. Unknown anchors yield an empty page so callers can drop
     * stale UI state instead of guessing a position.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     anchorRelativePath = Reference path to position next to; empty starts
     *         at the first file for forward requests.
     *     forward = Select rows after the anchor instead of before it.
     *     limit = Maximum rows to return; must be greater than zero.
     * Returns: The adjacent page, or an empty page for an unknown anchor.
     */
    CatalogFilePage listFilesFrom(CatalogFileQuery query, string anchorRelativePath,
        bool forward, size_t limit = 250);

    /** List deduplicated content rows for table-oriented projections.
     *
     * Params:
     *     query = Content filters applied by the backend.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded content page with total row count.
     */
    CatalogContentPage listContents(CatalogContentQuery query,
        CatalogPageRequest page = CatalogPageRequest.init);

    /**
     * Store or clear the archive password for one reference path.
     *
     * The path is resolved like `resolveReference`; a unique basename is also
     * accepted. An empty password clears the stored value. Unknown or ambiguous
     * paths raise `invalidIdentifier`, unsupported stores raise
     * `unsupportedFeature`.
     *
     * Params:
     *     relativePath = Reference path or unique basename to update.
     *     password = Password to store; empty clears the stored value.
     */
    void setArchivePassword(string relativePath, string password);

    /** Load one detached content snapshot, including only requested details.
     *
     * Params:
     *     contentId = Content identity to load.
     *     details = Detail families to include in the snapshot.
     * Returns: The requested content snapshot.
     */
    CatalogContentSnapshot loadContent(ContentId contentId,
        CatalogDetailMask details = CatalogDetailMask.init);

    /** Page through the current archive index for one content record.
     *
     * Params:
     *     contentId = Content identity of an indexed archive.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded archive-entry page.
     */
    CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** List bounded, structured member references for one selected container reference.
     *
     * Params:
     *     containerReferenceId = Reference identity of the container.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded archive-member page.
     */
    CatalogArchiveMemberPage listArchiveMembers(ReferenceId containerReferenceId,
        CatalogPageRequest page = CatalogPageRequest.init);

    /** Page through torrent manifest descriptors for one content record.
     *
     * Params:
     *     contentId = Content identity of an indexed torrent.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded torrent-entry page.
     */
    CatalogTorrentEntryPage listTorrentEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init);

    /**
     * Resolve a root-relative directory path to its typed identity.
     *
     * An empty path (or ".") denotes the source root and returns an invalid ID.
     * An unknown path also returns an invalid ID; callers must not treat
     * unresolved paths as errors during state restoration.
     *
     * Params:
     *     relativePath = Normalized source-relative directory path.
     * Returns: The matching identity, or an invalid ID when unresolved.
     */
    DirectoryId resolveDirectory(string relativePath);

    /**
     * Resolve a root-relative reference path to its typed identity.
     *
     * Canonical virtual member paths (`container!/member`) are accepted. An
     * unknown path returns an invalid ID.
     *
     * Params:
     *     relativePath = Normalized reference path.
     * Returns: The matching identity, or an invalid ID when unresolved.
     */
    ReferenceId resolveReference(string relativePath);

    /**
     * Load one reference row by typed identity.
     *
     * Params:
     *     referenceId = Reference identity to load.
     * Returns: The detached reference row.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when the
     *     reference is unknown or belongs to another source.
     */
    CatalogFile loadReference(ReferenceId referenceId);

    /**
     * Extract one archive member through the process-wide leased cache.
     *
     * The backend resolves the container chain, looks up stored container
     * passwords, and returns a lease the caller must release. Extraction
     * failures surface as typed backend errors; cache capacity and close
     * failures are reported by the cache.
     *
     * Params:
     *     memberReferenceId = Reference identity of the archive member.
     *     cancellation = Optional cooperative cancellation flag.
     * Returns: A lease over the extracted member content.
     */
    MemberContentLease acquireMemberContent(ReferenceId memberReferenceId,
        shared(bool)* cancellation = null);

    /**
     * Opaque key for UI tree/list models.
     *
     * The value is stable while this backend instance is open, differs between
     * identifier kinds, and must never be parsed or persisted. Use
     * `resolveDirectory`/`resolveReference` to restore UI state by path.
     *
     * Params:
     *     id = Directory identity to encode.
     * Returns: An opaque, kind-prefixed handle.
     */
    final string uiHandle(DirectoryId id)
    {
        if (!id.isValid)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Cannot build a UI handle for an invalid directory identity.");
        return "dir:" ~ id.adapterToken;
    }

    /** Opaque reference key for UI models; see the directory overload.
     *
     * Params:
     *     id = Reference identity to encode.
     * Returns: An opaque, kind-prefixed handle.
     */
    final string uiHandle(ReferenceId id)
    {
        if (!id.isValid)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Cannot build a UI handle for an invalid reference identity.");
        return "ref:" ~ id.adapterToken;
    }

    /** Opaque content key for UI models; see the directory overload.
     *
     * Params:
     *     id = Content identity to encode.
     * Returns: An opaque, kind-prefixed handle.
     */
    final string uiHandle(ContentId id)
    {
        if (!id.isValid)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Cannot build a UI handle for an invalid content identity.");
        return "content:" ~ id.adapterToken;
    }

    /** Page through repository-style blob query results.
     *
     * Params:
     *     options = Query offsets, limits, filters, and sort options.
     * Returns: The repository blob page with ids and flags.
     */
    RepositoryBlobPage queryBlobs(RepositoryQueryOptions options);

    /** Return duplicate groups without mutating the source.
     *
     * Params:
     *     limit = Maximum groups requested; must be greater than zero.
     * Returns: The duplicate groups, or an empty array when none exist.
     */
    RepositoryDuplicateGroup[] queryDuplicateGroups(size_t limit = 100);

    /** Export a selected relationship-closed subset to an explicit destination.
     *
     * Params:
     *     query = Selected path prefix and filters.
     *     options = Output format, destination, and detail flags.
     * Returns: Counts and publication state of the export.
     */
    CatalogExportResult exportSubset(CatalogSubsetQuery query,
        CatalogExportOptions options);

    /**
     * Export a subset with cooperative cancellation. Implementations stop at
     * safe checkpoints and leave `committed` false when cancelled.
     *
     * Params:
     *     query = Selected path prefix and filters.
     *     options = Output format, destination, and detail flags.
     *     control = Cooperative control used for progress and cancellation.
     *     operationId = Identifier reported with progress events.
     * Returns: Counts and publication state; `committed` is false when
     *     cancelled.
     */
    CatalogExportResult exportSubsetControlled(CatalogSubsetQuery query,
        CatalogExportOptions options, OperationControl control,
        ulong operationId);

    /** Import a JSON catalog into the bound repository source.
     *
     * Params:
     *     jsonPath = Path of the JSON catalog to import.
     *     options = Import options controlling merge behavior.
     */
    void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init);

    /**
     * Import a JSON catalog with cooperative cancellation. Returns `false` when
     * the import was cancelled before commit.
     *
     * Params:
     *     jsonPath = Path of the JSON catalog to import.
     *     options = Import options controlling merge behavior.
     *     control = Cooperative control used for progress and cancellation.
     *     operationId = Identifier reported with progress events.
     * Returns: `true` when committed, `false` when cancelled before commit.
     */
    bool importJsonControlled(string jsonPath, JsonImportOptions options,
        OperationControl control, ulong operationId);

    /** Run scan synchronously and require its explicit root to match this source.
     *
     * Params:
     *     request = Scan request including target and scan options.
     *     control = Cooperative operation control handle.
     * Returns: The operation result.
     */
    OperationResult runOperation(ScanOperationRequest request,
        OperationControl control);

    /** Run metadata synchronously when supported and bound to this source.
     *
     * Params:
     *     request = Metadata request including target and options.
     *     control = Cooperative operation control handle.
     * Returns: The operation result.
     */
    OperationResult runOperation(MetadataOperationRequest request,
        OperationControl control);

    /**
     * Run analysis synchronously when supported. JSON analysis may omit its
     * filesystem root; a supplied root must match the opened source.
     *
     * Params:
     *     request = Analysis request including target and options.
     *     control = Cooperative operation control handle.
     * Returns: The operation result.
     */
    OperationResult runOperation(AnalysisOperationRequest request,
        OperationControl control);

    /**
     * Release source resources after active operations have joined. Closing does
     * not mutate the catalog; subsequent calls report the typed `closed` error.
     */
    void close();
}

/** Explicit factory boundary; implementations select, but never reinterpret, a target. */
interface CatalogBackendFactory
{
    /**
     * Open exactly this target or throw a typed target/open error.
     *
     * JSON targets may omit the filesystem root for analysis-only use. Rooted
     * tree queries and scans require a root at open time or a later call to
     * `CatalogDocument.bindFilesystemRoot`.
     *
     * Params:
     *     target = Operation target to open.
     * Returns: A backend bound to the requested source.
     * Throws: `CatalogBackendException` when the target shape or source cannot
     *     be opened.
     */
    CatalogBackend open(OperationTarget target);
}
