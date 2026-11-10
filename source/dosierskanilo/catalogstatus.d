/** Aggregate, read-only status reporting for catalog backends.
 *
 * The status model is storage-neutral. `CatalogBackend` implementations that
 * can report efficient aggregate counters implement `CatalogStatusProvider`;
 * callers must fall back to a basic report when the optional interface is not
 * available.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.catalogstatus;

import dosierskanilo.operations : OperationStorageMode;

/** Aggregate counters and storage facts for one catalog source.
 *
 * Reference counters include physical files and virtual archive members.
 * Metadata counters count content blobs, not references. Size counters use the
 * physical references only, so archive members that duplicate container bytes
 * are not counted twice.
 */
struct CatalogStatus
{
    /// Storage mode selected when the backend was opened.
    OperationStorageMode storageMode;
    /// Repository root or JSON catalog path.
    string sourcePath;
    /// SQLite database path; empty for JSON catalogs.
    string databasePath;
    /// Repository schema version or JSON catalog version.
    ulong schemaVersion;
    /// Stored creation timestamp; empty when the format has none.
    string createdAt;
    /// Last catalog update or catalog-file modification timestamp.
    string updatedAt;
    /// MediaInfo version stored with the catalog; empty when unknown.
    string mediaInfoVersion;
    /// `file` utility version stored with the catalog; empty when unknown.
    string fileUtilityVersion;
    /// Number of non-null content blobs.
    size_t blobCount;
    /// Number of all file references, including virtual archive members.
    size_t referenceCount;
    /// Number of non-virtual file references.
    size_t physicalReferenceCount;
    /// Number of virtual archive-member references.
    size_t archiveMemberCount;
    /// Number of known directories.
    size_t directoryCount;
    /// Sum of the sizes of physical references in bytes.
    ulong aggregateSize;
    /// Physical references marked unavailable or missing on disk.
    size_t missingReferenceCount;
    /// Blobs with a complete MD5/SHA1/XXH64 digest set.
    size_t checksumBlobCount;
    /// Blobs with a non-empty stored file type.
    size_t fileTypeBlobCount;
    /// Blobs with a stored media signature.
    size_t mediaBlobCount;
    /// Blobs with a known archive index.
    size_t archiveBlobCount;
    /// Blobs with torrent metadata.
    size_t torrentBlobCount;
    /// Duplicate groups with complete digests and at least one reference.
    size_t duplicateGroupCount;
    /// SQLite database or JSON catalog size in bytes.
    ulong catalogSize;
    /// SQLite write-ahead log size in bytes; zero when absent or not SQLite.
    ulong walSize;
    /// SQLite shared-memory file size in bytes; zero when absent or not SQLite.
    ulong sharedMemorySize;
    /// Number of regular files in the repository backup directory.
    size_t backupCount;
    /// Catalog load or validation error; empty when the source is readable.
    string error;
    /// Whether directory and availability counters are reliable.
    bool treeStatisticsAvailable;
}

/** Optional backend capability for aggregate catalog status.
 *
 * Implementations should report counters from one consistent read snapshot and
 * avoid materializing complete paged result sets.
 */
interface CatalogStatusProvider
{
    /** Return aggregate counters and storage facts for this backend.
     *
     * Returns: The current catalog status.
     * Throws: `CatalogBackendException` when the backend is closed or the
     *     aggregate query fails.
     */
    CatalogStatus catalogStatus();
}
