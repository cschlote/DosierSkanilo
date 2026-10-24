/** JSON v0-v5 adapter for the storage-neutral catalog contract. */
module dosierskanilo.jsoncatalogbackend;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, isAbsolute;
import std.string : replace, split, toLower;
import std.uuid : randomUUID;

import dosierarkivo.archive : appendArchiveVirtualPath,
    ArchiveVirtualPathLayer, escapeArchiveVirtualPath,
    normalizeArchiveEntryPath, parseArchiveVirtualPath,
    ParsedArchiveVirtualPath;
import dosierskanilo.catalogbackend;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION3,
    DATA_CLASS_VERSION4, DATA_CLASS_VERSION5, NamedBinaryBlob, NamedBinaryBlobCatalog,
    deserializeDataClassJsonWrapperFile;
import dosierskanilo.repository.types : JsonImportOptions, RepositoryBlobPage,
    RepositoryBlobFlags, RepositoryDuplicateGroup, RepositoryInfo,
    RepositoryQueryOptions;
import dosierskanilo.operationrunner;
import dosierskanilo.operations : AnalysisOperationRequest, MetadataOperationRequest,
    OperationControl, OperationKind, OperationPhase, OperationProgress,
    OperationResult, OperationState, OperationStorageMode, OperationTarget,
    ScanOperationRequest;
import dosierskanilo.service.jsonoperations : commitJsonCatalog;

private struct JsonLocation
{
    string identityKey;
    string relativePath;
    string physicalRelativePath;
    bool isInSourceRoot;
    bool isVirtual;
    ArchiveVirtualPathLayer[] virtualEntries;
    FileSpec spec;
}

private struct V5JsonReference
{
    string relativePath;
    string physicalRelativePath;
    string contentToken;
    ArchiveVirtualPathLayer[] entries;
    ulong size;
    string modifiedAt;
}

private struct JsonMemberExportReference
{
    string contentToken;
    string relativePath;
    string modifiedAt;
}

private struct CatalogSlice
{
    size_t start;
    size_t end;
    CatalogPageCursor nextCursor;
    CatalogPageCursor previousCursor;
    bool hasMore;
    bool hasPrevious;
}

private struct ArchiveMemberRow
{
    CatalogFile file;
    size_t containerRow;
}

private struct ArchiveMemberRows
{
    ArchiveMemberRow[] rows;
    size_t[] sizeAscending;
    size_t[] sizeDescending;
}

/** JSON-backed catalog adapter for legacy and version-5 catalogs. */
final class JsonCatalogBackend : CatalogBackend
{
private:
    OperationTarget backendTarget;
    string sourceRoot;
    string sourceToken;
        NamedBinaryBlobCatalog catalog;
    string catalogLoadError;
    bool closed;
    bool treeQueriesAvailable;
    bool torrentEntryDetailsUnavailable;
    size_t nextIdentity;
    size_t indexGeneration;

    string[string] contentTokenByFingerprint;
    string[string] contentTokenByPath;
    string[string] oldFingerprintByPath;
    ulong[string] oldSizeByPath;
    string[string] referenceTokenByPath;

    CatalogFile[] fileRows;
    CatalogDirectory[] directoryRows;
    size_t[] sizeAscendingOrder;
    size_t[] sizeDescendingOrder;
    ArchiveMemberRows[string] archiveMemberRowsByDirectory;
    CatalogContentSnapshot[string] contentByToken;
    CatalogArchiveEntry[][string] archiveEntriesByToken;
    CatalogTorrentManifestEntry[][string] torrentEntriesByToken;
    size_t[string] blobIndexByRelativePath;
    size_t[string] blobIndexByContentToken;
    FileSpec[string] fileSpecByRelativePath;
    size_t[string] directoryIndexByPath;

public:
    /** Open a direct JSON catalog and optionally bind its filesystem source root. */
    this(OperationTarget target)
    {
        enforceJsonTarget(target);
        backendTarget = target;
        backendTarget.catalogPath = canonicalPath(target.catalogPath);
        if (target.filesystemRoot.length > 0)
        {
            backendTarget.filesystemRoot = canonicalPath(target.filesystemRoot);
            sourceRoot = backendTarget.filesystemRoot;
        }
        sourceToken = randomUUID().toString();
        try
            catalog = deserializeDataClassJsonWrapperFile(backendTarget.catalogPath);
        catch (Exception failure)
        {
            catalogLoadError = failure.msg;
            catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, []);
        }
        if (catalogLoadError.length == 0)
        {
            try
                rebuildIndex();
            catch (Exception failure)
            {
                /* Malformed virtual paths surface here as plain exceptions.
                 * Keep the source readable but disable tree queries instead of
                 * letting an untyped error escape the factory. */
                catalogLoadError = failure.msg;
                clearIndex();
            }
        }
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
        result.storageMode = OperationStorageMode.jsonCatalog;
        result.displayName = baseName(backendTarget.catalogPath);
        return result;
    }

    override RepositoryInfo repositoryInfo()
    {
        requireOpen();
        RepositoryInfo result;
        result.rootPath = sourceRoot.length > 0 ? sourceRoot : backendTarget.catalogPath;
        result.schemaVersion = catalog.dataVersion;
        return result;
    }

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
        return result;
    }

    override CatalogRootSummary rootSummary(CatalogFilter filter = CatalogFilter.init)
    {
        requireTreeQueries();
        CatalogRootSummary result;
        foreach (directory; directoryRows)
            if (!directory.parentId.isValid && directoryVisible(directory, filter))
                ++result.childDirectoryCount;
        foreach (file; fileRows)
        {
            if (!matches(file, filter))
                continue;
            ++result.fileReferenceCount;
            result.aggregateSize += file.size;
        }
        if (filter.includeArchiveMembers)
            foreach (container; fileRows)
                foreach (member; archiveMemberFiles(container))
                    if (matches(member, filter))
                    {
                        ++result.fileReferenceCount;
                        result.aggregateSize += member.size;
                    }
        return result;
    }

    override CatalogDirectoryPage listDirectories(CatalogDirectoryQuery query,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireTreeQueries();
        auto queryToken = directoryQueryToken(query);
        auto matching = matchingDirectories(query);
        auto slice = pageSlice(page, queryToken, matching.length);
        CatalogDirectoryPage result;
        result.directories = matching[slice.start .. slice.end];
        result.nextCursor = slice.nextCursor;
        result.previousCursor = slice.previousCursor;
        result.hasMore = slice.hasMore;
        result.hasPrevious = slice.hasPrevious;
        return result;
    }

    override CatalogFilePage listFiles(CatalogFileQuery query,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireTreeQueries();
        if (!query.filter.includeArchiveMembers)
        {
            size_t total;
            foreach (offset; 0 .. fileRows.length)
                if (fileRowMatches(fileOrderIndex(query.sortOrder, offset), query))
                    ++total;
            const auto slice = pageSlice(page, fileQueryToken(query), total);

            CatalogFilePage result;
            result.files.reserve(slice.end - slice.start);
            size_t matched;
            foreach (offset; 0 .. fileRows.length)
            {
                if (!fileRowMatches(fileOrderIndex(query.sortOrder, offset), query))
                    continue;
                if (matched >= slice.start && matched < slice.end)
                {
                    auto file = fileRows[fileOrderIndex(query.sortOrder, offset)];
                    refreshAvailability(file);
                    result.files ~= file;
                }
                ++matched;
                if (matched >= slice.end)
                    break;
            }
            result.nextCursor = slice.nextCursor;
            result.previousCursor = slice.previousCursor;
            result.hasMore = slice.hasMore;
            result.hasPrevious = slice.hasPrevious;
            return result;
        }

        const auto queryToken = fileQueryToken(query);
        size_t total;
        forEachFileCandidate(query, (ref CatalogFile, size_t) { ++total; });
        const auto slice = pageSlice(page, queryToken, total);

        CatalogFile[] matching;
        matching.reserve(slice.end - slice.start);
        size_t matched;
        forEachFileCandidate(query, (ref CatalogFile file, size_t containerRow) {
            if (matched >= slice.start && matched < slice.end)
            {
                if (containerRow == size_t.max)
                    refreshAvailability(file);
                else
                {
                    auto container = fileRows[containerRow];
                    refreshAvailability(container);
                    file.availability = container.availability;
                }
                matching ~= file;
            }
            ++matched;
        });
        CatalogFilePage result;
        result.files = matching;
        result.nextCursor = slice.nextCursor;
        result.previousCursor = slice.previousCursor;
        result.hasMore = slice.hasMore;
        result.hasPrevious = slice.hasPrevious;
        return result;
    }

    size_t fileOrderIndex(CatalogSortOrder sortOrder, size_t offset)
    {
        final switch (sortOrder)
        {
        case CatalogSortOrder.pathAscending:
            return offset;
        case CatalogSortOrder.pathDescending:
            return fileRows.length - 1 - offset;
        case CatalogSortOrder.sizeAscending:
            if (sizeAscendingOrder.length == 0 && fileRows.length > 0)
            {
                sizeAscendingOrder.length = fileRows.length;
                foreach (index; 0 .. fileRows.length)
                    sizeAscendingOrder[index] = index;
                sizeAscendingOrder.sort!((left, right) =>
                    fileRows[left].size < fileRows[right].size
                    || (fileRows[left].size == fileRows[right].size
                        && fileRows[left].relativePath < fileRows[right].relativePath));
            }
            return sizeAscendingOrder[offset];
        case CatalogSortOrder.sizeDescending:
            if (sizeDescendingOrder.length == 0 && fileRows.length > 0)
            {
                sizeDescendingOrder.length = fileRows.length;
                foreach (index; 0 .. fileRows.length)
                    sizeDescendingOrder[index] = index;
                sizeDescendingOrder.sort!((left, right) =>
                    fileRows[left].size > fileRows[right].size
                    || (fileRows[left].size == fileRows[right].size
                        && fileRows[left].relativePath < fileRows[right].relativePath));
            }
            return sizeDescendingOrder[offset];
        }
    }

    bool fileRowMatches(size_t rowIndex, CatalogFileQuery query) const
    {
        const file = fileRows[rowIndex];
        return file.directoryId == query.directoryId
            && matches(file, query.filter);
    }

    override CatalogFilePage nextFilesPage(CatalogFileQuery query,
        CatalogPageCursor cursor)
    {
        return listFiles(query, CatalogPageRequest(cursor.adapterPageSize, cursor));
    }

    override CatalogFilePage previousFilesPage(CatalogFileQuery query,
        CatalogPageCursor cursor)
    {
        if (!cursor.isValid)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                "A previous-page request requires a cursor.");
        /* The cursor marks the first row of the current page, so the previous
         * page starts one page size before it. */
        const auto start = cursor.adapterIndex > cursor.adapterPageSize
            ? cursor.adapterIndex - cursor.adapterPageSize : 0;
        return listFiles(query, CatalogPageRequest(cursor.adapterPageSize,
            CatalogPageCursor(start, cursor.adapterPageSize,
                cursor.adapterQueryToken)));
    }

    override CatalogContentSnapshot loadContent(ContentId contentId,
        CatalogDetailMask details = CatalogDetailMask.init)
    {
        requireOpen();
        const auto token = contentId.adapterToken;
        if (auto content = token in contentByToken)
            return maskedSnapshot(*content, details);
        throw new CatalogBackendException(CatalogBackendErrorCode.invalidIdentifier,
            "Unknown JSON content identity.");
    }

    private CatalogContentSnapshot maskedSnapshot(CatalogContentSnapshot source,
        CatalogDetailMask details) const
    {
        auto result = source;
        result.fingerprint.digests = source.fingerprint.digests.dup;
        foreach (index; 0 .. result.fingerprint.digests.length)
            result.fingerprint.digests[index].value =
                source.fingerprint.digests[index].value.dup;
        result.mediaStreams = source.mediaStreams.dup;
        result.extractors = source.extractors.dup;
        /* The archive index is authoritative for entries, so refresh the
         * summary at query time instead of trusting the build-time snapshot. */
        const bool indexedArchive =
            (result.id.adapterToken in archiveEntriesByToken) !is null;
        if (indexedArchive)
        {
            result.hasArchive = true;
            result.archiveSummary =
                archiveSummaryForToken(result.id.adapterToken);
        }
        const auto archiveState = !result.hasArchive
            ? CatalogExtractorState.notRequested
            : (result.archiveSummary.entryCount == 0
                ? CatalogExtractorState.empty
                : CatalogExtractorState.completed);
        if (!details.fingerprint)
        {
            result.fingerprint.digests = [];
            result.fingerprint.complete = false;
        }
        if (!details.fileType)
            result.fileType = "";
        if (!details.media)
            result.mediaStreams = [];
        if (!details.archiveSummary)
        {
            result.hasArchive = false;
            result.archiveSummary = CatalogArchiveSummary.init;
        }
        if (!details.torrentSummary)
        {
            result.hasTorrent = false;
            result.torrentSummary = CatalogTorrentSummary.init;
        }
        foreach (ref status; result.extractors)
            if (status.extractor == "archives")
                status.state = archiveState;
        return result;
    }

    CatalogArchiveSummary archiveSummaryForToken(string token) const
    {
        CatalogArchiveSummary summary;
        auto entries = token in archiveEntriesByToken;
        if (entries is null)
            return summary;
        summary.indexKnown = true;
        summary.entryCount = (*entries).length;
        foreach (entry; *entries)
            if (entry.fingerprint.complete)
                ++summary.entriesWithCompleteFingerprints;
        return summary;
    }

    override CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireOpen();
        const auto token = contentId.adapterToken;
        auto entries = token in archiveEntriesByToken;
        if (entries is null)
        {
            /* A known content without an archive index yields an empty page,
             * matching the SQLite backend; only unknown ids are errors. */
            if (token !in contentByToken)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Unknown JSON content identity.");
            CatalogArchiveEntryPage empty;
            return empty;
        }
        auto slice = pageSlice(page, sourceToken ~ "\0"
            ~ indexGeneration.to!string ~ "\0archives\0" ~ token,
            (*entries).length);
        CatalogArchiveEntryPage result;
        result.entries = (*entries)[slice.start .. slice.end];
        result.nextCursor = slice.nextCursor;
        result.hasMore = slice.hasMore;
        return result;
    }

    override CatalogArchiveMemberPage listArchiveMembers(
        ReferenceId containerReferenceId, CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireTreeQueries();
        if (page.limit == 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                "Archive member page limit must be greater than zero.");
        const auto referenceToken = containerReferenceId.adapterToken;
        CatalogFile container;
        bool foundContainer;
        foreach (file; fileRows)
            if (file.referenceId.adapterToken == referenceToken)
            {
                container = file;
                foundContainer = true;
                break;
            }
        if (!foundContainer)
            foreach (candidate; fileRows)
            {
                if (!candidate.hasArchive)
                    continue;
                foreach (member; archiveMemberFiles(candidate))
                    if (member.referenceId.adapterToken == referenceToken)
                    {
                        container = member;
                        foundContainer = true;
                        break;
                    }
                if (foundContainer)
                    break;
            }
        if (!foundContainer || !container.hasArchive)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Reference is not an indexed JSON archive container.");

        CatalogArchiveEntry[] entries;
        if (auto indexedEntries = container.contentId.adapterToken
            in archiveEntriesByToken)
            foreach (entry; *indexedEntries)
                if (entry.hasSafePath && !entry.isDirectory)
                    entries ~= entry;

        refreshAvailability(container);
        const auto queryToken = sourceToken ~ "\0" ~ indexGeneration.to!string
            ~ "\0archive-members\0" ~ referenceToken;
        const auto slice = pageSlice(page, queryToken, entries.length);
        CatalogArchiveMemberPage result;
        foreach (entry; entries[slice.start .. slice.end])
        {
            CatalogArchiveMember member;
            member.referenceId = ReferenceId(sourceToken
                ~ ":archive-reference:" ~ referenceToken ~ ":"
                ~ entry.id.adapterToken);
            member.contentId = entry.contentId;
            member.locator = ContentLocator.entry(container.referenceId, entry.id);
            member.name = entry.name;
            member.relativePath = entry.relativePath;
            member.size = entry.size;
            member.modifiedAt = entry.modifiedAt;
            member.availability = container.availability;
            member.fingerprint = entry.fingerprint;
            result.members ~= member;
            CatalogFile memberFile;
            memberFile.referenceId = member.referenceId;
            memberFile.contentId = member.contentId;
            memberFile.directoryId = container.directoryId;
            memberFile.locator = member.locator;
            memberFile.name = member.name;
            const auto displayContainerPath = container.locator.kind
                == ContentLocator.Kind.filesystem
                ? escapeArchiveVirtualPath(container.relativePath)
                : container.relativePath;
            memberFile.relativePath = appendArchiveVirtualPath(
                displayContainerPath, member.relativePath);
            memberFile.size = member.size;
            memberFile.modifiedAt = member.modifiedAt;
            memberFile.availability = member.availability;
            memberFile.hasArchive = (member.contentId.adapterToken
                in archiveEntriesByToken) !is null;
        }
        result.nextCursor = slice.nextCursor;
        result.hasMore = slice.hasMore;
        return result;
    }

    override CatalogTorrentEntryPage listTorrentEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireOpen();
        if (!capabilities().supportsTorrentEntryQueries)
            throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedFeature,
                "This JSON catalog does not contain torrent file-list details.");
        const auto token = contentId.adapterToken;
        auto entries = token in torrentEntriesByToken;
        if (entries is null)
        {
            if (token !in contentByToken)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Unknown JSON content identity.");
            CatalogTorrentEntryPage empty;
            return empty;
        }
        auto slice = pageSlice(page, sourceToken ~ "\0"
            ~ indexGeneration.to!string ~ "\0torrents\0" ~ token,
            (*entries).length);
        CatalogTorrentEntryPage result;
        result.entries = (*entries)[slice.start .. slice.end];
        result.nextCursor = slice.nextCursor;
        result.hasMore = slice.hasMore;
        return result;
    }

    override RepositoryBlobPage queryBlobs(RepositoryQueryOptions options)
    {
        requireOpen();
        enforce(options.limit > 0, new CatalogBackendException(
            CatalogBackendErrorCode.invalidIdentifier,
            "Blob query limit must be greater than zero."));
        CatalogFilter filter;
        filter.caseSensitive = options.caseSensitive;
        filter.video = options.video;
        filter.audio = options.audio;
        filter.image = options.image;
        filter.text = options.textStream;
        filter.mediaNegated = options.mediaNegated;
        filter.fileType = options.fileType;
        filter.archive = options.archive;
        filter.torrent = options.torrent;

        bool[string] matchedContents;
        foreach (file; fileRows)
        {
            if (!matches(file, filter))
                continue;
            bool matchedPath = options.text.length == 0;
            if (!matchedPath)
            {
                auto path = file.relativePath;
                auto text = options.text;
                if (!options.caseSensitive)
                {
                    path = path.toLower;
                    text = text.toLower;
                }
                matchedPath = path.canFind(text);
            }
            if (!matchedPath)
            {
                const auto blobIndex = blobIndexByContentToken.get(
                    file.contentId.adapterToken, size_t.max);
                if (blobIndex != size_t.max)
                {
                    auto blob = catalog.dataArray[blobIndex];
                    matchedPath = blob.checkSums.sha1sum_b64 == options.text;
                }
            }
            if (matchedPath)
                matchedContents[file.contentId.adapterToken] = true;
        }

        size_t[] matchingIndices;
        foreach (token; matchedContents.keys)
            if (auto index = token in blobIndexByContentToken)
                matchingIndices ~= *index;
        matchingIndices.sort;
        if (options.blobIds.length > 0)
        {
            bool[long] wanted;
            foreach (blobId; options.blobIds)
                wanted[blobId] = true;
            size_t[] restricted;
            foreach (index; matchingIndices)
                if ((cast(long) index + 1) in wanted)
                    restricted ~= index;
            matchingIndices = restricted;
        }

        RepositoryBlobPage result;
        result.total = matchingIndices.length;
        size_t start;
        if (options.useCursor)
        {
            while (start < matchingIndices.length
                && cast(long) matchingIndices[start] + 1 <= options.afterBlobId)
                ++start;
        }
        else
            start = options.offset < matchingIndices.length
                ? options.offset : matchingIndices.length;
        const auto end = start + (options.limit < matchingIndices.length - start
            ? options.limit : matchingIndices.length - start);
        foreach (index; matchingIndices[start .. end])
        {
            auto blob = catalog.dataArray[index];
            const auto token = contentTokenForBlobIndex(index);
            auto resultBlob = blob.dup();
            FileSpec[] references;
            foreach (file; fileRows)
                if (file.contentId.adapterToken == token)
                {
                    auto spec = fileSpecByRelativePath[file.relativePath];
                    references ~= new FileSpec(file.relativePath,
                        spec.timeLastModified);
                }
            if (references.length > 0)
                resultBlob.fileSpecs = references;
            result.blobs ~= resultBlob;
            result.blobIds ~= cast(long) index + 1;
            RepositoryBlobFlags flags;
            if (auto content = token in contentByToken)
            {
                flags.hasFileType = (*content).fileType.length > 0;
                flags.hasArchive = (*content).hasArchive;
                flags.hasTorrent = (*content).hasTorrent;
                foreach (stream; (*content).mediaStreams)
                    final switch (stream.kind)
                    {
                    case CatalogMediaKind.image:
                        flags.hasImage = true;
                        break;
                    case CatalogMediaKind.video:
                        flags.hasVideo = true;
                        break;
                    case CatalogMediaKind.audio:
                        flags.hasAudio = true;
                        break;
                    case CatalogMediaKind.text:
                        flags.hasText = true;
                        break;
                    }
                flags.hasMedia = flags.hasImage || flags.hasVideo
                    || flags.hasAudio || flags.hasText;
            }
            result.flags ~= flags;
        }
        result.hasMore = end < matchingIndices.length;
        if (result.hasMore)
            result.nextCursor = cast(long) matchingIndices[end - 1] + 1;
        return result;
    }

    override RepositoryDuplicateGroup[] queryDuplicateGroups(size_t limit = 100)
    {
        requireOpen();
        enforce(limit > 0, new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Duplicate query limit must be greater than zero."));
        long[][string] idsByFingerprint;
        size_t[string] sizeByFingerprint;
        foreach (index, blob; catalog.dataArray)
        {
            if (blob is null || !blob.checkSums.hasDigests
                || blob.getFirstFileName().length == 0)
                continue;
            const auto key = to!string(blob.fileSize) ~ "\0"
                ~ blob.checkSums.md5sum_b64 ~ "\0"
                ~ blob.checkSums.sha1sum_b64 ~ "\0"
                ~ blob.checkSums.xxh64sum_b64;
            idsByFingerprint[key] ~= cast(long) index + 1;
            sizeByFingerprint[key] = cast(size_t) blob.fileSize;
        }
        RepositoryDuplicateGroup[] groups;
        foreach (key, ids; idsByFingerprint)
            if (ids.length > 1)
                groups ~= RepositoryDuplicateGroup(sizeByFingerprint[key], ids);
        groups.sort!((left, right) => left.fileSize < right.fileSize
            || (left.fileSize == right.fileSize
                && left.blobIds[0] < right.blobIds[0]));
        return groups.length > limit ? groups[0 .. limit] : groups;
    }

    private string contentTokenForBlobIndex(size_t blobIndex) const
    {
        foreach (token, index; blobIndexByContentToken)
            if (index == blobIndex)
                return token;
        return "";
    }

    override CatalogExportResult exportSubset(CatalogSubsetQuery query,
        CatalogExportOptions options)
    {
        return exportSubsetControlled(query, options, null, 0);
    }

    override CatalogExportResult exportSubsetControlled(CatalogSubsetQuery query,
        CatalogExportOptions options, OperationControl control,
        ulong operationId)
    {
        requireTreeQueries();
        enforceJsonExportFormat(options);
        enforce(options.outputPath.length > 0, new CatalogBackendException(
            CatalogBackendErrorCode.invalidTarget,
            "A JSON subset export requires an explicit output path."));

        bool cancelled;
        void reportProgress(size_t completed, size_t total)
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
            progress.message = "Writing JSON catalog.";
            control.report(progress);
            cancelled = control.cancellationRequested;
        }
        bool checkCancelled()
        {
            if (control !is null && control.cancellationRequested)
                cancelled = true;
            return cancelled;
        }
        reportProgress(0, 0);
        if (cancelled)
            return CatalogExportResult.init;

        size_t[string] blobByContent;
        NamedBinaryBlob[string] exportedByContent;
        bool[string] includeAllArchiveEntries;
        bool[string] selectedArchiveContainerReferences;
        size_t[][string] selectedArchiveIndexes;
        bool[string] selectedMemberContents;
        bool[string] selectedMemberReferenceTokens;
        JsonMemberExportReference[] selectedMemberPaths;
        size_t selectedMemberReferences;
        void retainMemberReference(CatalogFile member)
        {
            const auto token = member.referenceId.adapterToken;
            if (token !in selectedMemberReferenceTokens)
            {
                selectedMemberReferenceTokens[token] = true;
                ++selectedMemberReferences;
                selectedMemberPaths ~= JsonMemberExportReference(
                    member.contentId.adapterToken, member.relativePath,
                    member.modifiedAt);
            }
            if (member.contentId.isValid)
                selectedMemberContents[member.contentId.adapterToken] = true;
        }
        void selectPhysicalReference(CatalogFile file, size_t blobIndex,
            bool includeAllArchiveMetadata)
        {
            const auto contentToken = file.contentId.adapterToken;
            if (contentToken !in blobByContent)
            {
                blobByContent[contentToken] = blobIndex;
                exportedByContent[contentToken] = catalog.dataArray[blobIndex].dup();
                exportedByContent[contentToken].fileSpecs = [];
            }
            else
                mergeExportMetadata(exportedByContent[contentToken],
                    catalog.dataArray[blobIndex]);
            auto spec = fileSpecByRelativePath[file.relativePath];
            auto exportFileName = spec.fileName;
            if (catalog.dataVersion != DATA_CLASS_VERSION5)
                exportFileName = escapeArchiveVirtualPath(
                    exportFileName.replace('\\', '/'));
            bool alreadySelected;
            foreach (selected; exportedByContent[contentToken].fileSpecs)
                if (selected.fileName == exportFileName)
                    alreadySelected = true;
            if (!alreadySelected)
                exportedByContent[contentToken].fileSpecs ~= new FileSpec(
                    exportFileName, spec.timeLastModified);
            if (includeAllArchiveMetadata)
            {
                includeAllArchiveEntries[contentToken] = true;
                if (file.hasArchive)
                    selectedArchiveContainerReferences[
                        file.referenceId.adapterToken] = true;
            }
        }
        void retainSelectedArchiveEntries(ref ArchiveSpec[] entries,
            string containerToken)
        {
            if (includeAllArchiveEntries.get(containerToken, false))
                return;
            auto selectedIndices = containerToken in selectedArchiveIndexes;
            if (selectedIndices is null)
            {
                entries = [];
                return;
            }
            ArchiveSpec[] retained;
            foreach (index, entry; entries)
            {
                if (entry is null)
                    continue;
                const auto stableIndex = entry.hasIndexIdentity
                    ? entry.entryIndex : index;
                if (!(*selectedIndices).canFind(stableIndex))
                    continue;
                if (entry.nestedEntries !is null
                    && entry.contentIdentity.length > 0)
                    retainSelectedArchiveEntries(entry.nestedEntries,
                        entry.contentIdentity);
                retained ~= entry;
            }
            entries = retained;
        }

        foreach (file; fileRows)
        {
            if (checkCancelled())
                return CatalogExportResult.init;
            if (!matches(file, query.filter)
                || !hasPathPrefix(file.relativePath, query.pathPrefix))
                continue;
            auto blobIndex = blobIndexByRelativePath[file.relativePath];
            selectPhysicalReference(file, blobIndex, true);
        }
        if (query.filter.includeArchiveMembers)
        {
            CatalogFile[string] memberByToken;
            foreach (container; fileRows)
                if (container.hasArchive)
                    foreach (member; archiveMemberFiles(container))
                        memberByToken[member.referenceId.adapterToken] = member;
            foreach (container; fileRows)
            {
                if (checkCancelled())
                    return CatalogExportResult.init;
                if (!container.hasArchive)
                    continue;
                auto blobIndex = blobIndexByRelativePath[container.relativePath];
                foreach (member; archiveMemberFiles(container))
                {
                    if (checkCancelled())
                        return CatalogExportResult.init;
                    if (!matches(member, query.filter)
                        || !hasPathPrefix(member.relativePath, query.pathPrefix))
                        continue;
                    auto current = member;
                    bool first = true;
                    while (true)
                    {
                        const auto parentReference =
                            current.locator.archiveEntry.containerReferenceId;
                        CatalogFile parentContainer;
                        if (parentReference == container.referenceId)
                            parentContainer = container;
                        else if (auto parentMember = parentReference.adapterToken
                            in memberByToken)
                            parentContainer = *parentMember;
                        else
                            throw new CatalogBackendException(
                                CatalogBackendErrorCode.backendFailure,
                                "Could not resolve the archive-member locator chain for export.");

                        auto parentEntries = parentContainer.contentId.adapterToken
                            in archiveEntriesByToken;
                        if (parentEntries is null)
                            throw new CatalogBackendException(
                                CatalogBackendErrorCode.backendFailure,
                                "The archive-member parent index disappeared during export.");
                        bool foundEntry;
                        foreach (entry; *parentEntries)
                            if (entry.id == current.locator.archiveEntry.entryId)
                            {
                                auto selectedIndices = parentContainer.contentId.adapterToken
                                    in selectedArchiveIndexes;
                                if (selectedIndices is null
                                    || !(*selectedIndices).canFind(entry.index))
                                    selectedArchiveIndexes[parentContainer.contentId.adapterToken]
                                        ~= entry.index;
                                foundEntry = true;
                                break;
                            }
                        if (!foundEntry)
                            throw new CatalogBackendException(
                                CatalogBackendErrorCode.backendFailure,
                                "An archive member disappeared during subset export.");

                        retainMemberReference(current);
                        if (first && member.hasArchive && member.contentId.isValid)
                            includeAllArchiveEntries[member.contentId.adapterToken] = true;
                        if (parentContainer.contentId.isValid)
                        {
                            if (current.contentId.isValid)
                                selectedMemberContents[current.contentId.adapterToken] = true;
                        }
                        if (parentContainer.referenceId == container.referenceId)
                        {
                            selectPhysicalReference(container, blobIndex, false);
                            break;
                        }
                        current = parentContainer;
                        first = false;
                    }
                }
            }
        }
        if (options.includeContentDetails && options.includeArchiveEntries)
            foreach (container; fileRows)
                if (container.hasArchive && container.referenceId.adapterToken
                    in selectedArchiveContainerReferences)
                    foreach (member; archiveMemberFiles(container))
                        retainMemberReference(member);
        if (selectedMemberReferences > 0
            && (!options.includeContentDetails || !options.includeArchiveEntries))
            throw new CatalogBackendException(
                CatalogBackendErrorCode.unsupportedFeature,
                "Archive-member subset export requires archive content details.");

        NamedBinaryBlob[] exportedBlobs;
        CatalogExportResult result;
        const size_t exportTotal = blobByContent.length;
        reportProgress(0, exportTotal);
        if (cancelled)
            return result;
        foreach (contentToken; blobByContent.keys)
        {
            if (checkCancelled())
                return result;
            auto exportBlob = exportedByContent[contentToken];
            result.referencesExported += exportBlob.fileSpecs.length;
            if (!options.includeContentDetails)
            {
                exportBlob.checkSums = typeof(exportBlob.checkSums).init;
                exportBlob.fileType = "";
                exportBlob.mediaInfoSig = null;
                exportBlob.archiveSpecs = null;
                exportBlob.archivePassword = "";
                exportBlob.torrentInfo = null;
            }
            else
            {
                if (!options.includeArchiveEntries)
                    exportBlob.archiveSpecs = null;
                else if (query.filter.includeArchiveMembers)
                    retainSelectedArchiveEntries(exportBlob.archiveSpecs,
                        contentToken);
                if (!options.includeTorrentEntries && exportBlob.torrentInfo !is null)
                {
                    exportBlob.torrentInfo = exportBlob.torrentInfo.dup;
                    exportBlob.torrentInfo.files = [];
                }
            }
            exportedBlobs ~= exportBlob;
        }
        foreach (reference; selectedMemberPaths)
        {
            const auto contentToken = reference.contentToken;
            if (contentToken.length == 0)
                continue;
            if (contentToken !in blobByContent)
            {
                auto blobIndex = blobIndexByContentToken.get(contentToken,
                    size_t.max);
                if (blobIndex == size_t.max)
                    continue;
                blobByContent[contentToken] = blobIndex;
                exportedByContent[contentToken] = catalog.dataArray[blobIndex].dup();
                exportedByContent[contentToken].fileSpecs = [];
                exportedBlobs ~= exportedByContent[contentToken];
            }
            auto exportBlob = exportedByContent[contentToken];
            if (auto memberBlobIndex = contentToken
                in blobIndexByContentToken)
            {
                auto retainedSpecs = exportBlob.fileSpecs;
                mergeExportMetadata(exportBlob,
                    catalog.dataArray[*memberBlobIndex]);
                exportBlob.fileSpecs = retainedSpecs;
            }
            bool alreadySelected;
            foreach (spec; exportBlob.fileSpecs)
                if (spec !is null && spec.fileName == reference.relativePath)
                    alreadySelected = true;
            if (!alreadySelected)
            {
                exportBlob.fileSpecs ~= new FileSpec(reference.relativePath,
                    reference.modifiedAt);
                ++result.referencesExported;
            }
        }
        auto exported = NamedBinaryBlobCatalog(DATA_CLASS_VERSION5,
            exportedBlobs);
        reportProgress(exportTotal, exportTotal);
        if (cancelled)
            return result;
        const bool committed = commitJsonCatalog(options.outputPath, exported,
            () {
                reportProgress(exportTotal, exportTotal);
                return cancelled;
            });
        if (!committed)
        {
            if (cancelled)
                return result;
            throw new CatalogBackendException(
                CatalogBackendErrorCode.backendFailure,
                "Could not publish the JSON subset export.");
        }
        result.contentsExported = exportedBlobs.length;
        foreach (contentToken; selectedMemberContents.keys)
            if (contentToken !in blobByContent)
                ++result.contentsExported;
        result.outputPath = canonicalPath(options.outputPath);
        result.committed = true;
        return result;
    }

    override void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init)
    {
        requireOpen();
        throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedOperation,
            "JSON catalogs cannot import into themselves through this adapter.");
    }

    override bool importJsonControlled(string jsonPath, JsonImportOptions options,
        OperationControl control, ulong operationId)
    {
        importJson(jsonPath, options);
        return true;
    }

    override OperationResult runOperation(ScanOperationRequest request,
        OperationControl control)
    {
        requireTarget(request.target, OperationKind.scan);
        if (!capabilities().supports(OperationKind.scan))
            throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedOperation,
                "JSON scanning requires a filesystem root bound to the backend.");
        return executeAndRefresh(request, control);
    }

    override OperationResult runOperation(MetadataOperationRequest request,
        OperationControl control)
    {
        requireTarget(request.target, OperationKind.metadata);
        throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedOperation,
            "Standalone metadata operations are not supported for JSON catalogs.");
    }

    override OperationResult runOperation(AnalysisOperationRequest request,
        OperationControl control)
    {
        requireTarget(request.target, OperationKind.analyze);
        return executeAndRefresh(request, control);
    }

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

private:
    void requireOpen() const
    {
        if (closed)
            throw new CatalogBackendException(CatalogBackendErrorCode.closed,
                "JSON catalog backend is closed.");
    }

    void requireTreeQueries() const
    {
        requireOpen();
        if (catalogLoadError.length > 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                "Could not read JSON catalog: " ~ catalogLoadError);
        if (!treeQueriesAvailable)
            throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedFeature,
                "JSON tree queries require a bound root and root-contained references.");
    }

    void requireTarget(OperationTarget request, OperationKind operation) const
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

    OperationResult executeAndRefresh(ScanOperationRequest request,
        OperationControl control)
    {
        auto result = dosierskanilo.operationrunner.runOperation(request, control);
        if (result.changesCommitted)
            reloadCatalog();
        return result;
    }

    OperationResult executeAndRefresh(AnalysisOperationRequest request,
        OperationControl control)
    {
        auto result = dosierskanilo.operationrunner.runOperation(request, control);
        if (result.changesCommitted)
            reloadCatalog();
        return result;
    }

    void reloadCatalog()
    {
        try
            catalog = deserializeDataClassJsonWrapperFile(backendTarget.catalogPath);
        catch (Exception failure)
            throw new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                "JSON operation committed but its output could not be reloaded: "
                ~ failure.msg);
        catalogLoadError = "";
        rebuildIndex();
    }

    string canonicalPath(string path) const
    {
        return buildNormalizedPath(absolutePath(path)).replace('\\', '/');
    }

    void enforceJsonTarget(OperationTarget target) const
    {
        if (target.mode != OperationStorageMode.jsonCatalog
            || target.catalogPath.length == 0 || target.repositoryRoot.length > 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidTarget,
                "JSON backend requires an explicit JSON catalog target.");
    }

    void enforceJsonExportFormat(CatalogExportOptions options) const
    {
        if (options.format != CatalogExportFormat.jsonV5)
            throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedFeature,
                "JSON catalog adapter exports version 5 only.");
    }

    void mergeExportMetadata(ref NamedBinaryBlob target, NamedBinaryBlob candidate)
    {
        if (!target.checkSums.hasDigests && candidate.checkSums.hasDigests)
            target.checkSums = candidate.checkSums;
        if (target.fileType.length == 0)
            target.fileType = candidate.fileType;
        if ((target.mediaInfoSig is null || target.mediaInfoSig.empty)
            && candidate.mediaInfoSig !is null)
            target.mediaInfoSig = candidate.mediaInfoSig.dup;
        if (target.archiveSpecs is null && candidate.archiveSpecs !is null)
            target.archiveSpecs = candidate.archiveSpecs.dup;
        target.archiveIndexKnown = target.archiveIndexKnown
            || candidate.archiveIndexKnown;
        if (target.archivePassword.length == 0)
            target.archivePassword = candidate.archivePassword;
        if (target.torrentInfo is null && candidate.torrentInfo !is null)
            target.torrentInfo = candidate.torrentInfo.dup;
    }

    JsonLocation resolvePath(string fileName, bool parseVirtual = false) const
    {
        JsonLocation result;
        auto input = fileName.replace('\\', '/');
        auto physicalInput = input;
        if (parseVirtual)
        {
            auto parsed = parseArchiveVirtualPath(input);
            physicalInput = parsed.physicalPath;
            result.isVirtual = parsed.isVirtual;
            result.virtualEntries = parsed.entries;
        }
        string normalizedPhysical;
        string prefix;
        string physicalRelative;
        if (sourceRoot.length == 0)
        {
            normalizedPhysical = buildNormalizedPath(physicalInput).replace('\\', '/');
            physicalRelative = normalizedPhysical;
            result.physicalRelativePath = physicalRelative;
            result.isInSourceRoot = false;
            result.relativePath = escapeArchiveVirtualPath(physicalRelative);
            foreach (entry; result.virtualEntries)
                result.relativePath = appendArchiveVirtualPath(result.relativePath,
                    entry.relativePath, entry.hasOccurrence ? entry.occurrence
                        : size_t.max);
            result.identityKey = "unbound:" ~ result.relativePath;
            return result;
        }

        normalizedPhysical = isAbsolute(physicalInput)
            ? buildNormalizedPath(physicalInput).replace('\\', '/')
            : buildNormalizedPath(buildPath(sourceRoot, physicalInput)).replace('\\', '/');
        prefix = sourceRoot == "/" ? "/" : sourceRoot ~ "/";
        if (!normalizedPhysical.startsWith(prefix))
        {
            result.identityKey = "outside:" ~ normalizedPhysical;
            return result;
        }
        physicalRelative = normalizedPhysical[prefix.length .. $];
        try
            ContentLocator.file(physicalRelative);
        catch (CatalogBackendException)
        {
            result.identityKey = "outside:" ~ normalizedPhysical;
            return result;
        }
        result.relativePath = escapeArchiveVirtualPath(physicalRelative);
        result.physicalRelativePath = physicalRelative;
        foreach (entry; result.virtualEntries)
            result.relativePath = appendArchiveVirtualPath(result.relativePath,
                entry.relativePath, entry.hasOccurrence ? entry.occurrence
                    : size_t.max);
        result.identityKey = result.relativePath;
        result.isInSourceRoot = true;
        return result;
    }

    string strongFingerprintKey(NamedBinaryBlob blob,
        CatalogContentFingerprint fingerprint) const
    {
        if (!fingerprint.complete)
            return "";
        return "fingerprint:" ~ blob.fileSize.to!string ~ ":"
            ~ blob.checkSums.md5sum_b64 ~ ":" ~ blob.checkSums.sha1sum_b64
            ~ ":" ~ blob.checkSums.xxh64sum_b64;
    }

    ContentId contentIdFromToken(string token) const
    {
        return ContentId(token);
    }

    CatalogContentFingerprint fingerprintFor(size_t size, CheckSums checksums) const
    {
        CatalogContentFingerprint fingerprint;
        fingerprint.size = size;
        bool digestsValid = true;
        try
        {
            auto md5 = checksums.get_md5sum;
            auto sha1 = checksums.get_sha1sum;
            auto xxh64 = checksums.get_xxh64;
            if (md5.length > 0)
                fingerprint.digests ~= CatalogDigest("md5", md5.dup);
            if (sha1.length > 0)
                fingerprint.digests ~= CatalogDigest("sha1", sha1.dup);
            if (xxh64.length > 0)
                fingerprint.digests ~= CatalogDigest("xxh64", xxh64.dup);
            digestsValid = md5.length == 16 && sha1.length == 20
                && xxh64.length == 8;
        }
        catch (Exception)
            digestsValid = false;
        fingerprint.complete = checksums.hasDigests && digestsValid;
        return fingerprint;
    }

    CatalogContentFingerprint fingerprintFor(NamedBinaryBlob blob) const
    {
        return fingerprintFor(blob.fileSize, blob.checkSums);
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

    CatalogContentSnapshot snapshotFor(NamedBinaryBlob blob, ContentId contentId) const
    {
        CatalogContentSnapshot result;
        result.id = contentId;
        result.fingerprint = fingerprintFor(blob);
        result.fileType = blob.fileType;
        result.mediaStreams = mediaStreamsFor(blob);
        auto indexedArchiveEntries = contentId.adapterToken in archiveEntriesByToken;
        const bool archiveIndexed = blob.archiveIndexKnown
            || blob.archiveSpecs !is null || indexedArchiveEntries !is null;
        result.hasArchive = archiveIndexed;
        result.hasTorrent = blob.torrentInfo !is null;
        result.archiveSummary.indexKnown = archiveIndexed;
        if (indexedArchiveEntries !is null)
        {
            result.archiveSummary.entryCount = (*indexedArchiveEntries).length;
            foreach (entry; *indexedArchiveEntries)
                if (entry.fingerprint.complete)
                    result.archiveSummary.entriesWithCompleteFingerprints++;
        }
        else if (blob.archiveSpecs !is null)
        {
            result.archiveSummary.entryCount = blob.archiveSpecs.length;
            foreach (entry; blob.archiveSpecs)
                if (entry !is null
                    && fingerprintFor(cast(size_t) entry.fileSize,
                        entry.checkSums).complete)
                    result.archiveSummary.entriesWithCompleteFingerprints++;
        }
        if (blob.torrentInfo !is null)
        {
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
        checksumStatus.state = result.fingerprint.complete
            ? CatalogExtractorState.completed
            : (blob.checkSums.hasDigests ? CatalogExtractorState.failed
                : CatalogExtractorState.notRequested);
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
        if (!archiveIndexed)
            archiveStatus.state = CatalogExtractorState.notRequested;
        else if (result.archiveSummary.entryCount == 0)
            archiveStatus.state = CatalogExtractorState.empty;
        else
            archiveStatus.state = CatalogExtractorState.completed;
        result.extractors ~= archiveStatus;
        CatalogExtractorStatus torrentStatus;
        torrentStatus.extractor = "torrents";
        torrentStatus.state = blob.torrentInfo is null
            ? CatalogExtractorState.notRequested : CatalogExtractorState.completed;
        result.extractors ~= torrentStatus;
        return result;
    }

    /** Drop every derived index and disable tree queries until a rebuild. */
    void clearIndex()
    {
        fileRows = [];
        directoryRows = [];
        sizeAscendingOrder = null;
        sizeDescendingOrder = null;
        archiveMemberRowsByDirectory = null;
        contentByToken = null;
        archiveEntriesByToken = null;
        torrentEntriesByToken = null;
        blobIndexByRelativePath = null;
        blobIndexByContentToken = null;
        fileSpecByRelativePath = null;
        directoryIndexByPath = null;
        treeQueriesAvailable = false;
        torrentEntryDetailsUnavailable = false;
    }

    void rebuildIndex()
    {
        clearIndex();
        treeQueriesAvailable = sourceRoot.length > 0;
        bool[string] seenPaths;
        bool[string] seenReferencePaths;
        string[string] v5ContentTokenByPath;
        V5JsonReference[] v5References;
        ++indexGeneration;

        foreach (blobIndex, blob; catalog.dataArray)
        {
            if (blob is null)
                continue;
            JsonLocation[] locations;
            string[] pathKeys;
            foreach (spec; blob.fileSpecs)
            {
                if (spec is null || spec.fileName.length == 0)
                    continue;
                auto location = resolvePath(spec.fileName,
                    catalog.dataVersion == DATA_CLASS_VERSION5);
                location.spec = spec;
                locations ~= location;
                pathKeys ~= location.identityKey;
                seenPaths[location.identityKey] = true;
                if (sourceRoot.length > 0 && !location.isInSourceRoot)
                    treeQueriesAvailable = false;
            }
            if (locations.length == 0)
            {
                auto legacyPath = blob.getFirstFileName;
                if (legacyPath.length > 0)
                {
                    auto location = resolvePath(legacyPath,
                        catalog.dataVersion == DATA_CLASS_VERSION5);
                    location.spec = new FileSpec(legacyPath, blob.timeLastModified);
                    locations ~= location;
                    pathKeys ~= location.identityKey;
                    seenPaths[location.identityKey] = true;
                    if (sourceRoot.length > 0 && !location.isInSourceRoot)
                        treeQueriesAvailable = false;
                }
            }

            auto fingerprint = fingerprintFor(blob);
            auto strongKey = strongFingerprintKey(blob, fingerprint);
            auto contentToken = contentTokenFor(blob, pathKeys, strongKey, blobIndex);
            if (contentToken !in blobIndexByContentToken)
                blobIndexByContentToken[contentToken] = blobIndex;
            auto contentId = contentIdFromToken(contentToken);
            if (auto existing = contentToken in contentByToken)
                mergeContentSnapshot(*existing, snapshotFor(blob, contentId));
            else
                contentByToken[contentToken] = snapshotFor(blob, contentId);
            indexArchiveAndTorrent(blob, contentToken);
            if (blob.torrentInfo !is null && blob.torrentInfo.files is null)
                torrentEntryDetailsUnavailable = true;

            foreach (location; locations)
            {
                if (catalog.dataVersion == DATA_CLASS_VERSION5)
                    v5ContentTokenByPath[location.relativePath] = contentToken;
                if (location.isVirtual)
                {
                    V5JsonReference reference;
                    reference.relativePath = location.relativePath;
                    reference.physicalRelativePath = location.physicalRelativePath;
                    reference.contentToken = contentToken;
                    reference.entries = location.virtualEntries;
                    reference.size = cast(ulong) blob.fileSize;
                    reference.modifiedAt = location.spec.timeLastModified;
                    v5References ~= reference;
                    continue;
                }
                if (!location.isInSourceRoot)
                    continue;
                seenReferencePaths[location.relativePath] = true;
                if (auto previousIndex = location.relativePath
                    in blobIndexByRelativePath)
                {
                    if (*previousIndex != blobIndex)
                        treeQueriesAvailable = false;
                    continue;
                }
                addFileReference(blob, location.spec, location, contentId, blobIndex);
            }
        }
        if (catalog.dataVersion == DATA_CLASS_VERSION5)
            indexV5ArchiveReferences(v5References, v5ContentTokenByPath);
        prunePathMap(contentTokenByPath, seenPaths);
        prunePathMap(oldFingerprintByPath, seenPaths);
        prunePathMap(oldSizeByPath, seenPaths);
        prunePathMap(referenceTokenByPath, seenReferencePaths);
        fileRows.sort!((left, right) => left.relativePath < right.relativePath);
        directoryRows.sort!((left, right) => left.relativePath < right.relativePath);
    }

    void prunePathMap(T)(ref T[string] values, bool[string] retained)
    {
        string[] removed;
        foreach (key; values.keys)
            if (key !in retained)
                removed ~= key;
        foreach (key; removed)
            values.remove(key);
    }

    void indexV5ArchiveReferences(V5JsonReference[] references,
        string[string] contentByPath)
    {
        foreach (reference; references)
        {
            if (reference.entries.length == 0)
                continue;
            auto parentPath = escapeArchiveVirtualPath(
                reference.physicalRelativePath);
            foreach (entry; reference.entries[0 .. $ - 1])
                parentPath = appendArchiveVirtualPath(parentPath,
                    entry.relativePath, entry.hasOccurrence ? entry.occurrence
                        : size_t.max);
            auto parentToken = parentPath in contentByPath;
            if (parentToken is null)
                continue;

            auto entries = archiveEntriesByToken.get(*parentToken, []);
            const auto finalLayer = reference.entries[$ - 1];
            const auto occurrence = finalLayer.hasOccurrence
                ? finalLayer.occurrence : 0;
            bool alreadyIndexed;
            foreach (existing; entries)
                if (existing.relativePath == finalLayer.relativePath
                    && existing.occurrence == occurrence)
                {
                    alreadyIndexed = true;
                    break;
                }
            if (alreadyIndexed)
                continue;
            CatalogArchiveEntry entry;
            entry.id = ArchiveEntryId(*parentToken ~ ":v5:"
                ~ finalLayer.relativePath ~ ":" ~ occurrence.to!string);
            entry.name = finalLayer.relativePath;
            entry.relativePath = finalLayer.relativePath;
            entry.index = entries.length;
            entry.occurrence = occurrence;
            entry.hasSafePath = true;
            entry.size = reference.size;
            entry.modifiedAt = reference.modifiedAt;
            entry.contentId = contentIdFromToken(reference.contentToken);
            if (auto content = reference.contentToken in contentByToken)
                entry.fingerprint = (*content).fingerprint;
            entries ~= entry;
            archiveEntriesByToken[*parentToken] = entries;

            if (auto parentContent = *parentToken in contentByToken)
            {
                parentContent.hasArchive = true;
                parentContent.archiveSummary.indexKnown = true;
                parentContent.archiveSummary.entryCount = entries.length;
                parentContent.archiveSummary.entriesWithCompleteFingerprints = 0;
                foreach (indexedEntry; entries)
                    if (indexedEntry.fingerprint.complete)
                        ++parentContent.archiveSummary.entriesWithCompleteFingerprints;
            }
            foreach (ref file; fileRows)
                if (file.contentId.adapterToken == *parentToken)
                    file.hasArchive = true;
        }
    }

    void mergeContentSnapshot(ref CatalogContentSnapshot current,
        CatalogContentSnapshot candidate)
    {
        if (!current.fingerprint.complete && candidate.fingerprint.complete)
            current.fingerprint = candidate.fingerprint;
        if (current.fileType.length == 0)
            current.fileType = candidate.fileType;
        if (current.mediaStreams.length == 0)
            current.mediaStreams = candidate.mediaStreams;
        current.hasArchive = current.hasArchive || candidate.hasArchive;
        current.hasTorrent = current.hasTorrent || candidate.hasTorrent;
        foreach (status; candidate.extractors)
        {
            bool hasStatus;
            foreach (existing; current.extractors)
                if (existing.extractor == status.extractor)
                    hasStatus = true;
            if (!hasStatus)
                current.extractors ~= status;
        }
    }

    string contentTokenFor(NamedBinaryBlob blob, string[] paths,
        string fingerprint, size_t blobIndex)
    {
        string token;
        if (fingerprint.length > 0)
            if (auto existing = fingerprint in contentTokenByFingerprint)
                token = *existing;

        foreach (path; paths)
        {
            if (token.length > 0)
                break;
            if (auto oldToken = path in contentTokenByPath)
            {
                ulong oldSize = ulong.max;
                if (auto storedSize = path in oldSizeByPath)
                    oldSize = *storedSize;
                string oldFingerprint;
                if (auto storedFingerprint = path in oldFingerprintByPath)
                    oldFingerprint = *storedFingerprint;
                if (oldSize == blob.fileSize
                    && (oldFingerprint.length == 0 || fingerprint.length == 0
                        || oldFingerprint == fingerprint))
                {
                    token = *oldToken;
                    break;
                }
            }
        }
        if (token.length == 0 && paths.length == 0)
        {
            auto key = "orphan:" ~ blobIndex.to!string ~ ":" ~ blob.fileSize.to!string;
            if (auto oldToken = key in contentTokenByFingerprint)
                token = *oldToken;
            else
                token = newContentToken();
            contentTokenByFingerprint[key] = token;
        }
        if (token.length == 0)
            token = newContentToken();
        if (fingerprint.length > 0)
            contentTokenByFingerprint[fingerprint] = token;
        foreach (path; paths)
        {
            contentTokenByPath[path] = token;
            oldFingerprintByPath[path] = fingerprint;
            oldSizeByPath[path] = blob.fileSize;
        }
        return token;
    }

    string newContentToken()
    {
        return sourceToken ~ ":content:" ~ (++nextIdentity).to!string;
    }

    string referenceToken(string relativePath)
    {
        if (auto oldToken = relativePath in referenceTokenByPath)
            return *oldToken;
        auto token = sourceToken ~ ":reference:" ~ (++nextIdentity).to!string;
        referenceTokenByPath[relativePath] = token;
        return token;
    }

    void indexArchiveAndTorrent(NamedBinaryBlob blob, string contentToken)
    {
        if (blob.archiveIndexKnown && blob.archiveSpecs is null)
            archiveEntriesByToken[contentToken] = [];
        else
            indexArchiveSpecs(blob.archiveSpecs, contentToken);
        if (blob.torrentInfo !is null)
        {
            if (contentToken !in torrentEntriesByToken)
                torrentEntriesByToken[contentToken] = [];
            foreach (entry; blob.torrentInfo.files)
                if (entry !is null)
                {
                    bool alreadyIndexed;
                    if (auto existingEntries = contentToken in torrentEntriesByToken)
                        foreach (existing; *existingEntries)
                            if (existing.pathComponents == entry.path
                                && existing.size == entry.length)
                                alreadyIndexed = true;
                    if (!alreadyIndexed)
                        torrentEntriesByToken[contentToken] ~=
                            CatalogTorrentManifestEntry(entry.path.dup, entry.length);
                }
        }
    }

    void indexArchiveSpecs(ArchiveSpec[] specs, string containerToken,
        size_t depth = 0)
    {
        if (depth >= 32)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.backendFailure,
                "Nested JSON archive index exceeds the maximum depth.");
        if (specs !is null && containerToken !in archiveEntriesByToken)
            archiveEntriesByToken[containerToken] = [];
        size_t[string] occurrences;
        bool[string] indexedEntryIds;
        if (auto existingEntries = containerToken in archiveEntriesByToken)
            foreach (existing; *existingEntries)
                indexedEntryIds[existing.id.adapterToken] = true;
        foreach (index, spec; specs)
        {
            if (spec is null)
                continue;
            bool hasSafePath;
            bool isDirectory;
            auto relativePath = normalizeArchiveEntryPath(spec.fileName,
                hasSafePath, isDirectory);
            const auto identityPath = hasSafePath ? relativePath : spec.fileName;
            auto occurrenceKey = (hasSafePath ? "safe\0" : "unsafe\0")
                ~ identityPath;
            auto occurrence = occurrences.get(occurrenceKey, 0);
            occurrences[occurrenceKey] = occurrence + 1;
            spec.entryIndex = index;
            spec.occurrence = occurrence;
            spec.hasIndexIdentity = true;
            auto entryToken = containerToken ~ ":archive-v1:" ~ occurrenceKey
                ~ ":" ~ occurrence.to!string;

            string memberToken;
            auto fingerprint = fingerprintFor(spec.fileSize, spec.checkSums);
            if (hasSafePath && !isDirectory)
            {
                if (fingerprint.complete)
                {
                    const auto fingerprintKey = "fingerprint:"
                        ~ spec.fileSize.to!string ~ ":" ~ spec.checkSums.md5sum_b64
                        ~ ":" ~ spec.checkSums.sha1sum_b64 ~ ":"
                        ~ spec.checkSums.xxh64sum_b64;
                    if (auto existingToken = fingerprintKey in contentTokenByFingerprint)
                        memberToken = *existingToken;
                    else
                    {
                        memberToken = newContentToken();
                        contentTokenByFingerprint[fingerprintKey] = memberToken;
                    }
                }
                else
                    memberToken = containerToken ~ ":archive-content-v1:"
                        ~ occurrenceKey ~ ":" ~ occurrence.to!string;
            }

            CatalogArchiveEntry entry;
            entry.id = ArchiveEntryId(entryToken);
            entry.name = spec.fileName;
            entry.relativePath = relativePath;
            entry.index = index;
            entry.occurrence = occurrence;
            entry.isDirectory = isDirectory;
            entry.hasSafePath = hasSafePath;
            entry.size = cast(ulong) spec.fileSize;
            entry.modifiedAt = spec.timeLastModified;
            entry.fingerprint = fingerprint;
            if (memberToken.length > 0)
            {
                auto memberId = contentIdFromToken(memberToken);
                spec.contentBlobId = 0;
                spec.contentIdentity = memberToken;
                entry.contentId = memberId;
                auto memberSnapshot = snapshotForArchiveEntry(spec, memberId,
                    fingerprint);
                if (auto existingContent = memberToken in contentByToken)
                    mergeContentSnapshot(*existingContent, memberSnapshot);
                else
                    contentByToken[memberToken] = memberSnapshot;
                if (spec.nestedEntries !is null)
                    indexArchiveSpecs(spec.nestedEntries, memberToken, depth + 1);
            }
            if (entry.id.adapterToken !in indexedEntryIds)
            {
                archiveEntriesByToken[containerToken] ~= entry;
                indexedEntryIds[entry.id.adapterToken] = true;
            }
        }
    }

    CatalogContentSnapshot snapshotForArchiveEntry(ArchiveSpec spec,
        ContentId id, CatalogContentFingerprint fingerprint) const
    {
        CatalogContentSnapshot result;
        result.id = id;
        result.fingerprint = fingerprint;
        result.hasArchive = spec.nestedEntries !is null;
        result.archiveSummary.indexKnown = result.hasArchive;
        result.archiveSummary.entryCount = spec.nestedEntries.length;
        CatalogExtractorStatus checksums;
        checksums.extractor = "checksums";
        checksums.state = fingerprint.complete ? CatalogExtractorState.completed
            : CatalogExtractorState.notRequested;
        result.extractors ~= checksums;
        if (result.hasArchive)
        {
            CatalogExtractorStatus archives;
            archives.extractor = "archives";
            archives.state = spec.nestedEntries.length == 0
                ? CatalogExtractorState.empty : CatalogExtractorState.completed;
            result.extractors ~= archives;
        }
        return result;
    }

    void addDirectory(string relativeDirectory)
    {
        if (relativeDirectory.length == 0 || relativeDirectory == ".")
            return;
        string current;
        DirectoryId parent;
        foreach (part; relativeDirectory.split("/"))
        {
            current = current.length == 0 ? part : current ~ "/" ~ part;
            size_t index;
            if (auto existing = current in directoryIndexByPath)
                index = *existing;
            else
            {
                CatalogDirectory directory;
                directory.id = DirectoryId(sourceToken ~ ":directory:" ~ current);
                directory.parentId = parent;
                directory.name = part;
                directory.relativePath = current;
                index = directoryRows.length;
                directoryRows ~= directory;
                directoryIndexByPath[current] = index;
                if (parent.isValid)
                {
                    auto parentIndex = directoryIndexByPath[parentPath(current)];
                    directoryRows[parentIndex].childDirectoryCount++;
                }
            }
            parent = directoryRows[index].id;
        }
    }

    string parentPath(string path) const
    {
        auto parent = dirName(path);
        return parent == "." ? "" : parent;
    }

    void addFileReference(NamedBinaryBlob blob, FileSpec spec,
        JsonLocation location, ContentId contentId, size_t blobIndex)
    {
        if (auto existingIndex = location.relativePath in blobIndexByRelativePath)
        {
            const auto oldToken = fileRows[*existingIndex].contentId.adapterToken;
            if (oldToken != contentId.adapterToken)
                treeQueriesAvailable = false;
            return;
        }
        auto parent = parentPath(location.relativePath);
        addDirectory(parent);
        DirectoryId directoryId;
        if (parent.length > 0)
            directoryId = directoryRows[directoryIndexByPath[parent]].id;
        CatalogFile row;
        row.referenceId = ReferenceId(referenceToken(location.relativePath));
        row.contentId = contentId;
        row.directoryId = directoryId;
        row.locator = ContentLocator.file(location.physicalRelativePath);
        row.name = baseName(location.physicalRelativePath);
        row.relativePath = location.relativePath;
        row.size = cast(ulong) blob.fileSize;
        row.modifiedAt = spec.timeLastModified;
        row.availability = exists(buildPath(sourceRoot,
            location.physicalRelativePath))
            ? CatalogReferenceAvailability.available
            : CatalogReferenceAvailability.unavailable;
        row.hasFileType = blob.fileType.length > 0;
        row.hasMedia = blob.mediaInfoSig !is null && !blob.mediaInfoSig.empty;
        row.hasVideo = blob.mediaInfoSig !is null
            && blob.mediaInfoSig.videoStreams.length > 0;
        row.hasAudio = blob.mediaInfoSig !is null
            && blob.mediaInfoSig.audioStreams.length > 0;
        row.hasImage = blob.mediaInfoSig !is null
            && blob.mediaInfoSig.imageStreams.length > 0;
        row.hasText = blob.mediaInfoSig !is null
            && blob.mediaInfoSig.textStreams.length > 0;
        row.hasArchive = blob.archiveIndexKnown || blob.archiveSpecs !is null;
        row.hasTorrent = blob.torrentInfo !is null;
        fileRows ~= row;
        blobIndexByRelativePath[location.relativePath] = blobIndex;
        fileSpecByRelativePath[location.relativePath] = spec;
        if (parent.length > 0)
        {
            auto parentIndex = directoryIndexByPath[parent];
            directoryRows[parentIndex].fileCount++;
        }
        auto path = parent;
        while (path.length > 0)
        {
            auto index = directoryIndexByPath[path];
            directoryRows[index].aggregateSize += row.size;
            path = parentPath(path);
        }
    }

    void refreshAvailability(ref CatalogFile file) const
    {
        if (file.locator.kind != ContentLocator.Kind.filesystem)
            return;
        file.availability = exists(buildPath(sourceRoot,
            file.locator.filesystem.relativePath))
            ? CatalogReferenceAvailability.available
            : CatalogReferenceAvailability.unavailable;
    }

    ArchiveMemberRows* archiveMemberRows(DirectoryId directoryId)
    {
        const key = directoryId.adapterToken;
        if (auto cached = key in archiveMemberRowsByDirectory)
            return cached;
        ArchiveMemberRows rows;
        size_t expectedMembers;
        foreach (containerRow, container; fileRows)
            if (container.directoryId == directoryId)
            {
                const auto contentToken = container.contentId.adapterToken;
                if (auto entries = contentToken in archiveEntriesByToken)
                    expectedMembers += (*entries).length;
            }
        rows.rows.reserve(expectedMembers);
        foreach (containerRow, container; fileRows)
            if (container.directoryId == directoryId)
            {
                auto freshContainer = container;
                refreshAvailability(freshContainer);
                foreach (member; archiveMemberFiles(freshContainer))
                    rows.rows ~= ArchiveMemberRow(member, containerRow);
            }
        rows.rows.sort!((left, right) =>
            left.file.relativePath < right.file.relativePath);
        rows.sizeAscending.length = rows.rows.length;
        rows.sizeDescending.length = rows.rows.length;
        foreach (index; 0 .. rows.rows.length)
        {
            rows.sizeAscending[index] = index;
            rows.sizeDescending[index] = index;
        }
        rows.sizeAscending.sort!((left, right) {
            const leftFile = rows.rows[left].file;
            const rightFile = rows.rows[right].file;
            return leftFile.size < rightFile.size
                || (leftFile.size == rightFile.size
                    && leftFile.relativePath < rightFile.relativePath);
        });
        rows.sizeDescending.sort!((left, right) {
            const leftFile = rows.rows[left].file;
            const rightFile = rows.rows[right].file;
            return leftFile.size > rightFile.size
                || (leftFile.size == rightFile.size
                    && leftFile.relativePath < rightFile.relativePath);
        });
        archiveMemberRowsByDirectory[key] = rows;
        return key in archiveMemberRowsByDirectory;
    }

    static bool fileBefore(in CatalogFile left, in CatalogFile right,
        CatalogSortOrder sortOrder)
    {
        final switch (sortOrder)
        {
        case CatalogSortOrder.pathAscending:
            return left.relativePath < right.relativePath;
        case CatalogSortOrder.pathDescending:
            return left.relativePath > right.relativePath;
        case CatalogSortOrder.sizeAscending:
            return left.size < right.size
                || (left.size == right.size
                    && left.relativePath < right.relativePath);
        case CatalogSortOrder.sizeDescending:
            return left.size > right.size
                || (left.size == right.size
                    && left.relativePath < right.relativePath);
        }
    }

    void forEachFileCandidate(CatalogFileQuery query,
        scope void delegate(ref CatalogFile file, size_t containerRow) sink)
    {
        auto rows = archiveMemberRows(query.directoryId);
        const physicalCount = fileRows.length;
        const memberCount = rows.rows.length;
        size_t physicalPosition;
        size_t memberPosition;
        while (physicalPosition < physicalCount || memberPosition < memberCount)
        {
            bool takePhysical;
            if (memberPosition >= memberCount)
                takePhysical = true;
            else if (physicalPosition >= physicalCount)
                takePhysical = false;
            else
            {
                const physicalIndex = fileOrderIndex(query.sortOrder,
                    physicalPosition);
                const memberIndex = memberOrderIndex(*rows, query.sortOrder,
                    memberPosition);
                takePhysical = !fileBefore(rows.rows[memberIndex].file,
                    fileRows[physicalIndex], query.sortOrder);
            }

            if (takePhysical)
            {
                auto index = fileOrderIndex(query.sortOrder, physicalPosition++);
                auto file = fileRows[index];
                if (file.directoryId != query.directoryId
                    || !matches(file, query.filter))
                    continue;
                sink(file, size_t.max);
            }
            else
            {
                auto index = memberOrderIndex(*rows, query.sortOrder,
                    memberPosition++);
                auto row = rows.rows[index];
                if (!matches(row.file, query.filter))
                    continue;
                auto file = row.file;
                sink(file, row.containerRow);
            }
        }
    }

    static size_t memberOrderIndex(in ArchiveMemberRows rows,
        CatalogSortOrder sortOrder, size_t position)
    {
        final switch (sortOrder)
        {
        case CatalogSortOrder.pathAscending:
            return position;
        case CatalogSortOrder.pathDescending:
            return rows.rows.length - 1 - position;
        case CatalogSortOrder.sizeAscending:
            return rows.sizeAscending[position];
        case CatalogSortOrder.sizeDescending:
            return rows.sizeDescending[position];
        }
    }

    CatalogDirectory[] matchingDirectories(CatalogDirectoryQuery query)
    {
        CatalogDirectory[] result;
        const auto activeFilter = hasActiveFilter(query.filter);
        foreach (directory; directoryRows)
        {
            if (directory.parentId != query.parentId)
                continue;
            if (activeFilter && !directoryHasMatch(directory.relativePath, query.filter))
                continue;
            result ~= directory;
        }
        result.sort!((left, right) => left.relativePath < right.relativePath);
        return result;
    }

    bool directoryHasMatch(string directoryPath, CatalogFilter filter)
    {
        const prefix = directoryPath ~ "/";
        const start = lowerBoundPath(prefix);
        /* "dir0" is the tight upper bound for "dir/" plus any byte suffix, and
         * unlike prefix ~ "\uFFFF" it also includes non-BMP UTF-8 paths. */
        const end = lowerBoundPath(directoryPath ~ "0");
        foreach (index; start .. end)
        {
            auto file = fileRows[index];
            if (matches(file, filter))
                return true;
        }
        if (filter.includeArchiveMembers)
            foreach (index; start .. end)
            {
                auto container = fileRows[index];
                if (container.hasArchive)
                    foreach (member; archiveMemberFiles(container))
                        if (matches(member, filter))
                            return true;
            }
        return false;
    }

    size_t lowerBoundPath(string path) const
    {
        size_t low;
        size_t high = fileRows.length;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            if (fileRows[middle].relativePath < path)
                low = middle + 1;
            else
                high = middle;
        }
        return low;
    }

    CatalogFile[] archiveMemberFiles(CatalogFile container)
    {
        bool[string] activeContents;
        return archiveMemberFiles(container, 0, activeContents);
    }

    private CatalogFile[] archiveMemberFiles(CatalogFile container, size_t depth,
        ref bool[string] activeContents)
    {
        CatalogFile[] result;
        if (!container.hasArchive || depth >= 32)
            return result;
        const auto contentToken = container.contentId.adapterToken;
        if (contentToken in activeContents)
            return result;
        activeContents[contentToken] = true;
        scope (exit)
            activeContents.remove(contentToken);
        auto entries = contentToken in archiveEntriesByToken;
        if (entries is null)
            return result;
        size_t[string] occurrenceCounts;
        foreach (entry; *entries)
            occurrenceCounts[entry.relativePath] = occurrenceCounts.get(entry.relativePath, 0) + 1;
        foreach (entry; *entries)
        {
            if (!entry.hasSafePath || entry.isDirectory || !entry.contentId.isValid)
                continue;
            CatalogFile member;
            member.referenceId = ReferenceId(sourceToken
                ~ ":archive-reference:" ~ container.referenceId.adapterToken ~ ":"
                ~ entry.id.adapterToken);
            member.contentId = entry.contentId;
            member.directoryId = container.directoryId;
            member.locator = ContentLocator.entry(container.referenceId, entry.id);
            member.name = baseName(entry.relativePath);
            const auto displayContainerPath = container.locator.kind
                == ContentLocator.Kind.filesystem
                ? escapeArchiveVirtualPath(container.relativePath)
                : container.relativePath;
            const samePathCount = occurrenceCounts.get(entry.relativePath, 1);
            member.relativePath = appendArchiveVirtualPath(displayContainerPath,
                entry.relativePath, samePathCount > 1 ? entry.occurrence
                    : size_t.max);
            member.size = entry.size;
            member.modifiedAt = entry.modifiedAt;
            member.availability = container.availability;
            if (auto content = entry.contentId.adapterToken in contentByToken)
            {
                member.hasFileType = (*content).fileType.length > 0;
                member.hasVideo = (*content).mediaStreams.canFind!((stream) =>
                    stream.kind == CatalogMediaKind.video);
                member.hasAudio = (*content).mediaStreams.canFind!((stream) =>
                    stream.kind == CatalogMediaKind.audio);
                member.hasImage = (*content).mediaStreams.canFind!((stream) =>
                    stream.kind == CatalogMediaKind.image);
                member.hasText = (*content).mediaStreams.canFind!((stream) =>
                    stream.kind == CatalogMediaKind.text);
                member.hasMedia = member.hasVideo || member.hasAudio
                    || member.hasImage || member.hasText;
            member.hasArchive = (*content).hasArchive;
            member.hasTorrent = (*content).hasTorrent;
            }
            result ~= member;
            if (member.hasArchive)
                result ~= archiveMemberFiles(member, depth + 1, activeContents);
        }
        return result;
    }

    bool directoryVisible(CatalogDirectory directory, CatalogFilter filter)
    {
        return !hasActiveFilter(filter)
            || directoryHasMatch(directory.relativePath, filter);
    }

    bool matches(CatalogFile file, CatalogFilter filter) const
    {
        auto path = file.relativePath;
        auto text = filter.pathText;
        if (text.length > 0)
        {
            if (!filter.caseSensitive)
            {
                path = path.toLower;
                text = text.toLower;
            }
            if (!path.canFind(text))
                return false;
        }
        if (filter.availableOnly
            && file.availability != CatalogReferenceAvailability.available)
            return false;
        const bool hasMediaFilter = filter.video || filter.audio || filter.image || filter.text;
        if (hasMediaFilter)
        {
            const bool hasSelectedMedia = (filter.video && file.hasVideo)
                || (filter.audio && file.hasAudio) || (filter.image && file.hasImage)
                || (filter.text && file.hasText);
            if (filter.mediaNegated ? hasSelectedMedia : !hasSelectedMedia)
                return false;
        }
        const bool hasTypeFilter = filter.fileType || filter.archive
            || filter.torrent;
        const bool matchesType = (filter.fileType && file.hasFileType)
            || (filter.archive && file.hasArchive)
            || (filter.torrent && file.hasTorrent);
        return !hasTypeFilter || matchesType;
    }

    bool hasActiveFilter(CatalogFilter filter) const
    {
        return filter.pathText.length > 0 || filter.video || filter.audio
            || filter.image || filter.text || filter.fileType || filter.archive
            || filter.torrent || filter.availableOnly || filter.includeArchiveMembers;
    }

    bool hasPathPrefix(string path, string prefix) const
    {
        return prefix.length == 0 || path == prefix
            || path.startsWith(prefix ~ "/") || path.startsWith(prefix ~ "!/");
    }

    string fileQueryToken(CatalogFileQuery query) const
    {
        return sourceToken ~ "\0" ~ indexGeneration.to!string ~ "\0files\0"
            ~ query.directoryId.adapterToken
            ~ "\0" ~ filterToken(query.filter) ~ "\0"
            ~ (cast(int) query.sortOrder).to!string;
    }

    string directoryQueryToken(CatalogDirectoryQuery query) const
    {
        return sourceToken ~ "\0" ~ indexGeneration.to!string ~ "\0directories\0"
            ~ query.parentId.adapterToken
            ~ "\0" ~ filterToken(query.filter);
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

    CatalogSlice pageSlice(CatalogPageRequest request, string queryToken,
        size_t itemCount) const
    {
        if (request.limit == 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                "Catalog page limit must be greater than zero.");
        auto start = request.cursor.isValid ? request.cursor.adapterIndex : 0;
        if (request.cursor.isValid
            && (request.cursor.adapterQueryToken != queryToken
                || request.cursor.adapterPageSize != request.limit))
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                "Catalog cursor does not match this source, query, or page size.");
        if (start > itemCount)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                "Catalog cursor is outside the result sequence.");
        const auto remaining = itemCount - start;
        auto end = start + (request.limit < remaining ? request.limit : remaining);
        CatalogSlice result;
        result.start = start;
        result.end = end;
        result.hasPrevious = start > 0;
        result.hasMore = end < itemCount;
        if (result.hasPrevious)
            result.previousCursor = CatalogPageCursor(
                start > request.limit ? start - request.limit : 0,
                request.limit, queryToken);
        if (result.hasMore)
            result.nextCursor = CatalogPageCursor(end, request.limit, queryToken);
        return result;
    }

    CatalogFilePage makeFilePage(CatalogFile[] matching, CatalogSlice slice) const
    {
        CatalogFilePage result;
        result.files = matching[slice.start .. slice.end];
        result.nextCursor = slice.nextCursor;
        result.previousCursor = slice.previousCursor;
        result.hasMore = slice.hasMore;
        result.hasPrevious = slice.hasPrevious;
        return result;
    }
}

/** Explicit factory for direct JSON catalog sources. */
final class JsonCatalogBackendFactory : CatalogBackendFactory
{
    override CatalogBackend open(OperationTarget target)
    {
        if (target.mode != OperationStorageMode.jsonCatalog)
            throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedOperation,
                "JsonCatalogBackendFactory only opens explicit JSON targets.");
        return new JsonCatalogBackend(target);
    }
}

version (unittest)
{
    import std.algorithm.searching : canFind;
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, read,
        remove, rmdirRecurse, tempDir, write;
    import std.path : baseName;
    import std.uuid : randomUUID;
    import dosierskanilo.model.namedbinaryblob :
        deserializeDataClassJsonWrapperFile;
    import dosierskanilo.operations : OperationState;
    import dosierskanilo.testdata : copySyntheticCatalogForTest;

    @("JSON directory filters include non-BMP descendants")
    unittest
    {
        import std.datetime.systime : SysTime;
        import dosierskanilo.model.namedbinaryblob :
            serializeDataClassWrapperFile;
        const token = randomUUID().toString();
        const catalogPath = buildPath(tempDir(), "json-nonbmp-" ~ token ~ ".json");
        scope (exit)
            if (exists(catalogPath))
                remove(catalogPath);

        NamedBinaryBlobCatalog catalog;
        catalog.dataVersion = DATA_CLASS_VERSION5;
        catalog.dataArray = [
            new NamedBinaryBlob("media/\U0001F600.txt", 5, SysTime(0)),
            new NamedBinaryBlob("other/plain.txt", 5, SysTime(0))
        ];
        serializeDataClassWrapperFile(catalogPath, catalog);

        auto backend = new JsonCatalogBackend(
            OperationTarget.jsonTarget(catalogPath, tempDir()));
        scope (exit)
            backend.close();

        CatalogDirectoryQuery query;
        query.filter.pathText = "\U0001F600";
        CatalogPageRequest request;
        request.limit = 10;
        const page = backend.listDirectories(query, request);
        assert(page.directories.length == 1);
        assert(page.directories[0].name == "media");
    }

    @("JSON backend indexes and operates on the generated catalog without SQLite")
    unittest
    {
        auto token = randomUUID().toString();
        auto root = copySyntheticCatalogForTest(buildPath(tempDir(),
            "json-catalog-backend-" ~ token));
        auto catalogPath = buildPath(tempDir(), "json-catalog-backend-"
            ~ token ~ ".json");
        auto exportPath = buildPath(tempDir(), "json-catalog-backend-export-"
            ~ token ~ ".json");
        auto backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
        CatalogBackend backend;
        scope (exit)
        {
            if (backend !is null)
                backend.close();
            if (exists(catalogPath))
                remove(catalogPath);
            if (exists(exportPath))
                remove(exportPath);
            foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
                if (entry.name.baseName.startsWith(backupPrefix)
                    && exists(entry.name))
                    remove(entry.name);
            if (exists(root))
                rmdirRecurse(root);
        }

        auto factory = new JsonCatalogBackendFactory();
        auto target = OperationTarget.jsonTarget(catalogPath, root);
        backend = factory.open(target);
        assert(backend.capabilities().supports(OperationKind.scan));
        assert(backend.capabilities().supports(OperationKind.analyze));
        assert(!backend.capabilities().supports(OperationKind.metadata));
        assert(backend.capabilities().supportsTreeQueries);

        ScanOperationRequest scan;
        scan.operationId = 1;
        scan.target = backend.target();
        scan.scanOptions.recursive = true;
        scan.metadataOptions.calculateChecksums = true;
        scan.metadataOptions.detectFileTypes = true;
        scan.metadataOptions.extractMediaInfo = true;
        scan.metadataOptions.scanArchives = true;
        scan.metadataOptions.deepArchiveScan = true;
        scan.metadataOptions.scanTorrents = true;
        scan.metadataOptions.threads = 2;
        const auto scanned = backend.runOperation(scan, new OperationControl());
        assert(scanned.state == OperationState.completed, scanned.error);
        assert(scanned.changesCommitted);
        assert(scanned.scanSummary.filesAdded == 12);
        assert(scanned.metadataSummary.checksumsUpdated == 12);
        assert(scanned.metadataSummary.archivesUpdated == 3);
        assert(scanned.metadataSummary.torrentsUpdated == 2);
        assert(!exists(buildPath(root, ".dosierskanilo")),
            "the explicit JSON adapter must not initialize SQLite");

        auto rootSummary = backend.rootSummary();
        assert(rootSummary.fileReferenceCount == 12);
        CatalogDirectoryQuery directoryQuery;
        CatalogPageRequest directoryPageRequest;
        directoryPageRequest.limit = 32;
        auto directoryPage = backend.listDirectories(directoryQuery,
            directoryPageRequest);
        DirectoryId archiveDirectory;
        DirectoryId mediaDirectory;
        DirectoryId torrentDirectory;
        foreach (directory; directoryPage.directories)
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
        CatalogPageRequest backwardsRequest;
        backwardsRequest.limit = 1;
        auto archivePage = backend.listFiles(archiveQuery, backwardsRequest);
        assert(archivePage.files.length == 1 && archivePage.hasMore);
        const auto secondArchivePage = backend.nextFilesPage(archiveQuery,
            archivePage.nextCursor);
        assert(secondArchivePage.hasMore);
        const auto backToSecond = backend.previousFilesPage(archiveQuery,
            secondArchivePage.nextCursor);
        assert(backToSecond.files.length == 1);
        assert(backToSecond.files[0].relativePath
            == secondArchivePage.files[0].relativePath);
        const auto backToFirst = backend.previousFilesPage(archiveQuery,
            backToSecond.previousCursor);
        assert(backToFirst.files.length == 1);
        assert(backToFirst.files[0].relativePath
            == archivePage.files[0].relativePath);
        assert(!backToFirst.hasPrevious);

        CatalogFileQuery sizeQuery;
        sizeQuery.directoryId = archiveDirectory;
        sizeQuery.sortOrder = CatalogSortOrder.sizeDescending;
        auto sizePage = backend.listFiles(sizeQuery);
        assert(sizePage.files.length == 3);
        foreach (index; 1 .. sizePage.files.length)
            assert(sizePage.files[index - 1].size >= sizePage.files[index].size);
        CatalogPageRequest sizeRequest;
        sizeRequest.limit = 1;
        auto sizeFirst = backend.listFiles(sizeQuery, sizeRequest);
        auto sizeSecond = backend.nextFilesPage(sizeQuery, sizeFirst.nextCursor);
        assert(sizeFirst.files[0].relativePath == sizePage.files[0].relativePath);
        assert(sizeSecond.files[0].relativePath == sizePage.files[1].relativePath);

        archivePage = backend.listFiles(archiveQuery);
        assert(archivePage.files.length == 3);
        CatalogFile sampleArchive;
        foreach (file; archivePage.files)
            if (file.name == "sample.zip")
                sampleArchive = file;
        assert(sampleArchive.contentId.isValid);
        auto archiveEntries = backend.listArchiveEntries(sampleArchive.contentId);
        assert(archiveEntries.entries.length == 7);
        assert(archiveEntries.entries[0].hasSafePath);
        assert(archiveEntries.entries[0].contentId.isValid);
        CatalogDetailMask archiveMemberDetails;
        archiveMemberDetails.fingerprint = true;
        auto archiveMember = backend.loadContent(
            archiveEntries.entries[0].contentId, archiveMemberDetails);
        assert(archiveMember.fingerprint.complete);
        CatalogPageRequest archiveMemberRequest;
        archiveMemberRequest.limit = 1;
        auto archiveMembers = backend.listArchiveMembers(
            sampleArchive.referenceId, archiveMemberRequest);
        assert(archiveMembers.members.length == 1 && archiveMembers.hasMore);
        assert(archiveMembers.members[0].locator.kind
            == ContentLocator.Kind.archiveEntry);
        assert(archiveMembers.members[0].contentId.isValid);
        string archiveEntryNames;
        foreach (entry; archiveEntries.entries)
            archiveEntryNames ~= "[" ~ entry.name ~ "]";
        assert(archiveEntries.entries.canFind!((entry) =>
            entry.name == "payload/copy.txt"), archiveEntryNames);
        assert(archiveEntries.entries[0].fingerprint.complete);

        /* Removing the container after indexing refreshes member availability. */
        const auto sampleArchivePath = buildPath(root, "archives", "sample.zip");
        const auto sampleArchiveBytes = read(sampleArchivePath);
        remove(sampleArchivePath);
        auto unavailableMembers = backend.listArchiveMembers(
            sampleArchive.referenceId, archiveMemberRequest);
        assert(unavailableMembers.members.length == 1);
        assert(unavailableMembers.members[0].availability
            == CatalogReferenceAvailability.unavailable);
        write(sampleArchivePath, sampleArchiveBytes);
        auto availableMembers = backend.listArchiveMembers(
            sampleArchive.referenceId, archiveMemberRequest);
        assert(availableMembers.members[0].availability
            == CatalogReferenceAvailability.available);

        CatalogFileQuery mediaQuery;
        mediaQuery.directoryId = mediaDirectory;
        mediaQuery.filter.audio = true;
        auto mediaPage = backend.listFiles(mediaQuery);
        assert(mediaPage.files.length == 1);
        CatalogDetailMask mediaDetails;
        mediaDetails.fingerprint = true;
        mediaDetails.media = true;
        auto media = backend.loadContent(mediaPage.files[0].contentId, mediaDetails);
        assert(media.fingerprint.complete);
        assert(media.mediaStreams.length == 1);
        assert(media.mediaStreams[0].kind == CatalogMediaKind.audio);

        /* Availability is checked when the page is served, not when indexed. */
        const auto mediaFilePath = buildPath(root, "media",
            mediaPage.files[0].name);
        const auto mediaBytes = read(mediaFilePath);
        remove(mediaFilePath);
        auto unavailableMedia = backend.listFiles(mediaQuery);
        assert(unavailableMedia.files.length == 1);
        assert(unavailableMedia.files[0].availability
            == CatalogReferenceAvailability.unavailable);
        write(mediaFilePath, mediaBytes);
        auto availableMedia = backend.listFiles(mediaQuery);
        assert(availableMedia.files[0].availability
            == CatalogReferenceAvailability.available);

        CatalogFileQuery torrentQuery;
        torrentQuery.directoryId = torrentDirectory;
        torrentQuery.filter.torrent = true;
        auto torrentPage = backend.listFiles(torrentQuery);
        assert(torrentPage.files.length == 2);
        CatalogFile singleTorrent;
        foreach (file; torrentPage.files)
            if (file.name == "single-file.torrent")
                singleTorrent = file;
        assert(singleTorrent.hasTorrent);
        CatalogDetailMask torrentDetails;
        torrentDetails.torrentSummary = true;
        const auto torrentContent = backend.loadContent(singleTorrent.contentId,
            torrentDetails);
        assert(torrentContent.torrentSummary.name == "tone.wav");
        assert(torrentContent.torrentSummary.totalSize == 76);
        assert(!torrentContent.torrentSummary.fileListAvailable);
        assert(!backend.capabilities().supportsTorrentEntryQueries,
            "The legacy source catalog contains no torrent file list.");
        bool torrentDetailUnavailable;
        try
            backend.listTorrentEntries(singleTorrent.contentId);
        catch (CatalogBackendException failure)
            torrentDetailUnavailable = failure.code
                == CatalogBackendErrorCode.unsupportedFeature;
        assert(torrentDetailUnavailable);

        CatalogExportOptions exportOptions;
        exportOptions.format = CatalogExportFormat.jsonV5;
        exportOptions.outputPath = exportPath;
        CatalogSubsetQuery subsetQuery;
        subsetQuery.pathPrefix = "archives";
        const auto exported = backend.exportSubset(subsetQuery, exportOptions);
        assert(exported.committed);
        assert(exported.referencesExported > 3);
        const auto exportedCatalog = deserializeDataClassJsonWrapperFile(exportPath);
        assert(exportedCatalog.dataVersion == DATA_CLASS_VERSION5);
        assert(exportedCatalog.dataArray.length > 3);

        auto missingPath = buildPath(root, "same-size", "different.txt");
        remove(missingPath);
        AnalysisOperationRequest analyze;
        analyze.operationId = 2;
        analyze.target = OperationTarget.jsonTarget(catalogPath);
        const auto retained = backend.runOperation(analyze, new OperationControl());
        assert(retained.state == OperationState.completed, retained.error);
        assert(retained.analysisSummary.missingFiles == 1);
        assert(retained.analysisSummary.droppedFiles == 0);
        DirectoryId missingDirectory;
        foreach (directory; backend.listDirectories(CatalogDirectoryQuery.init,
            directoryPageRequest).directories)
            if (directory.relativePath == "same-size")
                missingDirectory = directory.id;
        assert(missingDirectory.isValid);
        auto missingQuery = CatalogFileQuery.init;
        missingQuery.directoryId = missingDirectory;
        missingQuery.filter.pathText = "different.txt";
        auto retainedMissing = backend.listFiles(missingQuery);
        assert(retainedMissing.files.length == 1);
        assert(retainedMissing.files[0].availability
            == CatalogReferenceAvailability.unavailable);

        analyze.operationId = 3;
        analyze.options.dropMissing = true;
        const auto dropped = backend.runOperation(analyze, new OperationControl());
        assert(dropped.state == OperationState.completed, dropped.error);
        assert(dropped.analysisSummary.droppedFiles == 1);
        assert(backend.rootSummary().fileReferenceCount == 11);
    }

    @("JSON backend reads legacy arrays and v1-v3 wrapper representations")
    unittest
    {
        auto factory = new JsonCatalogBackendFactory();
        foreach (catalogPath; ["test/json_file_v0.json", "test/json_file_v1.json",
            "test/json_file_v2.json", "test/json_file_v2_archive.json",
            "test/json_file_v2_torrent.json", "test/json_file_wrapper_v2.json"])
        {
            auto target = OperationTarget.jsonTarget(catalogPath, "test");
            auto backend = factory.open(target);
            assert(backend.capabilities().supportsTreeQueries, catalogPath);
            assert(backend.rootSummary().fileReferenceCount > 0, catalogPath);
            backend.close();

            auto analysisOnly = factory.open(OperationTarget.jsonTarget(catalogPath));
            assert(!analysisOnly.capabilities().supportsTreeQueries, catalogPath);
            assert(analysisOnly.capabilities().supports(OperationKind.analyze));
            analysisOnly.close();
        }
    }

    @("JSON backend retains malformed catalogs unless overwrite is explicit")
    unittest
    {
        import std.file : exists, readText, remove, tempDir, write;
        import std.path : baseName, buildPath;

        auto token = randomUUID().toString();
        auto catalogPath = buildPath(tempDir(), "json-backend-malformed-"
            ~ token ~ ".json");
        auto backupPrefix = baseName(catalogPath)[0 .. $ - ".json".length] ~ "-";
        write(catalogPath, "not JSON");
        scope (exit)
        {
            if (exists(catalogPath))
                remove(catalogPath);
            foreach (DirEntry entry; dirEntries(getcwd(), SpanMode.shallow))
                if (entry.name.baseName.startsWith(backupPrefix)
                    && exists(entry.name))
                    remove(entry.name);
        }

        auto factory = new JsonCatalogBackendFactory();
        auto target = OperationTarget.jsonTarget(catalogPath);
        auto backend = factory.open(target);
        scope (exit)
            backend.close();
        AnalysisOperationRequest analyze;
        analyze.operationId = 51;
        analyze.target = target;
        const auto rejected = backend.runOperation(analyze, new OperationControl());
        assert(rejected.state == OperationState.failed);
        assert(!rejected.changesCommitted);
        assert(readText(catalogPath) == "not JSON");

        analyze.operationId = 52;
        analyze.forceJsonOverwrite = true;
        const auto replaced = backend.runOperation(analyze, new OperationControl());
        assert(replaced.state == OperationState.completed, replaced.error);
        assert(replaced.changesCommitted);
        assert(deserializeDataClassJsonWrapperFile(catalogPath).dataArray.length == 0);
    }
    @("JSON archive member pages merge physical and member sort orders")
    unittest
    {
        import std.algorithm.mutation : reverse;
        import std.datetime.systime : Clock;
        import dosierskanilo.model.archivespec : ArchiveSpec;
        import dosierskanilo.model.checksums : CheckSums;
        import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
            NamedBinaryBlob, NamedBinaryBlobCatalog,
            serializeDataClassWrapperFile;

        const token = randomUUID().toString();
        const root = buildPath(tempDir(), "json-member-pages-" ~ token);
        const catalogPath = buildPath(tempDir(), "json-member-pages-"
            ~ token ~ ".json");
        scope (exit)
        {
            if (exists(catalogPath))
                remove(catalogPath);
            if (exists(root))
                rmdirRecurse(root);
        }

        auto container = new NamedBinaryBlob("archive.zip", 100,
            Clock.currTime());
        container.archiveSpecs = [
            new ArchiveSpec("c.txt", 3, "2020-01-02T04:04:06", CheckSums.init),
            new ArchiveSpec("a.txt", 1, "2020-01-02T04:04:06", CheckSums.init),
            new ArchiveSpec("b.txt", 2, "2020-01-02T04:04:06", CheckSums.init)
        ];
        container.archiveIndexKnown = true;
        container.archiveIndexDeep = true;
        NamedBinaryBlobCatalog catalog;
        catalog.dataVersion = DATA_CLASS_VERSION5;
        catalog.dataArray = [
            container,
            new NamedBinaryBlob("plain.txt", 4, Clock.currTime())
        ];
        serializeDataClassWrapperFile(catalogPath, catalog);

        auto backend = new JsonCatalogBackend(
            OperationTarget.jsonTarget(catalogPath, root));
        scope (exit)
            backend.close();

        CatalogFileQuery query;
        query.filter.includeArchiveMembers = true;
        string[] collect(CatalogFileQuery current)
        {
            string[] paths;
            CatalogPageRequest request;
            request.limit = 2;
            auto page = backend.listFiles(current, request);
            foreach (file; page.files)
                paths ~= file.relativePath;
            while (page.hasMore)
            {
                page = backend.nextFilesPage(current, page.nextCursor);
                foreach (file; page.files)
                    paths ~= file.relativePath;
            }
            return paths;
        }

        const string[] pathAscending = ["archive.zip", "archive.zip!/a.txt",
            "archive.zip!/b.txt", "archive.zip!/c.txt", "plain.txt"];
        assert(collect(query) == pathAscending);

        query.sortOrder = CatalogSortOrder.pathDescending;
        assert(collect(query) == pathAscending.dup.reverse);

        query.sortOrder = CatalogSortOrder.sizeAscending;
        assert(collect(query) == ["archive.zip!/a.txt", "archive.zip!/b.txt",
            "archive.zip!/c.txt", "plain.txt", "archive.zip"]);

        query.sortOrder = CatalogSortOrder.sizeDescending;
        assert(collect(query) == ["archive.zip", "plain.txt",
            "archive.zip!/c.txt", "archive.zip!/b.txt", "archive.zip!/a.txt"]);

        query.sortOrder = CatalogSortOrder.pathAscending;
        CatalogPageRequest firstRequest;
        firstRequest.limit = 2;
        const auto firstPage = backend.listFiles(query, firstRequest);
        const auto secondPage = backend.nextFilesPage(query,
            firstPage.nextCursor);
        const auto backPage = backend.previousFilesPage(query,
            secondPage.previousCursor);
        assert(firstPage.files.length == 2 && secondPage.files.length == 2);
        assert(backPage.files[0].relativePath == firstPage.files[0].relativePath);
        assert(backPage.files[1].relativePath == firstPage.files[1].relativePath);
    }

}
