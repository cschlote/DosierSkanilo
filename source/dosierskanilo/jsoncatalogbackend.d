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
import dosierskanilo.operationrunner;
import dosierskanilo.operations : AnalysisOperationRequest, MetadataOperationRequest,
    OperationControl, OperationKind, OperationResult, OperationStorageMode,
    OperationTarget, ScanOperationRequest;
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
    CatalogContentSnapshot[string] contentByToken;
    CatalogArchiveEntry[][string] archiveEntriesByToken;
    CatalogTorrentManifestEntry[][string] torrentEntriesByToken;
    size_t[string] blobIndexByRelativePath;
    size_t[string] blobIndexByContentToken;
    FileSpec[string] fileSpecByRelativePath;
    size_t[string] directoryIndexByPath;
    CatalogFile[string] archiveMemberReferenceByToken;

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
            rebuildIndex();
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
        auto matching = matchingFiles(query);
        auto slice = pageSlice(page, fileQueryToken(query), matching.length);
        return makeFilePage(matching, slice);
    }

    override CatalogFilePage nextFilesPage(CatalogFileQuery query,
        CatalogPageCursor cursor)
    {
        return listFiles(query, CatalogPageRequest(cursor.adapterPageSize, cursor));
    }

    override CatalogFilePage previousFilesPage(CatalogFileQuery query,
        CatalogPageCursor cursor)
    {
        return listFiles(query, CatalogPageRequest(cursor.adapterPageSize, cursor));
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
        return result;
    }

    override CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireOpen();
        const auto token = contentId.adapterToken;
        auto entries = token in archiveEntriesByToken;
        if (entries is null)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidIdentifier,
                "Content has no JSON archive index.");
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
            if (auto archiveContainer = referenceToken
                in archiveMemberReferenceByToken)
            {
                container = *archiveContainer;
                foundContainer = true;
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
            archiveMemberReferenceByToken[member.referenceId.adapterToken] =
                memberFile;
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
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidIdentifier,
                "Content has no JSON torrent manifest.");
        auto slice = pageSlice(page, sourceToken ~ "\0"
            ~ indexGeneration.to!string ~ "\0torrents\0" ~ token,
            (*entries).length);
        CatalogTorrentEntryPage result;
        result.entries = (*entries)[slice.start .. slice.end];
        result.nextCursor = slice.nextCursor;
        result.hasMore = slice.hasMore;
        return result;
    }

    override CatalogExportResult exportSubset(CatalogSubsetQuery query,
        CatalogExportOptions options)
    {
        requireTreeQueries();
        enforceJsonExportFormat(options);
        enforce(options.outputPath.length > 0,
            "A JSON subset export requires an explicit output path.");

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
            if (!matches(file, query.filter)
                || !hasPathPrefix(file.relativePath, query.pathPrefix))
                continue;
            auto blobIndex = blobIndexByRelativePath[file.relativePath];
            selectPhysicalReference(file, blobIndex, true);
        }
        if (query.filter.includeArchiveMembers)
        {
            foreach (container; fileRows)
            {
                if (!container.hasArchive)
                    continue;
                auto blobIndex = blobIndexByRelativePath[container.relativePath];
                foreach (member; archiveMemberFiles(container))
                {
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
                            in archiveMemberReferenceByToken)
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
        foreach (contentToken; blobByContent.keys)
        {
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
        enforce(commitJsonCatalog(options.outputPath, exported),
            "Could not publish the JSON subset export.");
        result.contentsExported = exportedBlobs.length;
        foreach (contentToken; selectedMemberContents.keys)
            if (contentToken !in blobByContent)
                ++result.contentsExported;
        result.outputPath = canonicalPath(options.outputPath);
        result.committed = true;
        return result;
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
        result.hasArchive = blob.archiveIndexKnown || blob.archiveSpecs !is null;
        result.hasTorrent = blob.torrentInfo !is null;
        result.archiveSummary.indexKnown = blob.archiveIndexKnown
            || blob.archiveSpecs !is null;
        if (blob.archiveSpecs !is null)
        {
            result.archiveSummary.entryCount = blob.archiveSpecs.length;
            foreach (entry; blob.archiveSpecs)
                if (entry !is null && entry.checkSums.hasDigests)
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
        archiveStatus.state = !blob.archiveIndexKnown && blob.archiveSpecs is null
            ? CatalogExtractorState.notRequested
            : (blob.archiveSpecs.length == 0 ? CatalogExtractorState.empty
                : CatalogExtractorState.completed);
        result.extractors ~= archiveStatus;
        CatalogExtractorStatus torrentStatus;
        torrentStatus.extractor = "torrents";
        torrentStatus.state = blob.torrentInfo is null
            ? CatalogExtractorState.notRequested : CatalogExtractorState.completed;
        result.extractors ~= torrentStatus;
        return result;
    }

    void rebuildIndex()
    {
        fileRows = [];
        directoryRows = [];
        contentByToken = null;
        archiveEntriesByToken = null;
        torrentEntriesByToken = null;
        blobIndexByRelativePath = null;
        blobIndexByContentToken = null;
        fileSpecByRelativePath = null;
        directoryIndexByPath = null;
        archiveMemberReferenceByToken = null;
        treeQueriesAvailable = sourceRoot.length > 0;
        torrentEntryDetailsUnavailable = false;
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
            bool alreadyIndexed;
            if (auto existingEntries = containerToken in archiveEntriesByToken)
                foreach (existing; *existingEntries)
                    if (existing.id == entry.id)
                        alreadyIndexed = true;
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
            if (!alreadyIndexed)
                archiveEntriesByToken[containerToken] ~= entry;
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

    CatalogFile[] matchingFiles(CatalogFileQuery query)
    {
        CatalogFile[] result;
        foreach (file; fileRows)
            if (file.directoryId == query.directoryId && matches(file, query.filter))
                result ~= file;
        if (query.filter.includeArchiveMembers)
            foreach (container; fileRows)
                if (container.directoryId == query.directoryId)
                    foreach (member; archiveMemberFiles(container))
                        if (matches(member, query.filter))
                            result ~= member;
        final switch (query.sortOrder)
        {
        case CatalogSortOrder.pathAscending:
            result.sort!((left, right) => left.relativePath < right.relativePath);
            break;
        case CatalogSortOrder.pathDescending:
            result.sort!((left, right) => left.relativePath > right.relativePath);
            break;
        case CatalogSortOrder.sizeAscending:
            result.sort!((left, right) => left.size < right.size
                || (left.size == right.size && left.relativePath < right.relativePath));
            break;
        case CatalogSortOrder.sizeDescending:
            result.sort!((left, right) => left.size > right.size
                || (left.size == right.size && left.relativePath < right.relativePath));
            break;
        }
        return result;
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
        auto prefix = directoryPath ~ "/";
        foreach (file; fileRows)
            if (file.relativePath.startsWith(prefix) && matches(file, filter))
                return true;
        if (filter.includeArchiveMembers)
            foreach (container; fileRows)
                if (container.relativePath.startsWith(prefix))
                    foreach (member; archiveMemberFiles(container))
                        if (matches(member, filter))
                            return true;
        return false;
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
            size_t samePathCount;
            foreach (candidate; *entries)
                if (candidate.relativePath == entry.relativePath)
                    ++samePathCount;
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
            archiveMemberReferenceByToken[member.referenceId.adapterToken] = member;
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
    import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, remove,
        rmdirRecurse, tempDir;
    import std.path : baseName;
    import std.uuid : randomUUID;
    import dosierskanilo.model.namedbinaryblob :
        deserializeDataClassJsonWrapperFile;
    import dosierskanilo.operations : OperationState;
    import dosierskanilo.testdata : copySyntheticCatalogForTest;

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
        auto archivePage = backend.listFiles(archiveQuery);
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
}
