/** Persistent repository access for DosierSkanilo.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.repository.repository;

import d2sqlite3;

import std.algorithm.iteration : uniq;
import std.algorithm.sorting : sort;
import std.array : array;
import std.datetime.systime : Clock;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, copy, dirEntries, exists, getSize, isDir, isFile,
    mkdirRecurse, remove, rename;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName, isAbsolute;
import std.string : empty, endsWith, replace, startsWith, toLower;
import std.stdio : File;
import std.typecons : Nullable;

import dosierarkivo.archive : archivePathSeparator,
    escapeArchiveVirtualPath, nativePathToStoragePath;
import dosierskanilo.catalogstatus : CatalogStatus;
import dosierskanilo.model.namedbinaryblob : NamedBinaryBlob;
import dosierskanilo.operations : OperationControl, OperationStorageMode,
    OperationTarget;
import dosierskanilo.operationlease : TargetWriteLease;
import dosierskanilo.repository.errors;
import dosierskanilo.repository.filesystem : isUnsupportedRepositoryFilesystemType,
    repositoryFilesystemType;
import dosierskanilo.repository.analysis : analyzeRepositoryControlled;
import dosierskanilo.repository.analysis : queryDuplicateGroups;
import dosierskanilo.repository.metadata : updateRepositoryMetadataControlled;
import dosierskanilo.repository.schema : initialSchema, migrate;
import dosierskanilo.repository.scanner : scanRepositoryControlled;
import dosierskanilo.repository.transfer : currentTimestamp, exportCatalogJsonControlled,
    importCatalogJsonControlled;
import dosierskanilo.repository.catalogreads : countCatalogQueryFromDatabase,
    loadBlobDetailsFromDatabase, loadBlobFingerprintFromDatabase, loadCatalogFromDatabase,
    loadCatalogPageFromDatabase, loadCatalogQueryPageFromDatabase,
    loadCatalogQueryPageWithIdsFromDatabase;
import dosierskanilo.repository.referencequeries : archiveEntrySummaryFromDatabase,
    countPhysicalFileReferences, listArchiveEntriesFromDatabase, listDirectoriesFromDatabase,
    listFilesFromDatabase, listFilesPageFromDatabase, listTorrentFilesFromDatabase,
    loadArchiveEntryFromDatabase, loadFileReferenceFromDatabase, loadRootSummaryFromDatabase;
import dosierskanilo.repository.types;

import dosierskanilo.repository.lifecycle : RepositoryLifecycle, canonicalDirectory, escapeLogValue;
import dosierskanilo.repository.jsontransfer : RepositoryTransfer;
import dosierskanilo.repository.queries : RepositoryQueries;
import dosierskanilo.repository.passwords : RepositoryPasswords, passwordRelativePath;
import dosierskanilo.repository.operations : RepositoryOperations;

/** A connection to one `.dosierskanilo` repository. */
class Repository
{
package:
    /// Open SQLite connection owned by this handle.
    Database database;
    /// Paths derived from the repository root.
    RepositoryPaths repositoryPaths;
    /// Whether this handle is still open and usable.
    bool openState;

    /** Construct a handle from an already opened database and its paths. */
    this(Database database, RepositoryPaths repositoryPaths)
    {
        this.database = database;
        this.repositoryPaths = repositoryPaths;
        this.openState = true;
    }

public:
    mixin RepositoryLifecycle;

    mixin RepositoryTransfer;

    mixin RepositoryQueries;

    mixin RepositoryPasswords;

    mixin RepositoryOperations;

}
