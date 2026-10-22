/** SQLite repository adapter for the storage-neutral catalog contract. */
module dosierskanilo.sqlitecatalogbackend;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.base64 : Base64;
import std.conv : to;
import std.exception : enforce;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath;
import std.string : split;
import std.uuid : randomUUID;

import dosierarkivo.archive : parseArchiveVirtualPath;
import dosierskanilo.catalogbackend;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5, NamedBinaryBlob,
    NamedBinaryBlobCatalog;
import dosierskanilo.operationrunner;
import dosierskanilo.operations : AnalysisOperationRequest,
    MetadataOperationRequest, OperationControl, OperationKind, OperationResult,
    OperationStorageMode, OperationTarget, ScanOperationRequest;
import dosierskanilo.repository;
import dosierskanilo.repository.types : JsonExportOptions,
    RepositoryArchiveQuery, RepositoryBlobPage, RepositoryDirectoryQuery,
    RepositoryFile, RepositoryFileCursor, RepositoryFileQuery,
    RepositoryFileSortOrder, RepositoryQueryOptions, RepositoryTorrentQuery;
import dosierskanilo.jsoncatalogbackend : JsonCatalogBackendFactory;
import dosierskanilo.service.jsonoperations : commitJsonCatalog;

private enum size_t catalogPageSize = 250;

private struct ArchiveContainerSource
{
    long contentBlobId;
    long directoryId;
    CatalogReferenceAvailability availability;
    string identity;
}

/** SQLite-backed adapter over the public repository facade. */
final class SqliteCatalogBackend : CatalogBackend
{
private:
    OperationTarget backendTarget;
    string sourceToken;
    bool closed;
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

    override OperationTarget target()
    {
        requireOpen();
        return backendTarget;
    }

    override CatalogSourceInfo sourceInfo()
    {
        requireOpen();
        CatalogSourceInfo result;
        result.storageMode = OperationStorageMode.repository;
        result.displayName = baseName(backendTarget.repositoryRoot);
        return result;
    }

    override RepositoryInfo repositoryInfo()
    {
        return withRepository((Repository repository) {
            return repository.info;
        });
    }

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
        return result;
    }

    override CatalogRootSummary rootSummary(CatalogFilter filter = CatalogFilter.init)
    {
        return withRepository((Repository repository) {
            CatalogRootSummary result;
            if (!hasActiveFilter(filter))
            {
                auto summary = repository.rootSummary();
                result.childDirectoryCount = summary.childDirectoryCount;
                walkMatchingFiles(repository, filter, "", (RepositoryFile file) {
                    ++result.fileReferenceCount;
                    result.aggregateSize += file.size;
                });
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

    override CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        return withRepository((Repository repository) {
            validatePageRequest(page);
            const auto blobId = parseIdentity(contentId.adapterToken, "content");
            const auto queryToken = detailQueryToken(repository, "archive", blobId);
            const auto offset = cursorOffset(page, queryToken);
            RepositoryArchiveQuery query;
            query.blobId = blobId;
            query.offset = offset;
            query.limit = page.limit + 1;
            auto rows = repository.listArchiveEntries(query);
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

    override CatalogTorrentEntryPage listTorrentEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        return withRepository((Repository repository) {
            validatePageRequest(page);
            const auto blobId = parseIdentity(contentId.adapterToken, "content");
            const auto queryToken = detailQueryToken(repository, "torrent", blobId);
            const auto offset = cursorOffset(page, queryToken);
            RepositoryTorrentQuery query;
            query.blobId = blobId;
            query.offset = offset;
            query.limit = page.limit + 1;
            auto rows = repository.listTorrentFiles(query);
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

    override RepositoryBlobPage queryBlobs(RepositoryQueryOptions options)
    {
        return withRepository((Repository repository) {
            return repository.loadCatalogQueryPageWithIds(options);
        });
    }

    override RepositoryDuplicateGroup[] queryDuplicateGroups(size_t limit = 100)
    {
        return withRepository((Repository repository) {
            enforce(limit > 0, new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Duplicate query limit must be greater than zero."));
            return repository.queryDuplicates(limit);
        });
    }

    override CatalogExportResult exportSubset(CatalogSubsetQuery query,
        CatalogExportOptions options)
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

            RepositoryFile[][long] selectedReferences;
            long[] selectedBlobIds;
            bool[long][long] selectedReferenceIds;
            RepositoryFile[] archiveContainersToExpand;
            bool[long] expandedArchiveContainers;
            bool selectedMemberReference;
            void addReference(RepositoryFile reference)
            {
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
            if (selectedMemberReference
                && (!options.includeContentDetails || !options.includeArchiveEntries))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedFeature,
                    "Archive-member subset export requires archive content details.");

            if (options.includeContentDetails && options.includeArchiveEntries)
                foreach (container; archiveContainersToExpand)
                {
                    RepositoryFileQuery memberQuery;
                    memberQuery.directoryId = container.directoryId;
                    memberQuery.includeArchiveMembers = true;
                    memberQuery.limit = size_t.max;
                    memberQuery.caseSensitive = true;
                    const auto memberPrefix = container.relativePath ~ "!/";
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
            CatalogExportResult result;
            result.referencesExported = 0;
            foreach (blobId; selectedBlobIds)
            {
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
            }

            auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
                exportedBlobs);
            enforce(commitJsonCatalog(options.outputPath, catalog),
                new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                    "Could not publish the SQLite subset export."));
            result.contentsExported = exportedBlobs.length;
            result.outputPath = canonicalPath(options.outputPath);
            result.committed = true;
            return result;
        });
    }

    override void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init)
    {
        return withRepository((Repository repository) {
            repository.importJson(jsonPath, options);
        });
    }

    override OperationResult runOperation(ScanOperationRequest request,
        OperationControl control)
    {
        requireMatchingTarget(request.target);
        return dosierskanilo.operationrunner.runOperation(request, control);
    }

    override OperationResult runOperation(MetadataOperationRequest request,
        OperationControl control)
    {
        requireMatchingTarget(request.target);
        return dosierskanilo.operationrunner.runOperation(request, control);
    }

    override OperationResult runOperation(AnalysisOperationRequest request,
        OperationControl control)
    {
        requireMatchingTarget(request.target);
        return dosierskanilo.operationrunner.runOperation(request, control);
    }

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
    void requireOpen() const
    {
        if (closed)
            throw new CatalogBackendException(CatalogBackendErrorCode.closed,
                "SQLite catalog backend is closed.");
    }

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

    string canonicalPath(string path) const
    {
        return buildNormalizedPath(absolutePath(path));
    }

    string sourceVersion(Repository repository) const
    {
        return repository.info().updatedAt;
    }

    string identityToken(string kind, long id) const
    {
        enforce(id > 0, new CatalogBackendException(
            CatalogBackendErrorCode.invalidIdentifier,
            "SQLite catalog identity must be positive."));
        return sourceToken ~ ":" ~ kind ~ ":" ~ id.to!string;
    }

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

    ContentId contentId(long id) const
    {
        return ContentId(identityToken("content", id));
    }

    DirectoryId directoryId(long id) const
    {
        return DirectoryId(identityToken("directory", id));
    }

    long directoryDatabaseId(DirectoryId id) const
    {
        return id.isValid ? parseIdentity(id.adapterToken, "directory") : 0;
    }

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

    CatalogPageCursor filePageCursor(string queryToken, CatalogFile pivot,
        size_t limit) const
    {
        const auto id = repositoryFileCursorId(pivot.referenceId);
        const auto path64 = Base64.encode(cast(const(ubyte)[]) pivot.relativePath);
        auto token = cast(string) (queryToken ~ "\0cursor\0" ~ id.to!string
            ~ "\0" ~ pivot.size.to!string ~ "\0" ~ path64);
        return CatalogPageCursor(cast(size_t) 0, limit, token);
    }

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

    RepositoryDirectoryQuery repositoryDirectoryQuery(
        CatalogDirectoryQuery query, CatalogFilter filter) const
    {
        auto result = repositoryDirectoryQuery(query);
        applyFilter(result, filter);
        return result;
    }

    RepositoryDirectoryQuery repositoryDirectoryQuery(
        CatalogDirectoryQuery query) const
    {
        RepositoryDirectoryQuery result;
        result.parentId = directoryDatabaseId(query.parentId);
        applyFilter(result, query.filter);
        return result;
    }

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

    string directoryQueryToken(Repository repository,
        CatalogDirectoryQuery query) const
    {
        return sourceToken ~ "\0" ~ sourceVersion(repository) ~ "\0dirs\0"
            ~ query.parentId.adapterToken ~ "\0" ~ filterToken(query.filter);
    }

    string fileQueryToken(Repository repository, CatalogFileQuery query) const
    {
        return sourceToken ~ "\0" ~ sourceVersion(repository) ~ "\0files\0"
            ~ query.directoryId.adapterToken ~ "\0" ~ filterToken(query.filter)
            ~ "\0" ~ (cast(int) query.sortOrder).to!string;
    }

    string detailQueryToken(Repository repository, string family,
        long blobId) const
    {
        return sourceToken ~ "\0" ~ sourceVersion(repository) ~ "\0"
            ~ family ~ "\0" ~ blobId.to!string;
    }

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

    void validatePageRequest(CatalogPageRequest request) const
    {
        if (request.limit == 0 || request.limit >= cast(size_t) long.max)
            throw invalidCursor("Catalog page limit is invalid.");
    }

    CatalogBackendException invalidCursor(string message) const
    {
        return new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
            message);
    }

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

    void walkMatchingFiles(Repository repository, CatalogFilter filter,
        string pathPrefix, void delegate(RepositoryFile) visit) const
    {
        RepositoryFileQuery rootFiles;
        applyFilter(rootFiles, filter);
        visitFilePages(repository, rootFiles, pathPrefix, visit);
        walkDirectoryChildren(repository, CatalogDirectoryQuery.init, filter,
            pathPrefix, visit);
    }

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

    bool directoryCanContainPrefix(string directory, string prefix) const
    {
        if (prefix.length == 0)
            return true;
        return directory == prefix || directory.startsWith(prefix ~ "/")
            || prefix.startsWith(directory ~ "/");
    }

    bool withinPathPrefix(string path, string prefix) const
    {
        return prefix.length == 0 || path == prefix
            || path.startsWith(prefix ~ "/") || path.startsWith(prefix ~ "!/");
    }

    string archiveEntryToken(long blobId, long entryId) const
    {
        return sourceToken ~ ":archive-entry:" ~ blobId.to!string ~ ":"
            ~ entryId.to!string;
    }

    ReferenceId archiveContainerReference(string identity) const
    {
        if (identity.length > 1 && identity[0] == 'p'
            && !identity.canFind(':'))
            return ReferenceId(identityToken("reference",
                to!long(identity[1 .. $])));
        return ReferenceId(sourceToken ~ ":archive-reference:" ~ identity);
    }

    ReferenceId archiveMemberReferenceId(string containerIdentity,
        long entryId) const
    {
        return ReferenceId(sourceToken ~ ":archive-reference:"
            ~ containerIdentity ~ ":" ~ entryId.to!string);
    }

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

    bool hasActiveFilter(CatalogFilter filter) const
    {
        return filter.pathText.length > 0 || filter.video || filter.audio
            || filter.image || filter.text || filter.fileType || filter.archive
            || filter.torrent || filter.availableOnly || filter.includeArchiveMembers;
    }

    static void validateTargetShape(OperationTarget target)
    {
        if (target.mode != OperationStorageMode.repository
            || target.repositoryRoot.length == 0 || target.catalogPath.length > 0
            || target.filesystemRoot.length > 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "SQLite backend requires an explicit repository target.");
    }
}

/** Explicit factory for SQLite repository targets. */
final class SqliteCatalogBackendFactory : CatalogBackendFactory
{
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
    private JsonCatalogBackendFactory jsonFactory;
    private SqliteCatalogBackendFactory sqliteFactory;

    this()
    {
        jsonFactory = new JsonCatalogBackendFactory();
        sqliteFactory = new SqliteCatalogBackendFactory();
    }

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
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, mkdirRecurse,
        remove, rmdirRecurse, tempDir;
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
            == jsonBackend.rootSummary().aggregateSize);

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
        assert(sqliteBackend.listTorrentEntries(singleTorrent.contentId)
            .entries.length == 1);

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
