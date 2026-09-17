/** Persistent repository access for DosierSkanilo. */
module dosierskanilo.repository.repository;

import d2sqlite3;

import std.datetime.systime : Clock;
import std.file : exists, isDir, mkdirRecurse;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.string : empty;
import std.typecons : Nullable;

import dosierskanilo.repository.errors;
import dosierskanilo.repository.schema : migrate;
import dosierskanilo.repository.transfer : exportCatalogJson, importCatalogJson;
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
        exportCatalogJson(database, jsonFile, options);
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
