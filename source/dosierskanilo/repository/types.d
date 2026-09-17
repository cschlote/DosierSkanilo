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

/** Options controlling a repository filesystem scan. */
struct RepositoryScanOptions
{
    /// Traverse all descendant directories when true.
    bool recursive = true;
    /// Include hidden files and directories when true.
    bool pickHidden;
    /// Delete file references that are missing after the scan.
    bool dropMissing;
}

/** Counters returned by a repository filesystem scan. */
struct ScanSummary
{
    /// Number of directories encountered.
    size_t directoriesFound;
    /// Number of files encountered.
    size_t filesFound;
    /// Number of new file references inserted.
    size_t filesAdded;
    /// Number of file references whose size or timestamp changed.
    size_t filesChanged;
    /// Number of existing references not found during this scan.
    size_t filesMissing;
    /// Number of missing references removed by `dropMissing`.
    size_t filesDropped;
}

/** Options for metadata extraction after a repository filesystem scan. */
struct MetadataScanOptions
{
    /// Calculate MD5, SHA1 and XXH64 when a complete set is missing.
    bool calculateChecksums;
    /// Query the `file` utility when no file type is stored.
    bool detectFileTypes;
    /// Extract structured MediaInfo streams.
    bool extractMediaInfo;
    /// Inspect archive entries.
    bool scanArchives;
    /// Inspect archive entries and calculate entry checksums.
    bool deepArchiveScan = true;
    /// Parse torrent metadata.
    bool scanTorrents;
    /// Force refresh of metadata that is already present.
    bool rescan;
}

/** Counters returned by a repository metadata update. */
struct MetadataSummary
{
    /// Number of blobs with at least one existing file reference visited.
    size_t blobsVisited;
    /// Number of blobs whose checksum set was updated.
    size_t checksumsUpdated;
    /// Number of blobs whose file type was updated.
    size_t fileTypesUpdated;
    /// Number of blobs whose MediaInfo was updated.
    size_t mediaInfoUpdated;
    /// Number of blobs whose archive entries were updated.
    size_t archivesUpdated;
    /// Number of blobs whose torrent metadata was updated.
    size_t torrentsUpdated;
    /// Number of metadata jobs that failed.
    size_t failed;
}

/** Options controlling SQL-based repository analysis. */
struct RepositoryAnalysisOptions
{
    /// Remove stored file references marked as missing.
    bool dropMissing;
    /// Merge blobs with identical size and complete checksums.
    bool mergeDuplicates = true;
}

/** Counters returned by repository analysis. */
struct AnalysisSummary
{
    /// Missing file references found before optional cleanup.
    size_t missingFiles;
    /// Missing file references removed by `dropMissing`.
    size_t droppedFiles;
    /// Duplicate blob groups found.
    size_t duplicateGroups;
    /// Blob rows merged into another blob.
    size_t mergedBlobs;
    /// Unreferenced blob rows removed after cleanup.
    size_t orphanedBlobs;
}
