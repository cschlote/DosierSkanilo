/** Directory and file query members of `JsonCatalogBackend`.
 *
 *
 * Tree and file pages apply filters, sort orders, and cursors on the in-memory index.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.jsontree;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.file : exists;
import std.path : baseName, buildPath;
import dosierarkivo.archive : appendArchiveVirtualPath, archivePathMatchesText,
    archivePathSeparator, escapeArchiveVirtualPath;
import dosierskanilo.catalogbackend;
import dosierskanilo.operationrunner;
import dosierskanilo.jsoncatalogbackend : CatalogSlice, ArchiveMemberRow,
    ArchiveMemberRows;

/** Members of `JsonCatalogBackend` mixed into the class; see jsontree.d. */
mixin template JsonTreeQueries()
{
    /**
     * Count directory and file references directly below the source root.
     *
     * Archive members are included in the counts only when
     * `filter.includeArchiveMembers` is set.
     *
     * Params:
     *     filter = Optional source-neutral filters applied to directories and
     *         files.
     * Returns: Bounded root aggregates for matching content.
     * Throws: `CatalogBackendException` when the catalog is closed, unreadable,
     *     or tree queries are unavailable.
     */
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

    /**
     * List immediate child directories that match a query.
     *
     * Params:
     *     query = Parent directory and optional filters.
     *     page = Page size and optional continuation cursor.
     * Returns: A detached page of matching directories with continuation
     *     cursors.
     * Throws: `CatalogBackendException` for a closed backend, unavailable tree
     *     queries, or an invalid or mismatched cursor.
     */
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

    /**
     * List immediate file references that match a query and sort order.
     *
     * Params:
     *     query = Directory, filters, and stable sort order.
     *     page = Page size and optional continuation cursor.
     * Returns: A detached page of matching files with refreshed availability.
     * Throws: `CatalogBackendException` for a closed backend, unavailable tree
     *     queries, or an invalid or mismatched cursor.
     */
    override CatalogFilePage listFiles(CatalogFileQuery query,
        CatalogPageRequest page = CatalogPageRequest.init)
    {
        requireTreeQueries();
        size_t total;
        forEachMatchingFile(query, (ref CatalogFile, size_t) { ++total; });
        const auto slice = pageSlice(page, fileQueryToken(query), total);
        CatalogFilePage result;
        result.files = matchingWindow(query, slice.start, slice.end);
        result.nextCursor = slice.nextCursor;
        result.previousCursor = slice.previousCursor;
        result.hasMore = slice.hasMore;
        result.hasPrevious = slice.hasPrevious;
        return result;
    }

    /**
     * List files adjacent to an anchor path for keyboard-style navigation.
     *
     * With an empty anchor this returns the first forward page, or an empty page
     * when moving backward. When the anchor is not present in the result set the
     * returned page is empty.
     *
     * Params:
     *     query = Directory, filters, and stable sort order.
     *     anchorRelativePath = Path of the current row, or an empty string.
     *     forward = Whether to return rows after the anchor instead of before it.
     *     limit = Maximum number of rows to return; must be greater than zero.
     * Returns: A detached page of rows adjacent to the anchor.
     * Throws: `CatalogBackendException` when `limit` is zero, the backend is
     *     closed, or tree queries are unavailable.
     */
    override CatalogFilePage listFilesFrom(CatalogFileQuery query,
        string anchorRelativePath, bool forward, size_t limit = 250)
    {
        requireTreeQueries();
        if (limit == 0)
            throw new CatalogBackendException(CatalogBackendErrorCode.invalidCursor,
                "Catalog page limit must be greater than zero.");
        if (anchorRelativePath.length == 0)
        {
            if (!forward)
                return CatalogFilePage.init;
            return listFiles(query, CatalogPageRequest(limit));
        }

        size_t anchor = size_t.max;
        size_t total;
        forEachMatchingFile(query, (ref CatalogFile file, size_t) {
            if (file.relativePath == anchorRelativePath)
                anchor = total;
            ++total;
        });
        if (anchor == size_t.max)
            return CatalogFilePage.init;

        const size_t start = forward ? anchor + 1
            : (anchor > limit ? anchor - limit : 0);
        const size_t end = forward
            ? (start + limit < total ? start + limit : total) : anchor;
        CatalogFilePage result;
        result.files = matchingWindow(query, start, end);
        result.hasPrevious = start > 0;
        if (result.hasPrevious)
            result.previousCursor = CatalogPageCursor(start > limit ? start - limit : 0,
                limit, fileQueryToken(query));
        result.hasMore = forward ? end < total : anchor < total;
        if (result.hasMore)
            result.nextCursor = CatalogPageCursor(end, limit, fileQueryToken(query));
        return result;
    }

    /**
     * Invoke a handler for every matching file in the requested sort order.
     *
     * Physical files are passed with `size_t.max` as the container index; archive
     * members are passed with the index of their container row in `fileRows`.
     *
     * Params:
     *     query = Directory, filters, and sort order to apply.
     *     handler = Callback receiving each matching row and its container index.
     */
    package void forEachMatchingFile(CatalogFileQuery query,
        scope void delegate(ref CatalogFile file, size_t containerRow) handler)
    {
        if (query.filter.includeArchiveMembers)
        {
            forEachFileCandidate(query, handler);
            return;
        }
        foreach (offset; 0 .. fileRows.length)
        {
            const rowIndex = fileOrderIndex(query.sortOrder, offset);
            if (!fileRowMatches(rowIndex, query))
                continue;
            auto file = fileRows[rowIndex];
            handler(file, size_t.max);
        }
    }

    /**
     * Collect matching files in a half-open index window.
     *
     * Availability is refreshed for each returned row, or inherited from its
     * refreshed container for archive members.
     *
     * Params:
     *     query = Directory, filters, and sort order to apply.
     *     start = Inclusive index of the first row to keep.
     *     end = Exclusive index one past the last row to keep.
     * Returns: Detached matching rows in display order.
     */
    package CatalogFile[] matchingWindow(CatalogFileQuery query, size_t start,
        size_t end)
    {
        CatalogFile[] result;
        result.reserve(end - start);
        size_t matched;
        forEachMatchingFile(query, (ref CatalogFile file, size_t containerRow) {
            if (matched >= start && matched < end)
            {
                if (containerRow == size_t.max)
                    refreshAvailability(file);
                else
                {
                    auto container = fileRows[containerRow];
                    refreshAvailability(container);
                    file.availability = container.availability;
                }
                result ~= file;
            }
            ++matched;
        });
        return result;
    }

    /**
     * Map a logical position to a row index for a sort order.
     *
     * Size orders are built lazily and cached until the next index rebuild.
     *
     * Params:
     *     sortOrder = Requested stable order.
     *     offset = Logical position in that order.
     * Returns: Index into `fileRows`.
     */
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

    /**
     * Whether a file row belongs to the query directory and passes its filters.
     *
     * Params:
     *     rowIndex = Index into `fileRows`.
     *     query = Directory and filter to test against.
     * Returns: True when the row is an immediate child of the directory and
     *     matches the filter.
     */
    bool fileRowMatches(size_t rowIndex, CatalogFileQuery query) const
    {
        const file = fileRows[rowIndex];
        return file.directoryId == query.directoryId
            && matches(file, query.filter);
    }

    /**
     * Continue a file listing from a forward cursor.
     *
     * Params:
     *     query = File query the cursor was created for.
     *     cursor = Forward cursor returned by a previous page.
     * Returns: The next page, or an empty page past the end.
     * Throws: `CatalogBackendException` when the cursor does not match the query.
     */
    override CatalogFilePage nextFilesPage(CatalogFileQuery query,
        CatalogPageCursor cursor)
    {
        return listFiles(query, CatalogPageRequest(cursor.adapterPageSize, cursor));
    }

    /**
     * Continue a file listing backward from a cursor.
     *
     * The cursor marks the first row of the current page, so the previous page
     * starts one page size earlier.
     *
     * Params:
     *     query = File query the cursor was created for.
     *     cursor = Backward cursor from a previous page.
     * Returns: The preceding page.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidCursor` when the cursor is invalid or
     *     does not match the query.
     */
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

    /**
     * Refresh a filesystem reference's availability from the current disk state.
     *
     * Non-filesystem locators are left unchanged.
     *
     * Params:
     *     file = File row updated in place.
     */
    package void refreshAvailability(ref CatalogFile file) const
    {
        if (file.locator.kind != ContentLocator.Kind.filesystem)
            return;
        file.availability = exists(buildPath(sourceRoot,
            file.locator.filesystem.relativePath))
            ? CatalogReferenceAvailability.available
            : CatalogReferenceAvailability.unavailable;
    }

    /**
     * Return cached archive-member rows for one directory.
     *
     * The cache is built on first use and refreshed on the next index rebuild.
     *
     * Params:
     *     directoryId = Directory whose members are requested.
     * Returns: Cached rows with path and size sort orders.
     */
    package ArchiveMemberRows* archiveMemberRows(DirectoryId directoryId)
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
        archiveMemberRowsByDirectory[key] = rows;
        return key in archiveMemberRowsByDirectory;
    }

    /**
     * Order two file rows according to a catalog sort order.
     *
     * Path breaks ties for both size orders.
     *
     * Params:
     *     left = Left-hand row.
     *     right = Right-hand row.
     *     sortOrder = Requested stable order.
     * Returns: True when `left` should sort before `right`.
     */
    package static bool fileBefore(in CatalogFile left, in CatalogFile right,
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

    /**
     * Merge physical files and archive members into one sorted stream.
     *
     * Params:
     *     query = Directory, filters, and sort order.
     *     sink = Callback receiving each match and its container row index.
     */
    package void forEachFileCandidate(CatalogFileQuery query,
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
                const memberIndex = memberOrderIndex(rows, query.sortOrder,
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
                auto index = memberOrderIndex(rows, query.sortOrder,
                    memberPosition++);
                auto row = rows.rows[index];
                if (!matches(row.file, query.filter))
                    continue;
                auto file = row.file;
                sink(file, row.containerRow);
            }
        }
    }

    /**
     * Map a logical member position to a row index for a sort order.
     *
     * Params:
     *     rows = Cached member rows and their order indexes.
     *     sortOrder = Requested stable order.
     *     position = Logical position in that order.
     * Returns: Index into `rows.rows`.
     */
    package static size_t memberOrderIndex(ArchiveMemberRows* rows,
        CatalogSortOrder sortOrder, size_t position)
    {
        final switch (sortOrder)
        {
        case CatalogSortOrder.pathAscending:
            return position;
        case CatalogSortOrder.pathDescending:
            return rows.rows.length - 1 - position;
        case CatalogSortOrder.sizeAscending:
            rows.ensureSizeAscending();
            return rows.sizeAscending[position];
        case CatalogSortOrder.sizeDescending:
            rows.ensureSizeDescending();
            return rows.sizeDescending[position];
        }
    }

    /**
     * Collect immediate child directories that match a query.
     *
     * When a filter is active, per-directory counts are recomputed so they
     * describe only matching content.
     *
     * Params:
     *     query = Parent directory and optional filters.
     * Returns: Matching directories sorted by relative path.
     */
    package CatalogDirectory[] matchingDirectories(CatalogDirectoryQuery query)
    {
        CatalogDirectory[] result;
        const auto activeFilter = hasActiveFilter(query.filter);
        foreach (directory; directoryRows)
        {
            if (directory.parentId != query.parentId)
                continue;
            if (activeFilter && !directoryHasMatch(directory.relativePath, query.filter))
                continue;
            auto row = directory;
            if (activeFilter)
            {
                /* Precomputed index counts are unfiltered; recompute them for
                 * the active filter so counts match the listed content, like
                 * the SQLite backend does. */
                applyDirectoryFilterCounts(row, query.filter);
            }
            result ~= row;
        }
        result.sort!((left, right) => left.relativePath < right.relativePath);
        return result;
    }

    /**
     * Recompute a directory's matching file count and aggregate size.
     *
     * Params:
     *     directory = Directory row updated in place.
     *     filter = Filter applied to files and, when requested, archive members.
     */
    package void applyDirectoryFilterCounts(ref CatalogDirectory directory,
        CatalogFilter filter)
    {
        const prefix = directory.relativePath ~ "/";
        const start = lowerBoundPath(prefix);
        const end = lowerBoundPath(directory.relativePath ~ "0");
        size_t immediateCount;
        ulong total;
        foreach (const index; start .. end)
        {
            auto file = fileRows[index];
            if (!matches(file, filter))
                continue;
            total += file.size;
            if (file.directoryId == directory.id)
                ++immediateCount;
        }
        if (filter.includeArchiveMembers)
            foreach (const index; start .. end)
            {
                auto container = fileRows[index];
                if (!container.hasArchive)
                    continue;
                foreach (member; archiveMemberFiles(container))
                    if (matches(member, filter))
                    {
                        total += member.size;
                        if (container.directoryId == directory.id)
                            ++immediateCount;
                    }
            }
        directory.fileCount = immediateCount;
        directory.aggregateSize = total;
    }

    /**
     * Whether any file or archive member below a directory matches a filter.
     *
     * Params:
     *     directoryPath = Directory path relative to the source root.
     *     filter = Filter applied to candidate files and members.
     * Returns: True when at least one descendant reference matches.
     */
    package bool directoryHasMatch(string directoryPath, CatalogFilter filter)
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

    /**
     * Find the first file row whose relative path is not less than a value.
     *
     * Relies on `fileRows` being sorted by relative path.
     *
     * Params:
     *     path = Lower-bound path.
     * Returns: Index of the first row at or after `path`.
     */
    package size_t lowerBoundPath(string path) const
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

    /**
     * Find a file or archive-member row by reference identity.
     *
     * Params:
     *     referenceId = Reference identity to find.
     *     result = Receives the matching row when found.
     * Returns: True when a matching physical row or member was found.
     */
    package bool findFileRow(ReferenceId referenceId, out CatalogFile result)
    {
        foreach (row; fileRows)
            if (row.referenceId == referenceId)
            {
                result = row;
                return true;
            }
        foreach (container; fileRows)
            if (container.hasArchive)
                foreach (member; archiveMemberFiles(container))
                    if (member.referenceId == referenceId)
                    {
                        result = member;
                        return true;
                    }
        return false;
    }

    /**
     * List all locatable archive members of a container recursively.
     *
     * Params:
     *     container = Archive container file row.
     * Returns: Direct and nested member rows; empty when the container has no
     *     index or is not an archive.
     */
    package CatalogFile[] archiveMemberFiles(CatalogFile container)
    {
        bool[string] activeContents;
        return archiveMemberFiles(container, 0, activeContents);
    }

    /**
     * Recursively build member rows while guarding against archive cycles.
     *
     * Params:
     *     container = Archive container file row.
     *     depth = Current nesting depth; recursion stops at 32.
     *     activeContents = Content tokens on the current recursion stack.
     * Returns: Member rows for this container and its nested archives.
     */
    package CatalogFile[] archiveMemberFiles(CatalogFile container, size_t depth,
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
        result.reserve(entries.length);
        const auto displayContainerPath = container.locator.kind
            == ContentLocator.Kind.filesystem
            ? escapeArchiveVirtualPath(container.relativePath)
            : container.relativePath;
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

    /**
     * Whether a directory should be listed for the given filter.
     *
     * Params:
     *     directory = Directory to test.
     *     filter = Active filter, if any.
     * Returns: True when no filter is active or a descendant matches it.
     */
    package bool directoryVisible(CatalogDirectory directory, CatalogFilter filter)
    {
        return !hasActiveFilter(filter)
            || directoryHasMatch(directory.relativePath, filter);
    }

    /**
     * Whether a file row satisfies the path, availability, media, and type
     * filters.
     *
     * Params:
     *     file = File row to test.
     *     filter = Filter selectors to apply.
     * Returns: True when every active selector accepts the row.
     */
    package bool matches(CatalogFile file, CatalogFilter filter) const
    {
        if (filter.pathText.length > 0
            && !archivePathMatchesText(file.relativePath, filter.pathText,
                filter.caseSensitive))
            return false;
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

    /**
     * Whether a filter contains any active selector.
     *
     * Params:
     *     filter = Filter to inspect.
     * Returns: True when at least one filter field is set.
     */
    package bool hasActiveFilter(CatalogFilter filter) const
    {
        return filter.pathText.length > 0 || filter.video || filter.audio
            || filter.image || filter.text || filter.fileType || filter.archive
            || filter.torrent || filter.availableOnly || filter.includeArchiveMembers;
    }

    /**
     * Whether a path equals or lies below a prefix.
     *
     * Both native and archive path separators are accepted at the boundary.
     *
     * Params:
     *     path = Path to test.
     *     prefix = Prefix to match; an empty prefix matches everything.
     * Returns: True when `path` is the prefix or a descendant of it.
     */
    package bool hasPathPrefix(string path, string prefix) const
    {
        return prefix.length == 0 || path == prefix
            || path.startsWith(prefix ~ "/")
            || path.startsWith(prefix ~ archivePathSeparator());
    }

    /**
     * Build the cursor binding token for a file query.
     *
     * Params:
     *     query = Directory, filter, and sort order participating in the token.
     * Returns: Opaque token tied to this source and index generation.
     */
    package string fileQueryToken(CatalogFileQuery query) const
    {
        return sourceToken ~ "\0" ~ indexGeneration.to!string ~ "\0files\0"
            ~ query.directoryId.adapterToken
            ~ "\0" ~ filterToken(query.filter) ~ "\0"
            ~ (cast(int) query.sortOrder).to!string;
    }

    /**
     * Build the cursor binding token for a directory query.
     *
     * Params:
     *     query = Parent directory and filter participating in the token.
     * Returns: Opaque token tied to this source and index generation.
     */
    package string directoryQueryToken(CatalogDirectoryQuery query) const
    {
        return sourceToken ~ "\0" ~ indexGeneration.to!string ~ "\0directories\0"
            ~ query.parentId.adapterToken
            ~ "\0" ~ filterToken(query.filter);
    }

    /**
     * Serialize the active selector fields of a filter into a cursor token.
     *
     * Params:
     *     filter = Filter to serialize.
     * Returns: An opaque, stable representation of the filter.
     */
    package string filterToken(CatalogFilter filter) const
    {
        return filter.pathText ~ "\0" ~ (filter.caseSensitive ? "1" : "0")
            ~ (filter.video ? "1" : "0") ~ (filter.audio ? "1" : "0")
            ~ (filter.image ? "1" : "0") ~ (filter.text ? "1" : "0")
            ~ (filter.mediaNegated ? "1" : "0") ~ (filter.fileType ? "1" : "0")
            ~ (filter.archive ? "1" : "0") ~ (filter.torrent ? "1" : "0")
            ~ (filter.availableOnly ? "1" : "0")
            ~ (filter.includeArchiveMembers ? "1" : "0");
    }

    /**
     * Compute the item window and cursors for one page request.
     *
     * Params:
     *     request = Requested limit and optional cursor.
     *     queryToken = Token identifying the source, query, and sort order.
     *     itemCount = Total number of items in the result sequence.
     * Returns: The slice bounds plus forward and backward cursors.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.invalidCursor` when the limit is zero, the
     *     cursor is invalid for this query or page size, or the cursor lies past
     *     the end.
     */
    package CatalogSlice pageSlice(CatalogPageRequest request, string queryToken,
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

    /**
     * Assemble a file page from a matching slice.
     *
     * Params:
     *     matching = Ordered matching rows.
     *     slice = Window and cursors computed for the rows.
     * Returns: The detached page.
     */
    package CatalogFilePage makeFilePage(CatalogFile[] matching, CatalogSlice slice) const
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
