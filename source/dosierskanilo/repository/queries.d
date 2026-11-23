/** Repository read API: bounded catalog, file, archive, and torrent queries.
 *
 * Every read returns a bounded page or a summary so GUI and CLI consumers
 * never materialize the complete SQLite catalog.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.queries;

import d2sqlite3;
import std.conv : to;
import std.exception : enforce;
import std.file : copy, exists, mkdirRecurse;
import std.path : buildPath;
import std.string : empty, endsWith;
import std.stdio : File;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.analysis : queryDuplicateGroups;
import dosierskanilo.repository.catalogreads : countCatalogQueryFromDatabase,
    loadBlobDetailsFromDatabase, loadBlobFingerprintFromDatabase, loadCatalogPageFromDatabase,
    loadCatalogQueryPageFromDatabase, loadCatalogQueryPageWithIdsFromDatabase;
import dosierskanilo.repository.referencequeries : archiveEntrySummaryFromDatabase,
    countPhysicalFileReferences, listArchiveEntriesFromDatabase, listDirectoriesFromDatabase,
    listFilesFromDatabase, listFilesPageFromDatabase, listTorrentFilesFromDatabase,
    loadArchiveEntryFromDatabase, loadFileReferenceFromDatabase, loadRootSummaryFromDatabase;
import dosierskanilo.repository.types;
import dosierskanilo.repository.repository : Repository;

/** Members of `Repository` in the queries area; mixed into the class. */
mixin template RepositoryQueries()
{
    /** Return the number of blobs currently stored in the repository.
     *
     * Returns: Total blob row count.
     */
    size_t blobCount()
    {
        requireOpen();
        return cast(size_t) database.execute(
            "SELECT count(*) FROM blobs").oneValue!long;
    }

    /** Load a bounded page of repository blobs for UI consumers.
     *
     * Params:
     *     offset = Number of blobs to skip, ordered by blob ID.
     *     limit = Maximum number of blobs to return; must be greater than zero.
     *     options = Options controlling which related data is loaded.
     * Returns: The requested page of blobs.
     */
    NamedBinaryBlob[] loadCatalogPage(size_t offset, size_t limit = 100,
        JsonExportOptions options = JsonExportOptions())
    {
        requireOpen();
        enforce!RepositoryException(limit > 0, "Repository page size must be greater than zero.");
        return loadCatalogPageFromDatabase(database, repositoryPaths.rootPath,
            offset, limit, options);
    }

    /** Load a bounded page using repository-side filters.
     *
     * Params:
     *     options = Filters, ordering, and page size for the query.
     *     exportOptions = Options controlling which related data is loaded.
     * Returns: Matching blobs for the requested page.
     */
    NamedBinaryBlob[] loadCatalogQueryPage(RepositoryQueryOptions options,
        JsonExportOptions exportOptions = JsonExportOptions())
    {
        requireOpen();
        enforce!RepositoryException(options.limit > 0,
            "Repository query page size must be greater than zero.");
        return loadCatalogQueryPageFromDatabase(database, repositoryPaths.rootPath,
            options, exportOptions);
    }

    /** Load a bounded filtered page while retaining stable blob IDs.
     *
     * Params:
     *     options = Filters, ordering, and page size for the query.
     *     exportOptions = Options controlling which related data is loaded.
     * Returns: The matching page with stable blob IDs and the total match count.
     */
    RepositoryBlobPage loadCatalogQueryPageWithIds(RepositoryQueryOptions options,
        JsonExportOptions exportOptions = JsonExportOptions())
    {
        requireOpen();
        enforce!RepositoryException(options.limit > 0,
            "Repository query page size must be greater than zero.");
        auto page = loadCatalogQueryPageWithIdsFromDatabase(database,
            repositoryPaths.rootPath, options, exportOptions);
        page.total = countCatalogQuery(options);
        return page;
    }

    /** Iterate the filtered catalog by stable blob ID using internal chunks.
     *
     * Params:
     *     options = Filters, ordering, and chunk size for the query.
     *     exportOptions = Options controlling which related data is loaded.
     * Returns: One cursor page with stable blob IDs and the total match count.
     */
    RepositoryBlobPage loadCatalogQueryCursorPage(RepositoryQueryOptions options,
        JsonExportOptions exportOptions = JsonExportOptions())
    {
        requireOpen();
        enforce!RepositoryException(options.limit > 0,
            "Repository cursor chunk size must be greater than zero.");
        options.useCursor = true;
        auto page = loadCatalogQueryPageWithIdsFromDatabase(database,
            repositoryPaths.rootPath, options, exportOptions);
        page.total = countCatalogQuery(options);
        return page;
    }

    /** Load only the size and digests of one blob by stable repository ID.
     *
     * Params:
     *     blobId = Stable repository ID of the blob.
     * Returns: A blob populated with size and checksums only, or `null` when
     *     the ID does not exist.
     */
    NamedBinaryBlob loadBlobFingerprint(long blobId)
    {
        requireOpen();
        return loadBlobFingerprintFromDatabase(database, blobId);
    }

    /** Load one blob and its related details by stable repository ID.
     *
     * Params:
     *     blobId = Stable repository ID of the blob.
     *     options = Options controlling which related data is loaded.
     * Returns: The detailed blob, or `null` when the ID does not exist.
     */
    NamedBinaryBlob loadBlobDetails(long blobId,
        JsonExportOptions options = JsonExportOptions())
    {
        requireOpen();
        return loadBlobDetailsFromDatabase(database, repositoryPaths.rootPath,
            blobId, options);
    }

    /** Count blobs matching repository-side query filters.
     *
     * Params:
     *     options = Filters to apply to the blob count.
     * Returns: Number of matching blobs.
     */
    size_t countCatalogQuery(RepositoryQueryOptions options)
    {
        requireOpen();
        return cast(size_t) countCatalogQueryFromDatabase(database, options);
    }

    /** List immediate child directories using bounded SQL queries.
     *
     * Params:
     *     options = Parent selection and page size; `limit` must be greater
     *         than zero.
     * Returns: Child directories for the requested page.
     */
    RepositoryDirectory[] listDirectories(RepositoryDirectoryQuery options = RepositoryDirectoryQuery())
    {
        requireOpen();
        enforce!RepositoryException(options.limit > 0, "Directory page size must be greater than zero.");
        return listDirectoriesFromDatabase(database, options);
    }

    /** Return bounded aggregate values for the repository's root node.
     *
     * Returns: Aggregate directory and file values for the root node.
     */
    RepositoryRootSummary rootSummary()
    {
        requireOpen();
        return loadRootSummaryFromDatabase(database);
    }

    /** Count all file references, including virtual archive members.
     *
     * Returns: Total number of stored file references.
     */
    size_t fileReferenceCount()
    {
        requireOpen();
        return cast(size_t) database.execute(
            "SELECT count(*) FROM file_refs").oneValue!long;
    }

    /** Aggregate the sizes of all file references, including members.
     *
     * Returns: Sum of referenced blob sizes in bytes.
     */
    ulong referenceAggregateSize()
    {
        requireOpen();
        return cast(ulong) database.execute(
            "SELECT COALESCE(sum(b.file_size), 0) FROM file_refs f "
            ~ "JOIN blobs b ON b.id = f.blob_id").oneValue!long;
    }

    /** Count all non-virtual file references in one SQL query.
     *
     * Returns: Number of file references that are not archive or torrent
     *     members.
     */
    size_t physicalFileReferenceCount()
    {
        requireOpen();
        return countPhysicalFileReferences(database);
    }

    /** List immediate file references using bounded SQL queries.
     *
     * Params:
     *     options = Parent selection and page size; `limit` must be greater
     *         than zero.
     * Returns: File references for the requested page.
     */
    RepositoryFile[] listFiles(RepositoryFileQuery options = RepositoryFileQuery())
    {
        requireOpen();
        enforce!RepositoryException(options.limit > 0, "File page size must be greater than zero.");
        return listFilesFromDatabase(database, options);
    }

    /** List one keyset-paged file chunk without exposing SQL pagination details.
     *
     * Params:
     *     options = Filters, ordering, and page size; `limit` must be greater
     *         than zero.
     * Returns: One page with cursor data for forward and backward navigation.
     */
    RepositoryFilePage listFilesPage(RepositoryFileQuery options = RepositoryFileQuery())
    {
        requireOpen();
        enforce!RepositoryException(options.limit > 0, "File page size must be greater than zero.");
        return listFilesPageFromDatabase(database, options);
    }

    /** Load one physical file reference by its stable repository ID.
     *
     * Params:
     *     fileReferenceId = Stable ID of the file reference.
     * Returns: The file reference, or `RepositoryFile.init` when no row exists.
     */
    RepositoryFile fileReference(long fileReferenceId)
    {
        requireOpen();
        return loadFileReferenceFromDatabase(database, fileReferenceId);
    }

    /** Load one file reference by its exact repository-relative path.
     *
     * Params:
     *     relativePath = Exact stored relative path to look up.
     * Returns: The file reference, or `RepositoryFile.init` when not found.
     */
    RepositoryFile fileReferenceByRelativePath(string relativePath)
    {
        requireOpen();
        auto rows = database.execute("SELECT id FROM file_refs "
            ~ "WHERE relative_path = ?", relativePath);
        if (rows.empty)
            return RepositoryFile.init;
        return loadFileReferenceFromDatabase(database, rows.front.peek!long(0));
    }

    /** Return the directory ID at an exact repository-relative path, or zero.
     *
     * Params:
     *     relativePath = Exact stored relative directory path to look up.
     * Returns: The directory row ID, or zero when no row exists.
     */
    long directoryIdByRelativePath(string relativePath)
    {
        requireOpen();
        auto rows = database.execute("SELECT id FROM directories "
            ~ "WHERE relative_path = ?", relativePath);
        return rows.empty ? 0 : rows.front.peek!long(0);
    }

    /** Continue forward from a stable file cursor in the query's sorted result.
     *
     * Params:
     *     options = Filters, ordering, and page size.
     *     cursor = Cursor returned by a previous page.
     * Returns: The next page in sorted order.
     */
    RepositoryFilePage nextFilesPage(RepositoryFileQuery options,
        RepositoryFileCursor cursor)
    {
        options.afterPath = cursor.relativePath;
        options.afterId = cursor.id;
        options.afterSize = cursor.size;
        options.beforeCursor = false;
        return listFilesPage(options);
    }

    /** Continue backward from a stable file cursor, returning rows in display order.
     *
     * Params:
     *     options = Filters, ordering, and page size.
     *     cursor = Cursor returned by a previous page.
     * Returns: The previous page, with rows in display order.
     */
    RepositoryFilePage previousFilesPage(RepositoryFileQuery options,
        RepositoryFileCursor cursor)
    {
        options.afterPath = cursor.relativePath;
        options.afterId = cursor.id;
        options.afterSize = cursor.size;
        options.beforeCursor = true;
        return listFilesPage(options);
    }

    /** Return the aggregated archive index summary for one container blob.
     *
     * Params:
     *     blobId = Content blob identity of the archive container.
     * Returns: Distinct member count and complete-fingerprint count.
     * Throws: `RepositoryException` when the repository is not open.
     */
    RepositoryArchiveSummary archiveEntrySummary(long blobId)
    {
        requireOpen();
        return archiveEntrySummaryFromDatabase(database, blobId);
    }

    /** List one bounded page of archive entries.
     *
     * Params:
     *     options = Container blob ID plus page offset and limit.
     * Returns: Deduplicated archive entries ordered by stored path.
     */
    RepositoryArchiveEntry[] listArchiveEntries(RepositoryArchiveQuery options)
    {
        requireOpen();
        enforce!RepositoryException(options.limit > 0, "Archive entry page size must be greater than zero.");
        return listArchiveEntriesFromDatabase(database, options);
    }

    /** Load one archive index row by stable entry ID.
     *
     * Params:
     *     entryId = Stable file-reference ID of the archive entry.
     * Returns: The archive entry, or `RepositoryArchiveEntry.init` when the
     *     row is missing or is not an archive member.
     */
    RepositoryArchiveEntry archiveEntry(long entryId)
    {
        requireOpen();
        return loadArchiveEntryFromDatabase(database, entryId);
    }

    /** Whether a blob has an archive index, including a known empty index.
     *
     * Params:
     *     blobId = Stable repository ID of the container blob.
     * Returns: `true` when an archive index completed for the blob.
     */
    bool hasArchiveIndex(long blobId)
    {
        requireOpen();
        return !database.execute("SELECT 1 FROM metadata_status WHERE blob_id = ? "
            ~ "AND metadata_kind = 'archives' AND state IN ('completed', 'empty')",
            blobId).empty;
    }

    /** List torrent files for one blob using bounded SQL queries.
     *
     * Params:
     *     options = Torrent blob selection and page size; `limit` must be
     *         greater than zero.
     * Returns: Torrent file entries matching the query.
     */
    RepositoryTorrentFile[] listTorrentFiles(RepositoryTorrentQuery options)
    {
        requireOpen();
        enforce!RepositoryException(options.limit > 0, "Torrent file page size must be greater than zero.");
        return listTorrentFilesFromDatabase(database, options);
    }

    /** Return duplicate groups without changing repository data.
     *
     * Params:
     *     limit = Maximum number of duplicate groups; must be greater than zero.
     * Returns: Duplicate blob groups in the order returned by the query.
     */
    RepositoryDuplicateGroup[] queryDuplicates(size_t limit = 100)
    {
        requireOpen();
        enforce!RepositoryException(limit > 0, "Duplicate query limit must be greater than zero.");
        return queryDuplicateGroups(database, limit);
    }
}

@("catalog queries apply case sensitivity to paths for offset and cursor pages")
unittest
{
    import std.algorithm.searching : endsWith;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-catalog-case-filter-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    write(buildPath(root, "UPPER-NEEDLE.txt"), "upper path");
    write(buildPath(root, "lower-Needle.txt"), "mixed path");
    write(buildPath(root, "plain.txt"), "control");

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();

    RepositoryQueryOptions query;
    query.text = "NEEDLE";
    query.caseSensitive = true;
    query.limit = 10;
    auto sensitive = repository.loadCatalogQueryPageWithIds(query);
    assert(sensitive.total == 1);
    assert(sensitive.blobs.length == 1);
    assert(sensitive.blobs[0].getFirstFileName.endsWith("UPPER-NEEDLE.txt"));

    query.text = "needle";
    query.caseSensitive = false;
    query.limit = 1;
    auto insensitive = repository.loadCatalogQueryPageWithIds(query);
    assert(insensitive.total == 2);
    assert(insensitive.blobs.length == 1);

    query.useCursor = true;
    auto firstCursorPage = repository.loadCatalogQueryCursorPage(query);
    assert(firstCursorPage.blobs.length == 1);
    assert(firstCursorPage.total == 2);
    assert(firstCursorPage.hasMore);
    query.afterBlobId = firstCursorPage.nextCursor;
    auto secondCursorPage = repository.loadCatalogQueryCursorPage(query);
    assert(secondCursorPage.blobs.length == 1);
    assert(secondCursorPage.total == 2);
    assert(!secondCursorPage.hasMore);
    assert(firstCursorPage.blobIds[0] != secondCursorPage.blobIds[0]);

    query.text = "";
    query.useCursor = false;
    query.blobIds = [firstCursorPage.blobIds[0]];
    auto restricted = repository.loadCatalogQueryPageWithIds(query);
    assert(restricted.blobs.length == 1);
    assert(restricted.blobIds == [firstCursorPage.blobIds[0]]);
    query.blobIds = [];

    MetadataScanOptions checksumOptions;
    checksumOptions.calculateChecksums = true;
    repository.updateMetadata(checksumOptions);
    string encodedSha1;
    foreach (blob; repository.loadCatalog())
    {
        if (blob.getFirstFileName.endsWith("UPPER-NEEDLE.txt"))
            encodedSha1 = blob.checkSums.sha1sum_b64;
    }
    assert(encodedSha1.length > 0);
    query.text = encodedSha1;
    query.caseSensitive = true;
    query.useCursor = false;
    query.afterBlobId = 0;
    auto checksumMatch = repository.loadCatalogQueryPageWithIds(query);
    assert(checksumMatch.total == 1,
        "path case sensitivity must not alter exact binary SHA1 matching");
}

@("catalog page helpers reject a zero limit with a typed error")
unittest
{
    import std.exception : assertThrown;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-limit-zero-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
        if (exists(root))
            rmdirRecurse(root);
    write(buildPath(root, "plain.txt"), "content");

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();

    RepositoryQueryOptions query;
    query.limit = 0;
    assertThrown!RepositoryException(repository.loadCatalogQueryPageWithIds(query));

    query.useCursor = true;
    assertThrown!RepositoryException(repository.loadCatalogQueryPageWithIds(query));
    assertThrown!RepositoryException(repository.loadCatalogQueryCursorPage(query));

    assertThrown!RepositoryException(loadCatalogQueryPageWithIdsFromDatabase(
        repository.database, repository.repositoryPaths.rootPath, query,
        JsonExportOptions()));
}

@("repository concurrent readers during metadata write")
unittest
{
    import core.thread : Thread;
    import std.file : copy, exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.string : format;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-concurrent-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    foreach (index; 0 .. 8)
        copy("./test/dummy-text-file.txt", buildPath(root,
            "sample-%d.txt".format(index)));
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    repository.scan();
    shared bool failed;
    Thread[] readers;
    foreach (_; 0 .. 4)
    {
        readers ~= new Thread({
            try
            {
                auto reader = Repository.open(root);
                foreach (iteration; 0 .. 10)
                {
                    auto page = reader.loadCatalogPage(iteration % 4, 2);
                    assert(page.length <= 2);
                }
                reader.close();
            }
            catch (Exception)
            {
                failed = true;
            }
        });
    }
    foreach (reader; readers)
        reader.start();

    MetadataScanOptions options;
    options.calculateChecksums = true;
    options.threads = 2;
    repository.updateMetadata(options);

    foreach (reader; readers)
        reader.join();
    assert(!failed);
    repository.close();
}
