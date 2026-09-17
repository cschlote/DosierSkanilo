/** Persistent repository access for DosierSkanilo. */
module dosierskanilo.repository.repository;

import d2sqlite3;

import std.datetime.systime : Clock;
import std.exception : enforce;
import std.file : exists, isDir, mkdirRecurse;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.string : empty;
import std.stdio : File;
import std.typecons : Nullable;

import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.analysis : analyzeRepository;
import dosierskanilo.repository.metadata : updateRepositoryMetadata;
import dosierskanilo.repository.schema : migrate;
import dosierskanilo.repository.scanner : scanRepository;
import dosierskanilo.repository.transfer : exportCatalogJson, importCatalogJson,
    loadCatalogFromDatabase, loadCatalogPageFromDatabase,
    loadCatalogQueryPageFromDatabase, loadCatalogQueryPageWithIdsFromDatabase,
    loadBlobDetailsFromDatabase, countCatalogQueryFromDatabase;
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
            db.execute("PRAGMA journal_mode = WAL");
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

@("repository imports supported JSON fixture versions")
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
    foreach (index, fixture; fixtures)
    {
        repository.importJson(fixture);
        assert(repository.blobCount == expectedCounts[index]);
    }
    repository.close();
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
    auto secondFile = buildPath(nested, "second.txt");
    mkdirRecurse(nested);
    mkdirRecurse(emptyDirectory);
    write(firstFile, "first");
    write(secondFile, "second");
    scope (exit)
    {
        if (exists(root))
            rmdirRecurse(root);
    }

    auto repository = Repository.initialize(root);
    auto first = repository.scan();
    assert(first.filesFound == 2);
    assert(first.directoriesFound >= 2);
    assert(first.filesAdded == 2);
    assert(first.filesChanged == 0);

    auto unchanged = repository.scan();
    assert(unchanged.filesFound == 2);
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
