/** Public value types used by the repository API. */
module dosierskanilo.repository.types;

import std.path : buildPath;

/** Name of the repository metadata directory. */
enum repositoryDirectoryName = ".dosierskanilo";

/** Name of the SQLite database inside a repository. */
enum repositoryDatabaseFileName = "catalog.sqlite3";

/** Current database schema version. */
enum ulong currentRepositorySchemaVersion = 1;

/** Paths belonging to one repository root. */
struct RepositoryPaths
{
    /// Canonical directory represented by this repository.
    string rootPath;
    /// Hidden metadata directory below `rootPath`.
    string metadataPath;
    /// SQLite catalog file path.
    string databasePath;
    /// Operational log directory.
    string logsPath;
    /// JSON export directory.
    string exportsPath;
    /// Backup directory.
    string backupsPath;

    /** Construct repository paths from an absolute root directory. */
    static RepositoryPaths fromRoot(string rootPath)
    {
        auto metadataPath = buildPath(rootPath, repositoryDirectoryName);
        return RepositoryPaths(
            rootPath,
            metadataPath,
            buildPath(metadataPath, repositoryDatabaseFileName),
            buildPath(metadataPath, "logs"),
            buildPath(metadataPath, "exports"),
            buildPath(metadataPath, "backups"));
    }
}

/** Options used while creating or opening a repository. */
struct RepositoryOptions
{
    /// Enable SQLite write-ahead logging for concurrent readers.
    bool enableWal = true;
}

/** Metadata stored for the repository itself. */
struct RepositoryInfo
{
    /// Canonical repository root path.
    string rootPath;
    /// Database schema version.
    ulong schemaVersion;
    /// Repository creation timestamp.
    string createdAt;
    /// Last repository metadata update timestamp.
    string updatedAt;
    /// MediaInfo version stored by the scanner.
    string mediaInfoVersion;
    /// `file` utility version stored by the scanner.
    string fileUtilityVersion;
}

/** Options for importing a JSON catalog into a repository. */
struct JsonImportOptions
{
    /// Replace the current repository catalog before importing.
    bool replaceExisting = true;
}

/** Options for exporting repository data as JSON. */
struct JsonExportOptions
{
    /**
     * Optional root-relative path prefix. An empty prefix exports all current
     * file references.
     */
    string pathPrefix;
}
