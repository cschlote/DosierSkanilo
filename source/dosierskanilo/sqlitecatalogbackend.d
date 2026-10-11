/** SQLite repository adapter for the storage-neutral catalog contract. */
module dosierskanilo.sqlitecatalogbackend;

import std.algorithm.searching : startsWith;
import std.base64 : Base64;
import std.conv : to;
import std.exception : enforce;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath;
import std.string : split;
import std.uuid : randomUUID;

import dosierskanilo.catalogbackend;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION3,
    NamedBinaryBlob, NamedBinaryBlobCatalog;
import dosierskanilo.operationrunner;
import dosierskanilo.operations : AnalysisOperationRequest,
    MetadataOperationRequest, OperationControl, OperationKind, OperationResult,
    OperationStorageMode, OperationTarget, ScanOperationRequest;
import dosierskanilo.repository;
import dosierskanilo.repository.types : JsonExportOptions,
    RepositoryArchiveQuery, RepositoryDirectoryQuery, RepositoryFile,
    RepositoryFileCursor, RepositoryFileQuery, RepositoryFileSortOrder,
    RepositoryTorrentQuery;
import dosierskanilo.jsoncatalogbackend : JsonCatalogBackendFactory;
import dosierskanilo.service.jsonoperations : commitJsonCatalog;

private enum size_t catalogPageSize = 250;

/** SQLite-backed adapter over the public repository facade. */
final class SqliteCatalogBackend : CatalogBackend
{
private:
    OperationTarget backendTarget;
    string sourceToken;
    bool closed;

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
        {
            auto repository = Repository.open(backendTarget.repositoryRoot);
            scope (exit)
                repository.close();
        }
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
        result.supportsFirstClassArchiveReferences = false;
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
            JsonExportOptions options;
            options.absolutePaths = false;
            options.includeDetails = details.media || details.archiveSummary
                || details.torrentSummary;
            options.includeArchiveEntries = false;
            options.includeTorrentFiles = false;
            auto blob = repository.loadBlobDetails(blobId, options);
            if (blob is null)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Unknown SQLite content identity.");
            auto snapshot = snapshotFor(blob, contentId, details);
            if (details.archiveSummary)
                populateArchiveSummary(repository, blobId, snapshot);
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
                entry.size = row.size;
                entry.modifiedAt = row.modifiedAt;
                entry.fingerprint = fingerprintFor(row.size, row.checkSums);
                result.entries ~= entry;
            }
            result.hasMore = rows.length > page.limit;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(offset + count,
                    page.limit, queryToken);
            return result;
        });
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

    override CatalogExportResult exportSubset(CatalogSubsetQuery query,
        CatalogExportOptions options)
    {
        return withRepository((Repository repository) {
            if (options.format != CatalogExportFormat.jsonV3)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedFeature,
                    "SQLite currently exports JSON version 3 subsets only.");
            enforce(options.outputPath.length > 0,
                "A subset export requires an explicit output path.");
            if (query.pathPrefix.length > 0)
                ContentLocator.file(query.pathPrefix);

            RepositoryFile[][long] selectedReferences;
            long[] selectedBlobIds;
            walkMatchingFiles(repository, query.filter, query.pathPrefix,
                (RepositoryFile file) {
                    if (file.blobId !in selectedReferences)
                        selectedBlobIds ~= file.blobId;
                    selectedReferences[file.blobId] ~= file;
                });

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
                    blob.archivePassword = "";
                    blob.torrentInfo = null;
                }
                else if (!options.includeArchiveEntries)
                    blob.archiveSpecs = null;
                exportedBlobs ~= blob;
            }

            auto catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3,
                exportedBlobs);
            enforce(commitJsonCatalog(options.outputPath, catalog),
                "Could not publish the SQLite subset export.");
            result.contentsExported = exportedBlobs.length;
            result.outputPath = canonicalPath(options.outputPath);
            result.committed = true;
            return result;
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
        closed = true;
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
        Repository repository;
        try
        {
            repository = Repository.open(backendTarget.repositoryRoot);
            scope (exit)
                repository.close();
            return action(repository);
        }
        catch (CatalogBackendException failure)
            throw failure;
        catch (Exception failure)
            throw new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                "SQLite catalog query failed: " ~ failure.msg);
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
        enforce(id > 0, "SQLite catalog identity must be positive.");
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
        result.referenceId = ReferenceId(identityToken("reference", file.id));
        result.contentId = contentId(file.blobId);
        if (file.directoryId > 0)
            result.directoryId = directoryId(file.directoryId);
        try
            result.locator = ContentLocator.file(file.relativePath);
        catch (CatalogBackendException failure)
            throw new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                "Repository contains an invalid relative path: " ~ failure.msg);
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
            result.hasArchive = blob.archiveSpecs !is null;
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
            result.torrentSummary.fileListAvailable = true;
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
        ref CatalogContentSnapshot snapshot) const
    {
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
        const auto id = parseIdentity(pivot.referenceId.adapterToken, "reference");
        const auto path64 = Base64.encode(cast(const(ubyte)[]) pivot.relativePath);
        auto token = cast(string) (queryToken ~ "\0cursor\0" ~ id.to!string
            ~ "\0" ~ pivot.size.to!string ~ "\0" ~ path64);
        return CatalogPageCursor(cast(size_t) 0, limit, token);
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
            if (result.id > 0)
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
            ~ (filter.availableOnly ? "1" : "0");
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
            || path.startsWith(prefix ~ "/");
    }

    string archiveEntryToken(long blobId, long entryId) const
    {
        return sourceToken ~ ":archive-entry:" ~ blobId.to!string ~ ":"
            ~ entryId.to!string;
    }

    bool hasActiveFilter(CatalogFilter filter) const
    {
        return filter.pathText.length > 0 || filter.video || filter.audio
            || filter.image || filter.text || filter.fileType || filter.archive
            || filter.torrent || filter.availableOnly;
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
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, remove,
        rmdirRecurse, tempDir;
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
        const backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
        auto repository = Repository.initialize(sqliteRoot);
        repository.close();
        CatalogBackend jsonBackend;
        CatalogBackend sqliteBackend;
        scope (exit)
        {
            if (jsonBackend !is null)
                jsonBackend.close();
            if (sqliteBackend !is null)
                sqliteBackend.close();
            if (exists(catalogPath))
                remove(catalogPath);
            if (exists(exportPath))
                remove(exportPath);
            foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
                if (entry.name.baseName.startsWith(backupPrefix)
                    && exists(entry.name))
                    remove(entry.name);
            if (exists(jsonRoot))
                rmdirRecurse(jsonRoot);
            if (exists(sqliteRoot))
                rmdirRecurse(sqliteRoot);
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

        CatalogExportOptions exportOptions;
        exportOptions.outputPath = exportPath;
        CatalogSubsetQuery subset;
        subset.pathPrefix = "archives";
        const auto exported = sqliteBackend.exportSubset(subset, exportOptions);
        assert(exported.committed);
        assert(exported.referencesExported == 3);
        assert(deserializeDataClassJsonWrapperFile(exportPath).dataArray.length == 3);

        CatalogFilter archiveNameFilter;
        archiveNameFilter.pathText = "sample.zip";
        assert(sqliteBackend.rootSummary(archiveNameFilter).fileReferenceCount == 1);
        assert(sqliteBackend.rootSummary(archiveNameFilter).fileReferenceCount
            == jsonBackend.rootSummary(archiveNameFilter).fileReferenceCount);
        CatalogFilter typeUnionFilter;
        typeUnionFilter.archive = true;
        typeUnionFilter.torrent = true;
        assert(sqliteBackend.rootSummary(typeUnionFilter).fileReferenceCount == 5);
        assert(sqliteBackend.rootSummary(typeUnionFilter).fileReferenceCount
            == jsonBackend.rootSummary(typeUnionFilter).fileReferenceCount);

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
