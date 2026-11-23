/** Contract unittests for the storage-neutral catalog API.
 *
 *
 * The in-memory fake backend implements `CatalogBackend` for the
 * contract tests only; it is compiled into unittest builds.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.catalogcontracttests;

import dosierskanilo.catalogbackend;
import dosierskanilo.catalogtypes;
import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.string : startsWith;
import dosierarkivo.archive : archivePathMatchesText;
import dosierskanilo.membercontentcache : MemberContentLease;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob;
import dosierskanilo.operations : AnalysisOperationRequest,
    MetadataOperationRequest, OperationControl, OperationKind, OperationResult,
    OperationState, OperationStorageMode, OperationTarget, ScanOperationRequest;
import dosierskanilo.repository.types : JsonImportOptions, RepositoryBlobPage,
    RepositoryBlobFlags, RepositoryDuplicateGroup, RepositoryInfo,
    RepositoryQueryOptions;

version (unittest)
{
    import std.algorithm.mutation : reverse;
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;
    import std.conv : to;
    import std.path : baseName;
    import std.string : startsWith, toLower;
    import std.uuid : randomUUID;

    /** In-memory catalog backend used by the contract unittests.
     *
     * It exposes a small fixed tree and two content identities so query,
     * paging, and cursor behavior can be exercised without storage.
     */
    private class FakeCatalogBackend : CatalogBackend
    {
        /// Operation target this fake was opened with.
        private OperationTarget sourceTarget;
        /// Random per-instance token that scopes generated identities and cursors.
        private string instanceToken;
        /// Whether `close` has been called on this fake.
        private bool closed;
        /// Identity of the first fake content, shared by three file references.
        private ContentId contentOne;
        /// Identity of the second fake content, used by the image file.
        private ContentId contentTwo;
        /// Identity of fake directory `a`.
        private DirectoryId directoryA;
        /// Identity of fake directory `b`.
        private DirectoryId directoryB;
        /// Fixed file rows served by this fake.
        private CatalogFile[] files;
        /// Fixed directory rows served by this fake.
        private CatalogDirectory[] directories;

        /** Create the fixed fake data set for one operation target.
         *
         * Params:
         *     target = Operation target this fake reports and validates against.
         */
        this(OperationTarget target)
        {
            sourceTarget = target;
            instanceToken = randomUUID().toString();
            contentOne = ContentId(instanceToken ~ ":content-one");
            contentTwo = ContentId(instanceToken ~ ":content-two");
            directoryA = DirectoryId(instanceToken ~ ":directory-a");
            directoryB = DirectoryId(instanceToken ~ ":directory-b");

            const auto first = makeFile("a/one.txt", "reference-one", contentOne,
                directoryA, 10);
            const auto duplicate = makeFile("a/two-copy.txt", "reference-two",
                contentOne, directoryA, 10);
            const auto third = makeFile("a/three-copy.txt", "reference-three",
                contentOne, directoryA, 10);
            auto image = makeFile("b/photo.bmp", "reference-four", contentTwo,
                directoryB, 20);
            image.hasImage = true;
            image.hasMedia = true;
            image.hasArchive = true;
            files = [first, duplicate, third, image];

            CatalogDirectory a;
            a.id = directoryA;
            a.name = "a";
            a.relativePath = "a";
            a.fileCount = 3;
            a.aggregateSize = 30;
            CatalogDirectory b;
            b.id = directoryB;
            b.name = "b";
            b.relativePath = "b";
            b.fileCount = 1;
            b.aggregateSize = 20;
            directories = [a, b];
        }

        /** Reject calls made after this fake backend was closed.
         *
         * Throws: `CatalogBackendException` with `closed` when already closed.
         */
        private void requireOpen() const
        {
            if (closed)
                throw new CatalogBackendException(CatalogBackendErrorCode.closed,
                    "Catalog backend is closed.");
        }

        /** Require an open backend that can serve rooted tree queries.
         *
         * Throws: `CatalogBackendException` with `closed` when closed, or
         *     `unsupportedFeature` for an unrooted JSON target.
         */
        private void requireTreeQueries() const
        {
            requireOpen();
            if (sourceTarget.mode == OperationStorageMode.jsonCatalog
                && sourceTarget.filesystemRoot.length == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedFeature,
                    "JSON tree queries require an explicit filesystem root.");
        }

        /** Validate that an operation target names this fake's source.
         *
         * Params:
         *     requestTarget = Target supplied by the operation request.
         *     operation = Operation kind; scan additionally requires a root.
         * Throws: `CatalogBackendException` with `closed` or `invalidTarget`.
         */
        private void requireTarget(OperationTarget requestTarget,
            OperationKind operation) const
        {
            requireOpen();
            bool matchesSource = requestTarget.mode == sourceTarget.mode;
            if (matchesSource && requestTarget.mode == OperationStorageMode.repository)
                matchesSource = requestTarget.repositoryRoot == sourceTarget.repositoryRoot;
            else if (matchesSource)
            {
                matchesSource = requestTarget.catalogPath == sourceTarget.catalogPath;
                if (matchesSource && requestTarget.filesystemRoot.length > 0)
                    matchesSource = requestTarget.filesystemRoot
                        == sourceTarget.filesystemRoot;
                if (matchesSource && operation == OperationKind.scan)
                    matchesSource = requestTarget.filesystemRoot.length > 0
                        && requestTarget.filesystemRoot == sourceTarget.filesystemRoot;
            }
            if (!matchesSource)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidTarget,
                    "Operation target does not match the opened catalog source.");
        }

        /** Build one fake file row with a source-scoped reference identity.
         *
         * Params:
         *     path = Normalized source-relative file path.
         *     referenceToken = Per-instance suffix for the reference identity.
         *     contentId = Content identity shared by the row.
         *     parent = Parent directory identity.
         *     size = Content size in bytes.
         * Returns: The populated file row.
         * Throws: `CatalogBackendException` with `invalidLocator` for an
         *     unsafe path.
         */
        private CatalogFile makeFile(string path, string referenceToken,
            ContentId contentId, DirectoryId parent, ulong size)
        {
            CatalogFile file;
            file.referenceId = ReferenceId(instanceToken ~ ":" ~ referenceToken);
            file.contentId = contentId;
            file.directoryId = parent;
            file.locator = ContentLocator.file(path);
            file.name = baseName(path);
            file.relativePath = path;
            file.size = size;
            file.availability = CatalogReferenceAvailability.available;
            return file;
        }

        /** Return whether a fake file row satisfies all filter groups.
         *
         * Params:
         *     file = Row to test.
         *     filter = Source-neutral filters to apply.
         * Returns: `true` when the row matches.
         */
        private bool matches(CatalogFile file, CatalogFilter filter) const
        {
            if (filter.pathText.length > 0
                && !archivePathMatchesText(file.relativePath, filter.pathText,
                    filter.caseSensitive))
                return false;
            if (filter.availableOnly
                && file.availability != CatalogReferenceAvailability.available)
                return false;
            const bool selectedMedia = filter.video || filter.audio || filter.image
                || filter.text;
            if (selectedMedia)
            {
                const bool hasSelectedMedia = (filter.video && file.hasVideo)
                    || (filter.audio && file.hasAudio)
                    || (filter.image && file.hasImage)
                    || (filter.text && file.hasText);
                if (filter.mediaNegated ? hasSelectedMedia : !hasSelectedMedia)
                    return false;
            }
            const bool hasTypeFilter = filter.fileType || filter.archive
                || filter.torrent;
            const bool matchesType = (filter.fileType && file.hasFileType)
                || (filter.archive && file.hasArchive)
                || (filter.torrent && file.hasTorrent);
            if (hasTypeFilter && !matchesType)
                return false;
            return true;
        }

        /** Return query matches in the requested stable sort order.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         * Returns: Matching file rows, including archive members when asked.
         */
        private CatalogFile[] filteredFiles(CatalogFileQuery query) const
        {
            CatalogFile[] result;
            foreach (file; files)
                if (file.directoryId == query.directoryId
                    && matches(file, query.filter))
                    result ~= file;
            if (query.filter.includeArchiveMembers)
                foreach (container; files)
                    if (container.directoryId == query.directoryId
                        && container.hasArchive)
                        foreach (member; archiveMembersFor(container))
                            if (matches(member, query.filter))
                                result ~= member;
            if (query.sortOrder == CatalogSortOrder.pathDescending)
                result.reverse;
            else if (query.sortOrder == CatalogSortOrder.sizeAscending)
                result.sort!((left, right) => left.size < right.size
                    || (left.size == right.size
                        && left.relativePath < right.relativePath));
            else if (query.sortOrder == CatalogSortOrder.sizeDescending)
                result.sort!((left, right) => left.size > right.size
                    || (left.size == right.size
                        && left.relativePath < right.relativePath));
            return result;
        }

        /** Build the source binding token embedded in issued cursors.
         *
         * Returns: A token encoding the instance and opened target.
         */
        private string sourceToken() const
        {
            return instanceToken ~ "\0" ~ (cast(int) sourceTarget.mode).to!string ~ "\0"
                ~ sourceTarget.repositoryRoot ~ "\0" ~ sourceTarget.catalogPath
                ~ "\0" ~ sourceTarget.filesystemRoot;
        }

        /** Serialize filter flags into a stable cursor-binding token.
         *
         * Params:
         *     filter = Filters to encode.
         * Returns: A delimiter-joined token that changes with every flag.
         */
        private string filterToken(CatalogFilter filter) const
        {
            return filter.pathText ~ "\0" ~ (filter.caseSensitive ? "1" : "0")
                ~ (filter.video ? "1" : "0") ~ (filter.audio ? "1" : "0")
                ~ (filter.image ? "1" : "0") ~ (filter.text ? "1" : "0")
                ~ (filter.mediaNegated ? "1" : "0") ~ (filter.fileType ? "1" : "0")
                ~ (filter.archive ? "1" : "0") ~ (filter.torrent ? "1" : "0")
                ~ (filter.availableOnly ? "1" : "0")
                ~ (filter.includeArchiveMembers ? "1" : "0");
        }

        /** Build the single fake archive member row for a container.
         *
         * Params:
         *     container = Archive reference that owns the member.
         * Returns: A one-element array holding the member row.
         */
        private CatalogFile[] archiveMembersFor(CatalogFile container) const
        {
            auto entryId = ArchiveEntryId(instanceToken ~ ":archive-entry-one");
            CatalogFile member;
            member.referenceId = ReferenceId(instanceToken
                ~ ":archive-reference:" ~ container.referenceId.adapterToken
                ~ ":" ~ entryId.adapterToken);
            member.contentId = contentOne;
            member.directoryId = container.directoryId;
            member.locator = ContentLocator.entry(container.referenceId, entryId);
            member.name = "readme.txt";
            member.relativePath = container.relativePath ~ "!/nested/readme.txt";
            member.size = 10;
            member.availability = container.availability;
            return [member];
        }

        /** Build the cursor query binding for a file query.
         *
         * Params:
         *     query = Query whose directory, filter, and sort are encoded.
         * Returns: A token bound to this fake source and query.
         */
        private string fileQueryToken(CatalogFileQuery query) const
        {
            return sourceToken() ~ "\0file\0" ~ query.directoryId.token ~ "\0"
                ~ filterToken(query.filter) ~ "\0"
                ~ (cast(int) query.sortOrder).to!string;
        }

        /** Build the cursor query binding for a directory query.
         *
         * Params:
         *     query = Query whose parent and filter are encoded.
         * Returns: A token bound to this fake source and query.
         */
        private string directoryQueryToken(CatalogDirectoryQuery query) const
        {
            return sourceToken() ~ "\0directory\0" ~ query.parentId.token
                ~ "\0" ~ filterToken(query.filter);
        }

        /** Load one file page and its continuation cursors from the fake data.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     page = Requested limit and optional continuation cursor.
         * Returns: The detached page with forward/backward cursors.
         * Throws: `CatalogBackendException` with `unsupportedFeature`,
         *     `invalidCursor` for a zero limit, or a cursor bound to another
         *     source/query/page size.
         */
        private CatalogFilePage filePage(CatalogFileQuery query,
            CatalogPageRequest page)
        {
            requireTreeQueries();
            if (page.limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog page limit must be greater than zero.");
            auto all = filteredFiles(query);
            auto start = page.cursor.isValid ? page.cursor.index : 0;
            if (page.cursor.isValid
                && page.cursor.queryToken != fileQueryToken(query))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog cursor belongs to a different source or query.");
            if (start > all.length)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog cursor is outside this query result.");
            if (page.cursor.isValid && page.limit != page.cursor.pageSize)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog cursor page size does not match this request.");
            auto end = start + page.limit;
            if (end > all.length)
                end = all.length;
            CatalogFilePage result;
            result.files = all[start .. end];
            result.hasPrevious = start > 0;
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(
                    start > page.limit ? start - page.limit : 0, page.limit,
                    fileQueryToken(query));
            result.hasMore = end < all.length;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(end, page.limit,
                    fileQueryToken(query));
            return result;
        }

        /** Collapse fake file rows into deduplicated content rows.
         *
         * Params:
         *     query = Content filters; matching references select a row.
         *     page = Requested limit and optional continuation cursor.
         * Returns: The bounded content page with continuation state.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogContentPage listContents(CatalogContentQuery query,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireTreeQueries();
            if (page.limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog page limit must be greater than zero.");
            const auto queryToken = "contents\0" ~ filterToken(query.filter);
            if (page.cursor.isValid)
            {
                if (page.cursor.adapterQueryToken != queryToken
                    || page.limit != page.cursor.adapterPageSize)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidCursor,
                        "Catalog cursor belongs to a different query or page size.");
            }

            CatalogContentRow[] all;
            size_t[string] indexByContent;
            foreach (file; files)
            {
                const token = file.contentId.adapterToken;
                auto index = token in indexByContent;
                if (index is null)
                {
                    CatalogContentRow row;
                    row.id = file.contentId;
                    row.displayPath = file.relativePath;
                    row.displayName = file.name;
                    row.size = file.size;
                    row.referenceCount = 1;
                    row.availability = file.availability;
                    row.hasFileType = file.hasFileType;
                    row.hasMedia = file.hasMedia;
                    row.hasVideo = file.hasVideo;
                    row.hasAudio = file.hasAudio;
                    row.hasImage = file.hasImage;
                    row.hasText = file.hasText;
                    row.hasArchive = file.hasArchive;
                    row.hasTorrent = file.hasTorrent;
                    indexByContent[token] = all.length;
                    all ~= row;
                    continue;
                }
                auto row = &all[*index];
                ++row.referenceCount;
                if (file.relativePath < row.displayPath)
                {
                    row.displayPath = file.relativePath;
                    row.displayName = file.name;
                }
                row.hasFileType = row.hasFileType || file.hasFileType;
                row.hasMedia = row.hasMedia || file.hasMedia;
                row.hasVideo = row.hasVideo || file.hasVideo;
                row.hasAudio = row.hasAudio || file.hasAudio;
                row.hasImage = row.hasImage || file.hasImage;
                row.hasText = row.hasText || file.hasText;
                row.hasArchive = row.hasArchive || file.hasArchive;
                row.hasTorrent = row.hasTorrent || file.hasTorrent;
            }

            CatalogContentRow[] matching;
            foreach (row; all)
            {
                bool pathMatch;
                foreach (file; files)
                {
                    if (file.contentId != row.id)
                        continue;
                    if (matches(file, query.filter))
                    {
                        pathMatch = true;
                        break;
                    }
                }
                if (pathMatch)
                    matching ~= row;
            }
            const auto start = page.cursor.isValid ? page.cursor.adapterIndex : 0;
            if (start > matching.length)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog cursor is outside this query result.");
            const auto end = start + page.limit < matching.length
                ? start + page.limit : matching.length;
            CatalogContentPage result;
            result.rows = matching[start .. end];
            result.total = matching.length;
            result.hasPrevious = start > 0;
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(start > page.limit
                    ? start - page.limit : 0, page.limit, queryToken);
            result.hasMore = end < matching.length;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(end, page.limit, queryToken);
            return result;
        }

        /// Stored archive passwords keyed by reference path.
        private string[string] archivePasswords;

        /** Store or clear a fake archive password by reference path.
         *
         * Params:
         *     relativePath = Exact path or unique basename of the reference.
         *     password = Password to store; empty clears the stored value.
         * Throws: `CatalogBackendException` with `closed`, `invalidIdentifier`
         *     for an unknown or ambiguous path.
         */
        override void setArchivePassword(string relativePath, string password)
        {
            requireOpen();
            size_t[] exact;
            size_t[] byName;
            foreach (index, file; files)
                if (file.relativePath == relativePath)
                    exact ~= index;
                else if (baseName(file.relativePath) == relativePath
                    && baseName(relativePath) == relativePath)
                    byName ~= index;
            const auto matches = exact.length > 0 ? exact : byName;
            if (matches.length == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "No catalog reference matches the requested path.");
            if (matches.length > 1)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "The requested filename is ambiguous in this catalog.");
            if (password.length == 0)
                archivePasswords.remove(files[matches[0]].relativePath);
            else
                archivePasswords[files[matches[0]].relativePath] = password;
        }

        /** Reject the document view; the fake is a transactional store.
         *
         * Returns: Never returns; this fake always throws.
         * Throws: `CatalogBackendException` with `unsupportedFeature`.
         */
        override CatalogDocument document()
        {
            throw new CatalogBackendException(
                CatalogBackendErrorCode.unsupportedFeature,
                "The contract fake has no in-memory document view.");
        }

        /** Return the target this fake was opened with.
         *
         * Returns: The stored operation target.
         * Throws: `CatalogBackendException` with `closed`.
         */
        override OperationTarget target()
        {
            requireOpen();
            return sourceTarget;
        }

        /** Return the fake source label and storage mode.
         *
         * Returns: Storage mode from the target and a display label.
         * Throws: `CatalogBackendException` with `closed`.
         */
        override CatalogSourceInfo sourceInfo()
        {
            requireOpen();
            CatalogSourceInfo result;
            result.storageMode = sourceTarget.mode;
            result.displayName = sourceTarget.mode == OperationStorageMode.jsonCatalog
                ? sourceTarget.catalogPath : "in-memory repository";
            return result;
        }

        /** Return minimal repository-style metadata for the fake source.
         *
         * Returns: A synthetic repository root and schema version.
         * Throws: `CatalogBackendException` with `closed`.
         */
        override RepositoryInfo repositoryInfo()
        {
            requireOpen();
            RepositoryInfo result;
            result.rootPath = sourceTarget.mode == OperationStorageMode.repository
                ? sourceTarget.repositoryRoot : sourceTarget.catalogPath;
            result.schemaVersion = sourceTarget.mode == OperationStorageMode.repository ? 4 : 5;
            return result;
        }

        /** Return the capabilities advertised by the fake backend.
         *
         * Returns: Tree-query, export, archive, and torrent features for the
         *     fixed data set.
         * Throws: `CatalogBackendException` with `closed`.
         */
        override CatalogBackendCapabilities capabilities()
        {
            requireOpen();
            CatalogBackendCapabilities result;
            result.supportsTreeQueries = sourceTarget.mode == OperationStorageMode.repository
                || sourceTarget.filesystemRoot.length > 0;
            result.operations = [OperationKind.analyze];
            if (result.supportsTreeQueries)
                result.operations ~= OperationKind.scan;
            result.supportsConcurrentReads = true;
            result.supportsReadsDuringMutation = true;
            result.supportsFilteredExport = result.supportsTreeQueries;
            result.supportsArchiveEntryQueries = true;
            result.supportsTorrentEntryQueries = true;
            result.supportsFirstClassArchiveReferences = true;
            result.persistence = CatalogPersistence.transactionalStore;
            return result;
        }

        /** Aggregate fake root rows under the given filter.
         *
         * Params:
         *     filter = Source-neutral filters; archive members may be included.
         * Returns: Directory, reference, and aggregate-size totals.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `closed`.
         */
        override CatalogRootSummary rootSummary(CatalogFilter filter = CatalogFilter.init)
        {
            requireTreeQueries();
            CatalogRootSummary result;
            result.childDirectoryCount = directories.length;
            foreach (file; files)
                if (matches(file, filter))
                {
                    result.fileReferenceCount++;
                    result.aggregateSize += file.size;
                }
            if (filter.includeArchiveMembers)
                foreach (container; files)
                    if (container.hasArchive)
                        foreach (member; archiveMembersFor(container))
                            if (matches(member, filter))
                            {
                                ++result.fileReferenceCount;
                                result.aggregateSize += member.size;
                            }
            return result;
        }

        /** Page through the fixed fake directory rows.
         *
         * Params:
         *     query = Parent directory whose immediate children are requested.
         *     page = Requested limit and optional continuation cursor.
         * Returns: The bounded directory page with continuation state.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogDirectoryPage listDirectories(CatalogDirectoryQuery query,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireTreeQueries();
            if (page.limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog page limit must be greater than zero.");
            CatalogDirectory[] matching;
            foreach (directory; directories)
                if (directory.parentId == query.parentId)
                    matching ~= directory;
            auto start = page.cursor.isValid ? page.cursor.index : 0;
            if (start > matching.length)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Directory cursor is outside this query result.");
            if (page.cursor.isValid
                && page.cursor.queryToken != directoryQueryToken(query))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Directory cursor belongs to a different source or query.");
            if (page.cursor.isValid && page.limit != page.cursor.pageSize)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Directory cursor page size does not match this request.");
            auto end = start + page.limit;
            if (end > matching.length)
                end = matching.length;
            CatalogDirectoryPage result;
            result.directories = matching[start .. end];
            result.hasPrevious = start > 0;
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(
                    start > page.limit ? start - page.limit : 0, page.limit,
                    directoryQueryToken(query));
            result.hasMore = end < matching.length;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(end, page.limit,
                    directoryQueryToken(query));
            return result;
        }

        /** Page through fake file references from the first page.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     page = Requested limit and optional continuation cursor.
         * Returns: The requested file page.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogFilePage listFiles(CatalogFileQuery query,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            return filePage(query, page);
        }

        /** Continue forward from a fake file cursor.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     cursor = Cursor returned by this fake for the same query.
         * Returns: The next file page.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogFilePage nextFilesPage(CatalogFileQuery query,
            CatalogPageCursor cursor)
        {
            return filePage(query, CatalogPageRequest(cursor.pageSize, cursor));
        }

        /** Return the fake page before a file cursor.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     cursor = Cursor returned by this fake for the same query.
         * Returns: The preceding file page in display order.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor`.
         */
        override CatalogFilePage previousFilesPage(CatalogFileQuery query,
            CatalogPageCursor cursor)
        {
            return filePage(query, CatalogPageRequest(cursor.pageSize, cursor));
        }

        /** Load a fake page adjacent to an anchor file path.
         *
         * Params:
         *     query = Directory scope, filters, and sort order.
         *     anchorRelativePath = Anchor path; empty starts at the first file.
         *     forward = Select rows after the anchor instead of before it.
         *     limit = Maximum rows to return; must be greater than zero.
         * Returns: The adjacent page, or an empty page for an unknown anchor.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `invalidCursor` for a zero limit.
         */
        override CatalogFilePage listFilesFrom(CatalogFileQuery query,
            string anchorRelativePath, bool forward, size_t limit = 250)
        {
            requireTreeQueries();
            if (limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Catalog page limit must be greater than zero.");
            auto all = filteredFiles(query);
            if (anchorRelativePath.length == 0)
            {
                if (!forward || all.length == 0)
                    return CatalogFilePage.init;
                CatalogFilePage result;
                const auto end = limit < all.length ? limit : all.length;
                result.files = all[0 .. end];
                result.hasMore = end < all.length;
                if (result.hasMore)
                    result.nextCursor = CatalogPageCursor(end, limit,
                        fileQueryToken(query));
                return result;
            }
            size_t anchor = size_t.max;
            foreach (index, file; all)
                if (file.relativePath == anchorRelativePath)
                {
                    anchor = index;
                    break;
                }
            if (anchor == size_t.max)
                return CatalogFilePage.init;
            const size_t start = forward ? anchor + 1
                : (anchor > limit ? anchor - limit : 0);
            const size_t end = forward
                ? (start + limit < all.length ? start + limit : all.length)
                : anchor;
            CatalogFilePage result;
            result.files = all[start .. end];
            result.hasPrevious = start > 0;
            if (result.hasPrevious)
                result.previousCursor = CatalogPageCursor(start > limit
                    ? start - limit : 0, limit, fileQueryToken(query));
            result.hasMore = forward ? end < all.length : anchor < all.length;
            if (result.hasMore)
                result.nextCursor = CatalogPageCursor(end, limit,
                    fileQueryToken(query));
            return result;
        }

        /** Load a fake content snapshot for one of the two known contents.
         *
         * Params:
         *     contentId = Content identity issued by this fake.
         *     details = Detail families to include in the snapshot.
         * Returns: The requested content snapshot.
         * Throws: `CatalogBackendException` with `closed` or `invalidIdentifier`.
         */
        override CatalogContentSnapshot loadContent(ContentId contentId,
            CatalogDetailMask details = CatalogDetailMask.init)
        {
            requireOpen();
            if (contentId != contentOne && contentId != contentTwo)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Unknown content identity.");
            CatalogContentSnapshot result;
            result.id = contentId;
            result.fingerprint.size = contentId == contentOne ? 10 : 20;
            result.fingerprint.complete = true;
            if (contentId == contentOne)
            {
                result.hasTorrent = true;
                result.torrentSummary.name = "payload.torrent";
                result.torrentSummary.totalSize = 10;
                result.torrentSummary.fileListAvailable = true;
            }
            else
            {
                result.hasArchive = true;
                result.archiveSummary.indexKnown = true;
                result.archiveSummary.entryCount = 1;
            }
            return result;
        }

        /** Page through fake archive entries for the archive content.
         *
         * Params:
         *     contentId = Content identity; only the archive content is accepted.
         *     page = Requested limit and optional continuation cursor.
         * Returns: One entry on the first page, otherwise an empty page.
         * Throws: `CatalogBackendException` with `closed` or `invalidIdentifier`.
         */
        override CatalogArchiveEntryPage listArchiveEntries(ContentId contentId,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireOpen();
            if (contentId != contentTwo)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Content is not an indexed archive.");
            CatalogArchiveEntryPage result;
            if (!page.cursor.isValid || page.cursor.index == 0)
            {
                CatalogArchiveEntry entry;
                entry.id = ArchiveEntryId(instanceToken ~ ":archive-entry-one");
                entry.name = "nested/readme.txt";
                entry.size = 10;
                result.entries = [entry];
            }
            return result;
        }

        /** Return fake member references for an archive container.
         *
         * Params:
         *     containerReferenceId = Reference identity of an archive container.
         *     page = Requested limit and optional continuation cursor.
         * Returns: One member on the first page, otherwise an empty page.
         * Throws: `CatalogBackendException` with `unsupportedFeature`,
         *     `invalidIdentifier`, or `invalidCursor`.
         */
        override CatalogArchiveMemberPage listArchiveMembers(
            ReferenceId containerReferenceId, CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireTreeQueries();
            if (!containerReferenceId.isValid || page.limit == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Archive member query requires a valid container reference and page.");
            CatalogFile container;
            foreach (file; files)
                if (file.referenceId == containerReferenceId)
                    container = file;
            if (!container.referenceId.isValid || !container.hasArchive)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Reference is not an indexed archive container.");
            const auto queryToken = sourceToken() ~ "\0archive-members\0"
                ~ containerReferenceId.adapterToken;
            if (page.cursor.isValid
                && (page.cursor.adapterQueryToken != queryToken
                    || page.cursor.adapterPageSize != page.limit))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidCursor,
                    "Archive member cursor does not match this source or query.");
            const auto start = page.cursor.isValid
                ? page.cursor.adapterIndex : 0;
            if (start > 1)
                throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                    "Archive member cursor is outside the result sequence.");
            CatalogArchiveMemberPage result;
            if (start == 0)
            {
                auto entryId = ArchiveEntryId(instanceToken
                    ~ ":archive-entry-one");
                CatalogArchiveMember member;
                member.referenceId = ReferenceId(instanceToken
                    ~ ":archive-reference:" ~ containerReferenceId.adapterToken
                    ~ ":" ~ entryId.adapterToken);
                member.contentId = contentOne;
                member.locator = ContentLocator.entry(containerReferenceId, entryId);
                member.name = "readme.txt";
                member.relativePath = "nested/readme.txt";
                member.size = 10;
                member.availability = container.availability;
                member.fingerprint.size = 10;
                member.fingerprint.complete = true;
                result.members = [member];
            }
            return result;
        }

        /** Return fake torrent manifest rows for the torrent content.
         *
         * Params:
         *     contentId = Content identity; only the torrent content is accepted.
         *     page = Requested limit and optional continuation cursor.
         * Returns: One manifest entry on the first page.
         * Throws: `CatalogBackendException` with `closed` or `invalidIdentifier`.
         */
        override CatalogTorrentEntryPage listTorrentEntries(ContentId contentId,
            CatalogPageRequest page = CatalogPageRequest.init)
        {
            requireOpen();
            if (contentId != contentOne)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidIdentifier,
                    "Content is not an indexed torrent.");
            CatalogTorrentEntryPage result;
            if (!page.cursor.isValid || page.cursor.index == 0)
                result.entries = [CatalogTorrentManifestEntry(["payload.bin"], 10)];
            return result;
        }

        /** Resolve a fake directory path to its identity.
         *
         * Params:
         *     relativePath = Normalized path; empty or "." denotes the root.
         * Returns: The matching identity, or an invalid ID when unresolved.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `closed`.
         */
        override DirectoryId resolveDirectory(string relativePath)
        {
            requireTreeQueries();
            if (relativePath.length == 0 || relativePath == ".")
                return DirectoryId.init;
            foreach (directory; directories)
                if (directory.relativePath == relativePath)
                    return directory.id;
            return DirectoryId.init;
        }

        /** Resolve a fake file or archive-member path to its identity.
         *
         * Params:
         *     relativePath = Normalized reference path, including virtual
         *         member paths.
         * Returns: The matching identity, or an invalid ID when unresolved.
         * Throws: `CatalogBackendException` with `unsupportedFeature` or
         *     `closed`.
         */
        override ReferenceId resolveReference(string relativePath)
        {
            requireTreeQueries();
            foreach (file; files)
                if (file.relativePath == relativePath)
                    return file.referenceId;
            foreach (container; files)
                if (container.hasArchive)
                    foreach (member; archiveMembersFor(container))
                        if (member.relativePath == relativePath)
                            return member.referenceId;
            return ReferenceId.init;
        }

        /** Load a fake file or archive-member reference row.
         *
         * Params:
         *     referenceId = Reference identity issued by this fake.
         * Returns: The matching detached reference row.
         * Throws: `CatalogBackendException` with `unsupportedFeature`,
         *     `closed`, or `invalidIdentifier` for an unknown identity.
         */
        override CatalogFile loadReference(ReferenceId referenceId)
        {
            requireTreeQueries();
            foreach (file; files)
                if (file.referenceId == referenceId)
                    return file;
            foreach (container; files)
                if (container.hasArchive)
                    foreach (member; archiveMembersFor(container))
                        if (member.referenceId == referenceId)
                            return member;
            throw new CatalogBackendException(
                CatalogBackendErrorCode.invalidIdentifier,
                "Unknown reference identity.");
        }

        /** Reject member extraction; the fake has no physical content.
         *
         * Params:
         *     memberReferenceId = Identity whose content is requested.
         *     cancellation = Optional cooperative cancellation flag.
         * Returns: Never returns; this fake always throws.
         * Throws: `CatalogBackendException` with `unsupportedFeature`.
         */
        override MemberContentLease acquireMemberContent(
            ReferenceId memberReferenceId, shared(bool)* cancellation = null)
        {
            requireTreeQueries();
            throw new CatalogBackendException(
                CatalogBackendErrorCode.unsupportedFeature,
                "The in-memory contract test backend cannot extract members.");
        }

        /** Return one synthetic repository blob page.
         *
         * Params:
         *     options = Query options; `limit` must be greater than zero.
         * Returns: A page with one blob and its flags.
         * Throws: `Exception` when `options.limit` is not positive.
         */
        override RepositoryBlobPage queryBlobs(RepositoryQueryOptions options)
        {
            enforce(options.limit > 0);
            RepositoryBlobPage result;
            result.total = 1;
            result.blobIds = [1];
            result.blobs = [new NamedBinaryBlob([new FileSpec("alpha.txt", "")], 10)];
            result.flags = [RepositoryBlobFlags(true, false, false, false, false,
                false, false, false)];
            return result;
        }

        /** Return one synthetic duplicate group.
         *
         * Params:
         *     limit = Maximum groups requested; must be greater than zero.
         * Returns: A single group with a fixed size and blob list.
         * Throws: `Exception` when `limit` is zero.
         */
        override RepositoryDuplicateGroup[] queryDuplicateGroups(size_t limit = 100)
        {
            enforce(limit > 0);
            return [RepositoryDuplicateGroup(10, [1])];
        }

        /** Acknowledge a fake subset export request.
         *
         * Params:
         *     query = Selected path prefix and filters.
         *     options = Output format and destination details.
         *     control = Unused cooperative control handle.
         *     operationId = Unused operation identifier.
         * Returns: The counted export result from `exportSubset`.
         */
        override CatalogExportResult exportSubsetControlled(CatalogSubsetQuery query,
            CatalogExportOptions options, OperationControl control,
            ulong operationId)
        {
            return exportSubset(query, options);
        }

        /** Count fake subset matches without writing an output file.
         *
         * Params:
         *     query = Selected path prefix and filters.
         *     options = Output options; `outputPath` must not be empty.
         * Returns: Counts for the matching references and contents.
         * Throws: `CatalogBackendException` with `closed`,
         *     `unsupportedFeature`, or `invalidTarget`.
         */
        override CatalogExportResult exportSubset(CatalogSubsetQuery query,
            CatalogExportOptions options)
        {
            requireOpen();
            if (!capabilities().supportsFilteredExport)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedFeature,
                    "Filtered export requires a rooted catalog source.");
            if (options.outputPath.length == 0)
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.invalidTarget,
                    "An explicit subset export path is required.");
            bool[string] contentIds;
            CatalogExportResult result;
            result.outputPath = options.outputPath;
            foreach (file; files)
            {
                const bool inPrefix = query.pathPrefix.length == 0
                    || file.relativePath == query.pathPrefix
                    || file.relativePath.startsWith(query.pathPrefix ~ "/");
                if (!inPrefix || !matches(file, query.filter))
                    continue;
                result.referencesExported++;
                contentIds[file.contentId.token] = true;
            }
            result.contentsExported = contentIds.length;
            result.committed = true;
            return result;
        }

        /** Accept and ignore a JSON import request.
         *
         * Params:
         *     jsonPath = Source path; must not be empty (asserted).
         *     options = Import options, intentionally unused.
         * Throws: `CatalogBackendException` with `closed`; `AssertError` for an
         *     empty path.
         */
        override void importJson(string jsonPath, JsonImportOptions options = JsonImportOptions.init)
        {
            requireOpen();
            assert(jsonPath.length > 0);
            cast(void) options;
        }

        /** Delegate a controlled JSON import to `importJson`.
         *
         * Params:
         *     jsonPath = Source path forwarded to `importJson`.
         *     options = Import options forwarded to `importJson`.
         *     control = Unused cooperative control handle.
         *     operationId = Unused operation identifier.
         * Returns: Always `true`; the fake cannot be cancelled.
         * Throws: `CatalogBackendException` with `closed`; `AssertError` for an
         *     empty path.
         */
        override bool importJsonControlled(string jsonPath,
            JsonImportOptions options, OperationControl control,
            ulong operationId)
        {
            importJson(jsonPath, options);
            return true;
        }

        /** Return a completed fake scan result for a matching target.
         *
         * Params:
         *     request = Scan request; its target must match this fake.
         *     control = Unused operation control handle.
         * Returns: A completed result reporting all fake files as added.
         * Throws: `CatalogBackendException` with `closed`, `invalidTarget`, or
         *     `unsupportedOperation`.
         */
        override OperationResult runOperation(ScanOperationRequest request,
            OperationControl control)
        {
            requireTarget(request.target, OperationKind.scan);
            requireSupported(OperationKind.scan);
            OperationResult result;
            result.operationId = request.operationId;
            result.operation = OperationKind.scan;
            result.state = OperationState.completed;
            result.changesCommitted = true;
            result.scanSummary.filesFound = files.length;
            result.scanSummary.filesAdded = files.length;
            return result;
        }

        /** Return a completed fake metadata result for a matching target.
         *
         * Params:
         *     request = Metadata request; its target must match this fake.
         *     control = Unused operation control handle.
         * Returns: A completed result without summary changes.
         * Throws: `CatalogBackendException` with `closed`, `invalidTarget`, or
         *     `unsupportedOperation`.
         */
        override OperationResult runOperation(MetadataOperationRequest request,
            OperationControl control)
        {
            requireTarget(request.target, OperationKind.metadata);
            requireSupported(OperationKind.metadata);
            OperationResult result;
            result.operationId = request.operationId;
            result.operation = OperationKind.metadata;
            result.state = OperationState.completed;
            return result;
        }

        /** Return a completed fake analysis result for a matching target.
         *
         * Params:
         *     request = Analysis request; its target must match this fake.
         *     control = Unused operation control handle.
         * Returns: A completed result that reports committed changes.
         * Throws: `CatalogBackendException` with `closed`, `invalidTarget`, or
         *     `unsupportedOperation`.
         */
        override OperationResult runOperation(AnalysisOperationRequest request,
            OperationControl control)
        {
            requireTarget(request.target, OperationKind.analyze);
            requireSupported(OperationKind.analyze);
            OperationResult result;
            result.operationId = request.operationId;
            result.operation = OperationKind.analyze;
            result.state = OperationState.completed;
            result.changesCommitted = true;
            return result;
        }

        /// Mark this fake backend closed; repeated calls have no effect.
        override void close()
        {
            closed = true;
        }

        /** Reject operations not advertised by `capabilities`.
         *
         * Params:
         *     operation = Operation kind to check.
         * Throws: `CatalogBackendException` with `unsupportedOperation`.
         */
        private void requireSupported(OperationKind operation)
        {
            if (!capabilities().supports(operation))
                throw new CatalogBackendException(
                    CatalogBackendErrorCode.unsupportedOperation,
                    "The opened source does not support this operation.");
        }
    }

    /** Factory that opens `FakeCatalogBackend` instances for valid targets. */
    private class FakeCatalogBackendFactory : CatalogBackendFactory
    {
        /** Validate and open a fake backend for the requested target.
         *
         * Params:
         *     target = Repository or JSON target; the relevant root/path must
         *         not be empty.
         * Returns: A new fake backend bound to `target`.
         * Throws: `CatalogBackendException` with `invalidTarget` for an empty
         *     repository root or catalog path.
         */
        override CatalogBackend open(OperationTarget target)
        {
            final switch (target.mode)
            {
            case OperationStorageMode.repository:
                if (target.repositoryRoot.length == 0)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidTarget,
                        "A repository target requires a root.");
                break;
            case OperationStorageMode.jsonCatalog:
                if (target.catalogPath.length == 0)
                    throw new CatalogBackendException(
                        CatalogBackendErrorCode.invalidTarget,
                        "A JSON target requires a catalog path.");
                break;
            }
            return new FakeCatalogBackend(target);
        }
    }

    @("catalog backend contract exposes storage-neutral bounded queries and operations")
    unittest
    {
        bool rejectedAbsoluteLocator;
        try
        {
            const auto unexpectedLocator = ContentLocator.file("/outside/source.txt");
            rejectedAbsoluteLocator = unexpectedLocator.kind == ContentLocator.Kind.none;
        }
        catch (CatalogBackendException failure)
            rejectedAbsoluteLocator = failure.code
                == CatalogBackendErrorCode.invalidLocator;
        assert(rejectedAbsoluteLocator);

        bool rejectedTraversalLocator;
        try
        {
            const auto unexpectedLocator = ContentLocator.file("nested/../outside.txt");
            rejectedTraversalLocator = unexpectedLocator.kind == ContentLocator.Kind.none;
        }
        catch (CatalogBackendException failure)
            rejectedTraversalLocator = failure.code
                == CatalogBackendErrorCode.invalidLocator;
        assert(rejectedTraversalLocator);

        auto factory = new FakeCatalogBackendFactory();
        bool rejectedEmptyTarget;
        try
        {
            auto unexpectedBackend = factory.open(OperationTarget.init);
            rejectedEmptyTarget = unexpectedBackend.target().repositoryRoot.length > 0;
        }
        catch (CatalogBackendException failure)
            rejectedEmptyTarget = failure.code
                == CatalogBackendErrorCode.invalidTarget;
        assert(rejectedEmptyTarget);

        auto target = OperationTarget.jsonTarget("library.json", "/library");
        auto analysisOnlyTarget = OperationTarget.jsonTarget("library.json");
        auto analysisOnlyBackend = factory.open(analysisOnlyTarget);
        assert(!analysisOnlyBackend.capabilities().supportsTreeQueries);
        assert(analysisOnlyBackend.capabilities().supports(OperationKind.analyze));
        assert(!analysisOnlyBackend.capabilities().supports(OperationKind.scan));
        AnalysisOperationRequest analysisOnlyRequest;
        analysisOnlyRequest.operationId = 40;
        analysisOnlyRequest.target = analysisOnlyTarget;
        assert(analysisOnlyBackend.runOperation(analysisOnlyRequest,
            new OperationControl()).state == OperationState.completed);
        bool rejectedRootQuery;
        try
            analysisOnlyBackend.rootSummary();
        catch (CatalogBackendException failure)
            rejectedRootQuery = failure.code == CatalogBackendErrorCode.unsupportedFeature;
        assert(rejectedRootQuery);
        analysisOnlyBackend.close();

        auto backend = factory.open(target);
        assert(backend.target().mode == OperationStorageMode.jsonCatalog);
        assert(backend.sourceInfo().storageMode == OperationStorageMode.jsonCatalog);
        auto capabilities = backend.capabilities();
        assert(capabilities.supports(OperationKind.scan));
        assert(capabilities.supports(OperationKind.analyze));
        assert(!capabilities.supports(OperationKind.metadata));
        assert(capabilities.supportsConcurrentReads);
        assert(capabilities.supportsReadsDuringMutation);
        assert(capabilities.supportsFilteredExport);
        assert(capabilities.supportsArchiveEntryQueries);
        assert(capabilities.supportsTorrentEntryQueries);
        assert(capabilities.supportsFirstClassArchiveReferences);

        const auto root = backend.rootSummary();
        assert(root.childDirectoryCount == 2);
        assert(root.fileReferenceCount == 4);
        assert(root.aggregateSize == 50);

        CatalogDirectoryQuery directoryQuery;
        CatalogPageRequest oneDirectory;
        oneDirectory.limit = 1;
        auto firstDirectories = backend.listDirectories(directoryQuery, oneDirectory);
        assert(firstDirectories.directories.length == 1);
        assert(firstDirectories.directories[0].relativePath == "a");
        assert(firstDirectories.hasMore);
        CatalogPageRequest nextDirectoryRequest;
        nextDirectoryRequest.limit = 1;
        nextDirectoryRequest.cursor = firstDirectories.nextCursor;
        auto secondDirectories = backend.listDirectories(directoryQuery,
            nextDirectoryRequest);
        assert(secondDirectories.directories[0].relativePath == "b");

        CatalogFileQuery fileQuery;
        fileQuery.directoryId = firstDirectories.directories[0].id;
        CatalogPageRequest firstPageRequest;
        firstPageRequest.limit = 1;
        auto firstPage = backend.listFiles(fileQuery, firstPageRequest);
        assert(firstPage.files.length == 1);
        assert(firstPage.files[0].relativePath == "a/one.txt");
        assert(firstPage.files[0].contentId.isValid);
        assert(firstPage.hasMore);

        auto nextPage = backend.nextFilesPage(fileQuery, firstPage.nextCursor);
        assert(nextPage.files.length == 1);
        assert(nextPage.files[0].relativePath == "a/two-copy.txt");
        assert(nextPage.hasPrevious);
        assert(nextPage.hasMore);
        auto previousPage = backend.previousFilesPage(fileQuery,
            nextPage.previousCursor);
        assert(previousPage.files[0].relativePath == "a/one.txt");
        auto thirdPage = backend.nextFilesPage(fileQuery, nextPage.nextCursor);
        assert(thirdPage.files.length == 1);
        assert(thirdPage.files[0].relativePath == "a/three-copy.txt");
        assert(!thirdPage.hasMore);

        auto changedQuery = fileQuery;
        changedQuery.filter.pathText = "copy";
        bool rejectedMismatchedCursor;
        try
        {
            const auto unexpectedPage = backend.nextFilesPage(changedQuery,
                firstPage.nextCursor);
            rejectedMismatchedCursor = unexpectedPage.files.length == size_t.max;
        }
        catch (CatalogBackendException failure)
            rejectedMismatchedCursor = failure.code
                == CatalogBackendErrorCode.invalidCursor;
        assert(rejectedMismatchedCursor);

        auto otherBackend = factory.open(target);
        bool rejectedCrossSourceCursor;
        try
        {
            const auto unexpectedPage = otherBackend.nextFilesPage(fileQuery,
                firstPage.nextCursor);
            rejectedCrossSourceCursor = unexpectedPage.files.length == size_t.max;
        }
        catch (CatalogBackendException failure)
            rejectedCrossSourceCursor = failure.code
                == CatalogBackendErrorCode.invalidCursor;
        assert(rejectedCrossSourceCursor);
        otherBackend.close();

        /* UI handles are opaque kind-scoped keys; paths resolve back to IDs. */
        assert(backend.uiHandle(firstPage.files[0].referenceId)
            .startsWith("ref:"));
        assert(backend.uiHandle(firstPage.files[0].contentId)
            .startsWith("content:"));
        assert(backend.uiHandle(firstDirectories.directories[0].id)
            .startsWith("dir:"));
        assert(backend.uiHandle(firstPage.files[0].referenceId)
            != backend.uiHandle(firstPage.files[0].contentId));
        bool rejectedInvalidHandle;
        try
            backend.uiHandle(ReferenceId.init);
        catch (CatalogBackendException failure)
            rejectedInvalidHandle = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(rejectedInvalidHandle);

        /* Content rows collapse duplicate references into one display row. */
        auto contentPage = backend.listContents(CatalogContentQuery.init);
        assert(contentPage.total == 2);
        assert(contentPage.rows.length == 2);
        assert(contentPage.rows[0].displayPath == "a/one.txt");
        assert(contentPage.rows[0].referenceCount == 3);
        assert(contentPage.rows[1].displayPath == "b/photo.bmp");
        assert(contentPage.rows[1].referenceCount == 1);
        assert(contentPage.rows[1].hasImage);
        CatalogContentQuery contentTextQuery;
        contentTextQuery.filter.pathText = "photo";
        const auto filteredContents = backend.listContents(contentTextQuery);
        assert(filteredContents.rows.length == 1);
        assert(filteredContents.rows[0].displayPath == "b/photo.bmp");
        CatalogPageRequest contentRequest;
        contentRequest.limit = 1;
        const auto firstContents = backend.listContents(CatalogContentQuery.init,
            contentRequest);
        assert(firstContents.rows.length == 1 && firstContents.hasMore);
        const auto secondContents = backend.listContents(
            CatalogContentQuery.init,
            CatalogPageRequest(1, firstContents.nextCursor));
        assert(secondContents.rows.length == 1 && !secondContents.hasMore);

        /* Archive passwords are stored by reference path. */
        backend.setArchivePassword("a/one.txt", "secret");
        backend.setArchivePassword("a/one.txt", "");
        bool rejectedUnknownPasswordPath;
        try
            backend.setArchivePassword("missing.txt", "secret");
        catch (CatalogBackendException failure)
            rejectedUnknownPasswordPath = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(rejectedUnknownPasswordPath);

        assert(backend.resolveDirectory("a")
            == firstDirectories.directories[0].id);
        assert(!backend.resolveDirectory("").isValid);
        assert(!backend.resolveDirectory("a/missing").isValid);
        assert(backend.resolveReference("a/one.txt")
            == firstPage.files[0].referenceId);
        assert(!backend.resolveReference("a/missing.txt").isValid);
        assert(backend.loadReference(firstPage.files[0].referenceId).relativePath
            == "a/one.txt");
        bool rejectedMissingReference;
        try
            backend.loadReference(ReferenceId.init);
        catch (CatalogBackendException failure)
            rejectedMissingReference = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(rejectedMissingReference);

        const auto details = backend.loadContent(firstPage.files[0].contentId,
            CatalogDetailMask(true, false, false, false, false));
        assert(details.id == firstPage.files[0].contentId);
        assert(details.fingerprint.complete);
        CatalogFileQuery imageQuery;
        imageQuery.directoryId = secondDirectories.directories[0].id;
        auto imagePage = backend.listFiles(imageQuery);
        auto archivePage = backend.listArchiveEntries(imagePage.files[0].contentId);
        assert(archivePage.entries.length == 1);
        assert(archivePage.entries[0].name == "nested/readme.txt");
        auto archiveMembers = backend.listArchiveMembers(
            imagePage.files[0].referenceId);
        assert(archiveMembers.members.length == 1);
        assert(archiveMembers.members[0].contentId.isValid);
        assert(archiveMembers.members[0].locator.kind
            == ContentLocator.Kind.archiveEntry);
        assert(archiveMembers.members[0].relativePath == "nested/readme.txt");
        bool rejectedNonContainer;
        try
            backend.listArchiveMembers(firstPage.files[0].referenceId);
        catch (CatalogBackendException failure)
            rejectedNonContainer = failure.code
                == CatalogBackendErrorCode.invalidIdentifier;
        assert(rejectedNonContainer);
        auto torrentPage = backend.listTorrentEntries(firstPage.files[0].contentId);
        assert(torrentPage.entries.length == 1);
        assert(torrentPage.entries[0].pathComponents == ["payload.bin"]);
        auto duplicateGroups = backend.queryDuplicateGroups();
        assert(duplicateGroups.length == 1);
        assert(duplicateGroups[0].fileSize == 10);
        auto exportOptions = CatalogExportOptions(CatalogExportFormat.jsonV5,
            "/tmp/subset.json");
        const auto subset = backend.exportSubset(CatalogSubsetQuery("a", CatalogFilter.init),
            exportOptions);
        assert(subset.referencesExported == 3);
        assert(subset.contentsExported == 1);
        assert(subset.committed);

        ScanOperationRequest scan;
        scan.operationId = 41;
        scan.target = target;
        const auto scanResult = backend.runOperation(scan, new OperationControl());
        assert(scanResult.state == OperationState.completed);
        assert(scanResult.scanSummary.filesAdded == 4);

        MetadataOperationRequest metadata;
        metadata.operationId = 42;
        metadata.target = target;
        bool rejectedAsUnsupported;
        try
            backend.runOperation(metadata, new OperationControl());
        catch (CatalogBackendException failure)
        {
            rejectedAsUnsupported = failure.code
                == CatalogBackendErrorCode.unsupportedOperation;
        }
        assert(rejectedAsUnsupported);

        AnalysisOperationRequest analyze;
        analyze.operationId = 44;
        analyze.target = target;
        const auto analyzeResult = backend.runOperation(analyze, new OperationControl());
        assert(analyzeResult.state == OperationState.completed);

        auto wrongTargetScan = scan;
        wrongTargetScan.operationId = 43;
        wrongTargetScan.target = OperationTarget.jsonTarget("library.json",
            "/different-root");
        bool rejectedMismatchedTarget;
        try
            backend.runOperation(wrongTargetScan, new OperationControl());
        catch (CatalogBackendException failure)
            rejectedMismatchedTarget = failure.code
                == CatalogBackendErrorCode.invalidTarget;
        assert(rejectedMismatchedTarget);

        backend.close();
        bool rejectedAfterClose;
        try
            backend.rootSummary();
        catch (CatalogBackendException failure)
            rejectedAfterClose = failure.code == CatalogBackendErrorCode.closed;
        assert(rejectedAfterClose);
    }
}
