/** SQLite repository adapter for the storage-neutral catalog contract.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.sqlitecatalogbackend;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.base64 : Base64;
import std.conv : to;
import std.exception : enforce;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath;
import std.string : split;
import std.uuid : randomUUID;

import dosierarkivo.archive : archiveDisplayBaseName, archivePathSeparator,
    parseArchiveVirtualPath;
import dosierskanilo.catalogbackend;
import dosierskanilo.catalogstatus : CatalogStatus, CatalogStatusProvider;
import dosierskanilo.membercontentcache : MemberContentLease;
import dosierskanilo.membercontentcache : MemberContentCancelledException;
import dosierskanilo.memberextraction : ArchiveExtractionStep,
    extractArchiveMember;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5, NamedBinaryBlob,
    NamedBinaryBlobCatalog;
import dosierskanilo.operationrunner;
import dosierskanilo.operations : AnalysisOperationRequest,
    MetadataOperationRequest, OperationControl, OperationKind, OperationPhase,
    OperationProgress, OperationResult, OperationState, OperationStorageMode,
    OperationTarget, ScanOperationRequest;
import dosierskanilo.repository;
import dosierskanilo.repository.types : JsonExportOptions,
    RepositoryArchiveQuery, RepositoryBlobPage, RepositoryDirectoryQuery,
    RepositoryFile, RepositoryFileCursor, RepositoryFileQuery,
    RepositoryFileSortOrder, RepositoryQueryOptions, RepositoryTorrentQuery;
import dosierskanilo.jsoncatalogbackend : JsonCatalogBackendFactory;
import dosierskanilo.service.jsonoperations : commitJsonCatalog;

/// Default page size used for internal repository pagination walks.
private enum size_t catalogPageSize = 250;

/** Resolved container state for an archive reference, independent of its token. */
private struct ArchiveContainerSource
{
    long contentBlobId; /// Content blob holding the container archive, or zero.
    long directoryId; /// Repository directory that contains the physical file.
    CatalogReferenceAvailability availability; /// Availability of the physical file.
    string identity; /// Compact container identity (`p<id>` plus entry chain).
}

/** SQLite-backed adapter over the public repository facade. */
final class SqliteCatalogBackend : CatalogBackend, CatalogStatusProvider
{
private:
    /// Canonical repository target this backend was opened with.
    OperationTarget backendTarget;
    /// Random per-instance token that scopes all issued identities.
    string sourceToken;
    /// Whether `close` has released this backend's repository resources.
    bool closed;
    /// Lazily opened read connection reused across calls.
    Repository cachedRepository;

public:
    /** Open exactly one initialized SQLite repository target. */
    this(OperationTarget target)
    {
        validateTargetShape(target);
        string root;
        try
            root = Repository.findRoot(target.repositoryRoot);
        catch (Exception failure)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "Could not resolve SQLite repository target: " ~ failure.msg);
        if (root.length == 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "No DosierSkanilo repository found from: " ~ target.repositoryRoot);
        backendTarget = OperationTarget.repositoryTarget(canonicalPath(root));
        sourceToken = randomUUID().toString();
        try
            cachedRepository = Repository.open(backendTarget.repositoryRoot);
        catch (Exception failure)
            throw new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                "Could not open SQLite repository: " ~ failure.msg);
    }

    /** Reject the document view; SQLite backends are transactional stores.
     *
     * Returns: Never returns; this adapter always throws.
     * Throws: `CatalogBackendException` with `unsupportedFeature`.
     */
    override CatalogDocument document()
    {
        throw new CatalogBackendException(
            CatalogBackendErrorCode.unsupportedFeature,
            "SQLite repositories have no in-memory document view.");
    }

    /** Return the canonical repository target selected at open time.
     *
     * Returns: The target stored for this backend instance.
     * Throws: `CatalogBackendException` with `closed`.
     */
    override OperationTarget target()
    {
        requireOpen();
        return backendTarget;
    }

    /** Return the repository source label and storage mode.
     *
     * Returns: Repository storage mode and the repository directory basename.
     * Throws: `CatalogBackendException` with `closed`.
     */
    override CatalogSourceInfo sourceInfo()
    {
        requireOpen();
        CatalogSourceInfo result;
        result.storageMode = OperationStorageMode.repository;
        result.displayName = baseName(backendTarget.repositoryRoot);
        return result;
    }

    /** Return repository-style metadata for CLI info output.
     *
     * Returns: The opened repository's info record.
     * Throws: `CatalogBackendException` with `closed` or `backendFailure`.
     */
    override RepositoryInfo repositoryInfo()
    {
        return withRepository((Repository repository) {
            return repository.info;
        });
    }

    /** Return aggregate counters for the SQLite repository.
     *
     * Returns: The repository status produced by one aggregate read.
     * Throws: `CatalogBackendException` with `closed` or `backendFailure`.
     */
    override CatalogStatus catalogStatus()
    {
        return withRepository((Repository repository) {
            return repository.catalogStatus();
        });
    }

    /** Return the capabilities advertised by the SQLite adapter.
     *
     * Returns: All supported operations and tree/detail/export features.
     * Throws: `CatalogBackendException` with `closed`.
     */
    override CatalogBackendCapabilities capabilities()
    {
        requireOpen();
        CatalogBackendCapabilities result;
        result.operations = [OperationKind.scan, OperationKind.metadata,
            OperationKind.analyze];
        result.supportsTreeQueries = true;
        result.supportsConcurrentReads = true;
        result.supportsReadsDuringMutation = true;
        result.supportsFilteredExport = true;
        result.supportsArchiveEntryQueries = true;
        result.supportsTorrentEntryQueries = true;
        result.supportsFirstClassArchiveReferences = true;
        result.persistence = CatalogPersistence.transactionalStore;
        return result;
    }

    /** Return bounded root aggregates under the shared filter.
     *
     * Without an active filter the repository's normalized summary and
     * physical reference count are used directly; otherwise the tree is
     * walked in bounded pages.
     *
     * Params:
     *     filter = Source-neutral filters applied to the totals.
     * Returns: Directory, reference, and aggregate-size totals.
     * Throws: `CatalogBackendException` with `closed` or `backendFailure`.
     */
    override CatalogRootSummary rootSummary(CatalogFilter filter = CatalogFilter.init)
    {
        return withRepository((Repository repository) {
            CatalogRootSummary result;
            if (!hasActiveFilter(filter))
            {
                /* The normalized repository summary already counts every
                 * physical reference and aggregates its content size in SQL.
                 * Walking millions of rows through the page API here made the
                 * initial tree load take minutes on large repositories. */
                auto summary = repository.rootSummary();
                result.childDirectoryCount = summary.childDirectoryCount;
                result.fileReferenceCount = repository.physicalFileReferenceCount();
                result.aggregateSize = summary.aggregateSize;
                return result;
            }

            result.childDirectoryCount = countDirectories(repository,
                CatalogDirectoryQuery.init, filter);
            walkMatchingFiles(repository, filter, "", (RepositoryFile file) {
                ++result.fileReferenceCount;
                result.aggregateSize += file.size;
            });
            return result;
        });
    }

    /** List immediate child directories under the requested parent.
     *
     * Params:
     *     query = Parent directory and source-neutral filters.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded directory page with continuation state.
     * Throws: `CatalogBackendException` with `closed`, `invalidCursor`, or
     *     `backendFailure`.
     */
    override CatalogDirectoryPage listDirectories(CatalogDirectoryQuery query,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        return withRepository((Repository repository) {
            validatePageRequest(page);
            const auto queryToken = directoryQueryToken(repository, query);
            const auto offset = cursorOffset(page, queryToken);
            if (page.cursor.isValid && offset > countDirectories(repository,
                query, query.filter))
                throw invalidCursor("Directory cursor is outside the result sequence.");
            auto request = repositoryDirectoryQuery(query);
            request.offset = offset;
            request.limit = page.limit + 1;
            auto rows = repository.listDirectories(request);

            CatalogDirectoryPage result;
            auto count = rows.length < page.limit ? rows.length : page.limit;
            foreach (row; rows[0 .. count])
            {
                CatalogDirectory directory;
                directory.id = directoryId(row.id);
                if (row.parentId > 0)
                    directory.parentId = directoryId(row.parentId);
                directory.name = row.name;
                directory.relativePath = row.relativePath;
                directory.childDirectoryCount = row.childDirectoryCount;
                directory.fileCount = row.fileCount;
                directory.aggregateSize = row.aggregateSize;
                result.directories ~= directory;
            }
            result.hasPrevious = offset > 0;
            result.hasMore = rows.length > page.limit;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(offset + count,
                    page.limit, queryToken);
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(
                    offset > page.limit ? offset - page.limit : 0,
                    page.limit, queryToken);
            return result;
        });
    }

    /** List matching immediate file references in the selected stable order.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The requested file page.
     * Throws: `CatalogBackendException` with `closed`, `invalidCursor`, or
     *     `backendFailure`.
     */
    override CatalogFilePage listFiles(CatalogFileQuery query,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        return withRepository((Repository repository) {
            validatePageRequest(page);
            const auto queryToken = fileQueryToken(repository, query);
            if (!page.cursor.isValid)
                return loadForwardFilePage(repository, query, page.limit,
                    RepositoryFileCursor.init, false, queryToken);
            auto cursor = parseFileCursor(page.cursor, page.limit, queryToken);
            return loadForwardFilePage(repository, query, page.limit,
                cursor, true, queryToken);
        });
    }

    /** Continue forward using a cursor issued for this source and query.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     cursor = Forward continuation cursor returned for the same query.
     * Returns: The next file page.
     * Throws: `CatalogBackendException` with `closed` or `invalidCursor`.
     */
    override CatalogFilePage nextFilesPage(CatalogFileQuery query,
        CatalogPageCursor cursor)
    {
        return withRepository((Repository repository) {
            if (!cursor.isValid)
                throw invalidCursor("A next-page request requires a cursor.");
            const auto queryToken = fileQueryToken(repository, query);
            auto pivot = parseFileCursor(cursor, cursor.adapterPageSize, queryToken);
            return loadForwardFilePage(repository, query, cursor.adapterPageSize,
                pivot, true, queryToken);
        });
    }

    /** Continue backward and return rows in the query's display order.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     cursor = Backward continuation cursor returned for the same query.
     * Returns: The preceding file page.
     * Throws: `CatalogBackendException` with `closed` or `invalidCursor`.
     */
    override CatalogFilePage previousFilesPage(CatalogFileQuery query,
        CatalogPageCursor cursor)
    {
        return withRepository((Repository repository) {
            if (!cursor.isValid)
                throw invalidCursor("A previous-page request requires a cursor.");
            const auto queryToken = fileQueryToken(repository, query);
            auto pivot = parseFileCursor(cursor, cursor.adapterPageSize, queryToken);
            auto request = repositoryFileQuery(query);
            request.limit = cursor.adapterPageSize;
            auto page = repository.previousFilesPage(request, pivot);
            CatalogFilePage result;
            foreach (file; page.files)
                result.files ~= catalogFile(file);
            result.hasPrevious = page.hasMore;
            result.hasMore = result.files.length > 0;
            if (result.files.length > 0)
            {
                if (result.hasPrevious)
                    result.previousCursor = filePageCursor(queryToken,
                        result.files[0], cursor.adapterPageSize);
                if (result.hasMore)
                    result.nextCursor = filePageCursor(queryToken,
                        result.files[$ - 1], cursor.adapterPageSize);
            }
            return result;
        });
    }

    /** Return a bounded page adjacent to an anchor reference path.
     *
     * Params:
     *     query = Directory scope, filters, and sort order.
     *     anchorRelativePath = Anchor path; empty starts at the first file for
     *         forward requests.
     *     forward = Select rows strictly after the anchor instead of before it.
     *     limit = Maximum rows to return; must be greater than zero.
     * Returns: The adjacent page, or an empty page for an unknown anchor.
     * Throws: `CatalogBackendException` with `invalidCursor` for a zero limit,
     *     or `closed`/`backendFailure`.
     */
    override CatalogFilePage listFilesFrom(CatalogFileQuery query,
        string anchorRelativePath, bool forward, size_t limit = 250)
    {
        return withRepository((Repository repository) {
            if (limit == 0)
                throw invalidCursor("Catalog page limit must be greater than zero.");
            const auto queryToken = fileQueryToken(repository, query);
            if (anchorRelativePath.length == 0)
                return forward
                    ? loadForwardFilePage(repository, query, limit,
                        RepositoryFileCursor.init, false, queryToken)
                    : CatalogFilePage.init;

            const auto anchor = repository.fileReferenceByRelativePath(
                anchorRelativePath);
            if (anchor.id == 0)
                return CatalogFilePage.init;
            auto pivot = RepositoryFileCursor(anchor.relativePath, anchor.id,
                anchor.size);
            if (forward)
                return loadForwardFilePage(repository, query, limit, pivot, true,
                    queryToken);

            auto request = repositoryFileQuery(query);
            request.limit = limit;
            const auto sourcePage = repository.previousFilesPage(request, pivot);
            CatalogFilePage result;
            foreach (file; sourcePage.files)
                result.files ~= catalogFile(file);
            result.hasPrevious = sourcePage.hasMore;
            result.hasMore = result.files.length > 0;
            if (result.hasMore)
                result.nextCursor = filePageCursor(queryToken,
                    result.files[$ - 1], limit);
            if (result.hasPrevious)
                result.previousCursor = filePageCursor(queryToken,
                    result.files[0], limit);
            return result;
        });
    }

    /** List deduplicated content rows for table-oriented projections.
     *
     * Params:
     *     query = Content filters applied by the repository query.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded content page with total row count.
     * Throws: `CatalogBackendException` with `closed`, `invalidCursor`, or
     *     `backendFailure`.
     */
    override CatalogContentPage listContents(CatalogContentQuery query,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        return withRepository((Repository repository) {
            validatePageRequest(page);
            const auto queryToken = contentQueryToken(repository, query);
            const auto offset = cursorOffset(page, queryToken);
            RepositoryQueryOptions options;
            options.offset = offset;
            options.limit = page.limit + 1;
            options.text = query.filter.pathText;
            options.caseSensitive = query.filter.caseSensitive;
            options.video = query.filter.video;
            options.audio = query.filter.audio;
            options.image = query.filter.image;
            options.textStream = query.filter.text;
            options.mediaNegated = query.filter.mediaNegated;
            options.fileType = query.filter.fileType;
            options.archive = query.filter.archive;
            options.torrent = query.filter.torrent;
            options.referencedOnly = true;
            JsonExportOptions exportOptions;
            exportOptions.absolutePaths = false;
            exportOptions.includeDetails = false;
            auto source = repository.loadCatalogQueryPageWithIds(options,
                exportOptions);

            CatalogContentPage result;
            result.total = source.total;
            const auto count = source.blobs.length < page.limit
                ? source.blobs.length : page.limit;
            foreach (index; 0 .. count)
            {
                const blob = source.blobs[index];
                CatalogContentRow row;
                row.id = contentId(source.blobIds[index]);
                foreach (spec; blob.fileSpecs)
                    if (row.displayPath.length == 0
                        || spec.fileName < row.displayPath)
                        row.displayPath = spec.fileName;
                if (row.displayPath.length > 0)
                    row.displayName = archiveDisplayBaseName(row.displayPath);
                row.size = blob.fileSize;
                row.referenceCount = blob.fileSpecs.length;
                row.fingerprint = fingerprintFor(blob.fileSize, blob.checkSums);
                const auto flags = source.flags[index];
                row.hasFileType = flags.hasFileType;
                row.hasMedia = flags.hasMedia;
                row.hasVideo = flags.hasVideo;
                row.hasAudio = flags.hasAudio;
                row.hasImage = flags.hasImage;
                row.hasText = flags.hasText;
                row.hasArchive = flags.hasArchive;
                row.hasTorrent = flags.hasTorrent;
                result.rows ~= row;
            }
            result.hasPrevious = offset > 0;
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(offset > page.limit
                    ? offset - page.limit : 0, page.limit, queryToken);
            result.hasMore = source.blobs.length > page.limit;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(offset + result.rows.length,
                    page.limit, queryToken);
            return result;
        });
    }

    /** Build the source/version/query binding token for content cursors.
     *
     * Params:
     *     repository = Open repository supplying the source version.
     *     query = Content query whose filter is encoded.
     * Returns: A token that changes when the source or filter changes.
     */
    string contentQueryToken(Repository repository,
        CatalogContentQuery query) const
    {
        return sourceToken ~ "\0" ~ sourceVersion(repository) ~ "\0contents\0"
            ~ filterToken(query.filter);
    }

    /** Store or clear the archive password for one reference path.
     *
     * Params:
     *     relativePath = Exact path or unique basename of the reference.
     *     password = Password to store; empty clears the stored value.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when the
     *     path cannot be stored, or `closed`/`backendFailure`.
     */
    override void setArchivePassword(string relativePath, string password)
    {
        return withRepository((Repository repository) {
            try
                repository.setArchivePasswordForPath(relativePath, password);
            catch (RepositoryException failure)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Cannot store the archive password: " ~ failure.msg);
        });
    }

    /** Load one detached content snapshot, including only requested details.
     *
     * The full blob is loaded and then masked so extractor statuses match the
     * JSON backend even for masked requests.
     *
     * Params:
     *     contentId = Content identity issued by this backend.
     *     details = Detail families to include in the snapshot.
     * Returns: The requested content snapshot.
     * Throws: `CatalogBackendException` with `invalidIdentifier` for an
     *     unknown identity, or `closed`/`backendFailure`.
     */
    override CatalogContentSnapshot loadContent(ContentId contentId,
        CatalogDetailMask details = CatalogDetailMask.init)
    {
        return withRepository((Repository repository) {
            auto blobId = parseIdentity(contentId.adapterToken, "content");
            /* Load the full snapshot and mask it afterwards, matching the
             * JSON backend's extractor statuses even for masked requests. */
            JsonExportOptions options;
            options.absolutePaths = false;
            options.includeDetails = true;
            options.includeArchiveEntries = true;
            options.includeTorrentFiles = true;
            options.allowUnreferencedContent = true;
            auto blob = repository.loadBlobDetails(blobId, options);
            if (blob is null)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Unknown SQLite content identity.");
            auto snapshot = snapshotFor(blob, contentId, details);
            populateArchiveSummary(repository, blobId,
                blob.archiveIndexKnown || blob.archiveSpecs !is null, snapshot);
            if (!details.archiveSummary)
            {
                snapshot.hasArchive = false;
                snapshot.archiveSummary = CatalogArchiveSummary.init;
            }
            return snapshot;
        });
    }

    /** Page through the current archive index for one content record.
     *
     * Params:
     *     contentId = Content identity of an indexed archive.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded archive-entry page.
     * Throws: `CatalogBackendException` with `invalidIdentifier`,
     *     `invalidCursor`, `closed`, or `backendFailure`.
     */
    override CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        return withRepository((Repository repository) {
            validatePageRequest(page);
            const auto blobId = parseIdentity(contentId.adapterToken, "content");
            requireKnownContent(repository, blobId);
            const auto queryToken = detailQueryToken(repository, "archive", blobId);
            const auto offset = cursorOffset(page, queryToken);
            RepositoryArchiveQuery query;
            query.blobId = blobId;
            query.offset = offset;
            query.limit = page.limit + 1;
            auto rows = repository.listArchiveEntries(query);
            if (rows.length == 0 && offset > 0)
            {
                query.offset = offset - 1;
                query.limit = 1;
                if (repository.listArchiveEntries(query).length == 0)
                    throw invalidCursor("Archive member cursor is outside the result sequence.");
            }
            CatalogArchiveEntryPage result;
            const auto count = rows.length < page.limit ? rows.length : page.limit;
            foreach (row; rows[0 .. count])
            {
                CatalogArchiveEntry entry;
                entry.id = ArchiveEntryId(archiveEntryToken(blobId, row.id));
                entry.name = row.name;
                entry.relativePath = row.relativePath;
                entry.index = row.entryIndex;
                entry.occurrence = row.occurrence;
                entry.isDirectory = row.isDirectory;
                entry.hasSafePath = row.hasSafePath;
                entry.size = row.size;
                entry.modifiedAt = row.modifiedAt;
                entry.fingerprint = fingerprintFor(row.size, row.checkSums);
                if (row.contentBlobId > 0)
                    entry.contentId = this.contentId(row.contentBlobId);
                result.entries ~= entry;
            }
            result.hasMore = rows.length > page.limit;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(offset + count,
                    page.limit, queryToken);
            return result;
        });
    }

    /** List bounded member references for one selected container reference.
     *
     * Direct members are collected from bounded keyset pages and sorted by
     * relative path before the requested window is sliced out.
     *
     * Params:
     *     containerReferenceId = Reference identity of an indexed container.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded member page.
     * Throws: `CatalogBackendException` with `invalidIdentifier`,
     *     `invalidCursor`, `closed`, or `backendFailure`.
     */
    override CatalogArchiveMemberPage listArchiveMembers(
        ReferenceId containerReferenceId, CatalogPageRequest page = CatalogPageRequest.init)
    {
        return withRepository((Repository repository) {
            validatePageRequest(page);
            const auto container = resolveArchiveContainer(repository,
                containerReferenceId);
            if (container.contentBlobId == 0
                || !repository.hasArchiveIndex(container.contentBlobId))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Reference is not an indexed SQLite archive container.");
            const auto queryToken = detailQueryToken(repository,
                "archive-members", container.contentBlobId) ~ "\0"
                ~ containerReferenceId.adapterToken;
            RepositoryFileQuery query;
            query.directoryId = container.directoryId;
            query.includeArchiveMembers = true;
            query.limit = catalogPageSize;
            RepositoryFile[] directMembers;
            /* Walk the directory in bounded keyset pages instead of loading it
             * with an unbounded query. */
            RepositoryFilePage chunk = repository.listFilesPage(query);
            while (true)
            {
                foreach (file; chunk.files)
                    if (file.archiveMember
                        && file.archiveContainerIdentity == container.identity)
                        directMembers ~= file;
                if (!chunk.hasMore || chunk.files.length == 0)
                    break;
                chunk = repository.nextFilesPage(query, chunk.nextCursor);
            }
            directMembers.sort!((left, right) =>
                left.relativePath < right.relativePath);
            const auto offset = cursorOffset(page, queryToken);
            if (offset > directMembers.length)
                throw invalidCursor("Archive member cursor is outside the result sequence.");
            CatalogArchiveMemberPage result;
            const auto end = offset + page.limit < directMembers.length
                ? offset + page.limit : directMembers.length;
            foreach (file; directMembers[offset .. end])
            {
                CatalogArchiveMember member;
                member.referenceId = archiveMemberReferenceId(
                    container.identity, file.id);
                member.contentId = contentId(file.blobId);
                member.locator = ContentLocator.entry(containerReferenceId,
                    ArchiveEntryId(archiveEntryToken(container.contentBlobId,
                        file.id)));
                const auto parsed = parseArchiveVirtualPath(file.relativePath);
                const auto layer = parsed.entries[$ - 1];
                member.name = layer.relativePath;
                member.relativePath = layer.relativePath;
                member.size = file.size;
                member.modifiedAt = file.modifiedAt;
                member.availability = file.present
                    ? CatalogReferenceAvailability.available
                    : CatalogReferenceAvailability.unavailable;
                auto content = repository.loadBlobFingerprint(file.blobId);
                if (content !is null)
                    member.fingerprint = fingerprintFor(cast(size_t) content.fileSize,
                        content.checkSums);
                result.members ~= member;
            }
            result.hasMore = end < directMembers.length;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(end, page.limit, queryToken);
            return result;
        });
    }

    /** Resolve a reference identity to its archive container state.
     *
     * Physical references use the `:reference:` token prefix; archive members
     * carry a `p<physical-id>:<entry>:...` chain that is walked through the
     * repository to the innermost container.
     *
     * Params:
     *     repository = Open repository used for lookups.
     *     referenceId = Container reference identity issued by this backend.
     *     depth = Current recursion depth; at most 32 levels are accepted.
     * Returns: The resolved container blob, directory, availability, and identity.
     * Throws: `CatalogBackendException` with `invalidIdentifier` for an
     *     unknown, foreign, malformed, or too-deep reference chain.
     */
    ArchiveContainerSource resolveArchiveContainer(Repository repository,
        ReferenceId referenceId, size_t depth = 0) const
    {
        if (depth >= 32)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Archive container reference chain exceeds the maximum depth.");
        const auto physicalPrefix = sourceToken ~ ":reference:";
        if (referenceId.adapterToken.startsWith(physicalPrefix))
        {
            const auto fileId = parseIdentity(referenceId.adapterToken,
                "reference");
            auto file = repository.fileReference(fileId);
            if (file.id == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Unknown archive container file reference.");
            return ArchiveContainerSource(file.blobId, file.directoryId,
                file.present ? CatalogReferenceAvailability.available
                    : CatalogReferenceAvailability.unavailable,
                "p" ~ fileId.to!string);
        }

        const auto archivePrefix = sourceToken ~ ":archive-reference:";
        if (referenceId.adapterToken.startsWith(archivePrefix))
        {
            const auto identity = referenceId.adapterToken[archivePrefix.length .. $];
            auto components = identity.split(":");
            if (components.length < 2 || !components[0].startsWith("p"))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Malformed archive-member reference identity.");
            long physicalId;
            try
                physicalId = to!long(components[0][1 .. $]);
            catch (Exception)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Malformed physical archive-reference identity.");
            if (physicalId <= 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Malformed physical archive-reference identity.");
            auto root = repository.fileReference(physicalId);
            if (root.id == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Unknown physical archive container reference.");
            auto currentBlobId = root.blobId;
            foreach (component; components[1 .. $])
            {
                long entryId;
                try
                    entryId = to!long(component);
                catch (Exception)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidIdentifier,
                        "Malformed nested archive entry identity.");
                auto entry = repository.archiveEntry(entryId);
                if (entry.id == 0 || entry.containerBlobId != currentBlobId
                    || entry.contentBlobId <= 0)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidIdentifier,
                        "Archive member is not a resolvable nested container.");
                currentBlobId = entry.contentBlobId;
            }
            return ArchiveContainerSource(currentBlobId, root.directoryId,
                root.present ? CatalogReferenceAvailability.available
                    : CatalogReferenceAvailability.unavailable, identity);
        }

        throw new CatalogBackendException(CatalogBackendErrorCode.invalidIdentifier,
            "Reference is not an archive container.");
    }

    /** Resolve a root-relative directory path to its identity.
     *
     * Params:
     *     relativePath = Normalized path; empty or "." denotes the root.
     * Returns: The matching identity, or an invalid ID when unresolved.
     * Throws: `CatalogBackendException` with `closed` or `backendFailure`.
     */
    override DirectoryId resolveDirectory(string relativePath)
    {
        return withRepository((Repository repository) {
            if (relativePath.length == 0 || relativePath == ".")
                return DirectoryId.init;
            const auto id = repository.directoryIdByRelativePath(relativePath);
            return id == 0 ? DirectoryId.init : directoryId(id);
        });
    }

    /** Resolve a root-relative reference or virtual member path.
     *
     * Params:
     *     relativePath = Normalized reference path.
     * Returns: The matching identity, or an invalid ID when unresolved.
     * Throws: `CatalogBackendException` with `closed` or `backendFailure`.
     */
    override ReferenceId resolveReference(string relativePath)
    {
        return withRepository((Repository repository) {
            auto file = repository.fileReferenceByRelativePath(relativePath);
            return file.id == 0 ? ReferenceId.init : catalogFile(file).referenceId;
        });
    }

    /** Load one reference row by typed identity.
     *
     * Params:
     *     referenceId = Reference identity issued by this backend.
     * Returns: The matching detached reference row.
     * Throws: `CatalogBackendException` with `invalidIdentifier` for an
     *     unknown or foreign identity, or `closed`/`backendFailure`.
     */
    override CatalogFile loadReference(ReferenceId referenceId)
    {
        return withRepository((Repository repository) {
            return catalogFileForReference(repository, referenceId);
        });
    }

    /** Extract one archive member through the process-wide leased cache.
     *
     * The container chain is walked to the physical archive, stored passwords
     * are attached to each extraction step, and cancellation is forwarded.
     *
     * Params:
     *     memberReferenceId = Reference identity of an available archive member.
     *     cancellation = Optional cooperative cancellation flag.
     * Returns: A lease the caller must release.
     * Throws: `CatalogBackendException` with `invalidIdentifier` for a
     *     non-member or unavailable container, `cancelled` when extraction is
     *     cancelled, or `closed`/`backendFailure`.
     */
    override MemberContentLease acquireMemberContent(
        ReferenceId memberReferenceId, shared(bool)* cancellation = null)
    {
        return withRepository((Repository repository) {
            auto member = catalogFileForReference(repository, memberReferenceId);
            if (member.locator.kind != ContentLocator.Kind.archiveEntry)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Reference is not an SQLite archive member.");
            if (member.availability != CatalogReferenceAvailability.available)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "The archive container is not available on disk.");
            auto file = repository.fileReference(
                referenceFileId(memberReferenceId));
            ArchiveExtractionStep[] steps;
            string physicalContainer;
            while (true)
            {
                auto container = repository.fileReference(
                    file.containerReferenceId);
                if (container.id == 0)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidIdentifier,
                        "The archive container chain is incomplete.");
                const auto parsed = parseArchiveVirtualPath(file.relativePath);
                if (!parsed.isVirtual)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidIdentifier,
                        "Archive member path is not a virtual reference.");
                const auto layer = parsed.entries[$ - 1];
                const auto row = catalogFile(file);
                ArchiveExtractionStep step;
                step.memberPath = layer.relativePath;
                step.occurrence = layer.hasOccurrence ? layer.occurrence : 0;
                step.locator = row.locator;
                step.password = repository.loadBlobDetails(
                    container.blobId).archivePassword;
                step.knownSize = row.size;
                steps = step ~ steps;
                if (!container.archiveMember)
                {
                    physicalContainer = parseArchiveVirtualPath(
                        container.relativePath).physicalPath;
                    break;
                }
                file = container;
            }
            try
                return extractArchiveMember(repository.rootPath,
                    physicalContainer, steps, cancellation);
            catch (MemberContentCancelledException failure)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.cancelled, failure.msg);
        });
    }

    /** Extract the repository file id embedded in a reference identity.
     *
     * Archive-member identities encode the referenced row id after the last
     * colon; their negative value distinguishes them from physical references.
     *
     * Params:
     *     referenceId = Physical or archive-member reference identity.
     * Returns: The positive physical file id, or the negated member id for
     *     archive-member identities.
     * Throws: `CatalogBackendException` with `invalidIdentifier` for a foreign
     *     or malformed identity.
     */
    long referenceFileId(ReferenceId referenceId) const
    {
        const auto token = referenceId.adapterToken;
        const auto physicalPrefix = sourceToken ~ ":reference:";
        if (token.startsWith(physicalPrefix))
            return parseIdentity(token, "reference");
        const auto archivePrefix = sourceToken ~ ":archive-reference:";
        if (!token.startsWith(archivePrefix))
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Identifier belongs to a different SQLite catalog source.");
        const auto identity = token[archivePrefix.length .. $];
        const auto components = identity.split(":");
        if (components.length < 2)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Malformed archive-member reference identity.");
        long fileId;
        try
            fileId = to!long(components[$ - 1]);
        catch (Exception)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Malformed archive-member reference identity.");
        if (fileId <= 0)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Malformed archive-member reference identity.");
        return fileId;
    }

    /** Load and validate the file row behind a reference identity.
     *
     * Params:
     *     repository = Open repository used for lookups.
     *     referenceId = Reference identity issued by this backend.
     * Returns: The detached reference row.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when the row
     *     is missing or its stored path no longer matches the identity.
     */
    CatalogFile catalogFileForReference(Repository repository,
        ReferenceId referenceId) const
    {
        auto file = repository.fileReference(referenceFileId(referenceId));
        if (file.id == 0)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Unknown SQLite reference identity.");
        auto result = catalogFile(file);
        if (result.referenceId != referenceId)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Reference identity does not match its stored path.");
        return result;
    }

    /** Page through torrent manifest descriptors for one content record.
     *
     * Params:
     *     contentId = Content identity of an indexed torrent.
     *     page = Requested limit and optional continuation cursor.
     * Returns: The bounded torrent-entry page.
     * Throws: `CatalogBackendException` with `invalidIdentifier`,
     *     `invalidCursor`, `closed`, or `backendFailure`.
     */
    override CatalogTorrentEntryPage listTorrentEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        return withRepository((Repository repository) {
            validatePageRequest(page);
            const auto blobId = parseIdentity(contentId.adapterToken, "content");
            requireKnownContent(repository, blobId);
            const auto queryToken = detailQueryToken(repository, "torrent", blobId);
            const auto offset = cursorOffset(page, queryToken);
            RepositoryTorrentQuery query;
            query.blobId = blobId;
            query.offset = offset;
            query.limit = page.limit + 1;
            auto rows = repository.listTorrentFiles(query);
            if (rows.length == 0 && offset > 0)
            {
                query.offset = offset - 1;
                query.limit = 1;
                if (repository.listTorrentFiles(query).length == 0)
                    throw invalidCursor("Torrent entry cursor is outside the result sequence.");
            }
            CatalogTorrentEntryPage result;
            const auto count = rows.length < page.limit ? rows.length : page.limit;
            foreach (row; rows[0 .. count])
                result.entries ~= CatalogTorrentManifestEntry(
                    row.relativePath.split("/"), row.size);
            result.hasMore = rows.length > page.limit;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(offset + count,
                    page.limit, queryToken);
            return result;
        });
    }

    /** Page through repository-style blob query results.
     *
     * Params:
     *     options = Query offsets, limits, filters, and sort options.
     * Returns: The repository blob page with ids and flags.
     * Throws: `CatalogBackendException` with `closed` or `backendFailure`.
     */
    override RepositoryBlobPage queryBlobs(RepositoryQueryOptions options)
    {
        return withRepository((Repository repository) {
            return repository.loadCatalogQueryPageWithIds(options);
        });
    }

    /** Return duplicate groups without mutating the source.
     *
     * Params:
     *     limit = Maximum groups requested; must be greater than zero.
     * Returns: The repository's duplicate groups.
     * Throws: `CatalogBackendException` with `invalidIdentifier` for a zero
     *     limit, or `closed`/`backendFailure`.
     */
    override RepositoryDuplicateGroup[] queryDuplicateGroups(size_t limit = 100)
    {
        return withRepository((Repository repository) {
            enforce(limit > 0, new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Duplicate query limit must be greater than zero."));
            return repository.queryDuplicates(limit);
        });
    }

    /** Export a filtered subset without cooperative cancellation.
     *
     * Params:
     *     query = Selected path prefix and filters.
     *     options = Output format, destination, and detail flags.
     * Returns: Counts and publication state of the export.
     * Throws: `CatalogBackendException` on unsupported formats, missing
     *     output paths, or backend failures.
     */
    override CatalogExportResult exportSubset(CatalogSubsetQuery query,
        CatalogExportOptions options)
    {
        return exportSubsetControlled(query, options, null, 0);
    }

    /** Export a filtered relationship-closed subset with cancellation.
     *
     * Only JSON version 5 output is supported. Cancellation is checked at
     * selection, load, and publication checkpoints; a cancelled export leaves
     * `committed` false and publishes no file.
     *
     * Params:
     *     query = Selected path prefix and filters.
     *     options = Output format, destination, and detail flags.
     *     control = Cooperative control used for progress and cancellation.
     *     operationId = Identifier reported with progress events.
     * Returns: Counts and publication state; `committed` is true only after
     *     the output file was published.
     * Throws: `CatalogBackendException` with `unsupportedFeature`,
     *     `invalidTarget`, or `backendFailure`.
     */
    override CatalogExportResult exportSubsetControlled(CatalogSubsetQuery query,
        CatalogExportOptions options, OperationControl control,
        ulong operationId)
    {
        return withRepository((Repository repository) {
            if (options.format != CatalogExportFormat.jsonV5)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedFeature,
                    "SQLite subset exports use JSON version 5.");
            enforce(options.outputPath.length > 0, new CatalogBackendException(
                CatalogBackendErrorCode.invalidTarget,
                "A subset export requires an explicit output path."));
            if (query.pathPrefix.length > 0)
                ContentLocator.file(query.pathPrefix);

            CatalogExportResult result;
            result.referencesExported = 0;
            bool cancelled;
            void checkCancelled()
            {
                if (control !is null && control.cancellationRequested)
                    cancelled = true;
            }
            void reportProgress(size_t completed, size_t total, string message)
            {
                if (control is null)
                    return;
                OperationProgress progress;
                progress.operationId = operationId;
                progress.operation = OperationKind.catalogExport;
                progress.state = OperationState.running;
                progress.phase = OperationPhase.jsonWrite;
                progress.completed = completed;
                progress.total = total;
                progress.totalKnown = true;
                progress.message = message;
                control.report(progress);
            }
            reportProgress(0, 0, "Selecting export content.");
            checkCancelled();
            if (cancelled)
                return result;

            RepositoryFile[][long] selectedReferences;
            long[] selectedBlobIds;
            bool[long][long] selectedReferenceIds;
            RepositoryFile[] archiveContainersToExpand;
            bool[long] expandedArchiveContainers;
            bool selectedMemberReference;
            void addReference(RepositoryFile reference)
            {
                checkCancelled();
                if (cancelled)
                    return;
                if (reference.blobId !in selectedReferences)
                    selectedBlobIds ~= reference.blobId;
                if (auto selectedIds = reference.blobId in selectedReferenceIds)
                    if (reference.id in *selectedIds)
                        return;
                selectedReferenceIds[reference.blobId][reference.id] = true;
                selectedReferences[reference.blobId] ~= reference;
            }
            void addArchiveContainer(RepositoryFile container)
            {
                if (container.hasArchive && container.id > 0
                    && container.id !in expandedArchiveContainers)
                {
                    expandedArchiveContainers[container.id] = true;
                    archiveContainersToExpand ~= container;
                }
            }
            void retainArchiveMemberChain(RepositoryFile member)
            {
                const auto rootReferenceId = archiveRootReferenceId(
                    member.archiveContainerIdentity);
                auto rootContainer = repository.fileReference(rootReferenceId);
                if (rootContainer.id == 0)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.backendFailure,
                        "An archive member's physical root disappeared during export.");
                addReference(rootContainer);
                auto identities = member.archiveContainerIdentity.split(":");
                auto currentBlobId = rootContainer.blobId;
                foreach (component; identities[1 .. $])
                {
                    const auto entryId = to!long(component);
                    auto ancestorEntry = repository.archiveEntry(entryId);
                    if (ancestorEntry.id == 0
                        || ancestorEntry.containerBlobId != currentBlobId
                        || ancestorEntry.contentBlobId <= 0)
                        throw new CatalogBackendException(
                            CatalogBackendErrorCode.backendFailure,
                            "An archive member's parent entry disappeared during export.");
                    auto parentReference = repository.fileReference(entryId);
                    if (parentReference.id == 0)
                        throw new CatalogBackendException(
                            CatalogBackendErrorCode.backendFailure,
                            "An archive member's parent reference disappeared during export.");
                    addReference(parentReference);
                    addArchiveContainer(parentReference);
                    currentBlobId = ancestorEntry.contentBlobId;
                }
                if (currentBlobId != member.archiveContainerBlobId)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.backendFailure,
                        "Archive member container identity does not match its SQL row.");
                addReference(member);
                addArchiveContainer(member);
                selectedMemberReference = true;
            }

            walkMatchingFiles(repository, query.filter, query.pathPrefix,
                (RepositoryFile file) {
                    if (!file.archiveMember)
                    {
                        addReference(file);
                        if (file.hasArchive)
                            addArchiveContainer(file);
                    }
                    else
                        retainArchiveMemberChain(file);
                });
            checkCancelled();
            if (cancelled)
                return result;
            if (selectedMemberReference
                && (!options.includeContentDetails || !options.includeArchiveEntries))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedFeature,
                    "Archive-member subset export requires archive content details.");

            if (options.includeContentDetails && options.includeArchiveEntries)
                foreach (container; archiveContainersToExpand)
                {
                    checkCancelled();
                    if (cancelled)
                        return result;
                    RepositoryFileQuery memberQuery;
                    memberQuery.directoryId = container.directoryId;
                    memberQuery.includeArchiveMembers = true;
                    memberQuery.limit = size_t.max;
                    memberQuery.caseSensitive = true;
                    const auto memberPrefix = container.relativePath
                        ~ archivePathSeparator();
                    memberQuery.text = memberPrefix;
                    foreach (member; repository.listFiles(memberQuery))
                        if (member.archiveMember
                            && member.relativePath.startsWith(memberPrefix))
                        {
                            addReference(member);
                            addArchiveContainer(member);
                        }
                }

            NamedBinaryBlob[] exportedBlobs;
            const auto exportTotal = selectedBlobIds.length;
            size_t processed;
            foreach (blobId; selectedBlobIds)
            {
                checkCancelled();
                if (cancelled)
                    return result;
                JsonExportOptions loadOptions;
                loadOptions.absolutePaths = false;
                loadOptions.includeDetails = options.includeContentDetails;
                loadOptions.includeArchiveEntries = options.includeArchiveEntries;
                loadOptions.includeTorrentFiles = options.includeTorrentEntries;
                auto blob = repository.loadBlobDetails(blobId, loadOptions);
                if (blob is null)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.backendFailure,
                        "A selected SQLite reference has no content record.");
                blob.fileSpecs = [];
                foreach (reference; selectedReferences[blobId])
                    blob.fileSpecs ~= new FileSpec(reference.relativePath,
                        reference.modifiedAt);
                result.referencesExported += blob.fileSpecs.length;
                if (!options.includeContentDetails)
                {
                    blob.checkSums = CheckSums.init;
                    blob.fileType = "";
                    blob.mediaInfoSig = null;
                    blob.archiveSpecs = null;
                    blob.archiveIndexKnown = false;
                    blob.archiveIndexDeep = false;
                    blob.archivePassword = "";
                    blob.torrentInfo = null;
                }
                else if (!options.includeArchiveEntries)
                {
                    blob.archiveSpecs = null;
                    blob.archiveIndexKnown = false;
                    blob.archiveIndexDeep = false;
                }
                exportedBlobs ~= blob;
                if (control !is null && ++processed % 512 == 0)
                    reportProgress(processed, exportTotal,
                        "Writing JSON catalog.");
            }

            reportProgress(exportTotal, exportTotal, "Writing JSON catalog.");
            checkCancelled();
            if (cancelled)
                return result;
            auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
                exportedBlobs);
            const bool committed = commitJsonCatalog(options.outputPath, catalog,
                () {
                    reportProgress(exportTotal, exportTotal,
                        "Writing JSON catalog.");
                    return control !is null && control.cancellationRequested;
                }, options.prettyJson);
            if (!committed)
            {
                if (control !is null && control.cancellationRequested)
                    return result;
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.backendFailure,
                    "Could not publish the SQLite subset export.");
            }
            result.contentsExported = exportedBlobs.length;
            result.outputPath = canonicalPath(options.outputPath);
            result.committed = true;
            return result;
        });
    }

    /** Import a JSON catalog into the bound repository source.
     *
     * Params:
     *     jsonPath = Path of the JSON catalog to import.
     *     options = Import options controlling merge behavior.
     * Throws: `CatalogBackendException` with `closed`, `invalidIdentifier`, or
     *     `backendFailure`.
     */
    override void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init)
    {
        importJsonControlled(jsonPath, options, null, 0);
    }

    /** Import a JSON catalog with cooperative cancellation.
     *
     * Params:
     *     jsonPath = Path of the JSON catalog to import.
     *     options = Import options controlling merge behavior.
     *     control = Cooperative control used for progress and cancellation.
     *     operationId = Identifier reported with progress events.
     * Returns: `true` when the import committed, or `false` when it was
     *     cancelled before commit.
     * Throws: `CatalogBackendException` with `closed`, `invalidIdentifier`, or
     *     `backendFailure`.
     */
    override bool importJsonControlled(string jsonPath, JsonImportOptions options,
        OperationControl control, ulong operationId)
    {
        return withRepository((Repository repository) {
            return repository.importJsonControlled(jsonPath, options, control,
                operationId);
        });
    }

    /** Run a scan synchronously when its target matches this source.
     *
     * Params:
     *     request = Scan request including target and scan options.
     *     control = Cooperative operation control handle.
     * Returns: The operation result.
     * Throws: `CatalogBackendException` with `closed` or `invalidTarget`.
     */
    override OperationResult runOperation(ScanOperationRequest request,
        OperationControl control)
    {
        requireMatchingTarget(request.target);
        return dosierskanilo.operationrunner.runOperation(request, control);
    }

    /** Run metadata extraction synchronously when its target matches.
     *
     * Params:
     *     request = Metadata request including target and options.
     *     control = Cooperative operation control handle.
     * Returns: The operation result.
     * Throws: `CatalogBackendException` with `closed` or `invalidTarget`.
     */
    override OperationResult runOperation(MetadataOperationRequest request,
        OperationControl control)
    {
        requireMatchingTarget(request.target);
        return dosierskanilo.operationrunner.runOperation(request, control);
    }

    /** Run analysis synchronously when its target matches this source.
     *
     * Params:
     *     request = Analysis request including target and options.
     *     control = Cooperative operation control handle.
     * Returns: The operation result.
     * Throws: `CatalogBackendException` with `closed` or `invalidTarget`.
     */
    override OperationResult runOperation(AnalysisOperationRequest request,
        OperationControl control)
    {
        requireMatchingTarget(request.target);
        return dosierskanilo.operationrunner.runOperation(request, control);
    }

    /** Release the cached repository connection; repeated calls are harmless. */
    override void close()
    {
        if (closed)
            return;
        closed = true;
        if (cachedRepository !is null)
        {
            cachedRepository.close();
            cachedRepository = null;
        }
    }

private:
    /** Reject calls made after this backend was closed.
     *
     * Throws: `CatalogBackendException` with `closed` when already closed.
     */
    void requireOpen() const
    {
        if (closed)
            throw new CatalogBackendException(CatalogBackendErrorCode.closed,
                "SQLite catalog backend is closed.");
    }

    /** Require an operation target that names this repository.
     *
     * Params:
     *     request = Target supplied by the operation request.
     * Throws: `CatalogBackendException` with `closed` or `invalidTarget` when
     *     the shape or canonical root differs from the opened repository.
     */
    void requireMatchingTarget(OperationTarget request) const
    {
        requireOpen();
        if (request.mode != OperationStorageMode.repository
            || request.repositoryRoot.length == 0 || request.catalogPath.length > 0
            || request.filesystemRoot.length > 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "Operation target does not match the opened SQLite repository.");
        string root;
        try
            root = Repository.findRoot(request.repositoryRoot);
        catch (Exception)
        {
        }
        if (root.length == 0 || canonicalPath(root) != backendTarget.repositoryRoot)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidTarget,
                "Operation target does not match the opened SQLite repository.");
    }

    /** Run an action against the lazily opened, reused repository connection.
     *
     * The call is synchronized on this backend and rethrows typed backend
     * failures unchanged; other exceptions become `backendFailure`.
     *
     * Params:
     *     action = Callable receiving the open repository.
     * Returns: The action's return value.
     * Throws: `CatalogBackendException` with `closed` or `backendFailure`.
     */
    auto withRepository(F)(F action)
    {
        requireOpen();
        /* Reuse one read connection for the backend lifetime; paging through a
         * large catalog no longer reopens the database per page. */
        synchronized (this)
        {
            try
            {
                if (cachedRepository is null)
                    cachedRepository = Repository.open(
                        backendTarget.repositoryRoot);
                return action(cachedRepository);
            }
            catch (CatalogBackendException failure)
                throw failure;
            catch (Exception failure)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.backendFailure,
                    "SQLite catalog query failed: " ~ failure.msg);
        }
    }

    /** Return an absolute normalized form of `path`.
     *
     * Params:
     *     path = Path to make absolute and normalize.
     * Returns: The absolute normalized path.
     */
    string canonicalPath(string path) const
    {
        return buildNormalizedPath(absolutePath(path));
    }

    /** Return the repository's last-update stamp used to bind cursors.
     *
     * Params:
     *     repository = Open repository to inspect.
     * Returns: The repository update timestamp.
     */
    string sourceVersion(Repository repository) const
    {
        return repository.info().updatedAt;
    }

    /** Build a source-scoped identity token for a positive database id.
     *
     * Params:
     *     kind = Identity kind (`content`, `directory`, or `reference`).
     *     id = Positive database row id.
     * Returns: The opaque identity token.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when `id` is
     *     not positive.
     */
    string identityToken(string kind, long id) const
    {
        enforce(id > 0, new CatalogBackendException(
            CatalogBackendErrorCode.invalidIdentifier,
            "SQLite catalog identity must be positive."));
        return sourceToken ~ ":" ~ kind ~ ":" ~ id.to!string;
    }

    /** Parse a positive database id from a source-scoped identity token.
     *
     * Params:
     *     token = Opaque identity token.
     *     kind = Expected identity kind.
     * Returns: The decoded positive row id.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when the
     *     token has another source/kind or is malformed.
     */
    long parseIdentity(string token, string kind) const
    {
        const auto prefix = sourceToken ~ ":" ~ kind ~ ":";
        if (!token.startsWith(prefix))
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Identifier belongs to a different SQLite catalog source.");
        try
        {
            auto id = to!long(token[prefix.length .. $]);
            if (id > 0)
                return id;
        }
        catch (Exception)
        {
        }
        throw new CatalogBackendException(CatalogBackendErrorCode.invalidIdentifier,
            "Malformed SQLite catalog identifier.");
    }

    /** Require that a content blob exists in the repository.
     *
     * Params:
     *     repository = Open repository to inspect.
     *     blobId = Content blob id.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when the
     *     fingerprint lookup returns nothing.
     */
    void requireKnownContent(Repository repository, long blobId) const
    {
        if (repository.loadBlobFingerprint(blobId) is null)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Unknown SQLite content identity.");
    }

    /** Wrap a positive content blob id as a source-scoped content identity.
     *
     * Params:
     *     id = Positive content blob id.
     * Returns: The source-scoped content identity.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when `id` is
     *     not positive.
     */
    ContentId contentId(long id) const
    {
        return ContentId(identityToken("content", id));
    }

    /** Wrap a positive directory row id as a source-scoped directory identity.
     *
     * Params:
     *     id = Positive directory row id.
     * Returns: The source-scoped directory identity.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when `id` is
     *     not positive.
     */
    DirectoryId directoryId(long id) const
    {
        return DirectoryId(identityToken("directory", id));
    }

    /** Decode a directory identity to its database row id.
     *
     * Params:
     *     id = Directory identity.
     * Returns: The row id, or zero for an invalid identity.
     * Throws: `CatalogBackendException` with `invalidIdentifier` for a foreign
     *     or malformed token.
     */
    long directoryDatabaseId(DirectoryId id) const
    {
        return id.isValid ? parseIdentity(id.adapterToken, "directory") : 0;
    }

    /** Project one repository file row into the storage-neutral file model.
     *
     * Archive members receive archive-entry identities and locators; physical
     * rows receive file identities and root-relative physical locators.
     *
     * Params:
     *     file = Repository file row to convert.
     * Returns: The detached catalog file row.
     * Throws: `CatalogBackendException` with `backendFailure` when a physical
     *     row contains an invalid relative path.
     */
    CatalogFile catalogFile(RepositoryFile file) const
    {
        CatalogFile result;
        if (file.archiveMember)
        {
            const auto containerReferenceId = archiveContainerReference(
                file.archiveContainerIdentity);
            result.referenceId = archiveMemberReferenceId(
                file.archiveContainerIdentity, file.archiveEntryId);
            result.locator = ContentLocator.entry(
                containerReferenceId,
                ArchiveEntryId(archiveEntryToken(file.archiveContainerBlobId,
                    file.archiveEntryId)));
        }
        else
        {
            result.referenceId = ReferenceId(identityToken("reference", file.id));
            try
                result.locator = ContentLocator.file(
                    parseArchiveVirtualPath(file.relativePath).physicalPath);
            catch (CatalogBackendException failure)
                throw new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                    "Repository contains an invalid relative path: " ~ failure.msg);
        }
        result.contentId = contentId(file.blobId);
        if (file.directoryId > 0)
            result.directoryId = directoryId(file.directoryId);
        result.name = file.name;
        result.relativePath = file.relativePath;
        result.size = file.size;
        result.modifiedAt = file.modifiedAt;
        result.availability = file.present ? CatalogReferenceAvailability.available
            : CatalogReferenceAvailability.unavailable;
        result.hasFileType = file.hasFileType;
        result.hasMedia = file.hasMedia;
        result.hasVideo = file.hasVideo;
        result.hasAudio = file.hasAudio;
        result.hasImage = file.hasImage;
        result.hasText = file.hasText;
        result.hasArchive = file.hasArchive;
        result.hasTorrent = file.hasTorrent;
        return result;
    }

    /** Build a masked content snapshot from a fully loaded blob.
     *
     * Params:
     *     blob = Fully loaded blob details.
     *     id = Content identity to store in the snapshot.
     *     details = Detail families to include.
     * Returns: The content snapshot with extractor statuses.
     */
    CatalogContentSnapshot snapshotFor(NamedBinaryBlob blob, ContentId id,
        CatalogDetailMask details) const
    {
        CatalogContentSnapshot result;
        result.id = id;
        if (details.fingerprint)
            result.fingerprint = fingerprintFor(blob.fileSize, blob.checkSums);
        if (details.fileType)
            result.fileType = blob.fileType;
        if (details.media)
            result.mediaStreams = mediaStreamsFor(blob);
        if (details.archiveSummary)
        {
            result.hasArchive = blob.archiveIndexKnown
                || blob.archiveSpecs !is null;
            result.archiveSummary.indexKnown = result.hasArchive;
        }
        if (details.torrentSummary && blob.torrentInfo !is null)
        {
            result.hasTorrent = true;
            result.torrentSummary.name = blob.torrentInfo.name;
            result.torrentSummary.magnetUri = blob.torrentInfo.magnetURI;
            result.torrentSummary.totalSize = blob.torrentInfo.totalSize;
            result.torrentSummary.isMultiFile = blob.torrentInfo.isMultiFile;
            result.torrentSummary.infoHashHex = blob.torrentInfo.infoHashHex;
            result.torrentSummary.announce = blob.torrentInfo.announce;
            result.torrentSummary.pieceLength = blob.torrentInfo.pieceLength;
            result.torrentSummary.piecesCount = blob.torrentInfo.piecesCount;
            result.torrentSummary.fileListAvailable = blob.torrentInfo.files !is null;
        }

        CatalogExtractorStatus checksumStatus;
        checksumStatus.extractor = "checksums";
        checksumStatus.state = blob.checkSums.hasDigests
            ? (fingerprintFor(blob.fileSize, blob.checkSums).complete
                ? CatalogExtractorState.completed : CatalogExtractorState.failed)
            : CatalogExtractorState.notRequested;
        result.extractors ~= checksumStatus;
        CatalogExtractorStatus fileTypeStatus;
        fileTypeStatus.extractor = "fileType";
        fileTypeStatus.state = blob.fileType.length > 0
            ? CatalogExtractorState.completed : CatalogExtractorState.notRequested;
        result.extractors ~= fileTypeStatus;
        CatalogExtractorStatus mediaStatus;
        mediaStatus.extractor = "mediaInfo";
        mediaStatus.state = blob.mediaInfoSig is null
            ? CatalogExtractorState.notRequested
            : (blob.mediaInfoSig.empty ? CatalogExtractorState.empty
                : CatalogExtractorState.completed);
        result.extractors ~= mediaStatus;
        CatalogExtractorStatus archiveStatus;
        archiveStatus.extractor = "archives";
        if (!blob.archiveIndexKnown && blob.archiveSpecs is null)
            archiveStatus.state = CatalogExtractorState.notRequested;
        else if (blob.archiveSpecs !is null && blob.archiveSpecs.length > 0)
            archiveStatus.state = CatalogExtractorState.completed;
        else
            archiveStatus.state = CatalogExtractorState.empty;
        result.extractors ~= archiveStatus;
        CatalogExtractorStatus torrentStatus;
        torrentStatus.extractor = "torrents";
        torrentStatus.state = blob.torrentInfo is null
            ? CatalogExtractorState.notRequested : CatalogExtractorState.completed;
        result.extractors ~= torrentStatus;
        return result;
    }

    /** Build known digests and completeness state from repository checksums.
     *
     * Only digests with the expected MD5/SHA-1/XXH64 lengths contribute to a
     * complete fingerprint.
     *
     * Params:
     *     size = Content length in bytes.
     *     checksums = Stored checksums for the content.
     * Returns: The fingerprint with available digests.
     */
    CatalogContentFingerprint fingerprintFor(size_t size,
        CheckSums checksums) const
    {
        CatalogContentFingerprint result;
        result.size = size;
        bool valid = true;
        try
        {
            auto md5 = checksums.get_md5sum;
            auto sha1 = checksums.get_sha1sum;
            auto xxh64 = checksums.get_xxh64;
            if (md5.length > 0)
                result.digests ~= CatalogDigest("md5", md5.dup);
            if (sha1.length > 0)
                result.digests ~= CatalogDigest("sha1", sha1.dup);
            if (xxh64.length > 0)
                result.digests ~= CatalogDigest("xxh64", xxh64.dup);
            valid = md5.length == 16 && sha1.length == 20 && xxh64.length == 8;
        }
        catch (Exception)
            valid = false;
        result.complete = checksums.hasDigests && valid;
        return result;
    }

    /** Convert stored media info into the storage-neutral stream list.
     *
     * Params:
     *     blob = Blob whose media signature is converted.
     * Returns: Image, video, audio, and text streams; empty when no media info
     *     is stored.
     */
    CatalogMediaStream[] mediaStreamsFor(NamedBinaryBlob blob) const
    {
        CatalogMediaStream[] result;
        if (blob.mediaInfoSig is null)
            return result;
        foreach (stream; blob.mediaInfoSig.imageStreams)
        {
            CatalogMediaStream item;
            item.kind = CatalogMediaKind.image;
            item.index = stream.index;
            item.format = stream.format;
            item.width = stream.width;
            item.height = stream.height;
            result ~= item;
        }
        foreach (stream; blob.mediaInfoSig.videoStreams)
        {
            CatalogMediaStream item;
            item.kind = CatalogMediaKind.video;
            item.index = stream.index;
            item.language = stream.language;
            item.format = stream.format;
            item.width = stream.width;
            item.height = stream.height;
            item.frameRate = stream.frameRate;
            item.bitRate = stream.bitRate;
            item.duration = stream.duration;
            result ~= item;
        }
        foreach (stream; blob.mediaInfoSig.audioStreams)
        {
            CatalogMediaStream item;
            item.kind = CatalogMediaKind.audio;
            item.index = stream.index;
            item.language = stream.language;
            item.format = stream.format;
            item.channels = cast(uint) stream.channels;
            item.bitRate = stream.bitRate;
            item.duration = stream.duration;
            result ~= item;
        }
        foreach (stream; blob.mediaInfoSig.textStreams)
        {
            CatalogMediaStream item;
            item.kind = CatalogMediaKind.text;
            item.index = stream.index;
            item.language = stream.language;
            item.format = stream.format;
            item.frameRate = stream.frameRate;
            item.bitRate = stream.bitRate;
            item.duration = stream.duration;
            result ~= item;
        }
        return result;
    }

    /** Fill archive entry counts and extractor state into a snapshot.
     *
     * Params:
     *     repository = Open repository to query.
     *     blobId = Content blob id whose archive index is counted.
     *     indexKnown = Whether the caller already knows an index exists.
     *     snapshot = Snapshot updated in place, including its archive extractor
     *         status.
     * Throws: `CatalogBackendException` with `backendFailure` when a page
     *     query fails.
     */
    void populateArchiveSummary(Repository repository, long blobId,
        bool indexKnown, ref CatalogContentSnapshot snapshot) const
    {
        snapshot.archiveSummary.indexKnown = indexKnown;
        snapshot.hasArchive = indexKnown;
        size_t offset;
        while (true)
        {
            RepositoryArchiveQuery query;
            query.blobId = blobId;
            query.offset = offset;
            query.limit = catalogPageSize;
            auto entries = repository.listArchiveEntries(query);
            if (entries.length == 0)
                break;
            snapshot.archiveSummary.indexKnown = true;
            snapshot.hasArchive = true;
            snapshot.archiveSummary.entryCount += entries.length;
            foreach (entry; entries)
                if (fingerprintFor(entry.size, entry.checkSums).complete)
                    ++snapshot.archiveSummary.entriesWithCompleteFingerprints;
            offset += entries.length;
            if (entries.length < catalogPageSize)
                break;
        }
        foreach (ref status; snapshot.extractors)
            if (status.extractor == "archives")
                status.state = !snapshot.archiveSummary.indexKnown
                    ? CatalogExtractorState.notRequested
                    : (snapshot.archiveSummary.entryCount == 0
                        ? CatalogExtractorState.empty
                        : CatalogExtractorState.completed);
    }

    /** Load one forward file page from a keyset cursor or the first page.
     *
     * Params:
     *     repository = Open repository to query.
     *     query = Directory scope, filters, and sort order.
     *     limit = Maximum rows to return; must be greater than zero.
     *     pivot = Keyset position to start after.
     *     hasPivot = Whether `pivot` should be used.
     *     queryToken = Cursor binding token stored in emitted cursors.
     * Returns: The requested file page with continuation state.
     * Throws: `CatalogBackendException` with `invalidCursor` for a zero limit.
     */
    CatalogFilePage loadForwardFilePage(Repository repository,
        CatalogFileQuery query, size_t limit, RepositoryFileCursor pivot,
        bool hasPivot, string queryToken) const
    {
        if (limit == 0)
            throw invalidCursor("Catalog page limit must be greater than zero.");
        auto request = repositoryFileQuery(query);
        request.limit = limit;
        RepositoryFilePage sourcePage;
        if (hasPivot)
            sourcePage = repository.nextFilesPage(request, pivot);
        else
            sourcePage = repository.listFilesPage(request);

        CatalogFilePage result;
        foreach (file; sourcePage.files)
            result.files ~= catalogFile(file);
        result.hasMore = sourcePage.hasMore;
        result.hasPrevious = hasPivot && result.files.length > 0;
        if (result.hasMore && result.files.length > 0)
            result.nextCursor = filePageCursor(queryToken,
                result.files[$ - 1], limit);
        if (result.hasPrevious && result.files.length > 0)
            result.previousCursor = filePageCursor(queryToken,
                result.files[0], limit);
        return result;
    }

    /** Build a keyset file cursor encoded as an opaque catalog cursor.
     *
     * Params:
     *     queryToken = Binding token for the source/query/sort.
     *     pivot = Row the cursor is anchored at.
     *     limit = Page size the cursor is bound to.
     * Returns: An opaque cursor whose index field is zero.
     */
    CatalogPageCursor filePageCursor(string queryToken, CatalogFile pivot,
        size_t limit) const
    {
        const auto id = repositoryFileCursorId(pivot.referenceId);
        const auto path64 = Base64.encode(cast(const(ubyte)[]) pivot.relativePath);
        auto token = cast(string) (queryToken ~ "\0cursor\0" ~ id.to!string
            ~ "\0" ~ pivot.size.to!string ~ "\0" ~ path64);
        return CatalogPageCursor(cast(size_t) 0, limit, token);
    }

    /** Decode the repository row id encoded in a file cursor position.
     *
     * Physical references yield their positive row id; archive-member
     * references yield the negated member id.
     *
     * Params:
     *     referenceId = Reference identity anchored by the cursor.
     * Returns: The positive physical id or negated archive-member id.
     * Throws: `CatalogBackendException` with `invalidIdentifier` for a
     *     malformed or foreign identity.
     */
    long repositoryFileCursorId(ReferenceId referenceId) const
    {
        const auto archivePrefix = sourceToken ~ ":archive-reference:";
        if (referenceId.adapterToken.startsWith(archivePrefix))
        {
            const auto identity = referenceId.adapterToken[archivePrefix.length .. $];
            size_t separator = size_t.max;
            foreach_reverse (index, character; identity)
                if (character == ':')
                {
                    separator = index;
                    break;
                }
            if (separator != size_t.max && separator + 1 < identity.length)
            {
                try
                {
                    const auto parentToken = identity[0 .. separator];
                    auto entryId = to!long(identity[separator + 1 .. $]);
                    auto parentParts = parentToken.split(":");
                    bool validParent = parentParts.length > 0
                        && parentParts[0].startsWith("p")
                        && to!long(parentParts[0][1 .. $]) > 0;
                    if (validParent && parentParts.length > 1)
                        foreach (part; parentParts[1 .. $])
                            validParent = validParent && to!long(part) > 0;
                    if (validParent && entryId > 0)
                        return -entryId;
                }
                catch (Exception)
                {
                }
            }
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Malformed archive-member reference identity.");
        }
        return parseIdentity(referenceId.adapterToken, "reference");
    }

    /** Decode and validate an opaque catalog cursor for file paging.
     *
     * Params:
     *     cursor = Cursor returned by this backend.
     *     limit = Expected page size.
     *     queryToken = Expected source/query/sort binding token.
     * Returns: The keyset position encoded in the cursor.
     * Throws: `CatalogBackendException` with `invalidCursor` when the cursor,
     *     page size, binding token, or payload is invalid.
     */
    RepositoryFileCursor parseFileCursor(CatalogPageCursor cursor,
        size_t limit, string queryToken) const
    {
        if (!cursor.isValid || cursor.adapterPageSize != limit)
            throw invalidCursor("Catalog cursor does not match this page size.");
        const auto prefix = queryToken ~ "\0cursor\0";
        auto token = cursor.adapterQueryToken;
        if (!token.startsWith(prefix))
            throw invalidCursor("Catalog cursor does not match this source or query.");
        auto parts = token[prefix.length .. $].split("\0");
        if (parts.length != 3)
            throw invalidCursor("Malformed SQLite file cursor.");
        try
        {
            RepositoryFileCursor result;
            result.id = to!long(parts[0]);
            result.size = to!ulong(parts[1]);
            result.relativePath = cast(string) Base64.decode(parts[2]);
            if (result.id != 0)
                return result;
        }
        catch (Exception)
        {
        }
        throw invalidCursor("Malformed SQLite file cursor.");
    }

    /** Build a repository directory query using an explicit filter.
     *
     * Params:
     *     query = Catalog directory query supplying the parent.
     *     filter = Filters that override the query's own filter.
     * Returns: The repository query with filters applied.
     */
    RepositoryDirectoryQuery repositoryDirectoryQuery(
        CatalogDirectoryQuery query, CatalogFilter filter) const
    {
        auto result = repositoryDirectoryQuery(query);
        applyFilter(result, filter);
        return result;
    }

    /** Build a repository directory query from a catalog directory query.
     *
     * Params:
     *     query = Parent directory and filters to translate.
     * Returns: The repository query with filters applied.
     */
    RepositoryDirectoryQuery repositoryDirectoryQuery(
        CatalogDirectoryQuery query) const
    {
        RepositoryDirectoryQuery result;
        result.parentId = directoryDatabaseId(query.parentId);
        applyFilter(result, query.filter);
        return result;
    }

    /** Build a repository file query from a catalog file query.
     *
     * Params:
     *     query = Directory scope, filters, and sort order to translate.
     * Returns: The repository query with filters and sort order applied.
     */
    RepositoryFileQuery repositoryFileQuery(CatalogFileQuery query) const
    {
        RepositoryFileQuery result;
        result.directoryId = directoryDatabaseId(query.directoryId);
        applyFilter(result, query.filter);
        final switch (query.sortOrder)
        {
        case CatalogSortOrder.pathAscending:
            result.sortOrder = RepositoryFileSortOrder.pathAscending;
            break;
        case CatalogSortOrder.pathDescending:
            result.sortOrder = RepositoryFileSortOrder.pathDescending;
            break;
        case CatalogSortOrder.sizeAscending:
            result.sortOrder = RepositoryFileSortOrder.sizeAscending;
            break;
        case CatalogSortOrder.sizeDescending:
            result.sortOrder = RepositoryFileSortOrder.sizeDescending;
            break;
        }
        return result;
    }

    /** Copy catalog filters into a repository directory query.
     *
     * Params:
     *     query = Repository query updated in place.
     *     filter = Source-neutral filters to copy.
     */
    void applyFilter(ref RepositoryDirectoryQuery query, CatalogFilter filter) const
    {
        query.text = filter.pathText;
        query.caseSensitive = filter.caseSensitive;
        query.video = filter.video;
        query.audio = filter.audio;
        query.image = filter.image;
        query.textStream = filter.text;
        query.mediaNegated = filter.mediaNegated;
        query.fileType = filter.fileType;
        query.archive = filter.archive;
        query.torrent = filter.torrent;
        query.availableOnly = filter.availableOnly;
        query.includeArchiveMembers = filter.includeArchiveMembers;
    }

    /** Copy catalog filters into a repository file query.
     *
     * Params:
     *     query = Repository query updated in place.
     *     filter = Source-neutral filters to copy.
     */
    void applyFilter(ref RepositoryFileQuery query, CatalogFilter filter) const
    {
        query.text = filter.pathText;
        query.caseSensitive = filter.caseSensitive;
        query.video = filter.video;
        query.audio = filter.audio;
        query.image = filter.image;
        query.textStream = filter.text;
        query.mediaNegated = filter.mediaNegated;
        query.fileType = filter.fileType;
        query.archive = filter.archive;
        query.torrent = filter.torrent;
        query.availableOnly = filter.availableOnly;
        query.includeArchiveMembers = filter.includeArchiveMembers;
    }

    /** Build the source/version/query binding token for directory cursors.
     *
     * Params:
     *     repository = Open repository supplying the source version.
     *     query = Directory query whose parent and filter are encoded.
     * Returns: A token that changes when the source or query changes.
     */
    string directoryQueryToken(Repository repository,
        CatalogDirectoryQuery query) const
    {
        return sourceToken ~ "\0" ~ sourceVersion(repository) ~ "\0dirs\0"
            ~ query.parentId.adapterToken ~ "\0" ~ filterToken(query.filter);
    }

    /** Build the source/version/query binding token for file cursors.
     *
     * Params:
     *     repository = Open repository supplying the source version.
     *     query = File query whose directory, filter, and sort are encoded.
     * Returns: A token that changes when the source or query changes.
     */
    string fileQueryToken(Repository repository, CatalogFileQuery query) const
    {
        return sourceToken ~ "\0" ~ sourceVersion(repository) ~ "\0files\0"
            ~ query.directoryId.adapterToken ~ "\0" ~ filterToken(query.filter)
            ~ "\0" ~ (cast(int) query.sortOrder).to!string;
    }

    /** Build the source/version/family binding token for detail cursors.
     *
     * Params:
     *     repository = Open repository supplying the source version.
     *     family = Detail family key (`archive`, `torrent`, ...).
     *     blobId = Content blob id the detail page belongs to.
     * Returns: A token that changes when the source or detail family changes.
     */
    string detailQueryToken(Repository repository, string family,
        long blobId) const
    {
        return sourceToken ~ "\0" ~ sourceVersion(repository) ~ "\0"
            ~ family ~ "\0" ~ blobId.to!string;
    }

    /** Serialize filter flags into a stable cursor-binding token.
     *
     * Params:
     *     filter = Filters to encode.
     * Returns: A delimiter-joined token that changes with every flag.
     */
    string filterToken(CatalogFilter filter) const
    {
        return filter.pathText ~ "\0" ~ (filter.caseSensitive ? "1" : "0")
            ~ (filter.video ? "1" : "0") ~ (filter.audio ? "1" : "0")
            ~ (filter.image ? "1" : "0") ~ (filter.text ? "1" : "0")
            ~ (filter.mediaNegated ? "1" : "0") ~ (filter.fileType ? "1" : "0")
            ~ (filter.archive ? "1" : "0") ~ (filter.torrent ? "1" : "0")
            ~ (filter.availableOnly ? "1" : "0")
            ~ (filter.includeArchiveMembers ? "1" : "0");
    }

    /** Validate a page request and return its row offset.
     *
     * Params:
     *     request = Requested limit and optional cursor.
     *     queryToken = Expected source/query binding token.
     * Returns: Zero for the first page, otherwise the cursor's row offset.
     * Throws: `CatalogBackendException` with `invalidCursor` for a bad limit,
     *     a mismatched cursor, or an out-of-range offset.
     */
    size_t cursorOffset(CatalogPageRequest request, string queryToken) const
    {
        if (request.limit == 0 || request.limit >= cast(size_t) long.max)
            throw invalidCursor("Catalog page limit is invalid.");
        if (!request.cursor.isValid)
            return 0;
        if (request.cursor.adapterPageSize != request.limit
            || request.cursor.adapterQueryToken != queryToken)
            throw invalidCursor("Catalog cursor does not match this source or query.");
        if (request.cursor.adapterIndex > cast(size_t) long.max)
            throw invalidCursor("Catalog cursor offset is out of range.");
        return request.cursor.adapterIndex;
    }

    /** Validate that a page limit is positive and representable as `long`.
     *
     * Params:
     *     request = Page request whose limit is checked.
     * Throws: `CatalogBackendException` with `invalidCursor` when the limit is
     *     zero or too large.
     */
    void validatePageRequest(CatalogPageRequest request) const
    {
        if (request.limit == 0 || request.limit >= cast(size_t) long.max)
            throw invalidCursor("Catalog page limit is invalid.");
    }

    /** Create a typed invalid-cursor exception.
     *
     * Params:
     *     message = Diagnostic message for the failure.
     * Returns: A new `CatalogBackendException` with `invalidCursor`.
     */
    CatalogBackendException invalidCursor(string message) const
    {
        return new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
            message);
    }

    /** Count matching child directories by walking bounded query pages.
     *
     * Params:
     *     repository = Open repository to query.
     *     parent = Parent directory scope.
     *     filter = Filters applied to the count.
     * Returns: The number of matching child directories.
     * Throws: `CatalogBackendException` with `backendFailure` when a page query
     *     fails.
     */
    size_t countDirectories(Repository repository, CatalogDirectoryQuery parent,
        CatalogFilter filter) const
    {
        size_t result;
        size_t offset;
        while (true)
        {
            auto query = repositoryDirectoryQuery(parent, filter);
            query.offset = offset;
            query.limit = catalogPageSize;
            const auto rows = repository.listDirectories(query);
            result += rows.length;
            if (rows.length < catalogPageSize)
                break;
            offset += rows.length;
        }
        return result;
    }

    /** Visit every file below the source root that matches a filter.
     *
     * Root-level files are visited first, then child directories are walked
     * recursively in bounded pages.
     *
     * Params:
     *     repository = Open repository to query.
     *     filter = Filters applied to file and directory pages.
     *     pathPrefix = Optional path prefix used to prune directories.
     *     visit = Callback invoked for each matching file.
     * Throws: `CatalogBackendException` with `backendFailure` when a page query
     *     fails.
     */
    void walkMatchingFiles(Repository repository, CatalogFilter filter,
        string pathPrefix, void delegate(RepositoryFile) visit) const
    {
        RepositoryFileQuery rootFiles;
        applyFilter(rootFiles, filter);
        visitFilePages(repository, rootFiles, pathPrefix, visit);
        walkDirectoryChildren(repository, CatalogDirectoryQuery.init, filter,
            pathPrefix, visit);
    }

    /** Recursively visit files under one directory in bounded pages.
     *
     * Params:
     *     repository = Open repository to query.
     *     parent = Directory whose children are walked.
     *     filter = Filters applied to file and directory pages.
     *     pathPrefix = Optional path prefix used to prune directories.
     *     visit = Callback invoked for each matching file.
     * Throws: `CatalogBackendException` with `backendFailure` when a page query
     *     fails.
     */
    void walkDirectoryChildren(Repository repository,
        CatalogDirectoryQuery parent, CatalogFilter filter, string pathPrefix,
        void delegate(RepositoryFile) visit) const
    {
        size_t offset;
        while (true)
        {
            auto query = repositoryDirectoryQuery(parent, filter);
            query.offset = offset;
            query.limit = catalogPageSize;
            auto directories = repository.listDirectories(query);
            foreach (directory; directories)
            {
                if (!directoryCanContainPrefix(directory.relativePath, pathPrefix))
                    continue;
                CatalogFileQuery filesQuery;
                filesQuery.directoryId = directoryId(directory.id);
                filesQuery.filter = filter;
                visitFilePages(repository, repositoryFileQuery(filesQuery),
                    pathPrefix, visit);
                CatalogDirectoryQuery child;
                child.parentId = directoryId(directory.id);
                walkDirectoryChildren(repository, child, filter, pathPrefix, visit);
            }
            if (directories.length < catalogPageSize)
                break;
            offset += directories.length;
        }
    }

    /** Visit all files matching a query, following keyset pages.
     *
     * Params:
     *     repository = Open repository to query.
     *     query = File query; its limit is overwritten with the internal page
     *         size.
     *     pathPrefix = Optional path prefix used to filter visited files.
     *     visit = Callback invoked for each file within the prefix.
     * Throws: `CatalogBackendException` with `backendFailure` when a page query
     *     fails.
     */
    void visitFilePages(Repository repository, RepositoryFileQuery query,
        string pathPrefix, void delegate(RepositoryFile) visit) const
    {
        query.limit = catalogPageSize;
        auto page = repository.listFilesPage(query);
        while (true)
        {
            foreach (file; page.files)
                if (withinPathPrefix(file.relativePath, pathPrefix))
                    visit(file);
            if (!page.hasMore)
                break;
            page = repository.nextFilesPage(query, page.nextCursor);
        }
    }

    /** Return whether a directory subtree can contain the path prefix.
     *
     * Params:
     *     directory = Normalized directory path.
     *     prefix = Normalized path prefix; empty matches every directory.
     * Returns: `true` when the prefix is inside or above the directory.
     */
    bool directoryCanContainPrefix(string directory, string prefix) const
    {
        if (prefix.length == 0)
            return true;
        return directory == prefix || directory.startsWith(prefix ~ "/")
            || prefix.startsWith(directory ~ "/");
    }

    /** Return whether a path is equal to or below a prefix.
     *
     * Both the physical path separator and the archive virtual-path separator
     * are accepted.
     *
     * Params:
     *     path = Normalized reference path.
     *     prefix = Normalized path prefix; empty matches every path.
     * Returns: `true` when the path is the prefix or lies below it.
     */
    bool withinPathPrefix(string path, string prefix) const
    {
        return prefix.length == 0 || path == prefix
            || path.startsWith(prefix ~ "/")
            || path.startsWith(prefix ~ archivePathSeparator());
    }

    /** Build the source-scoped token for one archive entry.
     *
     * Params:
     *     blobId = Container content blob id.
     *     entryId = Archive entry row id.
     * Returns: The opaque archive-entry token.
     */
    string archiveEntryToken(long blobId, long entryId) const
    {
        return sourceToken ~ ":archive-entry:" ~ blobId.to!string ~ ":"
            ~ entryId.to!string;
    }

    /** Convert a compact container identity into a reference identity.
     *
     * Params:
     *     identity = `p<physical-id>` for a physical container, or a
     *         colon-joined entry chain.
     * Returns: The corresponding source-scoped container reference identity.
     */
    ReferenceId archiveContainerReference(string identity) const
    {
        if (identity.length > 1 && identity[0] == 'p'
            && !identity.canFind(':'))
            return ReferenceId(identityToken("reference",
                to!long(identity[1 .. $])));
        return ReferenceId(sourceToken ~ ":archive-reference:" ~ identity);
    }

    /** Build the source-scoped identity of one archive member occurrence.
     *
     * Params:
     *     containerIdentity = Compact container identity owning the member.
     *     entryId = Repository file row id of the member.
     * Returns: The opaque member reference identity.
     */
    ReferenceId archiveMemberReferenceId(string containerIdentity,
        long entryId) const
    {
        return ReferenceId(sourceToken ~ ":archive-reference:"
            ~ containerIdentity ~ ":" ~ entryId.to!string);
    }

    /** Extract the physical root reference id from a container identity.
     *
     * Params:
     *     containerIdentity = Compact `p<id>:<entry>:...` container identity.
     * Returns: The positive physical reference id.
     * Throws: `CatalogBackendException` with `invalidIdentifier` when the root
     *     component is missing or malformed.
     */
    long archiveRootReferenceId(string containerIdentity) const
    {
        auto root = containerIdentity.split(":")[0];
        if (root.length < 2 || root[0] != 'p')
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Archive member locator has no physical container root.");
        try
            return to!long(root[1 .. $]);
        catch (Exception)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Malformed physical container ID in archive member locator.");
    }

    /** Return whether a filter changes any query-visible condition.
     *
     * Params:
     *     filter = Source-neutral filter to inspect.
     * Returns: `true` when at least one filter field is active.
     */
    bool hasActiveFilter(CatalogFilter filter) const
    {
        return filter.pathText.length > 0 || filter.video || filter.audio
            || filter.image || filter.text || filter.fileType || filter.archive
            || filter.torrent || filter.availableOnly || filter.includeArchiveMembers;
    }

    /** Validate that a target has the pure repository shape this adapter opens.
     *
     * Params:
     *     target = Target to validate.
     * Throws: `CatalogBackendException` with `invalidTarget` when the mode,
     *     repository root, catalog path, or filesystem root is wrong.
     */
    static void validateTargetShape(OperationTarget target)
    {
        if (target.mode != OperationStorageMode.repository
            || target.repositoryRoot.length == 0 || target.catalogPath.length > 0
            || target.filesystemRoot.length > 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "SQLite backend requires an explicit repository target.");
    }
}

@("SQLite backend export cancellation writes no output")
unittest
{
    import std.datetime.systime : Clock;
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
        NamedBinaryBlobCatalog, serializeDataClassWrapperFile;
    import dosierskanilo.operations : OperationProgress;

    const token = randomUUID().toString();
    const root = buildPath(tempDir(), "sqlite-export-cancel-" ~ token);
    const sourcePath = buildPath(tempDir(), "sqlite-export-cancel-"
        ~ token ~ ".json");
    const outputPath = buildPath(tempDir(), "sqlite-export-cancel-output-"
        ~ token ~ ".json");
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(sourcePath))
            remove(sourcePath);
        if (exists(outputPath))
            remove(outputPath);
        if (exists(root))
            rmdirRecurse(root);
    }

    NamedBinaryBlobCatalog catalog;
    catalog.dataVersion = DATA_CLASS_VERSION5;
    foreach (index; 0 .. 600)
        catalog.dataArray ~= new NamedBinaryBlob("item" ~ index.to!string, 1,
            Clock.currTime());
    serializeDataClassWrapperFile(sourcePath, catalog);
    {
        auto repository = Repository.initialize(root);
        scope (exit)
            repository.close();
        repository.importJson(sourcePath);
        assert(repository.blobCount == 600);
    }

    auto backend = new DefaultCatalogBackendFactory().open(
        OperationTarget.repositoryTarget(root));
    scope (exit)
        backend.close();

    OperationControl control;
    control = new OperationControl((OperationProgress event) {
        if (event.operation == OperationKind.catalogExport
            && event.completed > 0)
            control.requestCancellation();
    });
    CatalogSubsetQuery query;
    CatalogExportOptions options;
    options.format = CatalogExportFormat.jsonV5;
    options.outputPath = outputPath;
    const auto result = backend.exportSubsetControlled(query, options, control, 7);
    assert(!result.committed);
    assert(!exists(outputPath), "Cancelled export must not publish a catalog.");
    assert(backend.repositoryInfo().schemaVersion > 0);
}

/** Explicit factory for SQLite repository targets. */
final class SqliteCatalogBackendFactory : CatalogBackendFactory
{
    /** Open a SQLite backend for a repository target.
     *
     * Params:
     *     target = Repository target to open.
     * Returns: A new backend bound to the repository.
     * Throws: `CatalogBackendException` with `invalidTarget` for non-repository
     *     targets.
     */
    override CatalogBackend open(OperationTarget target)
    {
        if (target.mode != OperationStorageMode.repository)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidTarget,
                "SqliteCatalogBackendFactory only opens repository targets.");
        return new SqliteCatalogBackend(target);
    }
}

/** Default factory routing explicit JSON and repository targets to adapters. */
final class DefaultCatalogBackendFactory : CatalogBackendFactory
{
    /// Factory used for JSON catalog targets.
    private JsonCatalogBackendFactory jsonFactory;
    /// Factory used for SQLite repository targets.
    private SqliteCatalogBackendFactory sqliteFactory;

    /// Create the JSON and SQLite factories used for target routing.
    this()
    {
        jsonFactory = new JsonCatalogBackendFactory();
        sqliteFactory = new SqliteCatalogBackendFactory();
    }

    /** Route an explicit target to the matching JSON or SQLite factory.
     *
     * Params:
     *     target = Target whose storage mode selects the adapter.
     * Returns: The backend opened by the selected factory.
     * Throws: `CatalogBackendException` for errors from the selected factory.
     */
    override CatalogBackend open(OperationTarget target)
    {
        final switch (target.mode)
        {
        case OperationStorageMode.jsonCatalog:
            return jsonFactory.open(target);
        case OperationStorageMode.repository:
            return sqliteFactory.open(target);
        }
    }
}

version (unittest)
{
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, getSize,
        mkdirRecurse, remove, rmdirRecurse, tempDir;
    import std.path : baseName, buildPath;
    import std.uuid : randomUUID;

    import dosierskanilo.model.namedbinaryblob :
        deserializeDataClassJsonWrapperFile;
    import dosierskanilo.operations : OperationState;
    import dosierskanilo.testdata : copySyntheticCatalogForTest;

    @("SQLite backend routes repositories and matches JSON catalog queries")
    unittest
    {
        const token = randomUUID().toString();
        const jsonRoot = copySyntheticCatalogForTest(buildPath(tempDir(),
            "sqlite-backend-json-" ~ token));
        const sqliteRoot = copySyntheticCatalogForTest(buildPath(tempDir(),
            "sqlite-backend-db-" ~ token));
        const catalogPath = buildPath(tempDir(), "sqlite-backend-source-"
            ~ token ~ ".json");
        const exportPath = buildPath(tempDir(), "sqlite-backend-export-"
            ~ token ~ ".json");
        const memberExportPath = buildPath(tempDir(), "sqlite-backend-member-export-"
            ~ token ~ ".json");
        const jsonMemberExportPath = buildPath(tempDir(),
            "sqlite-backend-json-member-export-" ~ token ~ ".json");
        const nestedMemberExportPath = buildPath(tempDir(),
            "sqlite-backend-nested-member-export-" ~ token ~ ".json");
        const nestedImportRoot = buildPath(tempDir(),
            "sqlite-backend-nested-import-" ~ token);
        const jsonNestedMemberExportPath = buildPath(tempDir(),
            "sqlite-backend-json-nested-member-export-" ~ token ~ ".json");
        const backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
        auto repository = Repository.initialize(sqliteRoot);
        repository.close();
        CatalogBackend jsonBackend;
        CatalogBackend sqliteBackend;
        CatalogBackend nestedImportBackend;
        scope (exit)
        {
            if (nestedImportBackend !is null)
                nestedImportBackend.close();
            if (jsonBackend !is null)
                jsonBackend.close();
            if (sqliteBackend !is null)
                sqliteBackend.close();
            if (exists(catalogPath))
                remove(catalogPath);
            if (exists(exportPath))
                remove(exportPath);
            if (exists(memberExportPath))
                remove(memberExportPath);
            if (exists(jsonMemberExportPath))
                remove(jsonMemberExportPath);
            if (exists(nestedMemberExportPath))
                remove(nestedMemberExportPath);
            if (exists(jsonNestedMemberExportPath))
                remove(jsonNestedMemberExportPath);
            foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
                if (entry.name.baseName.startsWith(backupPrefix)
                    && exists(entry.name))
                    remove(entry.name);
            if (exists(jsonRoot))
                rmdirRecurse(jsonRoot);
            if (exists(sqliteRoot))
                rmdirRecurse(sqliteRoot);
            if (exists(nestedImportRoot))
                rmdirRecurse(nestedImportRoot);
        }

        auto factory = new DefaultCatalogBackendFactory();
        jsonBackend = factory.open(OperationTarget.jsonTarget(catalogPath, jsonRoot));
        sqliteBackend = factory.open(OperationTarget.repositoryTarget(sqliteRoot));
        assert(jsonBackend.sourceInfo().storageMode == OperationStorageMode.jsonCatalog);
        assert(sqliteBackend.sourceInfo().storageMode == OperationStorageMode.repository);
        assert(sqliteBackend.capabilities().supportsReadsDuringMutation);
        assert(sqliteBackend.target().repositoryRoot == Repository.findRoot(sqliteRoot));

        ScanOperationRequest scan;
        scan.operationId = 1;
        scan.scanOptions.recursive = true;
        scan.metadataOptions.calculateChecksums = true;
        scan.metadataOptions.detectFileTypes = true;
        scan.metadataOptions.extractMediaInfo = true;
        scan.metadataOptions.scanArchives = true;
        scan.metadataOptions.deepArchiveScan = true;
        scan.metadataOptions.scanTorrents = true;
        scan.metadataOptions.threads = 2;
        scan.target = jsonBackend.target();
        const auto jsonScan = jsonBackend.runOperation(scan, new OperationControl());
        assert(jsonScan.state == OperationState.completed, jsonScan.error);
        scan.operationId = 2;
        scan.target = sqliteBackend.target();
        const auto sqliteScan = sqliteBackend.runOperation(scan, new OperationControl());
        assert(sqliteScan.state == OperationState.completed, sqliteScan.error);
        assert(sqliteScan.scanSummary.filesFound == jsonScan.scanSummary.filesFound);
        assert(sqliteBackend.rootSummary().fileReferenceCount == 12);
        assert(sqliteBackend.rootSummary().aggregateSize
            == jsonBackend.rootSummary().aggregateSize,
            sqliteBackend.rootSummary().aggregateSize.to!string ~ " != "
            ~ jsonBackend.rootSummary().aggregateSize.to!string);

        CatalogDirectoryQuery directoryQuery;
        CatalogPageRequest directoryRequest;
        directoryRequest.limit = 1;
        auto firstDirectory = sqliteBackend.listDirectories(directoryQuery,
            directoryRequest);
        assert(firstDirectory.directories.length == 1);
        assert(firstDirectory.hasMore);
        directoryRequest.cursor = firstDirectory.nextCursor;
        auto secondDirectory = sqliteBackend.listDirectories(directoryQuery,
            directoryRequest);
        assert(secondDirectory.directories.length == 1);
        assert(secondDirectory.hasPrevious);
        auto previousDirectory = sqliteBackend.listDirectories(directoryQuery,
            CatalogPageRequest(1, secondDirectory.previousCursor));
        assert(previousDirectory.directories[0].id
            == firstDirectory.directories[0].id);

        DirectoryId archiveDirectory;
        DirectoryId mediaDirectory;
        DirectoryId torrentDirectory;
        directoryRequest = CatalogPageRequest.init;
        directoryRequest.limit = 32;
        foreach (directory; sqliteBackend.listDirectories(directoryQuery,
            directoryRequest).directories)
        {
            if (directory.relativePath == "archives")
                archiveDirectory = directory.id;
            else if (directory.relativePath == "media")
                mediaDirectory = directory.id;
            else if (directory.relativePath == "torrent")
                torrentDirectory = directory.id;
        }
        assert(archiveDirectory.isValid && mediaDirectory.isValid
            && torrentDirectory.isValid);

        CatalogFileQuery archiveQuery;
        archiveQuery.directoryId = archiveDirectory;
        archiveQuery.filter.archive = true;
        auto archivePage = sqliteBackend.listFiles(archiveQuery);
        assert(archivePage.files.length == 3);
        CatalogFileQuery archiveMemberQuery;
        archiveMemberQuery.directoryId = archiveDirectory;
        archiveMemberQuery.filter.includeArchiveMembers = true;
        archiveMemberQuery.filter.pathText = "sample.zip!/";
        auto archiveMemberFiles = sqliteBackend.listFiles(archiveMemberQuery);
        assert(archiveMemberFiles.files.length == 8);
        foreach (member; archiveMemberFiles.files)
            assert(member.locator.kind == ContentLocator.Kind.archiveEntry);
        auto nestedArchiveMemberQuery = archiveMemberQuery;
        nestedArchiveMemberQuery.filter.pathText =
            "sample.zip!/nested.zip!/deep/readme.txt";
        auto nestedArchiveMemberFiles = sqliteBackend.listFiles(
            nestedArchiveMemberQuery);
        assert(nestedArchiveMemberFiles.files.length == 1);
        assert(nestedArchiveMemberFiles.files[0].locator.kind
            == ContentLocator.Kind.archiveEntry);
        assert(!nestedArchiveMemberFiles.files[0].hasArchive);
        bool nestedArchiveMemberHasIndex;
        foreach (member; archiveMemberFiles.files)
            if (member.relativePath == "archives/sample.zip!/nested.zip")
                nestedArchiveMemberHasIndex = member.hasArchive;
        assert(nestedArchiveMemberHasIndex);
        CatalogPageRequest archiveMemberFileRequest;
        archiveMemberFileRequest.limit = 2;
        auto firstArchiveMemberPage = sqliteBackend.listFiles(
            archiveMemberQuery, archiveMemberFileRequest);
        assert(firstArchiveMemberPage.hasMore);
        auto secondArchiveMemberPage = sqliteBackend.nextFilesPage(
            archiveMemberQuery, firstArchiveMemberPage.nextCursor);
        assert(secondArchiveMemberPage.files.length == 2);
        auto priorArchiveMemberPage = sqliteBackend.previousFilesPage(
            archiveMemberQuery, secondArchiveMemberPage.previousCursor);
        assert(priorArchiveMemberPage.files[0].referenceId
            == firstArchiveMemberPage.files[0].referenceId);
        CatalogDirectoryQuery memberDirectoryQuery;
        memberDirectoryQuery.parentId = archiveDirectory;
        memberDirectoryQuery.filter = archiveMemberQuery.filter;
        auto visibleMemberDirectories = sqliteBackend.listDirectories(
            memberDirectoryQuery).directories;
        assert(visibleMemberDirectories.length == 0);
        memberDirectoryQuery.parentId = DirectoryId.init;
        visibleMemberDirectories = sqliteBackend.listDirectories(
            memberDirectoryQuery).directories;
        assert(visibleMemberDirectories.length == 1);
        assert(visibleMemberDirectories[0].relativePath == "archives");
        CatalogPageRequest fileRequest;
        fileRequest.limit = 1;
        auto firstFilePage = sqliteBackend.listFiles(archiveQuery, fileRequest);
        assert(firstFilePage.files.length == 1 && firstFilePage.hasMore);
        auto secondFilePage = sqliteBackend.nextFilesPage(archiveQuery,
            firstFilePage.nextCursor);
        assert(secondFilePage.files.length == 1 && secondFilePage.hasPrevious);
        auto priorFilePage = sqliteBackend.previousFilesPage(archiveQuery,
            secondFilePage.previousCursor);
        assert(priorFilePage.files.length == 1);
        assert(priorFilePage.files[0].referenceId
            == firstFilePage.files[0].referenceId);

        auto sizeQuery = archiveQuery;
        sizeQuery.sortOrder = CatalogSortOrder.sizeAscending;
        auto sizePage = sqliteBackend.listFiles(sizeQuery);
        assert(sizePage.files.length == 3);
        assert(sizePage.files[0].size <= sizePage.files[1].size);
        assert(sizePage.files[1].size <= sizePage.files[2].size);
        auto firstSizePage = sqliteBackend.listFiles(sizeQuery, fileRequest);
        auto secondSizePage = sqliteBackend.nextFilesPage(sizeQuery,
            firstSizePage.nextCursor);
        auto priorSizePage = sqliteBackend.previousFilesPage(sizeQuery,
            secondSizePage.previousCursor);
        assert(priorSizePage.files[0].referenceId
            == firstSizePage.files[0].referenceId);

        auto afterFirstSize = sqliteBackend.listFilesFrom(sizeQuery,
            sizePage.files[0].relativePath, true, 1);
        assert(afterFirstSize.files.length == 1);
        assert(afterFirstSize.files[0].referenceId
            == sizePage.files[1].referenceId);
        auto beforeSecondSize = sqliteBackend.listFilesFrom(sizeQuery,
            sizePage.files[1].relativePath, false, 1);
        assert(beforeSecondSize.files.length == 1);
        assert(beforeSecondSize.files[0].referenceId
            == sizePage.files[0].referenceId);
        assert(sqliteBackend.listFilesFrom(sizeQuery,
            sizePage.files[0].relativePath, false, 1).files.length == 0);
        assert(sqliteBackend.listFilesFrom(sizeQuery,
            sizePage.files[$ - 1].relativePath, true, 1).files.length == 0);
        assert(sqliteBackend.listFilesFrom(sizeQuery, "missing.bin", true, 1)
            .files.length == 0);
        const auto sizeFromEmpty = sqliteBackend.listFilesFrom(sizeQuery, "",
            true, 2);
        assert(sizeFromEmpty.files.length == 2 && sizeFromEmpty.hasMore);
        assert(sizeFromEmpty.files[0].referenceId
            == sizePage.files[0].referenceId);

        const auto sqliteContents = sqliteBackend.listContents(
            CatalogContentQuery.init);
        const auto jsonContents = jsonBackend.listContents(
            CatalogContentQuery.init);
        /* JSON merges identical payloads by content hash, while the SQLite
         * fixture keeps unmerged duplicate blobs until analysis runs, so the
         * SQLite row set is a superset of the JSON row set here. */
        assert(jsonContents.total > 0);
        assert(sqliteContents.total >= jsonContents.total);
        foreach (row; jsonContents.rows)
        {
            bool found;
            foreach (candidate; sqliteContents.rows)
                if (candidate.displayPath == row.displayPath)
                {
                    found = true;
                    assert(candidate.size == row.size);
                    break;
                }
            assert(found, row.displayPath);
        }
        CatalogPageRequest contentRequest;
        contentRequest.limit = 1;
        const auto sqliteFirstContent = sqliteBackend.listContents(
            CatalogContentQuery.init, contentRequest);
        assert(sqliteFirstContent.hasMore);
        const auto sqliteNextContent = sqliteBackend.listContents(
            CatalogContentQuery.init,
            CatalogPageRequest(1, sqliteFirstContent.nextCursor));
        assert(sqliteNextContent.rows.length == 1);
        assert(sqliteNextContent.rows[0].id
            == sqliteContents.rows[1].id);

        /* Archive passwords are stored through the neutral path method. */
        const auto passwordTarget = sqliteBackend.loadReference(
            sqliteBackend.resolveReference("archives/sample.zip"));
        sqliteBackend.setArchivePassword("archives/sample.zip", "catalog-secret");
        {
            auto storedRepository = Repository.open(sqliteRoot);
            scope (exit)
                storedRepository.close();
            const auto storedReference = storedRepository.fileReferenceByRelativePath(
                "archives/sample.zip");
            assert(storedReference.id > 0);
            assert(storedRepository.loadBlobDetails(storedReference.blobId)
                .archivePassword == "catalog-secret");
        }
        sqliteBackend.setArchivePassword("archives/sample.zip", "");
        {
            auto storedRepository = Repository.open(sqliteRoot);
            scope (exit)
                storedRepository.close();
            const auto storedReference = storedRepository.fileReferenceByRelativePath(
                "archives/sample.zip");
            assert(storedReference.id > 0);
            assert(storedRepository.loadBlobDetails(storedReference.blobId)
                .archivePassword.length == 0);
        }

        /* A base64 SHA-1 is accepted as an exact content filter. */
        string sha1Text;
        foreach (digest; sqliteContents.rows[0].fingerprint.digests)
            if (digest.algorithm == "sha1")
                sha1Text = Base64.encode(digest.value);
        if (sha1Text.length > 0)
        {
            CatalogContentQuery digestQuery;
            digestQuery.filter.pathText = sha1Text;
            const auto digestContents = sqliteBackend.listContents(digestQuery);
            assert(digestContents.rows.length >= 1);
            bool containsFirst;
            foreach (row; digestContents.rows)
                if (row.id == sqliteContents.rows[0].id)
                    containsFirst = true;
            assert(containsFirst);
            assert(jsonBackend.listContents(digestQuery).rows.length >= 1);
        }

        auto wildcardTextQuery = archiveQuery;
        wildcardTextQuery.filter.pathText = "%";
        assert(sqliteBackend.listFiles(wildcardTextQuery).files.length == 0);

        CatalogFile sampleArchive;
        foreach (file; archivePage.files)
            if (file.name == "sample.zip")
                sampleArchive = file;
        assert(sampleArchive.contentId.isValid);
        CatalogPageRequest archiveRequest;
        archiveRequest.limit = 2;
        const auto archiveEntries = sqliteBackend.listArchiveEntries(
            sampleArchive.contentId, archiveRequest);
        assert(archiveEntries.entries.length == 2 && archiveEntries.hasMore);
        assert(archiveEntries.entries[0].hasSafePath);
        assert(archiveEntries.entries[0].contentId.isValid);
        CatalogDetailMask memberDetails;
        memberDetails.fingerprint = true;
        auto archiveMember = sqliteBackend.loadContent(
            archiveEntries.entries[0].contentId, memberDetails);
        assert(archiveMember.fingerprint.complete);
        CatalogPageRequest archiveMemberRequest;
        archiveMemberRequest.limit = 1;
        auto archiveMembers = sqliteBackend.listArchiveMembers(
            sampleArchive.referenceId, archiveMemberRequest);
        assert(archiveMembers.members.length == 1 && archiveMembers.hasMore);
        assert(archiveMembers.members[0].locator.kind
            == ContentLocator.Kind.archiveEntry);
        assert(archiveMembers.members[0].contentId.isValid);
        CatalogPageRequest allArchiveMemberRequest;
        allArchiveMemberRequest.limit = 32;
        CatalogArchiveMember nestedZipMember;
        foreach (member; sqliteBackend.listArchiveMembers(
            sampleArchive.referenceId, allArchiveMemberRequest).members)
            if (member.name == "nested.zip")
                nestedZipMember = member;
        assert(nestedZipMember.referenceId.isValid);
        const auto nestedArchiveMembers = sqliteBackend.listArchiveMembers(
            nestedZipMember.referenceId, allArchiveMemberRequest);
        assert(nestedArchiveMembers.members.length == 1);
        assert(nestedArchiveMembers.members[0].relativePath == "deep/readme.txt");
        assert(nestedArchiveMembers.members[0].locator.archiveEntry.containerReferenceId
            == nestedZipMember.referenceId);
        DirectoryId jsonArchiveDirectory;
        DirectoryId jsonTorrentDirectory;
        foreach (directory; jsonBackend.listDirectories(directoryQuery,
            directoryRequest).directories)
            if (directory.relativePath == "archives")
                jsonArchiveDirectory = directory.id;
            else if (directory.relativePath == "torrent")
                jsonTorrentDirectory = directory.id;
        assert(jsonTorrentDirectory.isValid);
        CatalogFile jsonContainer;
        CatalogFile jsonNestedArchiveFile;
        CatalogFileQuery jsonArchiveQuery;
        jsonArchiveQuery.directoryId = jsonArchiveDirectory;
        jsonArchiveQuery.filter.archive = true;
        foreach (file; jsonBackend.listFiles(jsonArchiveQuery).files)
        {
            if (file.name == "sample.zip")
                jsonContainer = file;
            else if (file.name == "nested.zip")
                jsonNestedArchiveFile = file;
        }
        const auto jsonArchiveMembers = jsonBackend.listArchiveMembers(
            jsonContainer.referenceId, archiveMemberRequest);
        assert(jsonArchiveMembers.members.length == archiveMembers.members.length);
        bool sharesArchiveMemberPath;
        foreach (member; jsonBackend.listArchiveMembers(jsonContainer.referenceId,
            allArchiveMemberRequest).members)
            sharesArchiveMemberPath = sharesArchiveMemberPath
                || member.relativePath == archiveMembers.members[0].relativePath;
        assert(sharesArchiveMemberPath);
        assert(jsonArchiveMembers.members[0].fingerprint.complete);
        CatalogArchiveMember jsonNestedZipMember;
        foreach (member; jsonBackend.listArchiveMembers(jsonContainer.referenceId,
            allArchiveMemberRequest).members)
            if (member.name == "nested.zip")
                jsonNestedZipMember = member;
        assert(jsonNestedZipMember.referenceId.isValid);
        assert(jsonNestedZipMember.contentId.isValid);
        assert(jsonNestedZipMember.contentId == jsonNestedArchiveFile.contentId);
        assert(jsonBackend.listArchiveEntries(jsonNestedArchiveFile.contentId)
            .entries.length == 1);
        const auto jsonNestedEntryPage = jsonBackend.listArchiveEntries(
            jsonNestedZipMember.contentId);
        assert(jsonNestedEntryPage.entries.length == 1);
        const auto jsonNestedArchiveMembers = jsonBackend.listArchiveMembers(
            jsonNestedZipMember.referenceId, allArchiveMemberRequest);
        assert(jsonNestedArchiveMembers.members.length
            == nestedArchiveMembers.members.length);
        assert(jsonNestedArchiveMembers.members[0].relativePath
            == nestedArchiveMembers.members[0].relativePath);

        /* Handles, path restoration, and nested extraction agree across backends. */
        assert(sqliteBackend.uiHandle(sampleArchive.referenceId)
            .startsWith("ref:"));
        assert(sqliteBackend.uiHandle(archiveDirectory).startsWith("dir:"));
        assert(sqliteBackend.uiHandle(sampleArchive.contentId)
            .startsWith("content:"));
        assert(sqliteBackend.uiHandle(sampleArchive.referenceId)
            != sqliteBackend.uiHandle(sampleArchive.contentId));
        assert(jsonBackend.uiHandle(jsonContainer.referenceId)
            .startsWith("ref:"));
        assert(sqliteBackend.resolveDirectory("archives") == archiveDirectory);
        assert(jsonBackend.resolveDirectory("archives") == jsonArchiveDirectory);
        assert(!sqliteBackend.resolveDirectory("").isValid);
        assert(sqliteBackend.resolveReference(sampleArchive.relativePath)
            == sampleArchive.referenceId);
        assert(jsonBackend.resolveReference(jsonContainer.relativePath)
            == jsonContainer.referenceId);
        assert(sqliteBackend.loadReference(sampleArchive.referenceId)
            .relativePath == sampleArchive.relativePath);
        assert(jsonBackend.loadReference(jsonContainer.referenceId)
            .relativePath == jsonContainer.relativePath);
        assert(!sqliteBackend.resolveReference(
            "archives/missing.zip").isValid);
        const auto nestedMemberPath =
            "archives/sample.zip!/nested.zip!/deep/readme.txt";
        assert(sqliteBackend.resolveReference(nestedMemberPath).isValid);
        assert(jsonBackend.resolveReference(nestedMemberPath).isValid);
        auto sqliteNestedLease = sqliteBackend.acquireMemberContent(
            nestedArchiveMembers.members[0].referenceId);
        assert(exists(sqliteNestedLease.path));
        assert(getSize(sqliteNestedLease.path)
            == nestedArchiveMembers.members[0].size);
        sqliteNestedLease.release();
        auto jsonNestedLease = jsonBackend.acquireMemberContent(
            jsonNestedArchiveMembers.members[0].referenceId);
        assert(exists(jsonNestedLease.path));
        assert(getSize(jsonNestedLease.path)
            == jsonNestedArchiveMembers.members[0].size);
        jsonNestedLease.release();

        shared bool cancelledLease;
        cancelledLease = true;
        bool jsonCancelled;
        bool sqliteCancelled;
        try
            jsonBackend.acquireMemberContent(
                jsonNestedArchiveMembers.members[0].referenceId,
                &cancelledLease);
        catch (CatalogBackendException failure)
            jsonCancelled = failure.code == CatalogBackendErrorCode.cancelled;
        try
            sqliteBackend.acquireMemberContent(
                nestedArchiveMembers.members[0].referenceId, &cancelledLease);
        catch (CatalogBackendException failure)
            sqliteCancelled = failure.code == CatalogBackendErrorCode.cancelled;
        assert(jsonCancelled && sqliteCancelled,
            "both adapters must honor member-extraction cancellation");

        /* Detail snapshots and extractor statuses must agree across backends. */
        CatalogDetailMask archiveDetails;
        archiveDetails.archiveSummary = true;
        const auto sqliteArchiveSnapshot = sqliteBackend.loadContent(
            sampleArchive.contentId, archiveDetails);
        const auto jsonArchiveSnapshot = jsonBackend.loadContent(
            jsonContainer.contentId, archiveDetails);
        assert(sqliteArchiveSnapshot.hasArchive == jsonArchiveSnapshot.hasArchive);
        assert(sqliteArchiveSnapshot.archiveSummary.indexKnown
            == jsonArchiveSnapshot.archiveSummary.indexKnown);
        assert(sqliteArchiveSnapshot.archiveSummary.entryCount
            == jsonArchiveSnapshot.archiveSummary.entryCount);
        assert(sqliteArchiveSnapshot.archiveSummary.entriesWithCompleteFingerprints
            == jsonArchiveSnapshot.archiveSummary.entriesWithCompleteFingerprints);
        assert(sqliteArchiveSnapshot.extractors.length
            == jsonArchiveSnapshot.extractors.length);
        foreach (index, status; sqliteArchiveSnapshot.extractors)
        {
            assert(status.extractor == jsonArchiveSnapshot.extractors[index].extractor);
            assert(status.state == jsonArchiveSnapshot.extractors[index].state,
                status.extractor ~ ": sqlite=" ~ status.state.to!string
                ~ " json=" ~ jsonArchiveSnapshot.extractors[index].state.to!string);
        }

        auto jsonArchiveMemberQuery = archiveMemberQuery;
        jsonArchiveMemberQuery.directoryId = jsonArchiveDirectory;
        const auto jsonArchiveMemberFiles = jsonBackend.listFiles(
            jsonArchiveMemberQuery).files;
        assert(jsonArchiveMemberFiles.length == archiveMemberFiles.files.length,
            "JSON member rows=" ~ jsonArchiveMemberFiles.length.to!string
            ~ ", SQLite member rows=" ~ archiveMemberFiles.files.length.to!string);
        foreach (index, member; archiveMemberFiles.files)
        {
            assert(jsonArchiveMemberFiles[index].relativePath == member.relativePath);
            assert(jsonArchiveMemberFiles[index].size == member.size);
            assert(jsonArchiveMemberFiles[index].locator.kind
                == ContentLocator.Kind.archiveEntry);
        }
        auto jsonNestedMemberQuery = jsonArchiveMemberQuery;
        jsonNestedMemberQuery.filter.pathText =
            "sample.zip!/nested.zip!/deep/readme.txt";
        const auto jsonNestedMemberFiles = jsonBackend.listFiles(
            jsonNestedMemberQuery);
        assert(jsonNestedMemberFiles.files.length
            == nestedArchiveMemberFiles.files.length);
        assert(!jsonNestedMemberFiles.files[0].hasArchive);
        bool jsonNestedArchiveMemberHasIndex;
        foreach (member; jsonArchiveMemberFiles)
            if (member.relativePath == "archives/sample.zip!/nested.zip")
                jsonNestedArchiveMemberHasIndex = member.hasArchive;
        assert(jsonNestedArchiveMemberHasIndex);
        assert(jsonNestedMemberFiles.files[0].relativePath
            == nestedArchiveMemberFiles.files[0].relativePath);
        archiveRequest.cursor = archiveEntries.nextCursor;
        auto nextArchiveEntries = sqliteBackend.listArchiveEntries(
            sampleArchive.contentId, archiveRequest);
        assert(nextArchiveEntries.entries.length == 2);
        assert(nextArchiveEntries.entries[0].fingerprint.complete);

        import std.exception : assertThrown;
        CatalogPageRequest pastArchiveRequest = archiveRequest;
        pastArchiveRequest.cursor = CatalogPageCursor(999, pastArchiveRequest.limit,
            archiveEntries.nextCursor.queryToken);
        assertThrown!CatalogBackendException(
            sqliteBackend.listArchiveEntries(sampleArchive.contentId,
                pastArchiveRequest));

        CatalogFileQuery mediaQuery;
        mediaQuery.directoryId = mediaDirectory;
        mediaQuery.filter.audio = true;
        auto mediaPage = sqliteBackend.listFiles(mediaQuery);
        assert(mediaPage.files.length == 1);
        CatalogDetailMask mediaDetails;
        mediaDetails.fingerprint = true;
        mediaDetails.media = true;
        auto media = sqliteBackend.loadContent(mediaPage.files[0].contentId,
            mediaDetails);
        assert(media.fingerprint.complete);
        assert(media.mediaStreams.length == 1);
        assert(media.mediaStreams[0].kind == CatalogMediaKind.audio);

        CatalogFileQuery torrentQuery;
        torrentQuery.directoryId = torrentDirectory;
        torrentQuery.filter.torrent = true;
        auto torrentPage = sqliteBackend.listFiles(torrentQuery);
        assert(torrentPage.files.length == 2);
        CatalogFile singleTorrent;
        foreach (file; torrentPage.files)
            if (file.name == "single-file.torrent")
                singleTorrent = file;
        CatalogDetailMask torrentDetails;
        torrentDetails.torrentSummary = true;
        auto torrent = sqliteBackend.loadContent(singleTorrent.contentId,
            torrentDetails);
        assert(torrent.torrentSummary.name == "tone.wav");
        assert(torrent.torrentSummary.fileListAvailable);
        /* A known content without an archive index is an empty page, not an error. */
        assert(sqliteBackend.listArchiveEntries(singleTorrent.contentId)
            .entries.length == 0);
        CatalogFileQuery jsonTorrentQuery;
        jsonTorrentQuery.directoryId = jsonTorrentDirectory;
        jsonTorrentQuery.filter.torrent = true;
        CatalogFile jsonSingleTorrent;
        foreach (file; jsonBackend.listFiles(jsonTorrentQuery).files)
            if (file.name == "single-file.torrent")
                jsonSingleTorrent = file;
        assert(jsonSingleTorrent.contentId.isValid);
        assert(jsonBackend.listArchiveEntries(jsonSingleTorrent.contentId)
            .entries.length == 0);

        const auto sqliteTorrentSnapshot = sqliteBackend.loadContent(
            singleTorrent.contentId, torrentDetails);
        const auto jsonTorrentSnapshot = jsonBackend.loadContent(
            jsonSingleTorrent.contentId, torrentDetails);
        assert(sqliteTorrentSnapshot.hasTorrent == jsonTorrentSnapshot.hasTorrent);
        assert(sqliteTorrentSnapshot.torrentSummary.name
            == jsonTorrentSnapshot.torrentSummary.name);
        /* The SQLite repository always stores the manifest; a JSON source may
         * legitimately omit torrent files, which its capabilities report. */
        assert(sqliteTorrentSnapshot.torrentSummary.fileListAvailable);
        assert(sqliteTorrentSnapshot.extractors.length
            == jsonTorrentSnapshot.extractors.length);
        foreach (index, status; sqliteTorrentSnapshot.extractors)
        {
            assert(status.extractor == jsonTorrentSnapshot.extractors[index].extractor);
            assert(status.state == jsonTorrentSnapshot.extractors[index].state);
        }

        CatalogExportOptions exportOptions;
        exportOptions.format = CatalogExportFormat.jsonV5;
        exportOptions.outputPath = exportPath;
        CatalogSubsetQuery subset;
        subset.pathPrefix = "archives";
        const auto exported = sqliteBackend.exportSubset(subset, exportOptions);
        assert(exported.committed);
        assert(exported.referencesExported > 3);
        const auto rootSubsetCatalog = deserializeDataClassJsonWrapperFile(exportPath);
        assert(rootSubsetCatalog.dataVersion == DATA_CLASS_VERSION5);
        assert(rootSubsetCatalog.dataArray.length > 3);

        CatalogFilter archiveNameFilter;
        archiveNameFilter.pathText = "sample.zip";
        assert(sqliteBackend.rootSummary(archiveNameFilter).fileReferenceCount == 1);
        assert(sqliteBackend.rootSummary(archiveNameFilter).fileReferenceCount
            == jsonBackend.rootSummary(archiveNameFilter).fileReferenceCount);
        CatalogFilter typeUnionFilter;
        typeUnionFilter.archive = true;
        typeUnionFilter.torrent = true;
        assert(sqliteBackend.rootSummary(typeUnionFilter).fileReferenceCount == 5,
            sqliteBackend.rootSummary(typeUnionFilter).fileReferenceCount.to!string);
        assert(sqliteBackend.rootSummary(typeUnionFilter).fileReferenceCount
            == jsonBackend.rootSummary(typeUnionFilter).fileReferenceCount);

        CatalogSubsetQuery memberSubset;
        memberSubset.pathPrefix = "archives/sample.zip!/payload/copy.txt";
        memberSubset.filter.includeArchiveMembers = true;
        auto memberExportOptions = CatalogExportOptions.init;
        memberExportOptions.format = CatalogExportFormat.jsonV5;
        memberExportOptions.outputPath = memberExportPath;
        const auto sqliteMemberExport = sqliteBackend.exportSubset(memberSubset,
            memberExportOptions);
        assert(sqliteMemberExport.committed);
        assert(sqliteMemberExport.referencesExported == 2);
        const auto sqliteMemberCatalog = deserializeDataClassJsonWrapperFile(
            memberExportPath);
        assert(sqliteMemberCatalog.dataVersion == DATA_CLASS_VERSION5);
        bool exportedCopy;
        foreach (blob; sqliteMemberCatalog.dataArray)
            foreach (spec; blob.fileSpecs)
                exportedCopy = exportedCopy
                    || spec.fileName == "archives/sample.zip!/payload/copy.txt";
        assert(exportedCopy);
        memberExportOptions.outputPath = jsonMemberExportPath;
        const auto jsonMemberExport = jsonBackend.exportSubset(memberSubset,
            memberExportOptions);
        assert(jsonMemberExport.committed);
        assert(jsonMemberExport.referencesExported
            == sqliteMemberExport.referencesExported);

        memberSubset.pathPrefix = "archives/sample.zip!/nested.zip";
        memberExportOptions.format = CatalogExportFormat.jsonV5;
        memberExportOptions.outputPath = nestedMemberExportPath;
        const auto sqliteNestedExport = sqliteBackend.exportSubset(memberSubset,
            memberExportOptions);
        assert(sqliteNestedExport.committed);
        const auto sqliteNestedCatalog = deserializeDataClassJsonWrapperFile(
            nestedMemberExportPath);
        assert(sqliteNestedCatalog.dataVersion == DATA_CLASS_VERSION5);
        bool exportedNestedContainer;
        bool exportedDeepMember;
        foreach (blob; sqliteNestedCatalog.dataArray)
            foreach (spec; blob.fileSpecs)
            {
                exportedNestedContainer = exportedNestedContainer
                    || spec.fileName == "archives/sample.zip";
                exportedDeepMember = exportedDeepMember
                    || spec.fileName == "archives/sample.zip!/nested.zip!/deep/readme.txt";
            }
        assert(exportedNestedContainer && exportedDeepMember);
        memberExportOptions.outputPath = jsonNestedMemberExportPath;
        const auto jsonNestedExport = jsonBackend.exportSubset(memberSubset,
            memberExportOptions);
        assert(jsonNestedExport.committed);
        const auto jsonNestedCatalog = deserializeDataClassJsonWrapperFile(
            jsonNestedMemberExportPath);
        assert(jsonNestedCatalog.dataVersion == DATA_CLASS_VERSION5);
        bool jsonExportedDeepMember;
        foreach (blob; jsonNestedCatalog.dataArray)
            foreach (spec; blob.fileSpecs)
                jsonExportedDeepMember = jsonExportedDeepMember
                    || spec.fileName == "archives/sample.zip!/nested.zip!/deep/readme.txt";
        assert(jsonExportedDeepMember);

        mkdirRecurse(nestedImportRoot);
        auto nestedImportRepository = Repository.initialize(nestedImportRoot);
        nestedImportRepository.importJson(nestedMemberExportPath);
        RepositoryQueryOptions importedCountQuery;
        assert(nestedImportRepository.countCatalogQuery(importedCountQuery) == 3);
        nestedImportRepository.close();
        nestedImportBackend = factory.open(
            OperationTarget.repositoryTarget(nestedImportRoot));
        DirectoryId importedArchiveDirectoryId;
        foreach (directory; nestedImportBackend.listDirectories(
            CatalogDirectoryQuery.init).directories)
            if (directory.relativePath == "archives")
                importedArchiveDirectoryId = directory.id;
        assert(importedArchiveDirectoryId.isValid);
        CatalogFileQuery importedAllQuery;
        importedAllQuery.directoryId = importedArchiveDirectoryId;
        const auto importedPhysicalFiles = nestedImportBackend.listFiles(
            importedAllQuery).files;
        assert(importedPhysicalFiles.length == 1,
            importedPhysicalFiles.length.to!string);
        assert(importedPhysicalFiles[0].name == "sample.zip",
            importedPhysicalFiles[0].relativePath);
        CatalogFileQuery importedArchiveQuery;
        importedArchiveQuery.directoryId = importedArchiveDirectoryId;
        importedArchiveQuery.filter.archive = true;
        CatalogFile importedSampleArchive;
        foreach (file; nestedImportBackend.listFiles(importedArchiveQuery).files)
            if (file.name == "sample.zip")
                importedSampleArchive = file;
        assert(importedSampleArchive.referenceId.isValid);
        auto importedOuterMembers = nestedImportBackend.listArchiveMembers(
            importedSampleArchive.referenceId);
        assert(importedOuterMembers.members.length == 1);
        auto importedInnerMembers = nestedImportBackend.listArchiveMembers(
            importedOuterMembers.members[0].referenceId);
        assert(importedInnerMembers.members.length == 1);
        assert(importedInnerMembers.members[0].name == "deep/readme.txt",
            importedInnerMembers.members[0].relativePath);
        CatalogFileQuery importedNestedQuery;
        importedNestedQuery.directoryId = importedArchiveDirectoryId;
        importedNestedQuery.filter.includeArchiveMembers = true;
        const auto importedNestedMembers = nestedImportBackend.listFiles(
            importedNestedQuery);
        bool importedDeepReadme;
        foreach (member; importedNestedMembers.files)
            if (member.relativePath
                == "archives/sample.zip!/nested.zip!/deep/readme.txt")
                importedDeepReadme = true;
        assert(importedDeepReadme);

        auto missingRelativePath = buildPath("same-size", "different.txt");
        remove(buildPath(jsonRoot, missingRelativePath));
        remove(buildPath(sqliteRoot, missingRelativePath));
        ScanOperationRequest refreshMissingState;
        refreshMissingState.operationId = 3;
        refreshMissingState.target = sqliteBackend.target();
        refreshMissingState.scanOptions.recursive = true;
        const auto refreshed = sqliteBackend.runOperation(refreshMissingState,
            new OperationControl());
        assert(refreshed.state == OperationState.completed, refreshed.error);

        CatalogDirectoryQuery staleCursorQuery;
        CatalogPageRequest staleCursorPage;
        staleCursorPage.limit = 1;
        const auto staleCursorSource = sqliteBackend.listDirectories(
            staleCursorQuery, staleCursorPage);
        assert(staleCursorSource.hasMore);
        const auto staleCursor = staleCursorSource.nextCursor;

        AnalysisOperationRequest analysis;
        analysis.operationId = 4;
        analysis.target = jsonBackend.target();
        const auto jsonAnalysis = jsonBackend.runOperation(analysis,
            new OperationControl());
        assert(jsonAnalysis.state == OperationState.completed, jsonAnalysis.error);
        analysis.operationId = 5;
        analysis.target = sqliteBackend.target();
        const auto sqliteAnalysis = sqliteBackend.runOperation(analysis,
            new OperationControl());
        assert(sqliteAnalysis.state == OperationState.completed, sqliteAnalysis.error);
        assert(sqliteAnalysis.analysisSummary.missingFiles
            == jsonAnalysis.analysisSummary.missingFiles);
        bool staleCursorRejected;
        CatalogPageRequest staleFollowUp = staleCursorPage;
        staleFollowUp.cursor = staleCursor;
        try
            sqliteBackend.listDirectories(staleCursorQuery, staleFollowUp);
        catch (CatalogBackendException failure)
            staleCursorRejected = failure.code == CatalogBackendErrorCode.invalidCursor;
        assert(staleCursorRejected,
            "Analysis must invalidate cursors issued before the change.");
        CatalogFilter availableOnly;
        availableOnly.availableOnly = true;
        assert(sqliteBackend.rootSummary(availableOnly).fileReferenceCount == 11);
        assert(sqliteBackend.rootSummary(availableOnly).fileReferenceCount
            == jsonBackend.rootSummary(availableOnly).fileReferenceCount);

        bool rejectedJsonTarget;
        try
            new SqliteCatalogBackend(OperationTarget.jsonTarget(catalogPath));
        catch (CatalogBackendException failure)
            rejectedJsonTarget = failure.code == CatalogBackendErrorCode.invalidTarget;
        assert(rejectedJsonTarget);
    }
}

@("SQLite duplicate analysis invalidates cursors issued before the merge")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const auto root = buildPath(tempDir(), "sqlite-analysis-cursor-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    write(buildPath(root, "first.txt"), "identical payload");
    write(buildPath(root, "second.txt"), "identical payload");
    write(buildPath(root, "third.txt"), "different payload");
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    auto repository = Repository.initialize(root);
    repository.close();

    auto factory = new DefaultCatalogBackendFactory();
    auto backend = factory.open(OperationTarget.repositoryTarget(root));
    scope (exit)
        backend.close();

    ScanOperationRequest scan;
    scan.operationId = 1;
    scan.target = backend.target();
    scan.scanOptions.recursive = true;
    scan.metadataOptions.calculateChecksums = true;
    const auto scanResult = backend.runOperation(scan, new OperationControl());
    assert(scanResult.state == OperationState.completed, scanResult.error);

    CatalogFileQuery fileQuery;
    CatalogPageRequest page;
    page.limit = 1;
    const auto firstPage = backend.listFiles(fileQuery, page);
    assert(firstPage.hasMore);
    const auto staleCursor = firstPage.nextCursor;

    AnalysisOperationRequest analysis;
    analysis.operationId = 2;
    analysis.target = backend.target();
    const auto analysisResult = backend.runOperation(analysis,
        new OperationControl());
    assert(analysisResult.state == OperationState.completed,
        analysisResult.error);
    assert(analysisResult.analysisSummary.mergedBlobs == 1);

    bool rejected;
    try
        backend.nextFilesPage(fileQuery, staleCursor);
    catch (CatalogBackendException failure)
        rejected = failure.code == CatalogBackendErrorCode.invalidCursor;
    assert(rejected, "The merged duplicate set must invalidate the old cursor.");
}

@("JSON and SQLite backends agree on duplicate groups and filtered reads")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const token = randomUUID().toString();
    const root = buildPath(tempDir(), "backend-parity-reads-" ~ token);
    const catalogPath = buildPath(tempDir(), "backend-parity-reads-"
        ~ token ~ ".json");
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
        if (exists(catalogPath))
            remove(catalogPath);
    }
    write(buildPath(root, "first.txt"), "identical payload");
    write(buildPath(root, "second.txt"), "identical payload");
    write(buildPath(root, "third.txt"), "different payload");

    auto repository = Repository.initialize(root);
    repository.close();

    auto factory = new DefaultCatalogBackendFactory();
    auto sqliteBackend = factory.open(OperationTarget.repositoryTarget(root));
    auto jsonBackend = factory.open(OperationTarget.jsonTarget(catalogPath, root));
    scope (exit)
    {
        if (sqliteBackend !is null)
            sqliteBackend.close();
        if (jsonBackend !is null)
            jsonBackend.close();
    }

    foreach (index, backend; [sqliteBackend, jsonBackend])
    {
        ScanOperationRequest scan;
        scan.operationId = cast(ulong) index + 1;
        scan.target = backend.target();
        scan.scanOptions.recursive = true;
        scan.metadataOptions.calculateChecksums = true;
        const result = backend.runOperation(scan, new OperationControl());
        assert(result.state == OperationState.completed, result.error);
    }

    const sqliteGroups = sqliteBackend.queryDuplicateGroups();
    const jsonGroups = jsonBackend.queryDuplicateGroups();
    assert(sqliteGroups.length == 1);
    assert(jsonGroups.length == sqliteGroups.length);
    assert(sqliteGroups[0].fileSize == jsonGroups[0].fileSize);
    assert(sqliteGroups[0].blobIds.length == 2);
    assert(jsonGroups[0].blobIds.length == sqliteGroups[0].blobIds.length);

    CatalogFileQuery filteredQuery;
    filteredQuery.filter.pathText = "first";
    const sqliteFiles = sqliteBackend.listFiles(filteredQuery).files;
    const jsonFiles = jsonBackend.listFiles(filteredQuery).files;
    assert(sqliteFiles.length == 1);
    assert(jsonFiles.length == sqliteFiles.length);
    assert(sqliteFiles[0].relativePath == "first.txt");
    assert(jsonFiles[0].relativePath == sqliteFiles[0].relativePath);
    assert(sqliteFiles[0].size == jsonFiles[0].size);
}

@("SQLite backends are transactional stores without document sessions")
unittest
{
    import std.exception : assertThrown;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "sqlite-document-" ~ randomUUID().toString());
    mkdirRecurse(root);
    auto repository = Repository.initialize(root);
    repository.close();
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);

    auto backend = new SqliteCatalogBackend(OperationTarget.repositoryTarget(root));
    scope (exit)
        backend.close();
    assert(backend.capabilities().persistence
        == CatalogPersistence.transactionalStore);
    assertThrown!CatalogBackendException(backend.document());
}
