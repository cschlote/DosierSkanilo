/** Persistent repository access for DosierSkanilo. */
module dosierskanilo.repository.repository;

import d2sqlite3;

import std.datetime.systime : Clock;
import std.exception : enforce;
import std.file : copy, exists, isDir, mkdirRecurse;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.string : empty, toLower;
import std.stdio : File;
import std.typecons : Nullable;

import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.analysis : analyzeRepository;
import dosierskanilo.repository.analysis : queryDuplicateGroups;
import dosierskanilo.repository.metadata : updateRepositoryMetadata;
import dosierskanilo.repository.schema : migrate;
import dosierskanilo.repository.scanner : scanRepository;
import dosierskanilo.repository.transfer : exportCatalogJson, importCatalogJson,
    loadCatalogFromDatabase, loadCatalogPageFromDatabase,
    loadCatalogQueryPageFromDatabase, loadCatalogQueryPageWithIdsFromDatabase,
    loadBlobDetailsFromDatabase, countCatalogQueryFromDatabase,
    listDirectoriesFromDatabase, loadRootSummaryFromDatabase, listFilesFromDatabase,
    listFilesPageFromDatabase, listArchiveEntriesFromDatabase,
    listTorrentFilesFromDatabase;
import dosierskanilo.repository.types;

/** A connection to one `.dosierskanilo` repository. */
class Repository
{
private:
    Database database;
    RepositoryPaths repositoryPaths;
    bool openState;

    this(Database database, RepositoryPaths repositoryPaths)
    {
        this.database = database;
        this.repositoryPaths = repositoryPaths;
        this.openState = true;
    }

    static Repository openRoot(string rootPath, RepositoryOptions options)
    {
        auto paths = RepositoryPaths.fromRoot(rootPath);
        if (!exists(paths.metadataPath))
            throw new RepositoryException("Not a DosierSkanilo repository: "
                ~ rootPath);

        auto db = Database(paths.databasePath);
        try
        {
            configure(db, options);
            migrate(db, currentTimestamp());
            ensureRepositoryRow(db, rootPath);
            return new Repository(db, paths);
        }
        catch (Exception ex)
        {
            db.close();
            throw ex;
        }
    }

    static void configure(ref Database db, RepositoryOptions options)
    {
        db.execute("PRAGMA foreign_keys = ON");
        db.execute("PRAGMA busy_timeout = 5000");
        if (options.enableWal)
        {
            string journalMode;
            {
                auto currentJournal = db.execute("PRAGMA journal_mode");
                if (!currentJournal.empty)
                    journalMode = currentJournal.front.peek!string(0).toLower;
            }
            if (journalMode != "wal")
            {
                auto walResult = db.execute("PRAGMA journal_mode = WAL");
                if (!walResult.empty)
                    walResult.front.peek!string(0);
            }
        }
        db.execute("PRAGMA synchronous = NORMAL");
    }

    static string currentTimestamp()
    {
        return Clock.currTime.toISOExtString;
    }

    static void ensureRepositoryRow(ref Database db, string rootPath)
    {
        auto result = db.execute("SELECT root_path FROM repository WHERE id = 1");
        if (!result.empty)
        {
            auto storedRoot = result.front.peek!string(0);
            if (storedRoot != rootPath)
                throw new RepositoryException("Repository root mismatch: "
                    ~ storedRoot ~ " != " ~ rootPath);
            return;
        }

        auto now = currentTimestamp();
        db.execute("INSERT INTO repository "
            ~ "(id, root_path, schema_version, created_at, updated_at) "
            ~ "VALUES (1, ?, ?, ?, ?)", rootPath,
            cast(long) currentRepositorySchemaVersion, now, now);
    }

    void requireOpen() const
    {
        if (!openState)
            throw new RepositoryException("Repository is already closed.");
    }

public:
    /** Initialize or open a repository rooted at `rootPath`. */
    static Repository initialize(string rootPath,
        RepositoryOptions options = RepositoryOptions())
    {
        rootPath = canonicalDirectory(rootPath);
        auto paths = RepositoryPaths.fromRoot(rootPath);
        mkdirRecurse(paths.metadataPath);
        mkdirRecurse(paths.logsPath);
        mkdirRecurse(paths.exportsPath);
        mkdirRecurse(paths.backupsPath);
        return openRoot(rootPath, options);
    }

    /** Open the repository containing `startPath`. */
    static Repository open(string startPath, RepositoryOptions options = RepositoryOptions())
    {
        auto rootPath = findRoot(startPath);
        if (rootPath.empty)
            throw new RepositoryException("No .dosierskanilo repository found from: "
                ~ startPath);
        return openRoot(rootPath, options);
    }

    /** Find the nearest repository root or return an empty string. */
    static string findRoot(string startPath)
    {
        if (startPath.empty)
            return "";

        auto current = canonicalDirectory(startPath);
        while (true)
        {
            auto metadataPath = buildPath(current, repositoryDirectoryName);
            if (exists(metadataPath) && isDir(metadataPath))
                return current;

            const auto parent = buildNormalizedPath(dirName(current));
            if (parent == current)
                return "";
            current = parent;
        }
    }

    /** Return the canonical repository root. */
    @property string rootPath()
    {
        requireOpen();
        return repositoryPaths.rootPath;
    }

    /** Return the SQLite database path. */
    @property string databasePath()
    {
        requireOpen();
        return repositoryPaths.databasePath;
    }

    /** Return the structured repository operation log path. */
    @property string logFilePath()
    {
        requireOpen();
        return repositoryPaths.logFilePath;
    }

    /** Append one structured operation record to the repository log. */
    void appendLog(string eventName, string message)
    {
        requireOpen();
        auto file = File(repositoryPaths.logFilePath, "a");
        file.writeln("{\"timestamp\":\"", currentTimestamp(),
            "\",\"event\":\"", escapeLogValue(eventName),
            "\",\"message\":\"", escapeLogValue(message), "\"}");
    }

    private void backupDatabase()
    {
        database.execute("PRAGMA wal_checkpoint(TRUNCATE)");
        import std.string : replace;
        auto stamp = currentTimestamp().replace(":", "-");
        auto backupPath = buildPath(repositoryPaths.backupsPath,
            "catalog-" ~ stamp ~ ".sqlite3");
        copy(repositoryPaths.databasePath, backupPath);
        appendLog("repository.backup", backupPath);
    }

    /** Return repository metadata. */
    RepositoryInfo info()
    {
        requireOpen();
        auto result = database.execute("SELECT root_path, schema_version, "
            ~ "created_at, updated_at, media_info_version, "
            ~ "file_utility_version FROM repository WHERE id = 1");
        if (result.empty)
            throw new RepositoryException("Repository metadata row is missing.");

        auto row = result.front;
        return RepositoryInfo(
            row.peek!string(0),
            cast(ulong) row.peek!long(1),
            row.peek!string(2),
            row.peek!string(3),
            row.peek!(Nullable!string)(4).isNull
                ? "" : row.peek!(Nullable!string)(4).get,
            row.peek!(Nullable!string)(5).isNull
                ? "" : row.peek!(Nullable!string)(5).get);
    }

    /** Replace the repository catalog with data from a JSON file. */
    void importJson(string jsonFile, JsonImportOptions options = JsonImportOptions())
    {
        requireOpen();
        if (blobCount > 0)
        {
            if (!options.force)
                throw new RepositoryException(
                    "Repository is not empty. Use force to replace its catalog.");
            if (options.backupExisting)
                backupDatabase();
        }
        importCatalogJson(database, repositoryPaths.rootPath, jsonFile, options);
    }

    /** Export repository data to a JSON file. */
    void exportJson(string jsonFile, JsonExportOptions options = JsonExportOptions())
    {
        requireOpen();
        exportCatalogJson(database, repositoryPaths.rootPath, jsonFile, options);
    }

    /** Load repository blobs using the shared domain model for consumers. */
    NamedBinaryBlob[] loadCatalog(JsonExportOptions options = JsonExportOptions())
    {
        requireOpen();
        return loadCatalogFromDatabase(database, repositoryPaths.rootPath, options);
    }

    /** Return the number of blobs currently stored in the repository. */
    size_t blobCount()
    {
        requireOpen();
        return cast(size_t) database.execute(
            "SELECT count(*) FROM blobs").oneValue!long;
    }

    /** Load a bounded page of repository blobs for UI consumers. */
    NamedBinaryBlob[] loadCatalogPage(size_t offset, size_t limit = 100,
        JsonExportOptions options = JsonExportOptions())
    {
        requireOpen();
        enforce(limit > 0, "Repository page size must be greater than zero.");
        return loadCatalogPageFromDatabase(database, repositoryPaths.rootPath,
            offset, limit, options);
    }

    /** Load a bounded page using repository-side filters. */
    NamedBinaryBlob[] loadCatalogQueryPage(RepositoryQueryOptions options,
        JsonExportOptions exportOptions = JsonExportOptions())
    {
        requireOpen();
        enforce(options.limit > 0,
            "Repository query page size must be greater than zero.");
        return loadCatalogQueryPageFromDatabase(database, repositoryPaths.rootPath,
            options, exportOptions);
    }

    /** Load a bounded filtered page while retaining stable blob IDs. */
    RepositoryBlobPage loadCatalogQueryPageWithIds(RepositoryQueryOptions options,
        JsonExportOptions exportOptions = JsonExportOptions())
    {
        requireOpen();
        enforce(options.limit > 0,
            "Repository query page size must be greater than zero.");
        auto page = loadCatalogQueryPageWithIdsFromDatabase(database,
            repositoryPaths.rootPath, options, exportOptions);
        page.total = countCatalogQuery(options);
        return page;
    }

    /** Iterate the filtered catalog by stable blob ID using internal chunks. */
    RepositoryBlobPage loadCatalogQueryCursorPage(RepositoryQueryOptions options,
        JsonExportOptions exportOptions = JsonExportOptions())
    {
        requireOpen();
        enforce(options.limit > 0, "Repository cursor chunk size must be greater than zero.");
        options.useCursor = true;
        auto page = loadCatalogQueryPageWithIdsFromDatabase(database,
            repositoryPaths.rootPath, options, exportOptions);
        page.total = countCatalogQuery(options);
        return page;
    }

    /** Load one blob and its related details by stable repository ID. */
    NamedBinaryBlob loadBlobDetails(long blobId,
        JsonExportOptions options = JsonExportOptions())
    {
        requireOpen();
        return loadBlobDetailsFromDatabase(database, repositoryPaths.rootPath,
            blobId, options);
    }

    /** Count blobs matching repository-side query filters. */
    size_t countCatalogQuery(RepositoryQueryOptions options)
    {
        requireOpen();
        return cast(size_t) countCatalogQueryFromDatabase(database, options);
    }

    /** List immediate child directories using bounded SQL queries. */
    RepositoryDirectory[] listDirectories(RepositoryDirectoryQuery options = RepositoryDirectoryQuery())
    {
        requireOpen();
        enforce(options.limit > 0, "Directory page size must be greater than zero.");
        return listDirectoriesFromDatabase(database, options);
    }

    /** Return bounded aggregate values for the repository's root node. */
    RepositoryRootSummary rootSummary()
    {
        requireOpen();
        return loadRootSummaryFromDatabase(database);
    }

    /** List immediate file references using bounded SQL queries. */
    RepositoryFile[] listFiles(RepositoryFileQuery options = RepositoryFileQuery())
    {
        requireOpen();
        enforce(options.limit > 0, "File page size must be greater than zero.");
        return listFilesFromDatabase(database, options);
    }

    /** List one keyset-paged file chunk without exposing SQL pagination details. */
    RepositoryFilePage listFilesPage(RepositoryFileQuery options = RepositoryFileQuery())
    {
        requireOpen();
        enforce(options.limit > 0, "File page size must be greater than zero.");
        return listFilesPageFromDatabase(database, options);
    }

    /** Continue forward from a stable file cursor in the query's sorted result. */
    RepositoryFilePage nextFilesPage(RepositoryFileQuery options,
        RepositoryFileCursor cursor)
    {
        options.afterPath = cursor.relativePath;
        options.afterId = cursor.id;
        options.afterSize = cursor.size;
        options.beforeCursor = false;
        return listFilesPage(options);
    }

    /** Continue backward from a stable file cursor, returning rows in display order. */
    RepositoryFilePage previousFilesPage(RepositoryFileQuery options,
        RepositoryFileCursor cursor)
    {
        options.afterPath = cursor.relativePath;
        options.afterId = cursor.id;
        options.afterSize = cursor.size;
        options.beforeCursor = true;
        return listFilesPage(options);
    }

    /** List archive entries for one blob using bounded SQL queries. */
    RepositoryArchiveEntry[] listArchiveEntries(RepositoryArchiveQuery options)
    {
        requireOpen();
        enforce(options.limit > 0, "Archive entry page size must be greater than zero.");
        return listArchiveEntriesFromDatabase(database, options);
    }

    /** List torrent files for one blob using bounded SQL queries. */
    RepositoryTorrentFile[] listTorrentFiles(RepositoryTorrentQuery options)
    {
        requireOpen();
        enforce(options.limit > 0, "Torrent file page size must be greater than zero.");
        return listTorrentFilesFromDatabase(database, options);
    }

    /** Scan the repository root and update its filesystem references. */
    ScanSummary scan(RepositoryScanOptions options = RepositoryScanOptions())
    {
        requireOpen();
        return scanRepository(database, repositoryPaths.rootPath, options);
    }

    /** Run selected metadata extraction jobs for stored file references. */
    MetadataSummary updateMetadata(
        MetadataScanOptions options = MetadataScanOptions())
    {
        requireOpen();
        return updateRepositoryMetadata(database, repositoryPaths.rootPath, options);
    }

    /** Analyze missing references and duplicate blobs in SQL. */
    AnalysisSummary analyze(
        RepositoryAnalysisOptions options = RepositoryAnalysisOptions())
    {
        requireOpen();
        return analyzeRepository(database, options);
    }

    /** Return duplicate groups without changing repository data. */
    RepositoryDuplicateGroup[] queryDuplicates(size_t limit = 100)
    {
        requireOpen();
        enforce(limit > 0, "Duplicate query limit must be greater than zero.");
        return queryDuplicateGroups(database, limit);
    }

    /** Explicitly close the repository connection. */
    void close()
    {
        if (openState)
        {
            database.close();
            openState = false;
        }
    }
}

private string canonicalDirectory(string path)
{
    auto resolved = buildNormalizedPath(absolutePath(path));
    if (!exists(resolved))
        throw new RepositoryException("Directory does not exist: " ~ path);
    if (!isDir(resolved))
        resolved = dirName(resolved);
    return resolved;
}

private string escapeLogValue(string value)
{
    import std.string : replace;
    return value.replace("\\", "\\\\").replace("\"", "\\\"")
        .replace("\n", "\\n").replace("\r", "\\r");
}

@("repository initialization and root discovery")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-" ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    assert(repository.rootPath == buildNormalizedPath(root));
    assert(repository.info.schemaVersion == currentRepositorySchemaVersion);
    assert(exists(repository.databasePath));
    repository.close();

    auto nested = buildPath(root, "nested", "path");
    mkdirRecurse(nested);
    auto reopened = Repository.open(nested);
    assert(reopened.rootPath == buildNormalizedPath(root));
    reopened.close();
}

@("repository JSON import and export roundtrip")
unittest
{
    import dosierskanilo.model.namedbinaryblob : deserializeDataClassJsonFile,
        sortDataClassArrayByFileName;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-json-" ~ randomUUID().toString());
    mkdirRecurse(root);
    auto exported = buildPath(root, "roundtrip.json");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    repository.importJson("./test/json_file_v2.json");
    assert(repository.blobCount == 3);
    assert(repository.countCatalogQuery(RepositoryQueryOptions()) == 3);
    assert(repository.loadCatalogPage(0, 1).length == 1);
    RepositoryQueryOptions query;
    query.text = "ala";
    assert(repository.loadCatalogQueryPage(query).length == 1);
    repository.exportJson(exported);
    repository.close();

    auto imported = deserializeDataClassJsonFile("./test/json_file_v2.json");
    auto roundtrip = deserializeDataClassJsonFile(exported);
    auto expected = sortDataClassArrayByFileName(imported);
    auto actual = sortDataClassArrayByFileName(roundtrip);
    assert(expected.length == actual.length);
    foreach (index; 0 .. expected.length)
        assert(expected[index].toString == actual[index].toString,
            expected[index].toString ~ " != " ~ actual[index].toString);
}

@("repository imports legacy array and version-1/version-3 fixtures")
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-json-versions-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    string[] fixtures = [
        "./test/json_file_v0.json",
        "./test/json_file_v1.json",
        "./test/json_file_v2.json",
        "./test/json_file_v2_archive.json",
        "./test/json_file_v2_torrent.json"
    ];
    size_t[] expectedCounts = [3, 3, 3, 1, 1];
    JsonImportOptions importOptions;
    importOptions.force = true;
    foreach (index, fixture; fixtures)
    {
        repository.importJson(fixture, importOptions);
        assert(repository.blobCount == expectedCounts[index]);
    }
    repository.close();
}

@("repository imports an actual version-2 wrapper and exports migrated version-3 data")
unittest
{
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION3,
        deserializeDataClassJsonWrapperFile;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto fixture = buildPath(tempDir(), "repository-json-v2-roundtrip-"
        ~ randomUUID().toString());
    auto root = buildPath(fixture, "repository");
    auto exported = buildPath(fixture, "exported-v3.json");
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(fixture))
            rmdirRecurse(fixture);
    }

    auto input = deserializeDataClassJsonWrapperFile(
        "./test/json_file_wrapper_v2.json");
    assert(input.dataVersion == 2);
    assert(input.dataArray.length == 1);

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.importJson("./test/json_file_wrapper_v2.json");

    auto imported = repository.loadCatalog();
    assert(imported.length == 1);
    auto blob = imported[0];
    assert(blob.fileSize == 4096);
    assert(blob.getFirstFileName == "v2/sample.rar");
    assert(blob.checkSums.md5sum_b64 == "CJDSa/B3y0CdbYM+kidLhg==");
    assert(blob.checkSums.sha1sum_b64 == "K8ByyTS7PbXAvLXGiMJ9LnR+UF4=");
    assert(blob.fileType == "RAR archive data");
    assert(blob.archiveSpecs.length == 1);
    assert(blob.archiveSpecs[0].fileName == "payload.bin");
    assert(blob.archiveSpecs[0].checkSums.sha1sum_b64
        == "K8ByyTS7PbXAvLXGiMJ9LnR+UF4=");

    repository.exportJson(exported);
    auto roundtrip = deserializeDataClassJsonWrapperFile(exported);
    assert(roundtrip.dataVersion == DATA_CLASS_VERSION3);
    assert(roundtrip.dataArray.length == 1);
    assert(roundtrip.dataArray[0].fileSize == blob.fileSize);
    assert(roundtrip.dataArray[0].getFirstFileName == "v2/sample.rar");
    assert(roundtrip.dataArray[0].archiveSpecs.length == 1);
    assert(roundtrip.dataArray[0].archiveSpecs[0].fileName == "payload.bin");
}

@("filtered JSON export preserves selected blob relationship closure")
unittest
{
    import std.algorithm.searching : startsWith;
    import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION3,
        deserializeDataClassJsonWrapperFile;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto fixture = buildPath(tempDir(), "repository-filtered-export-closure-"
        ~ randomUUID().toString());
    auto root = buildPath(fixture, "source");
    auto roundtripRoot = buildPath(fixture, "roundtrip");
    auto exported = buildPath(fixture, "selected-export.json");
    mkdirRecurse(buildPath(root, "wanted"));
    mkdirRecurse(buildPath(root, "excluded"));
    mkdirRecurse(roundtripRoot);
    scope (exit)
    {
        if (exists(fixture))
            rmdirRecurse(fixture);
    }

    write(buildPath(root, "wanted", "selected-one.bin"), "same selected content");
    write(buildPath(root, "wanted", "selected-two.bin"), "same selected content");
    write(buildPath(root, "excluded", "shared-outside.bin"), "same selected content");
    write(buildPath(root, "excluded", "outside-only.bin"), "not selected");

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();
    MetadataScanOptions metadataOptions;
    metadataOptions.calculateChecksums = true;
    repository.updateMetadata(metadataOptions);
    auto analysis = repository.analyze();
    assert(analysis.duplicateGroups == 1);
    assert(analysis.mergedBlobs == 2);
    assert(repository.blobCount == 2);

    JsonExportOptions exportOptions;
    exportOptions.pathPrefix = "wanted";
    repository.exportJson(exported, exportOptions);

    auto exportedCatalog = deserializeDataClassJsonWrapperFile(exported);
    assert(exportedCatalog.dataVersion == DATA_CLASS_VERSION3);
    assert(exportedCatalog.dataArray.length == 1,
        "only the blob referenced by the selected paths should be exported");
    auto selectedBlob = exportedCatalog.dataArray[0];
    assert(selectedBlob.fileSpecs.length == 2);
    assert(selectedBlob.checkSums.hasDigests);
    bool sawFirst;
    bool sawSecond;
    foreach (spec; selectedBlob.fileSpecs)
    {
        assert(spec !is null);
        assert(spec.fileName.startsWith("wanted/"));
        sawFirst = sawFirst || spec.fileName == "wanted/selected-one.bin";
        sawSecond = sawSecond || spec.fileName == "wanted/selected-two.bin";
    }
    assert(sawFirst && sawSecond);

    auto roundtrip = Repository.initialize(roundtripRoot);
    scope (exit)
        roundtrip.close();
    roundtrip.importJson(exported);
    auto imported = roundtrip.loadCatalog();
    assert(imported.length == 1);
    assert(imported[0].fileSpecs.length == 2);
    assert(imported[0].checkSums.hasDigests);
    foreach (spec; imported[0].fileSpecs)
        assert(spec.fileName.startsWith("wanted/"));
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

@("repository incremental filesystem scan")
unittest
{
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-scan-" ~ randomUUID().toString());
    auto nested = buildPath(root, "nested");
    auto emptyDirectory = buildPath(root, "empty");
    auto firstFile = buildPath(root, "first.txt");
    auto thirdFile = buildPath(root, "third.txt");
    auto secondFile = buildPath(nested, "second.txt");
    mkdirRecurse(nested);
    mkdirRecurse(emptyDirectory);
    write(firstFile, "first");
    write(thirdFile, "third");
    write(secondFile, "second");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    auto first = repository.scan();
    assert(first.filesFound == 3);
    assert(first.directoriesFound >= 2);
    assert(first.filesAdded == 3);
    assert(first.filesChanged == 0);

    auto rootSummary = repository.rootSummary();
    assert(rootSummary.childDirectoryCount == 2);
    assert(rootSummary.fileCount == 2);
    assert(rootSummary.aggregateSize == 16);

    RepositoryQueryOptions catalogCursorQuery;
    catalogCursorQuery.limit = 1;
    auto catalogFirstChunk = repository.loadCatalogQueryCursorPage(catalogCursorQuery);
    assert(catalogFirstChunk.blobIds.length == 1);
    assert(catalogFirstChunk.hasMore);
    catalogCursorQuery.afterBlobId = catalogFirstChunk.nextCursor;
    auto catalogSecondChunk = repository.loadCatalogQueryCursorPage(catalogCursorQuery);
    assert(catalogSecondChunk.blobIds.length == 1);
    assert(catalogSecondChunk.blobIds[0] > catalogFirstChunk.blobIds[0]);
    assert(catalogSecondChunk.hasMore);

    RepositoryDirectoryQuery matchingDirectoryQuery;
    matchingDirectoryQuery.limit = 10;
    matchingDirectoryQuery.text = "second.txt";
    auto matchingDirectories = repository.listDirectories(matchingDirectoryQuery);
    assert(matchingDirectories.length == 1);
    assert(matchingDirectories[0].name == "nested");
    matchingDirectoryQuery.text = "SECOND.TXT";
    assert(repository.listDirectories(matchingDirectoryQuery).length == 1);
    matchingDirectoryQuery.caseSensitive = true;
    assert(repository.listDirectories(matchingDirectoryQuery).length == 0);
    matchingDirectoryQuery.text = "not-present";
    assert(repository.listDirectories(matchingDirectoryQuery).length == 0);

    auto unchanged = repository.scan();
    assert(unchanged.filesFound == 3);
    assert(unchanged.filesAdded == 0);
    assert(unchanged.filesChanged == 0);
    assert(unchanged.filesMissing == 0);

    write(firstFile, "changed content");
    auto changed = repository.scan();
    assert(changed.filesChanged == 1);

    remove(secondFile);
    auto missing = repository.scan();
    assert(missing.filesMissing == 1);

    RepositoryScanOptions dropOptions;
    dropOptions.dropMissing = true;
    auto dropped = repository.scan(dropOptions);
    assert(dropped.filesDropped == 1);

    RepositoryDirectoryQuery directoryQuery;
    directoryQuery.limit = 10;
    auto rootDirectories = repository.listDirectories(directoryQuery);
    assert(rootDirectories.length >= 2);
    auto nestedDirectory = rootDirectories[0].name == "nested"
        ? rootDirectories[0] : rootDirectories[1];
    assert(nestedDirectory.name == "nested");
    assert(nestedDirectory.fileCount == 0,
        "missing file should no longer be counted");

    RepositoryFileQuery fileQuery;
    fileQuery.limit = 10;
    auto rootFiles = repository.listFiles(fileQuery);
    assert(rootFiles.length == 2);
    assert(rootFiles[0].name == "first.txt");
    RepositoryFileQuery cursorQuery;
    cursorQuery.limit = 1;
    auto firstPage = repository.listFilesPage(cursorQuery);
    assert(firstPage.files.length == 1);
    assert(firstPage.hasMore);
    cursorQuery.afterPath = firstPage.nextCursor.relativePath;
    cursorQuery.afterId = firstPage.nextCursor.id;
    auto secondPage = repository.listFilesPage(cursorQuery);
    assert(secondPage.files.length == 1);
    assert(!secondPage.hasMore);
    auto previousPage = repository.previousFilesPage(cursorQuery,
        RepositoryFileCursor(secondPage.files[0].relativePath, secondPage.files[0].id,
            secondPage.files[0].size));
    assert(previousPage.files.length == 1);
    assert(previousPage.files[0].id == firstPage.files[0].id);

    RepositoryFileQuery sizeQuery;
    sizeQuery.limit = 1;
    sizeQuery.sortOrder = RepositoryFileSortOrder.sizeAscending;
    auto smallestPage = repository.listFilesPage(sizeQuery);
    assert(smallestPage.files.length == 1);
    sizeQuery.afterPath = smallestPage.nextCursor.relativePath;
    sizeQuery.afterId = smallestPage.nextCursor.id;
    sizeQuery.afterSize = smallestPage.nextCursor.size;
    auto nextSizePage = repository.listFilesPage(sizeQuery);
    assert(nextSizePage.files.length == 1);
    assert(nextSizePage.files[0].size >= smallestPage.files[0].size);
    auto previousSizePage = repository.previousFilesPage(sizeQuery,
        RepositoryFileCursor(nextSizePage.files[0].relativePath, nextSizePage.files[0].id,
            nextSizePage.files[0].size));
    assert(previousSizePage.files.length == 1);
    assert(previousSizePage.files[0].id == smallestPage.files[0].id);
    repository.close();
}

@("repository metadata update for checksums and file type")
unittest
{
    import std.file : copy, exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-metadata-" ~ randomUUID().toString());
    mkdirRecurse(root);
    auto input = buildPath(root, "sample.txt");
    auto secondInput = buildPath(root, "sample-copy.txt");
    copy("./test/dummy-text-file.txt", input);
    copy("./test/dummy-text-file.txt", secondInput);
    auto exported = buildPath(root, "metadata.json");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    auto scanSummary = repository.scan();
    assert(scanSummary.filesAdded == 2);

    MetadataScanOptions options;
    options.calculateChecksums = true;
    options.detectFileTypes = true;
    options.threads = 2;
    auto metadataSummary = repository.updateMetadata(options);
    assert(metadataSummary.blobsVisited == 2);
    assert(metadataSummary.checksumsUpdated == 2);
    assert(metadataSummary.fileTypesUpdated == 2);
    assert(metadataSummary.failed == 0);

    repository.exportJson(exported);
    repository.close();

    import dosierskanilo.model.namedbinaryblob : deserializeDataClassJsonFile;
    auto blobs = deserializeDataClassJsonFile(exported);
    assert(blobs.length == 2);
    foreach (blob; blobs)
    {
        assert(blob.checkSums.hasDigests);
        assert(blob.fileType.length > 0);
    }
}

@("repository metadata update for media and torrent data")
unittest
{
    import std.file : copy, exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-rich-metadata-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    copy("./test/dummy-picture-file.jpg", buildPath(root, "picture.jpg"));
    copy("./test/example.torrent", buildPath(root, "example.torrent"));
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    repository.scan();
    MetadataScanOptions options;
    options.extractMediaInfo = true;
    options.scanTorrents = true;
    auto summary = repository.updateMetadata(options);
    assert(summary.blobsVisited == 2);
    assert(summary.mediaInfoUpdated >= 1);
    assert(summary.torrentsUpdated == 1);
    assert(summary.failed == 0);
    RepositoryFileQuery imageQuery;
    imageQuery.limit = size_t.max;
    imageQuery.image = true;
    auto imagePage = repository.listFilesPage(imageQuery);
    assert(imagePage.files.length == 1);
    assert(imagePage.files[0].hasImage);
    imageQuery.mediaNegated = true;
    auto nonImagePage = repository.listFilesPage(imageQuery);
    assert(nonImagePage.files.length == 1);
    assert(!nonImagePage.files[0].hasImage);
    auto secondSummary = repository.updateMetadata(options);
    assert(secondSummary.mediaInfoUpdated == 0);
    assert(secondSummary.torrentsUpdated == 0);
    repository.close();
}

@("repository SQL duplicate and missing-file analysis")
unittest
{
    import std.file : copy, exists, mkdirRecurse, remove, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-analysis-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto first = buildPath(root, "first.txt");
    auto second = buildPath(root, "second.txt");
    copy("./test/dummy-text-file.txt", first);
    copy("./test/dummy-text-file.txt", second);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    repository.scan();
    MetadataScanOptions metadataOptions;
    metadataOptions.calculateChecksums = true;
    repository.updateMetadata(metadataOptions);

    auto duplicateGroups = repository.queryDuplicates();
    assert(duplicateGroups.length == 1);
    assert(duplicateGroups[0].blobIds.length == 2);

    auto duplicates = repository.analyze();
    assert(duplicates.duplicateGroups == 1);
    assert(duplicates.mergedBlobs == 1);

    remove(second);
    repository.scan();
    RepositoryAnalysisOptions analysisOptions;
    analysisOptions.dropMissing = true;
    auto missing = repository.analyze(analysisOptions);
    assert(missing.missingFiles == 1);
    assert(missing.droppedFiles == 1);
    repository.close();
}

@("repository archive and torrent metadata persistence")
unittest
{
    import dosierskanilo.model.namedbinaryblob : deserializeDataClassJsonFile;
    import std.file : copy, exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-rich-persistence-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    auto payload = buildPath(root, "payload.txt");
    auto archive = buildPath(root, "payload.zip");
    auto torrent = buildPath(root, "example.torrent");
    write(payload, "repository archive payload\n");
    assert(execute(["zip", "-q", "-j", archive, payload]).status == 0);
    copy("./test/example.torrent", torrent);
    auto exported = buildPath(root, "export.json");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    repository.scan();
    MetadataScanOptions options;
    options.scanArchives = true;
    options.scanTorrents = true;
    options.deepArchiveScan = true;
    auto summary = repository.updateMetadata(options);
    assert(summary.archivesUpdated == 1);
    assert(summary.torrentsUpdated == 1);
    assert(summary.failed == 0);
    RepositoryFileQuery archiveQuery;
    archiveQuery.archive = true;
    archiveQuery.limit = 10;
    auto archiveFiles = repository.listFiles(archiveQuery);
    assert(archiveFiles.length == 1);
    assert(archiveFiles[0].hasArchive);
    JsonExportOptions lazyDetails;
    lazyDetails.includeArchiveEntries = false;
    lazyDetails.includeTorrentFiles = false;
    auto archiveBlob = repository.loadBlobDetails(archiveFiles[0].blobId, lazyDetails);
    assert(archiveBlob !is null);
    assert(archiveBlob.archiveSpecs.length == 0);
    RepositoryArchiveQuery archiveEntriesQuery;
    archiveEntriesQuery.blobId = archiveFiles[0].blobId;
    assert(repository.listArchiveEntries(archiveEntriesQuery).length > 0);
    RepositoryFileQuery torrentQuery;
    torrentQuery.torrent = true;
    torrentQuery.limit = 10;
    auto torrentFiles = repository.listFiles(torrentQuery);
    assert(torrentFiles.length == 1);
    assert(torrentFiles[0].hasTorrent);
    auto torrentBlob = repository.loadBlobDetails(torrentFiles[0].blobId, lazyDetails);
    assert(torrentBlob !is null && torrentBlob.torrentInfo !is null);
    assert(torrentBlob.torrentInfo.files.length == 0);
    RepositoryTorrentQuery torrentEntriesQuery;
    torrentEntriesQuery.blobId = torrentFiles[0].blobId;
    assert(repository.listTorrentFiles(torrentEntriesQuery).length > 0);
    repository.exportJson(exported);
    repository.close();

    auto blobs = deserializeDataClassJsonFile(exported);
    bool foundArchive;
    bool foundTorrent;
    foreach (blob; blobs)
    {
        if (blob.archiveSpecs.length > 0)
            foundArchive = true;
        if (blob.torrentInfo !is null)
            foundTorrent = true;
    }
    assert(foundArchive);
    assert(foundTorrent);
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

@("repository missing-file reconciliation and drop counters cover all references")
unittest
{
    import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir, write;
    import std.format : format;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-missing-reconcile-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    string[] missingPaths;
    foreach (index; 0 .. 40)
    {
        auto path = buildPath(root, format("gone-%02d.txt", index));
        write(path, format("payload-%02d", index));
        missingPaths ~= path;
    }
    auto keepPath = buildPath(root, "keep.txt");
    write(keepPath, "still here");
    write(buildPath(root, ".hidden-control.txt"), "hidden and ignored");

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    assert(repository.scan().filesAdded == 41);

    foreach (path; missingPaths)
        remove(path);
    auto missing = repository.scan();
    assert(missing.filesMissing == missingPaths.length);
    assert(missing.filesDropped == 0);

    RepositoryScanOptions dropOptions;
    dropOptions.dropMissing = true;
    auto dropped = repository.scan(dropOptions);
    assert(dropped.filesMissing == 0,
        "filesMissing counts references newly observed missing in this run");
    assert(dropped.filesDropped == missingPaths.length,
        "filesDropped counts missing references physically removed in this run");
    assert(repository.blobCount == 1);
}

@("repository changed-file scans clean only unreferenced old blobs")
unittest
{
    import std.file : copy, exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "repository-changed-file-orphans-"
        ~ randomUUID().toString());
    mkdirRecurse(root);
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto firstPath = buildPath(root, "first.torrent");
    auto secondPath = buildPath(root, "second.torrent");
    copy("./test/example.torrent", firstPath);
    copy("./test/example.torrent", secondPath);

    auto repository = Repository.initialize(root);
    scope (exit)
        repository.close();
    repository.scan();
    MetadataScanOptions metadataOptions;
    metadataOptions.calculateChecksums = true;
    metadataOptions.scanTorrents = true;
    repository.updateMetadata(metadataOptions);
    auto merged = repository.analyze();
    assert(merged.mergedBlobs == 1);
    assert(repository.blobCount == 1,
        "identical file contents should share one blob before change checks");
    auto original = repository.loadCatalog();
    assert(original.length == 1 && original[0].torrentInfo !is null,
        "shared original blob has dependent torrent metadata");

    write(firstPath, "first file changed to a larger payload");
    auto firstChange = repository.scan();
    assert(firstChange.filesChanged == 1);
    assert(repository.blobCount == 2,
        "the old blob remains while second.torrent still references it");

    write(secondPath, "second file changed to another payload");
    auto secondChange = repository.scan();
    assert(secondChange.filesChanged == 1);
    assert(repository.blobCount == 2,
        "the shared original blob is removed after its final reference moves");

    write(firstPath, "first file changed again to another size");
    auto thirdChange = repository.scan();
    assert(thirdChange.filesChanged == 1);
    assert(repository.blobCount == 2,
        "the unreferenced intermediate blob must be cleaned after reassignment");

    auto unchanged = repository.scan();
    assert(unchanged.filesChanged == 0);
    assert(repository.blobCount == 2,
        "an unchanged scan must not accumulate additional blobs");
}
