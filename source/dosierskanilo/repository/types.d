/** Public value types used by the repository API.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.types;

import std.path : buildPath;

import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob;
import dosierarkivo.archive : ArchivePasswordCallback;

/** Name of the repository metadata directory. */
enum repositoryDirectoryName = ".dosierskanilo";

/** Name of the SQLite database inside a repository. */
enum repositoryDatabaseFileName = "catalog.sqlite3";

/** Current database schema version. */
enum ulong currentRepositorySchemaVersion = 6;

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
    /// Structured operational log file.
    string logFilePath;

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
            buildPath(metadataPath, "backups"),
            buildPath(metadataPath, "logs", "operations.jsonl"));
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
    /// Require explicit confirmation before replacing non-empty data.
    bool force;
    /// Create a SQLite backup before replacing existing data.
    bool backupExisting = true;
}

/** Options for exporting repository data as JSON. */
struct JsonExportOptions
{
    /**
     * Optional root-relative path prefix. An empty prefix exports all current
     * file references.
     */
    string pathPrefix;
    /// Return absolute filesystem paths for an in-process repository reader.
    bool absolutePaths;
    /// Include nested MediaInfo, archive and torrent details.
    bool includeDetails = true;
    /// Include archive entry rows as part of blob details.
    bool includeArchiveEntries = true;
    /// Include torrent file rows as part of blob details.
    bool includeTorrentFiles = true;
    /// Allow loading an archive-member content row without physical file refs.
    bool allowUnreferencedContent;
    /// Indent the exported JSON for human reading.
    bool prettyJson;
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
    /// Number of references newly detected as missing during this scan.
    size_t filesMissing;
    /// Number of missing references physically removed by `dropMissing` this run.
    size_t filesDropped;
}

/** Scan summary plus cooperative-cancellation outcome for controlled callers. */
struct ScanExecutionResult
{
    ScanSummary summary; /// Counters collected by the scan.
    bool cancelled; /// True when cooperative cancellation stopped the scan.
    bool committed; /// True when the scan committed its changes.
}

/** Options for metadata extraction after a repository filesystem scan. */
struct MetadataScanOptions
{
    /// Number of metadata workers. One keeps serial execution.
    size_t threads = 1;
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
    /// Optional frontend callback used when an archive requires a password.
    ArchivePasswordCallback archivePasswordCallback;
    /// Optional repository-relative path restricting metadata work to one blob.
    string filePath;
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
    /// Last job error message, empty when every selected job succeeded.
    string lastError;
}

/** Metadata summary plus cooperative-cancellation outcome. */
struct MetadataExecutionResult
{
    MetadataSummary summary; /// Counters collected by the metadata run.
    bool cancelled; /// True when cooperative cancellation stopped the run.
    bool committed; /// True when the metadata run committed its changes.
}

/** Options controlling SQL-based repository analysis. */
struct RepositoryAnalysisOptions
{
    /// Remove stored file references marked as missing.
    bool dropMissing;
    /// Merge blobs with identical size and complete checksums.
    bool mergeDuplicates = true;
}

/** Directory projection returned by the repository tree API. */
struct RepositoryDirectory
{
    long id; /// Stable repository directory identity.
    long parentId; /// Parent directory ID; zero denotes the repository root.
    string name; /// Final path component shown in the tree.
    string relativePath; /// Root-relative display path.
    size_t childDirectoryCount; /// Immediate matching child directories.
    size_t fileCount; /// File references below this directory.
    ulong aggregateSize; /// Aggregate size of referenced content below this directory.
}

/** Bounded aggregate values used to construct the repository root node. */
struct RepositoryRootSummary
{
    size_t childDirectoryCount; /// Immediate matching child directories.
    size_t fileCount; /// Matching file references below the root.
    ulong aggregateSize; /// Aggregate size of matching references.
}

/** File projection returned by the repository tree API. */
struct RepositoryFile
{
    long id; /// Stable file-reference identity.
    long directoryId; /// Parent directory ID.
    long blobId; /// Content blob identity.
    string name; /// Final path component shown in the tree.
    string relativePath; /// Root-relative display path.
    ulong size; /// Content size in bytes.
    string modifiedAt; /// Last observed modification timestamp.
    bool present; /// True when at least one reference currently exists on disk.
    bool hasFileType; /// File-type metadata exists.
    bool hasMedia; /// One or more media streams exist.
    bool hasVideo; /// A video stream exists.
    bool hasAudio; /// An audio stream exists.
    bool hasImage; /// An image stream exists.
    bool hasText; /// A text/subtitle stream exists.
    bool hasArchive; /// Archive metadata exists.
    bool hasTorrent; /// Torrent metadata exists.
    bool archiveMember; /// True for a virtual archive-member reference.
    long containerReferenceId; /// Container file-reference ID for archive members.
    long archiveEntryId; /// Archive-entry row ID for archive members.
    long archiveContainerBlobId; /// Container content blob ID for archive members.
    size_t archiveEntryIndex; /// Ordered index of the member in its container.
    string archiveContainerIdentity; /// Canonical virtual container path for nested members.
}

/** Query options for bounded directory children reads. */
struct RepositoryDirectoryQuery
{
    /// Parent directory ID; zero denotes the repository root.
    long parentId;
    size_t offset; /// Zero-based result offset.
    size_t limit = 250; /// Maximum number of directories to return.
    string text; /// Optional path text filter.
    bool caseSensitive; /// Apply `text` case-sensitively.
    bool video; /// Require a video media stream.
    bool audio; /// Require an audio media stream.
    bool image; /// Require an image media stream.
    bool textStream; /// Require a text/subtitle media stream.
    bool mediaNegated; /// Invert the combined media-stream condition.
    bool fileType; /// Require file-type metadata.
    bool archive; /// Require archive metadata.
    bool torrent; /// Require torrent metadata.
    /// Exclude references currently marked missing on disk.
    bool availableOnly;
    /// Include indexed archive members in child-file queries.
    bool includeArchiveMembers;
}

/** Archive entry projection for lazy detail views. */
struct RepositoryArchiveEntry
{
    long id; /// Stable row identity within the repository.
    long containerBlobId; /// Content blob that owns this index entry.
    size_t entryIndex; /// Position in the persisted index sequence.
    size_t occurrence; /// Duplicate occurrence for this normalized path.
    string name; /// Original archive-provided entry name.
    string relativePath; /// Normalized member path when safe.
    bool isDirectory; /// Whether this row describes a directory entry.
    bool hasSafePath; /// Whether the path is relative and traversal-free.
    ulong size; /// Uncompressed member size when deeply scanned.
    string modifiedAt; /// Member timestamp when available.
    /// Raw file checksums when deep archive inspection persisted them.
    CheckSums checkSums;
    /// Content blob ID when the member has a complete persisted fingerprint.
    long contentBlobId;
}

/** Torrent file projection for lazy detail views. */
struct RepositoryTorrentFile
{
    long id; /// Stable torrent-file row identity.
    string relativePath; /// Path relative to the torrent root.
    ulong size; /// Declared member size in bytes.
}

/** Bounded archive-entry query. */
struct RepositoryArchiveQuery
{
    long blobId; /// Content blob that owns the archive index.
    size_t offset; /// Zero-based entry offset.
    size_t limit = 250; /// Maximum number of entries to return.
}

/** Bounded torrent-file query. */
struct RepositoryTorrentQuery
{
    long blobId; /// Content blob that owns the torrent manifest.
    size_t offset; /// Zero-based entry offset.
    size_t limit = 250; /// Maximum number of entries to return.
}

/** Stable ordering for repository file pages. */
enum RepositoryFileSortOrder : int
{
    pathAscending = 0, ///< Root-relative path ascending.
    pathDescending = 1, ///< Root-relative path descending.
    sizeAscending = 2, ///< Content size ascending, path as tie-breaker.
    sizeDescending = 3, ///< Content size descending, path as tie-breaker.
}

/** Query options for bounded file children reads. */
struct RepositoryFileQuery
{
    /// Directory ID; zero denotes files directly below the repository root.
    long directoryId;
    size_t offset; /// Zero-based result offset when no keyset cursor is used.
    size_t limit = 250; /// Maximum number of files to return.
    string text; /// Optional path text filter.
    bool caseSensitive; /// Apply `text` case-sensitively.
    bool video; /// Require a video media stream.
    bool audio; /// Require an audio media stream.
    bool image; /// Require an image media stream.
    bool textStream; /// Require a text/subtitle media stream.
    bool mediaNegated; /// Invert the combined media-stream condition.
    bool fileType; /// Require file-type metadata.
    bool archive; /// Require archive metadata.
    bool torrent; /// Require torrent metadata.
    /// Exclude references currently marked missing on disk.
    bool availableOnly;
    /// Include indexed archive members in child-file queries.
    bool includeArchiveMembers;
    RepositoryFileSortOrder sortOrder = RepositoryFileSortOrder.pathAscending; ///< Stable page ordering.
    /// Keyset cursor path, interpreted using `sortOrder`.
    string afterPath;
    long afterId; /// Keyset cursor reference ID.
    ulong afterSize; /// Keyset cursor size for size orderings.
    bool beforeCursor; /// Page backward from the keyset cursor.
}

/** Opaque position in a stable repository file sequence. */
struct RepositoryFileCursor
{
    string relativePath; /// Root-relative path at the cursor.
    long id; /// File-reference ID at the cursor.
    ulong size; /// Content size used by size orderings.
}

/** One bounded file result chunk and its continuation state. */
struct RepositoryFilePage
{
    RepositoryFile[] files; /// File rows in the requested stable order.
    RepositoryFileCursor nextCursor; /// Cursor for the following page.
    bool hasMore; /// Additional rows follow this page.
}

/** Query options for bounded repository catalog reads. */
struct RepositoryQueryOptions
{
    /// Zero-based result offset.
    size_t offset;
    /// Maximum number of blobs to return.
    size_t limit = 250;
    /// Path text filter; caseSensitive affects paths, not binary SHA1 equality.
    string text;
    bool caseSensitive; /// Apply `text` case-sensitively.
    /// Require a video media stream.
    bool video;
    /// Require an audio media stream.
    bool audio;
    /// Require an image media stream.
    bool image;
    /// Require a text/subtitle media stream.
    bool textStream;
    /// Invert the combined media stream condition.
    bool mediaNegated;
    /// Require file type metadata.
    bool fileType;
    /// Require archive metadata.
    bool archive;
    /// Require torrent metadata.
    bool torrent;
    /// Restrict the result to these blob ids; empty means no restriction.
    long[] blobIds;
    /// Stable keyset position for forward-only catalog iteration.
    long afterBlobId;
    bool useCursor; /// Use `afterBlobId` instead of `offset` when true.
    /// Restrict results to content with at least one file reference.
    bool referencedOnly;
}

/** A bounded repository page with stable blob identities. */
struct RepositoryBlobPage
{
    NamedBinaryBlob[] blobs; /// Blob payloads in stable cursor order.
    long[] blobIds; /// Stable blob IDs matching `blobs`.
    RepositoryBlobFlags[] flags; /// Presence flags matching `blobs`.
    size_t total; /// Total matching blobs before paging.
    long nextCursor; /// Cursor for the following page; zero when exhausted.
    bool hasMore; /// Additional blobs follow this page.
}

/** Presence flags for one repository blob summary. */
struct RepositoryBlobFlags
{
    bool hasMedia; /// One or more media streams exist.
    bool hasVideo; /// A video stream exists.
    bool hasAudio; /// An audio stream exists.
    bool hasImage; /// An image stream exists.
    bool hasText; /// A text/subtitle stream exists.
    bool hasFileType; /// File-type metadata exists.
    bool hasArchive; /// Archive metadata exists.
    bool hasTorrent; /// Torrent metadata exists.
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

/** Analysis summary plus cooperative-cancellation outcome. */
struct AnalysisExecutionResult
{
    AnalysisSummary summary; /// Counters collected by the analysis.
    bool cancelled; /// True when cooperative cancellation stopped the analysis.
    bool committed; /// True when the analysis committed its changes.
}

/** One read-only group of blobs with identical complete checksums. */
struct RepositoryDuplicateGroup
{
    /// Common payload size for all blobs in the group.
    size_t fileSize;
    /// Stable repository blob IDs belonging to the duplicate group.
    long[] blobIds;
}
