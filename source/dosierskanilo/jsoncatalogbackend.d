/** JSON v0-v5 adapter for the storage-neutral catalog contract.
 *
 *
 * The class is assembled from mixin templates; each mixin lives in its own module.
 *
 * Authors: Carsten Schlote, schlote@vahanus.net
 * Copyright: Carsten Schlote, licensed under GPL-3.0-only
 * License: GPL-3.0-only
 */
module dosierskanilo.jsoncatalogbackend;

import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.conv : to;
import std.exception : enforce;
import std.datetime.systime : SysTime;
import std.file : exists, getSize, timeLastModified;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    isAbsolute,
    dirName, isAbsolute;
import std.string : replace, split, toLower;
import std.uuid : randomUUID;

import dosierarkivo.archive : appendArchiveVirtualPath,
    archiveDisplayBaseName, archivePathEscapeSequence,
    archivePathMatchesText, archivePathSeparator,
    ArchiveVirtualPathLayer, escapeArchiveVirtualPath,
    nativePathToStoragePath, normalizeArchiveEntryPath,
    parseArchiveVirtualPath, ParsedArchiveVirtualPath;
import dosierskanilo.catalogbackend;
import dosierskanilo.catalogstatus : CatalogStatus, CatalogStatusProvider;
import dosierskanilo.logging : logLineVerbose;
import dosierskanilo.membercontentcache : MemberContentCancelledException,
    MemberContentLease;
import dosierskanilo.memberextraction : ArchiveExtractionStep,
    extractArchiveMember;
import dosierskanilo.metadata.mediainfosig : MediaInfoSig;
import dosierskanilo.model.archivespec : ArchiveSpec;
import dosierskanilo.model.checksums : CheckSums;
import dosierskanilo.model.filespec : FileSpec;
import dosierskanilo.model.namedbinaryblob : DATA_CLASS_VERSION3,
    DATA_CLASS_VERSION4, DATA_CLASS_VERSION5, NamedBinaryBlob, NamedBinaryBlobCatalog,
    deserializeDataClassJsonWrapperFile, serializeDataClassWrapperFile;
import dosierskanilo.operationlease : TargetCatalogReplacementLease,
    TargetWriteLease;
import dosierskanilo.repository.types : JsonImportOptions, RepositoryBlobPage,
    RepositoryBlobFlags, RepositoryDuplicateGroup, RepositoryInfo,
    RepositoryQueryOptions;
import dosierskanilo.operationrunner;
import dosierskanilo.service.jsonoperations : JsonAnalysisApplication,
    JsonScanApplication, analyzeJsonCatalogInto, commitJsonCatalog,
    commitJsonCatalogUnderLease, normalizeJsonCatalogPaths,
    scanJsonCatalogInto;
import dosierskanilo.operations : AnalysisOperationRequest, MetadataOperationRequest,
    OperationControl, OperationErrorCode, OperationKind, OperationPhase,
    OperationProgress, OperationResult, OperationState, OperationStorageMode,
    OperationTarget,
    ScanOperationRequest;
import dosierskanilo.service.jsonoperations : commitJsonCatalog;

import dosierskanilo.jsonsession : JsonBackendSession;
import dosierskanilo.jsontree : JsonTreeQueries;
import dosierskanilo.jsoncontent : JsonContentQueries;
import dosierskanilo.jsonindex : JsonIndexBuilding;
import dosierskanilo.jsoncatalogdocument : JsonCatalogDocument;

/** Build a cheap on-disk fingerprint for a JSON catalog file.
 *
 * Params:
 *     path = Catalog file path.
 * Returns: A `size:mtime` fingerprint, or an empty string when the file does
 *     not exist.
 */
package string catalogFileFingerprint(string path)
{
    import std.file : exists, getSize, timeLastModified;

    if (!exists(path))
        return "";
    return getSize(path).to!string ~ ":"
        ~ timeLastModified(path).stdTime.to!string;
}

/**
 * One resolved catalog file reference and its relationship to the bound
 * source root.
 *
 * The same catalog specification can resolve differently with and without
 * a filesystem root, so this is a per-index value rather than a property of
 * the specification.
 */
package struct JsonLocation
{
    /// Canonical key used to deduplicate locations and prune path maps.
    string identityKey;
    /// Display path relative to the source root, including archive virtual layers.
    string relativePath;
    /// Physical container path relative to the source root, without virtual layers.
    string physicalRelativePath;
    /// Whether the resolved physical path lies inside the bound source root.
    bool isInSourceRoot;
    /// Whether `relativePath` adds archive virtual layers over the physical path.
    bool isVirtual;
    /// Parsed archive layers applied on top of the physical path.
    ArchiveVirtualPathLayer[] virtualEntries;
    /// Catalog file specification this location was resolved from.
    FileSpec spec;
}

/**
 * Deferred version-5 archive member reference collected while indexing.
 *
 * Version-5 catalogs store member references as ordinary file specifications
 * with virtual paths. They are gathered first and folded into the container
 * archive index once all containers are known.
 */
package struct V5JsonReference
{
    /// Virtual display path of the member reference.
    string relativePath;
    /// Physical container path without virtual layers.
    string physicalRelativePath;
    /// Content token of the blob the member resolves to.
    string contentToken;
    /// Archive layers from the physical container down to the member.
    ArchiveVirtualPathLayer[] entries;
    /// Member size in bytes as stored in the catalog.
    ulong size;
    /// Member modification timestamp string as stored in the catalog.
    string modifiedAt;
}

/**
 * Archive member selected for inclusion in a subset export.
 *
 * Only the fields needed to add the member reference to the exported blob are
 * retained.
 */
package struct JsonMemberExportReference
{
    /// Content token of the member's payload.
    string contentToken;
    /// Path written into the exported file specification.
    string relativePath;
    /// Modification timestamp written into the exported specification.
    string modifiedAt;
}

/**
 * Page window into an ordered result sequence together with its cursors.
 *
 * `start` is inclusive and `end` is exclusive.
 */
package struct CatalogSlice
{
    /// Index of the first item in the page.
    size_t start;
    /// Index one past the last item in the page.
    size_t end;
    /// Forward continuation; valid only when `hasMore` is true.
    CatalogPageCursor nextCursor;
    /// Backward continuation; valid only when `hasPrevious` is true.
    CatalogPageCursor previousCursor;
    /// Whether more items follow this page.
    bool hasMore;
    /// Whether items precede this page.
    bool hasPrevious;
}

/**
 * One archive member paired with the index of its container file row.
 *
 * The container row index lets availability be refreshed from the container
 * while serving member pages.
 */
package struct ArchiveMemberRow
{
    /// Catalog file row representing the archive member.
    CatalogFile file;
    /// Index into the backend's `fileRows` of the physical container.
    size_t containerRow;
}

/**
 * Cached archive-member rows for one directory plus lazily built sort orders.
 *
 * The index arrays contain positions into `rows` and are built on the first
 * matching size-order request, so path-order queries do not pay for the extra
 * sorts.
 */
package struct ArchiveMemberRows
{
    /// Member rows sorted by relative path.
    ArchiveMemberRow[] rows;
    /// Positions into `rows` ordered by ascending size, then path.
    size_t[] sizeAscending;
    /// Positions into `rows` ordered by descending size, then path.
    size_t[] sizeDescending;
    /// Whether `sizeAscending` has been built.
    bool sizeAscendingReady;
    /// Whether `sizeDescending` has been built.
    bool sizeDescendingReady;

    /** Build the ascending size order on first use. */
    void ensureSizeAscending()
    {
        if (sizeAscendingReady)
            return;
        sizeAscending.length = rows.length;
        foreach (index; 0 .. rows.length)
            sizeAscending[index] = index;
        sizeAscending.sort!((left, right) {
            const leftFile = rows[left].file;
            const rightFile = rows[right].file;
            return leftFile.size < rightFile.size
                || (leftFile.size == rightFile.size
                    && leftFile.relativePath < rightFile.relativePath);
        });
        sizeAscendingReady = true;
    }

    /** Build the descending size order on first use. */
    void ensureSizeDescending()
    {
        if (sizeDescendingReady)
            return;
        sizeDescending.length = rows.length;
        foreach (index; 0 .. rows.length)
            sizeDescending[index] = index;
        sizeDescending.sort!((left, right) {
            const leftFile = rows[left].file;
            const rightFile = rows[right].file;
            return leftFile.size > rightFile.size
                || (leftFile.size == rightFile.size
                    && leftFile.relativePath < rightFile.relativePath);
        });
        sizeDescendingReady = true;
    }
}

/** Deep-copy a JSON catalog so an operation can be applied transactionally.
 *
 * Params:
 *     source = Catalog to copy.
 * Returns: A catalog whose blobs and mutable metadata are independent of the
 *     source.
 */
package NamedBinaryBlobCatalog cloneCatalog(NamedBinaryBlobCatalog source)
{
    NamedBinaryBlob[] records;
    records.reserve(source.dataArray.length);
    foreach (blob; source.dataArray)
        records ~= blob is null ? null : blob.dup();
    auto result = NamedBinaryBlobCatalog(source.dataVersion, records);
    result.mediaInfoVersion = source.mediaInfoVersion;
    result.fileUtilityVersion = source.fileUtilityVersion;
    return result;
}

/** JSON-backed catalog adapter for legacy and version-5 catalogs. */
final class JsonCatalogBackend : CatalogBackend, CatalogStatusProvider
{
package:
    /// Normalized operation target the backend was opened with.
    OperationTarget backendTarget;
    /// Bound filesystem root, or an empty string when the source is unbound.
    string sourceRoot;
    /// Random per-instance token that prefixes emitted content and reference IDs.
    string sourceToken;
        /// In-memory catalog document currently indexed.
        NamedBinaryBlobCatalog catalog;
    /// Load failure message; empty when the catalog loaded successfully.
    string catalogLoadError;
    /// Whether `close` has been called on this backend.
    bool closed;
    /// On-disk fingerprint captured when the catalog was loaded.
    string loadFingerprint;
    /// Whether directory and file-reference queries can be served.
    bool treeQueriesAvailable;
    /// Whether at least one torrent lacks a persisted file list.
    bool torrentEntryDetailsUnavailable;
    /// Counter used to allocate unique content and reference identities.
    size_t nextIdentity;
    /// Incremented on every index rebuild and embedded in cursor tokens.
    size_t indexGeneration;

    /// Strong fingerprint key to content token, carried across rebuilds.
    string[string] contentTokenByFingerprint;
    /// Relative path to content token from the previous index.
    string[string] contentTokenByPath;
    /// Fingerprint recorded for a path in the previous index.
    string[string] oldFingerprintByPath;
    /// File size recorded for a path in the previous index.
    ulong[string] oldSizeByPath;
    /// Stable reference token keyed by relative virtual path.
    string[string] referenceTokenByPath;

    /// Indexed physical file references, sorted by relative path.
    CatalogFile[] fileRows;
    /// Indexed directories, sorted by relative path.
    CatalogDirectory[] directoryRows;
    /// Lazily built file-row indices ordered by ascending size.
    size_t[] sizeAscendingOrder;
    /// Lazily built file-row indices ordered by descending size.
    size_t[] sizeDescendingOrder;
    /// Cached member rows keyed by directory ID token.
    ArchiveMemberRows[string] archiveMemberRowsByDirectory;
    /// Content snapshots keyed by content token.
    CatalogContentSnapshot[string] contentByToken;
    /// Archive entries keyed by container content token.
    CatalogArchiveEntry[][string] archiveEntriesByToken;
    /// Torrent file lists keyed by content token.
    CatalogTorrentManifestEntry[][string] torrentEntriesByToken;
    /// Catalog blob index keyed by physical file relative path.
    size_t[string] blobIndexByRelativePath;
    /// Catalog blob index keyed by content token.
    size_t[string] blobIndexByContentToken;
    /// Content token for each catalog blob index; empty when unassigned.
    string[] contentTokenByBlobIndex;
    /// Lazily created document session shared by all callers.
    JsonCatalogDocument documentSession;
    /// Original file specification keyed by relative path.
    FileSpec[string] fileSpecByRelativePath;
    /// Index into `directoryRows` keyed by relative path.
    size_t[string] directoryIndexByPath;

public:
    /** Open a direct JSON catalog and optionally bind its filesystem source root. */
    this(OperationTarget target)
    {
        enforceJsonTarget(target);
        backendTarget = target;
        backendTarget.catalogPath = canonicalPath(target.catalogPath);
        if (target.filesystemRoot.length > 0)
        {
            backendTarget.filesystemRoot = canonicalPath(target.filesystemRoot);
            sourceRoot = backendTarget.filesystemRoot;
        }
        sourceToken = randomUUID().toString();
        loadFingerprint = catalogFileFingerprint(backendTarget.catalogPath);
        try
            catalog = deserializeDataClassJsonWrapperFile(backendTarget.catalogPath);
        catch (Exception failure)
        {
            catalogLoadError = failure.msg;
            catalog = NamedBinaryBlobCatalog(DATA_CLASS_VERSION3, []);
        }
        /* An unrooted JSON source is analysis-only until a filesystem root is
         * bound. Deferring the tree index avoids building and discarding the
         * complete directory/reference index twice when a frontend binds the
         * suggested root immediately after opening. */
        if (catalogLoadError.length == 0 && sourceRoot.length > 0)
        {
            try
                rebuildIndex();
            catch (Exception failure)
            {
                /* Malformed virtual paths surface here as plain exceptions.
                 * Keep the source readable but disable tree queries instead of
                 * letting an untyped error escape the factory. */
                catalogLoadError = failure.msg;
                clearIndex();
            }
        }
    }

    mixin JsonBackendSession;
    mixin JsonTreeQueries;
    mixin JsonContentQueries;
    mixin JsonIndexBuilding;
}


/** Explicit factory for direct JSON catalog sources. */
final class JsonCatalogBackendFactory : CatalogBackendFactory
{
    /**
     * Open a JSON catalog backend for an explicit JSON target.
     *
     * Params:
     *     target = Target describing the catalog to open.
     * Returns: A new backend bound to the target.
     * Throws: `CatalogBackendException` with
     *     `CatalogBackendErrorCode.unsupportedOperation` unless the target mode is
     *     `OperationStorageMode.jsonCatalog`.
     */
    override CatalogBackend open(OperationTarget target)
    {
        if (target.mode != OperationStorageMode.jsonCatalog)
            throw new CatalogBackendException(CatalogBackendErrorCode.unsupportedOperation,
                "JsonCatalogBackendFactory only opens explicit JSON targets.");
        return new JsonCatalogBackend(target);
    }
}
