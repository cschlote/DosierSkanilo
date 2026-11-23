/** Content, archive, torrent, export, and member-content members of `JsonCatalogBackend`.
 *
 *
 * Content rows are deduplicated by digest; archive members resolve through their
 * container locator.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.jsoncontent;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, timeLastModified;
import std.path : baseName, buildNormalizedPath;
import dosierarkivo.archive : appendArchiveVirtualPath, archiveDisplayBaseName,
    archivePathMatchesText, escapeArchiveVirtualPath, nativePathToStoragePath;
import dosierskanilo.catalogbackend;
import dosierskanilo.logging : logLineVerbose;
import dosierskanilo.membercontentcache : MemberContentCancelledException,
    MemberContentLease;
import dosierskanilo.memberextraction : ArchiveExtractionStep,
    extractArchiveMember;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION5,
    NamedBinaryBlob, NamedBinaryBlobCatalog,
    deserializeDataClassJsonWrapperFile;
import dosierskanilo.operationlease : TargetWriteLease;
import dosierskanilo.repository.types : RepositoryBlobPage, RepositoryBlobFlags,
    RepositoryDuplicateGroup, RepositoryQueryOptions;
import dosierskanilo.operationrunner;
import dosierskanilo.service.jsonoperations : commitJsonCatalog,
    commitJsonCatalogUnderLease;
import dosierskanilo.operations : OperationControl, OperationKind,
    OperationPhase, OperationProgress, OperationState, OperationTarget;
import dosierskanilo.service.jsonoperations : commitJsonCatalog;
import dosierskanilo.jsoncatalogbackend : JsonMemberExportReference;

/** Members of `JsonCatalogBackend` mixed into the class; see jsoncontent.d. */
mixin template JsonContentQueries()
{
    /**
     * List deduplicated content rows across all files and archive members.
     *
     * One row is emitted per content identity, with the lexicographically smallest
     * reference path as its display path. A `pathText` filter accepts either a
     * path substring or an exact base64 SHA-1 digest.
     *
     * Params:
     *     query = Optional content filters.
     *     page = Page size and optional continuation cursor.
     * Returns: A page of content rows and the total number of matches.
     * Throws: `CatalogBackendException` when the backend is closed, the limit is
     *     zero, or the cursor belongs to another query or page size.
     */
    override CatalogContentPage listContents(CatalogContentQuery query,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireOpen();
        if (page.limit == 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                "Catalog page limit must be greater than zero.");
        const auto queryToken = contentQueryToken(query);
        if (page.cursor.isValid
            && (page.cursor.adapterQueryToken != queryToken
                || page.limit != page.cursor.adapterPageSize))
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                "Catalog cursor belongs to a different query or page size.");
        const auto start = page.cursor.isValid ? page.cursor.adapterIndex : 0;
        import core.time : MonoTime;
        const auto contentsStarted = MonoTime.currTime;

        CatalogFile[] references = fileRows.dup;
        foreach (ref container; fileRows)
            if (container.hasArchive)
                references ~= archiveMemberFiles(container);

        size_t[string] referenceCounts;
        string[string] displayPaths;
        foreach (ref candidate; references)
        {
            const token = candidate.contentId.adapterToken;
            ++referenceCounts[token];
            const auto displayPath = displayPaths.get(token, "");
            if (displayPath.length == 0 || candidate.relativePath < displayPath)
                displayPaths[token] = candidate.relativePath;
        }
        logLineVerbose("[contents] reference maps=", references.length,
            " elapsedMs=", cast(long) (MonoTime.currTime - contentsStarted).total!"msecs");

        const auto scanStarted = MonoTime.currTime;
        size_t matched;
        CatalogContentRow[] window;
        foreach (blobIndex, ref blob; catalog.dataArray)
        {
            const token = contentTokenForBlobIndex(blobIndex);
            if (token.length == 0 || !contentMatchesFilter(token, query.filter))
                continue;
            const bool digestMatch = query.filter.pathText.length > 0
                && blob.checkSums.sha1sum_b64 == query.filter.pathText;
            const auto referenceCount = referenceCounts.get(token, 0);
            if (referenceCount == 0 && !digestMatch)
                continue;
            if (query.filter.pathText.length > 0 && !digestMatch)
            {
                const auto path = displayPaths.get(token, "");
                if (path.length == 0 || !archivePathMatchesText(path,
                    query.filter.pathText, query.filter.caseSensitive))
                    continue;
            }
            if (matched >= start && window.length < page.limit)
            {
                CatalogContentRow row;
                row.id = ContentId(token);
                row.size = blob.fileSize;
                row.referenceCount = referenceCount;
                row.displayPath = displayPaths.get(token, "");
                row.displayName = archiveDisplayBaseName(row.displayPath);
                row.fingerprint = fingerprintFor(blob.fileSize, blob.checkSums);
                row.availability = CatalogReferenceAvailability.notChecked;
                if (auto content = token in contentByToken)
                {
                    row.hasFileType = (*content).fileType.length > 0;
                    row.hasArchive = (*content).hasArchive;
                    row.hasTorrent = (*content).hasTorrent;
                    foreach (stream; (*content).mediaStreams)
                        final switch (stream.kind)
                        {
                        case CatalogMediaKind.image:
                            row.hasImage = true;
                            break;
                        case CatalogMediaKind.video:
                            row.hasVideo = true;
                            break;
                        case CatalogMediaKind.audio:
                            row.hasAudio = true;
                            break;
                        case CatalogMediaKind.text:
                            row.hasText = true;
                            break;
                        }
                    row.hasMedia = row.hasImage || row.hasVideo || row.hasAudio
                        || row.hasText;
                }
                window ~= row;
            }
            ++matched;
        }
        logLineVerbose("[contents] scan blobs=", catalog.dataArray.length,
            " matches=", matched, " window=", window.length, " elapsedMs=",
            cast(long) (MonoTime.currTime - scanStarted).total!"msecs");

        if (start > matched)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                "Catalog cursor is outside this query result.");
        const auto end = start + window.length;
        CatalogContentPage result;
        result.rows = window;
        result.total = matched;
        result.hasPrevious = start > 0;
        if (result.hasPrevious)
            result.previousCursor = CatalogPageCursor(start > page.limit
                ? start - page.limit : 0, page.limit, queryToken);
        result.hasMore = end < matched;
        if (result.hasMore)
            result.nextCursor = CatalogPageCursor(end, page.limit, queryToken);
        return result;
    }

    /**
     * Build the cursor binding token for a content query.
     *
     * Params:
     *     query = Content query whose filter participates in the token.
     * Returns: Opaque token tied to this source instance and the filter.
     */
    package string contentQueryToken(CatalogContentQuery query) const
    {
        return sourceToken ~ "\0contents\0" ~ filterToken(query.filter);
    }

    /**
     * Test a content snapshot against the media and type selectors of a filter.
     *
     * Path and availability filters are evaluated by the caller. Content without a
     * snapshot only matches when no media or type selector is active.
     *
     * Params:
     *     token = Content token to look up.
     *     filter = Filter whose media and type selectors are applied.
     * Returns: True when the content satisfies the filter's selector groups.
     */
    package bool contentMatchesFilter(string token, CatalogFilter filter) const
    {
        const content = token in contentByToken;
        const bool selectedMedia = filter.video || filter.audio || filter.image
            || filter.text;
        if (content is null)
            return !selectedMedia && !filter.fileType && !filter.archive
                && !filter.torrent;
        if (selectedMedia)
        {
            bool hasSelected;
            foreach (stream; (*content).mediaStreams)
            {
                if ((filter.video && stream.kind == CatalogMediaKind.video)
                    || (filter.audio && stream.kind == CatalogMediaKind.audio)
                    || (filter.image && stream.kind == CatalogMediaKind.image)
                    || (filter.text && stream.kind == CatalogMediaKind.text))
                {
                    hasSelected = true;
                    break;
                }
            }
            if (filter.mediaNegated ? hasSelected : !hasSelected)
                return false;
        }
        if (filter.fileType && (*content).fileType.length == 0)
            return false;
        if (filter.archive && !(*content).hasArchive)
            return false;
        if (filter.torrent && !(*content).hasTorrent)
            return false;
        return true;
    }

    /**
     * Store or clear the archive password for exactly one catalog file.
     *
     * The catalog is re-read under a write lease, so concurrent writers cannot be
     * overwritten silently. Matching prefers the exact storage-relative path and
     * falls back to a base-name match when the request is just a file name.
     *
     * Params:
     *     relativePath = Path or base name of the file to update.
     *     password = New archive password; an empty string clears it.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidIdentifier` when no file or more than one
     *     file matches, and `CatalogBackendErrorCode.backendFailure` when the
     *     catalog cannot be written.
     */
    override void setArchivePassword(string relativePath, string password)
    {
        requireOpen();
        auto targetLease = TargetWriteLease.acquire(
            OperationTarget.jsonTarget(backendTarget.catalogPath));
        scope (exit)
            targetLease.release();
        NamedBinaryBlobCatalog fresh;
        try
            fresh = deserializeDataClassJsonWrapperFile(
                backendTarget.catalogPath);
        catch (Exception failure)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.backendFailure,
                "Cannot read the catalog before updating the archive password: "
                ~ failure.msg);
        const auto requestedPath = buildNormalizedPath(relativePath);
        size_t[] exact;
        size_t[] byName;
        foreach (index, blob; fresh.dataArray)
        {
            foreach (spec; blob.fileSpecs)
            {
                if (spec is null || spec.fileName.length == 0)
                    continue;
                const auto specPath = storageRelativePath(spec.fileName);
                if (specPath == requestedPath)
                {
                    exact ~= index;
                    break;
                }
                if (baseName(requestedPath) == requestedPath
                    && baseName(specPath) == requestedPath)
                {
                    byName ~= index;
                    break;
                }
            }
        }
        const auto matches = exact.length > 0 ? exact : byName;
        if (matches.length == 0)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "No catalog file matches: " ~ relativePath);
        if (matches.length > 1)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Filename is ambiguous in this catalog: " ~ relativePath);
        fresh.dataArray[matches[0]].archivePassword = password;
        try
            commitJsonCatalogUnderLease(backendTarget.catalogPath, fresh, null);
        catch (Exception failure)
            throw new CatalogBackendException(CatalogBackendErrorCode.backendFailure,
                "Cannot write the archive password: " ~ failure.msg);
        reloadCatalog();
    }

    /**
     * Load a detached content snapshot, masked to the requested detail families.
     *
     * Params:
     *     contentId = Content identity to load.
     *     details = Optional detail families to include; unrequested families are
     *         cleared.
     * Returns: The masked content snapshot.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidIdentifier` for unknown content or when
     *     the backend is closed.
     */
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

    /**
     * Copy a content snapshot and drop detail families that were not requested.
     *
     * Archive state is refreshed from the current index rather than trusting the
     * build-time snapshot.
     *
     * Params:
     *     source = Snapshot to copy.
     *     details = Detail families to keep.
     * Returns: An independent, masked snapshot.
     */
    package CatalogContentSnapshot maskedSnapshot(CatalogContentSnapshot source,
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

    /**
     * Build the archive summary for a content token from the current index.
     *
     * Params:
     *     token = Container content token.
     * Returns: A summary with `indexKnown` set only when an archive index exists
     *     for the token.
     */
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

    /**
     * Page through archive metadata for one content identity.
     *
     * A known content without an archive index yields an empty page, matching the
     * SQLite backend; only unknown identities are errors.
     *
     * Params:
     *     contentId = Container content identity.
     *     page = Page size and optional continuation cursor.
     * Returns: A page of archive metadata rows.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidIdentifier` for unknown content or when
     *     the backend is closed.
     */
    override CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireOpen();
        if (page.limit == 0)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidCursor,
                "Archive entry page limit must be greater than zero.");
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

    /**
     * Page through locatable members of an indexed archive container.
     *
     * Only safe, non-directory entries with a linked content identity are listed.
     * Member availability follows the container's current on-disk availability.
     *
     * Params:
     *     containerReferenceId = Reference identity of the archive container.
     *     page = Page size and optional continuation cursor.
     * Returns: A page of member references for the container.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidCursor` for a zero limit and
     *     `CatalogBackendErrorCode.invalidIdentifier` when the reference is not an
     *     indexed archive container.
     */
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

    /**
     * Page through the persisted file list of one torrent.
     *
     * Params:
     *     contentId = Torrent content identity.
     *     page = Page size and optional continuation cursor.
     * Returns: A page of torrent manifest descriptors; an empty page when the
     *     content is known but has no file-list details.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.unsupportedFeature` when any indexed torrent
     *     lacks a file list, `CatalogBackendErrorCode.invalidIdentifier` for
     *     unknown content, or when the backend is closed.
     */
    override CatalogTorrentEntryPage listTorrentEntries(ContentId contentId,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireOpen();
        if (page.limit == 0)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidCursor,
                "Torrent entry page limit must be greater than zero.");
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

    /**
     * Resolve a root-relative directory path to its indexed identity.
     *
     * Params:
     *     relativePath = Directory path; empty or "." denotes the source root.
     * Returns: The directory ID, or `DirectoryId.init` for the root or an unknown
     *     path.
     * Throws: `CatalogBackendException` when tree queries are unavailable.
     */
    override DirectoryId resolveDirectory(string relativePath)
    {
        requireTreeQueries();
        if (relativePath.length == 0 || relativePath == ".")
            return DirectoryId.init;
        if (auto index = relativePath in directoryIndexByPath)
            return directoryRows[*index].id;
        return DirectoryId.init;
    }

    /**
     * Resolve a relative path to a file or archive-member reference identity.
     *
     * Params:
     *     relativePath = Physical file path or archive virtual path.
     * Returns: The matching reference ID, or `ReferenceId.init` when not found.
     * Throws: `CatalogBackendException` when tree queries are unavailable.
     */
    override ReferenceId resolveReference(string relativePath)
    {
        requireTreeQueries();
        if (auto token = relativePath in referenceTokenByPath)
            return ReferenceId(*token);
        foreach (row; fileRows)
            if (row.relativePath == relativePath)
                return row.referenceId;
        foreach (container; fileRows)
            if (container.hasArchive)
                foreach (member; archiveMemberFiles(container))
                    if (member.relativePath == relativePath)
                        return member.referenceId;
        return ReferenceId.init;
    }

    /**
     * Load one indexed reference by identity with refreshed availability.
     *
     * Params:
     *     referenceId = Reference identity to load.
     * Returns: The detached file row for the reference.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidIdentifier` for unknown references or
     *     when tree queries are unavailable.
     */
    override CatalogFile loadReference(ReferenceId referenceId)
    {
        requireTreeQueries();
        CatalogFile result;
        if (!findFileRow(referenceId, result))
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Unknown JSON reference identity.");
        refreshAvailability(result);
        return result;
    }

    /**
     * Extract one archive member into a leased content cache file.
     *
     * The container chain is walked up to its physical filesystem archive, and
     * extraction steps are applied from the outermost to the innermost container.
     *
     * Params:
     *     memberReferenceId = Reference identity of the archive member.
     *     cancellation = Optional shared cancellation flag polled during
     *         extraction.
     * Returns: A lease for the extracted member file; callers must release it.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.unsupportedFeature` when no filesystem root is
     *     bound, `CatalogBackendErrorCode.invalidIdentifier` when the reference is
     *     not an available indexed member, or
     *     `CatalogBackendErrorCode.cancelled` when extraction is cancelled.
     */
    override MemberContentLease acquireMemberContent(
        ReferenceId memberReferenceId, shared(bool)* cancellation = null)
    {
        requireTreeQueries();
        if (sourceRoot.length == 0)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.unsupportedFeature,
                "JSON member extraction requires an explicit filesystem root.");
        CatalogFile member;
        if (!findFileRow(memberReferenceId, member)
            || member.locator.kind != ContentLocator.Kind.archiveEntry)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Reference is not an indexed JSON archive member.");
        refreshAvailability(member);
        if (member.availability != CatalogReferenceAvailability.available)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "The archive container is not available on disk.");
        ArchiveExtractionStep[] steps;
        auto current = member;
        string physicalContainer;
        while (true)
        {
            if (current.locator.kind != ContentLocator.Kind.archiveEntry)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Archive member chain does not end at a filesystem container.");
            const auto containerReferenceId =
                current.locator.archiveEntry.containerReferenceId;
            const auto entryId = current.locator.archiveEntry.entryId;
            CatalogFile container;
            if (!findFileRow(containerReferenceId, container))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Unknown archive container reference.");
            refreshAvailability(container);
            if (container.availability != CatalogReferenceAvailability.available)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "The archive container is not available on disk.");
            CatalogArchiveEntry entry;
            bool foundEntry;
            if (auto entries = container.contentId.adapterToken
                in archiveEntriesByToken)
                foreach (candidate; *entries)
                    if (candidate.id == entryId)
                    {
                        entry = candidate;
                        foundEntry = true;
                        break;
                    }
            if (!foundEntry)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "The archive entry identity is no longer indexed.");
            ArchiveExtractionStep step;
            step.memberPath = entry.relativePath;
            step.occurrence = entry.occurrence;
            step.locator = current.locator;
            step.password = archivePasswordForContent(container.contentId);
            step.knownSize = current.size;
            steps = step ~ steps;
            if (container.locator.kind == ContentLocator.Kind.filesystem)
            {
                physicalContainer = container.locator.filesystem.relativePath;
                break;
            }
            current = container;
        }
        try
            return extractArchiveMember(sourceRoot, physicalContainer, steps,
                cancellation);
        catch (MemberContentCancelledException failure)
            throw new CatalogBackendException(
                CatalogBackendErrorCode.cancelled, failure.msg);
    }

    /**
     * Query catalog blobs for repository-style tooling.
     *
     * Blob identifiers are one-based catalog array positions, which is also the
     * cursor unit used for continuation.
     *
     * Params:
     *     options = Text, media, and type filters plus paging and cursor options.
     * Returns: A page of cloned blobs with file specifications, flags, and blob
     *     identifiers.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidIdentifier` when the limit is zero, or
     *     when the backend is closed.
     */
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
            bool matchedPath = options.text.length == 0
                || archivePathMatchesText(file.relativePath, options.text,
                    options.caseSensitive);
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

    /**
     * Group catalog blobs that share size and checksums.
     *
     * Only blobs with complete digests and at least one file name are considered;
     * groups with a single member are omitted.
     *
     * Params:
     *     limit = Maximum number of groups to return; must be greater than zero.
     * Returns: Duplicate groups sorted by size, then by lowest blob identifier.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidIdentifier` when the limit is zero, or
     *     when the backend is closed.
     */
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

    /**
     * Look up the content token assigned to a catalog blob index.
     *
     * Params:
     *     blobIndex = Index into the catalog data array.
     * Returns: The content token, or an empty string when the index is out of
     *     range.
     */
    package string contentTokenForBlobIndex(size_t blobIndex) const
    {
        return blobIndex < contentTokenByBlobIndex.length
            ? contentTokenByBlobIndex[blobIndex] : "";
    }

    /**
     * Export a filtered subset without progress reporting or cancellation.
     *
     * Params:
     *     query = Path prefix and file filters selecting the subset.
     *     options = Output format, destination, and detail selection.
     * Returns: Counts and publication state of the export.
     * Throws: `CatalogBackendException` for invalid options or I/O failures; see
     *     `exportSubsetControlled`.
     */
    override CatalogExportResult exportSubset(CatalogSubsetQuery query,
        CatalogExportOptions options)
    {
        return exportSubsetControlled(query, options, null, 0);
    }

    /**
     * Export a filtered subset as a version-5 JSON catalog.
     *
     * Exactly one reference is exported per selected physical path, along with the
     * requested content and archive/torrent detail. Archive members are exported
     * only when content details and archive entries are both requested.
     *
     * Params:
     *     query = Path prefix and file filters selecting the subset.
     *     options = Output format, destination, and detail selection.
     *     control = Optional progress and cancellation control; may be null.
     *     operationId = Operation ID copied into reported progress.
     * Returns: Counts and publication state; `committed` is true only after the
     *     output was published.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidTarget` when no output path is given,
     *     `CatalogBackendErrorCode.unsupportedFeature` for unsupported formats or
     *     member exports without content details, and
     *     `CatalogBackendErrorCode.backendFailure` when publishing fails.
     */
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
                    nativePathToStoragePath(exportFileName));
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
            }, options.prettyJson);
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

    /**
     * Convert persisted media info into catalog media stream rows.
     *
     * Params:
     *     blob = Blob whose media signature is converted.
     * Returns: One row per image, video, audio, or text stream; empty when no
     *     media signature is stored.
     */
    package CatalogMediaStream[] mediaStreamsFor(NamedBinaryBlob blob) const
    {
        CatalogMediaStream[] result;
        if (blob.mediaInfoSig is null)
            return result;
        foreach (stream; blob.mediaInfoSig.imageStreams)
        {
            if (stream is null)
                continue;
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
            if (stream is null)
                continue;
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
            if (stream is null)
                continue;
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
            if (stream is null)
                continue;
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

    /**
     * Build a detached content snapshot for a catalog blob.
     *
     * Params:
     *     blob = Blob supplying content metadata.
     *     contentId = Identity to assign to the snapshot.
     * Returns: The snapshot, including archive/torrent summaries and extractor
     *     statuses derived from the stored metadata.
     */
    package CatalogContentSnapshot snapshotFor(NamedBinaryBlob blob, ContentId contentId) const
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
            : (hasAnyMediaStream(blob.mediaInfoSig)
                ? CatalogExtractorState.completed
                : CatalogExtractorState.empty);
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

    /**
     * Merge a candidate snapshot into an existing content snapshot.
     *
     * Missing fingerprints, file types, and media streams are filled in; boolean
     * flags are unioned and extractor statuses are added when absent.
     *
     * Params:
     *     current = Snapshot updated in place.
     *     candidate = Snapshot providing fallback metadata.
     */
    package void mergeContentSnapshot(ref CatalogContentSnapshot current,
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

    /**
     * Build a content snapshot for an archive member linked to a specification.
     *
     * Params:
     *     spec = Archive entry describing the member.
     *     id = Content identity assigned to the member.
     *     fingerprint = Fingerprint computed for the member.
     * Returns: A snapshot with archive and checksum extractor statuses.
     */
    package CatalogContentSnapshot snapshotForArchiveEntry(ArchiveSpec spec,
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

    /**
     * Return the stored archive password for a content identity.
     *
     * Params:
     *     contentId = Content identity to look up.
     * Returns: The stored password, or an empty string when none is stored.
     */
    package string archivePasswordForContent(ContentId contentId) const
    {
        if (auto index = contentId.adapterToken in blobIndexByContentToken)
            if (*index < catalog.dataArray.length)
                return catalog.dataArray[*index].archivePassword;
        return "";
    }
}
